-- 模块存盘接口
local skynet = require "skynet"
local string = string
local pairs = pairs
local traceback = debug.traceback
local assert = assert
local type = type
local rawset = rawset
local skyent_queue = require "skynet_queue"
CS = skyent_queue()

assert(CALLOUT)
local DB_COMMON = Import("game/global/db_common.lua")
local _LOG_EVENT = assert(_LOG_EVENT)

-- 注意：
-- 1.服务关闭的需要调用一下来存储
-- 2.恢复文件数据是可能会有重入的，所以一般尽量保证启动service就加载了所以模块，如果不能保证就要自己处理重入的问题
-- 3.每个模块的存储数据都应该为，
-- 		(1).设置__SAVE_NAME = "xxx/xxx"，例如 __SAVE_NAME = "login/login"下
--		(2).模块的env必须将MODULE_DATA设置为全局变量，例如MODULE_DATA = false
--		(2).在__init__函数中MOUDLE_DB.Register("需要保存的table或者全局变量","需要保存的table或者全局变量", 等等)

local SAVE_TIME = 8 * 60							-- 8分钟一次数据存盘
local SAVE_TIME_F = math.abs(skynet.self() + 5) 	-- 第一次存盘的时间，因为每个service时间不一样，这样就能防止扎堆
local SAVE_NORMALCNT = 5							-- 每SAVE_MODULETIME存储的个数
local SAVE_MODULETIME = 1							-- 模块数据分时存储 1秒存SAVE_NORMALCNT个模块

IS_SHUTDOWN = false
ModuleCache = {}
SaveDataTarget = {}
SaveDataQueue = { h = 1, t = 0, total = 0 }

SaveData2Sz = {
	-- [saveName] = sz,
}

local function _DumpWarn(fmt, ...)
	if _WARN_F then
		_WARN_F(fmt, ...)
	else
		local msg = string.format(fmt, ...)
		skynet.error(msg)
	end
end

local function _RestoreModuleFormDb(saveName)
	local isOk, data = pcall(DB_COMMON.Call_ModGetData, saveName)
	if isOk and data then
		local a = load("return " .. data, "unserialize module error")()
		return assert(load("return " .. data, "unserialize module error")()), #data
	else
		error("restore module error:" .. saveName)
	end
end

local function _ModuleRestore(saveName)
	local saveData = ModuleCache[saveName]
	if saveData then
		-- 一般而言，saveData只能获取一次，同服务下想要访问可以直接进行模块调用即可，其他服务想要访问这份数据可以通过rpc获得！
		error(string.format("%s repeated register, traceback:%s", saveName, traceback()))
	end

	-- 在数据库中创建，判断是否有这个数据，没有就insert into
	DB_COMMON.Send_ModCreateNexist(saveName)
	local saveData, sz = _RestoreModuleFormDb(saveName)
	if not saveData then
		return
	end

	setmetatable(saveData, {
		__newindex = function (data, k, v)
			if not SaveDataTarget[saveName] then
				SaveDataTarget[saveName] = true
				SaveDataQueue.t = SaveDataQueue.t + 1
				SaveDataQueue[SaveDataQueue.t] = saveName
			end
			return rawset(data, k, v)
		end
	})
	ModuleCache[saveName] = saveData
	SaveDataQueue.total = SaveDataQueue.total + 1
	SaveData2Sz[saveName] = sz
	return saveData, sz
end

-- 注册saveName的变量名以供存储
function Register(saveName)
	assert(not IS_SHUTDOWN, string.format("%s register fail, because is shutdown!", saveName))
	assert(type(saveName) == "string" and #saveName > 0)
	return CS(_ModuleRestore, saveName)
end

function SaveModule()
	if IS_SHUTDOWN then
		return
	end
	if SaveDataQueue.h > SaveDataQueue.t then
		return
	end

	local saveCount = math.ceil(SaveDataQueue.total * 0.3) -- 分批执行
	local h
	for i = 1, saveCount, 1 do
		if h then
			SaveDataQueue.h = SaveDataQueue.h + 1
			h = SaveDataQueue.h
		else
			h = SaveDataQueue.h
		end
		local saveName = SaveDataQueue[h]
		SaveDataQueue[h] = nil
		local saveData = saveName and ModuleCache[saveName]
		if not saveData then
			break
		end
		local salData = DB_COMMON.ModDataSerialise(saveData)
		DB_COMMON.Send_ModSave(saveName, salData)
		SaveData2Sz[saveName] = #salData
		_LOG_EVENT("module2dbsave.log", saveName, IS_SHUTDOWN)
	end
	if SaveDataQueue.h > SaveDataQueue.t then
		SaveDataQueue.h = 1
		SaveDataQueue.t = 0
	end
end


function __init__()
	-- CALLOUT.CallFre("SaveModule", SAVE_TIME)
	CALLOUT.CallFre("SaveModule", 1)
end

-- 关服处理
function Shutdown_SaveModule()
	if IS_SHUTDOWN then
		return
	end
	IS_SHUTDOWN = true

	-- 刷新ClsSave，并发送数据库进行保存
	local clsName2Data = CLSSAVE.ShutDown_SaveCls()
	for name2data in pairs(clsName2Data) do
		for saveName, salData in pairs(name2data) do
			name2data[saveName] = nil
			if ModuleCache[saveName] then
				ModuleCache[saveName] = nil
				DB_COMMON.Call_ModSave(saveName, salData)
			else
				DB_COMMON.Call_ModSaveReplace(saveName, salData)
			end
		end
		clsName2Data[name2data] = nil
	end

	-- 将全部数据发送数据库进行保存
	for saveName, saveData in pairs(ModuleCache) do
		DB_COMMON.Call_ModSave(saveName, DB_COMMON.ModDataSerialise(saveData))
	end
end

function IsShutDown()
	return IS_SHUTDOWN
end

function GetSaveData2Sz()
	return SaveData2Sz
end