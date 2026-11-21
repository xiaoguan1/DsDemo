-- 模块存盘接口
-- 热更说明：ModuleCache / SaveDataQueue / SaveDataTarget 等运行期状态是模块级全局 table，
-- Import 热更时会保留旧 table 引用（不会清空），函数逻辑会被替换；
-- 但模块级常量（SAVE_TIME / SAVE_NORMALCNT / SAVE_MODULETIME）热更后仍取旧值，
-- 且 __init__ 不会重跑（定时器不重建），调整保存频率或新增定时器需重启节点。
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

local SAVE_TIME = 8 * 60							-- 8分钟一次全量标脏，兜底嵌套修改等漏标场景
local SAVE_NORMALCNT = 5							-- 每SAVE_MODULETIME最多存储的脏模块个数
local SAVE_MODULETIME = 1							-- 模块数据分时存储：1秒存SAVE_NORMALCNT个模块

IS_SHUTDOWN = false
ModuleCache = {}
SaveDataTarget = {}
SaveDataQueue = { h = 1, t = 0 }

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

-- 标脏并入队（同一模块同一时刻只占一个队列位）
local function _MarkDirty(saveName)
	if SaveDataTarget[saveName] then
		return
	end
	SaveDataTarget[saveName] = true
	SaveDataQueue.t = SaveDataQueue.t + 1
	SaveDataQueue[SaveDataQueue.t] = saveName
end

-- 同步保存并重试：超时/失败时用同一份数据重复写入是幂等的（整行覆盖）
local function _SaveWithRetry(saveName, salData)
	for i = 1, 3 do
		local isOk, ret = pcall(DB_COMMON.Call_ModSave, saveName, salData)
		if isOk and ret then
			return true
		end
		_DumpWarn("save module[%s] fail(try %d):%s", saveName, i, tostring(ret))
	end
	return false
end

local function _RestoreModuleFormDb(saveName)
	local isOk, data = pcall(DB_COMMON.Call_ModGetData, saveName)
	if isOk and data then
		local func, err = load("return " .. data, "unserialize module error")
		if not func then
			error(err)
		end
		return func(), #data
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
			_MarkDirty(saveName)
			return rawset(data, k, v)
		end
	})
	ModuleCache[saveName] = saveData
	SaveData2Sz[saveName] = sz
	return saveData, sz
end

