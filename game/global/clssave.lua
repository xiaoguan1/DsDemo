-- 模块作用：分table存盘，不用一堆数据旨在一个table里

local skynet = require "skynet"
local table = table
local tclear = table.clear
local tinsert = table.insert
local string = string
local pairs = pairs
local type = type
local assert = assert
local _ERROR = _ERROR
local _INFO_F = _INFO_F
local ostime = os.time
local sformat = string.format
local is_testserver = skynet.getenv("is_testserver") == "true"
local UTIL = Import("game/global/util.lua")
local DB_COMMON = Import("game/global/db_common.lua")
local nodename = assert(skynet.getenv("node_name"))
local posix = require "posix"

assert(MODULE_DB, "not Import MODULE_DB")
local THRESHOLD_WARN_DATALEN = 3 * 1024 * 1024 + 820 -- 内存3.8m，报警

local SAVE_SPLIT_MAXCNT = 2048	-- 最大分行数量
local SAVE_SPLIT_INITCNT = 8	-- 默认分行数量

AllClsSave = {}

local CHECK_SPLIT_SECORDS = 60 * 10	-- 10分钟检测一次

local DUMP_PATH = "./log/" .. nodename .. "/module_data/"
local DUMP_FILE = DUMP_PATH .. "%s.data"
posix.mkdir_p(DUMP_PATH)
function _DumpFile(saveName, data)
	assert(saveName and data)
	local f = io.open(sformat(DUMP_FILE, saveName), "w")
	if not f then
		_ERROR_F("clssave saveData:%s dump file fail!", saveName)
		return
	end
	f:write(data)
	f:flush()
	return true
end

local function _SizeGreaterThanX(tbl, x)
	local size = 0
	for _, _ in pairs(tbl) do
		size = size + 1
		if size > x then
			return true
		end
	end
end


DivideSave = { __ClassType = "<<dividesave class>>" }

-- 注意：此函数是有调用call的，所以要在__init__或者__startup__的时候创建存盘的对象.
--          不然不在__init__或者__startup__中创建，热更的时候又重新创建对象会出问题
-- @params : __SAVE_NAME    存盘文件名
-- @params : __SAVE_CNT     有 __SAVE_CNT 个 table 来分开序列化存盘(默认为8个)
function DivideSave:New(saveName)
	assert(type(saveName) == "string" and saveName:len() > 0)
	local o = {
		__TOTAL_DATA = {},
		__SAVE_NAME = saveName,
		__IS_MERGE = false,
		__HEAD_DATA = MODULE_DB.Register(saveName)
	}

	local headData = o.__HEAD_DATA
	if table.empty(headData) then
		headData.__SAVE_NAME = saveName
		headData.__SAVE_CNT = SAVE_SPLIT_INITCNT
	end
	assert(headData.__SAVE_NAME == saveName)
	o.__SAVE_CNT = headData.__SAVE_CNT

	local nowSplitCnt = headData.__SAVE_CNT
	local isSplit
	for i = 1, nowSplitCnt do
		o.__TOTAL_DATA[i] = {
			__SAVE_NAME = saveName .. "_" .. i,
			__DATA = {},		-- {[unique1] = {}, [unique2] = {}, ...}
		}
		local data, sz = MODULE_DB.Register(o.__TOTAL_DATA[i].__SAVE_NAME)
		o.__TOTAL_DATA[i].__DATA = data
		if sz > THRESHOLD_WARN_DATALEN then
			isSplit = true
			-- 检测分盘存储大小！
			if _SizeGreaterThanX(o.__TOTAL_DATA[i].__DATA, 1) then
				local newSplitCnt = nowSplitCnt * 2
				if newSplitCnt > SAVE_SPLIT_MAXCNT then
					_ERROR(string.format("error sz:%s > THRESHOLD_WARN_DATALEN:%s to change __SAVE_CNT, because tCnt:%s > %s in DivideSave.New:%s",
						sz, THRESHOLD_WARN_DATALEN, newSplitCnt, SAVE_SPLIT_MAXCNT, saveName
					))
				else
					_ERROR(string.format("sz:%s > THRESHOLD_WARN_DATALEN:%s to change __SAVE_CNT from %d to %d in DivideSave.New:%s",
					sz, THRESHOLD_WARN_DATALEN, nowSplitCnt, newSplitCnt, saveName
				))
				end
			else
				_ERROR(string.format("error sz:%s > THRESHOLD_WARN_DATALEN:%s to change __SAVE_CNT, because size:%s <= 1 in DivideSave.New:%s",
					sz, THRESHOLD_WARN_DATALEN, table.size(o.__TOTAL_DATA[i].__DATA), saveName
				))
			end
		end
	end

	o.__SuperClass = self		-- 标记DivideSave为父类
	o.__IsObject = ostime()		-- 标记为实例对象
	setmetatable(o, {__index = self})
	if isSplit then
		o:DoSplit()
	end
	tinsert(AllClsSave, o)
	return o
end