-- 注册saveName的变量名以供存储
function Register(saveName)
	assert(not IS_SHUTDOWN, string.format("%s register fail, because is shutdown!", saveName))
	assert(type(saveName) == "string" and #saveName > 0)
	return CS(_ModuleRestore, saveName)
end

-- 从队列中取出至多 maxCount 个脏模块同步保存；返回本轮是否全部成功
local function _SaveQueued(maxCount, stopOnFail)
	local allOk = true
	for _ = 1, maxCount do
		if SaveDataQueue.h > SaveDataQueue.t then
			break
		end
		local h = SaveDataQueue.h
		local saveName = SaveDataQueue[h]
		SaveDataQueue[h] = nil
		SaveDataQueue.h = h + 1

		local saveData = saveName and ModuleCache[saveName]
		if not saveData then
			break
		end
		local salData = DB_COMMON.ModDataSerialise(saveData)
		SaveDataTarget[saveName] = nil	-- 先复位，保存期间的新修改会重新入队
		if _SaveWithRetry(saveName, salData) then
			SaveData2Sz[saveName] = #salData
			_LOG_EVENT("module2dbsave.log", saveName, IS_SHUTDOWN)
		else
			allOk = false
			_MarkDirty(saveName)	-- 失败重新入队，下一轮再试
			if stopOnFail then
				break
			end
		end
	end
	if SaveDataQueue.h > SaveDataQueue.t then
		SaveDataQueue.h, SaveDataQueue.t = 1, 0
	end
	return allOk
end

-- 存盘串行化：周期存盘与即刻存盘可能并发触发，统一用 isSaving 防重入
local isSaving = false
local function _RunSave(func, ...)
	if IS_SHUTDOWN or isSaving then
		return false
	end
	isSaving = true
	local isOk, err = pcall(func, ...)
	isSaving = false
	if not isOk then
		_DumpWarn("save module error:%s", tostring(err))
	end
	return isOk
end

-- 分时存盘：每次最多处理 SAVE_NORMALCNT 个脏模块
function SaveModule()
	_RunSave(_SaveQueued, SAVE_NORMALCNT, false)
end

-- 全量标脏：交给分时存盘逐步落库（兜底嵌套修改不触发 __newindex 的情况）
function SaveAllModule()
	_RunSave(function ()
		for saveName in pairs(ModuleCache) do
			_MarkDirty(saveName)
		end
	end)
end

-- 立即同步保存当前所有脏模块（玩家下线等时机调用）
function SaveDirtyNow()
	if IS_SHUTDOWN then
		return
	end
	-- 等待进行中的周期保存结束（最多1秒），尽量不漏掉下线玩家的数据
	for _ = 1, 100 do
		if not isSaving then
			break
		end
		skynet.sleep(1)
	end
	_RunSave(function ()
		while SaveDataQueue.h <= SaveDataQueue.t do
			if not _SaveQueued(1, true) then
				break
			end
		end
	end)
end

function __init__()
	-- 分时存盘：每 SAVE_MODULETIME 秒最多存 SAVE_NORMALCNT 个脏模块
	CALLOUT.CallFre("SaveModule", SAVE_MODULETIME)

	-- 全量标脏：每 SAVE_TIME 秒一次，首次按服务地址错峰
	local firstTime = math.abs(skynet.self() + 7) % SAVE_TIME
	if firstTime < 1 then
		firstTime = 1
	end
	CALLOUT.CallOut("SaveAllModule", firstTime)
	CALLOUT.CallFre("SaveAllModule", SAVE_TIME)
end

-- 关服处理：同步落库全部模块（单批单事务，失败退化为逐条重试）
function Shutdown_SaveModule()
	if IS_SHUTDOWN then
		return
	end
	IS_SHUTDOWN = true

	-- 刷新ClsSave（扁平结构：saveName -> salData）
	local clsSave = CLSSAVE
	if not clsSave then
		-- 业务服务未显式装载时兜底惰性装载；失败只告警，不阻塞模块数据保存
		local isOk, ret = pcall(Import, "game/global/clssave.lua")
		if isOk and ret then
			clsSave = ret
			CLSSAVE = clsSave
		else
			_DumpWarn("Shutdown_SaveModule load clssave fail:%s", tostring(ret))
		end
	end
	local clsName2Data = {}
	if clsSave then
		local isOk, ret = pcall(clsSave.ShutDown_SaveCls)
		if isOk and ret then
			clsName2Data = ret
		else
			_DumpWarn("Shutdown_SaveModule flush cls data fail:%s", tostring(ret))
		end
	end

	local saveList, seen = {}, {}
	for saveName, salData in pairs(clsName2Data) do
		saveList[#saveList + 1] = { saveName, salData }
		seen[saveName] = true
	end
	for saveName, saveData in pairs(ModuleCache) do
		if not seen[saveName] then
			local isOk, salData = pcall(DB_COMMON.ModDataSerialise, saveData)
			if isOk then
				saveList[#saveList + 1] = { saveName, salData }
			else
				_DumpWarn("Shutdown_SaveModule serialise[%s] fail:%s", saveName, tostring(salData))
			end
		end
	end

	-- 按批在单事务内提交（按数据量切批，避免超过 skynet 单包 4MB 限制）；失败退化为逐条重试
	local BATCH_MAX_BYTES = 2 * 1024 * 1024
	local batch, batchBytes = {}, 0
	local function _FlushBatch()
		if #batch == 0 then
			return
		end
		local isOk, ret = pcall(DB_COMMON.Call_ModSaveMulti, batch)
		if not (isOk and ret) then
			_DumpWarn("shutdown save batch(%d items) fail:%s, save one by one", #batch, tostring(ret))
			for _, item in ipairs(batch) do
				_SaveWithRetry(item[1], item[2])
			end
		end
		batch, batchBytes = {}, 0
	end
	for _, item in ipairs(saveList) do
		local sz = #item[2]
		if #batch > 0 and batchBytes + sz > BATCH_MAX_BYTES then
			_FlushBatch()
		end
		batch[#batch + 1] = item
		batchBytes = batchBytes + sz
	end
	_FlushBatch()
end

function IsShutDown()
	return IS_SHUTDOWN
end

function GetSaveData2Sz()
	return SaveData2Sz
end