function DivideSave:DoSplit(isShutDown)
	local headData = assert(self.__HEAD_DATA)
	local saveName = headData.__SAVE_NAME
	local nowSplitCnt = headData.__SAVE_CNT
	local newSplitCnt = nowSplitCnt * 2
	if newSplitCnt > SAVE_SPLIT_MAXCNT then
		error(string.format("%s new split cnt:%s > %s!", saveName, newSplitCnt, SAVE_SPLIT_MAXCNT))
	end

	local tmpData = {}
	for _, v in pairs(self.__TOTAL_DATA) do
		for uniqueKey, sData in pairs(v.__DATA) do
			tmpData[uniqueKey] = sData
		end
		tclear(v.__DATA)
	end
	for i = nowSplitCnt + 1, newSplitCnt do
		self.__TOTAL_DATA[i] = { __SAVE_NAME = saveName .. "_" .. i, }
		if isShutDown then
			self.__TOTAL_DATA[i].__DATA = {}
		else
			self.__TOTAL_DATA[i].__DATA = MODULE_DB.Register(self.__TOTAL_DATA[i].__SAVE_NAME)
		end
	end

	for uniqueKey, sData in pairs(tmpData) do
		local hashNo = UTIL.HashNo(uniqueKey, newSplitCnt)
		self.__TOTAL_DATA[hashNo].__DATA[uniqueKey] = sData
	end
	headData.__SAVE_CNT = newSplitCnt
	self.__SAVE_CNT = newSplitCnt
	_INFO_F("saveName:%s add old:%s to new:%s split finish!", saveName, nowSplitCnt, newSplitCnt)
end

-- func(uniqueKey, data, ...)	注意：该函数内部不能有增加排行榜名单的，但可以删除名单，不然遍历有问题
function DivideSave:Foreach(func, ...)
	for _, _aData in pairs(self.__TOTAL_DATA) do
		for _uniqueKey, _data in pairs(_aData.__DATA) do
			if func(_uniqueKey, _data, ...) then
				return
			end
		end
	end
end

function DivideSave:Clear()
	for _, _aData in pairs(self.__TOTAL_DATA) do
		for _uniqueKey, _data in pairs(_aData.__DATA) do
			_aData.__DATA[_uniqueKey] = nil
		end
	end
end

function DivideSave:GetData(uniqueKey)
	local hNo = UTIL.HashNo(uniqueKey, self.__SAVE_CNT)
	local aData = self.__TOTAL_DATA[hNo]
	return aData and aData.__DATA[uniqueKey]
end

function DivideSave:GetOneKey(uniqueKey, key)
	local aData = self:GetData(uniqueKey)
	if aData then
		return aData[key]
	end
end

function DivideSave:SetData(uniqueKey, sData)
	local hNo = UTIL.HashNo(uniqueKey, self.__SAVE_CNT)
	self.__TOTAL_DATA[hNo].__DATA[uniqueKey] = sData
end

function DivideSave:SetOneData(uniqueKey, key, value)
	local hNo = UTIL.HashNo(uniqueKey, self.__SAVE_CNT)
	local sData = self.__TOTAL_DATA[hNo].__DATA[uniqueKey]
	if not sData then
		sData = {}
		self.__TOTAL_DATA[hNo].__DATA[uniqueKey] = sData
	end
	sData[key] = value
end

function CheckClsSplit()
	if MODULE_DB.IsShutDown() then
		return
	end
	local SaveData2Sz = MODULE_DB.GetSaveData2Sz()
	local splitList = {}
	for _, clsObj in pairs(AllClsSave) do
		local headSz = SaveData2Sz[clsObj.__SAVE_NAME]
		SaveData2Sz[clsObj.__SAVE_NAME] = nil
		if headSz and headSz >= THRESHOLD_WARN_DATALEN then
			splitList[clsObj] = true
		else
			for _, data in pairs(clsObj.__TOTAL_DATA) do
				local dataSz = SaveData2Sz[data.__SAVE_NAME]
				SaveData2Sz[data.__SAVE_NAME] = nil
				if dataSz and dataSz >= THRESHOLD_WARN_DATALEN and not splitList[clsObj] then
					splitList[clsObj] = true
				end
			end
		end
	end
	for clsObj in pairs(splitList) do
		clsObj:DoSplit()
	end
end

function __init__()
	CALLOUT.CallFre("CheckClsSplit", CHECK_SPLIT_SECORDS)
end

function GetAllClsSave()
	return AllClsSave
end

function ShutDown_SaveCls()
	-- return table | nil(需要进行分盘处理)
	local function _packData(clsObj)
		local name2data = {}
		local headData = clsObj.__HEAD_DATA
		-- 头文件仅仅只是记录一些简要的信息，绝大多数情况不会超过4M
		local salData = DB_COMMON.ModDataSerialise(headData)
		name2data[headData.__SAVE_NAME] = salData

		for _, data in pairs(clsObj.__TOTAL_DATA) do
			local salData = DB_COMMON.ModDataSerialise(data.__DATA)
			if #salData >= THRESHOLD_WARN_DATALEN then
				if _SizeGreaterThanX(data.__DATA, 1) then
					return
				else
					-- 序列化的数据长度大于4M限制！
					if is_testserver then
						error(sformat("shut down clssave saveName:%s data size:%s > %s",
							data.__SAVE_NAME, #salData, THRESHOLD_WARN_DATALEN))
					else
						-- 将超过阈值的数据写入文件中，数据库不做任何保存！
						_DumpFile(data.__SAVE_NAME, salData)
						name2data[data.__SAVE_NAME] = DB_COMMON.ModDataSerialise({})
					end
				end
			else
				name2data[data.__SAVE_NAME] = salData
			end
		end
		return name2data
	end

	local clsName2Data = {}
	for _, clsObj in pairs(AllClsSave) do
		local name2data = _packData(clsObj)
		if name2data then
			for k, v in pairs(name2data) do
				clsName2Data[k] = v
			end
		elseif name2data == nil then
			local loop = 0
			while true do
				loop = loop + 1
				if loop > 50 then
					error(string.format("%s do split fail", tool.dump(clsObj.__HEAD_DATA)))
				end
				clsObj:DoSplit(true)
				name2data = _packData(clsObj)
				if name2data then
					clsName2Data[name2data] = true
					break
				end
			end
		end
	end
	return clsName2Data
end