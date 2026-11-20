local skynet = require "skynet"
require "skynet.manager"
local bson = require "bson"
local bson_encode =	bson.encode
local tinsert = table.insert
local string = string
local sformat = string.format

local isShutDown = false
local is_testserver = skynet.getenv("is_testserver") == "true"
local writelog_time = tonumber(skynet.getenv("writelog_time")) or 3
local writedblog_time = tonumber(skynet.getenv("writedblog_time")) or 180 -- 3分钟

CMD = {}

-- 文件日志相关缓存
CacheLogs = {}
CacheFopen = {}

-- db日志相关缓存
CacheCollLogs = {}

local LOG_LEVEL = LOG_LEVEL

-- 定时器相关回调函数 --------------------
function DealFopenTimer()
	while true do
		skynet.sleep(1000)	-- 10秒
		if isShutDown then return end
		--写文件
		TryCall(FileLog.DoCloseFopen)
	end
end

function DealWithTimer()
	while true do
		skynet.sleep(100 * writelog_time)
		if isShutDown then return end
		--写文件
		TryCall(FileLog.DoOnceWriteLog)
	end
end

function DealDbLogTimer()
	while true do
		skynet.sleep(100 * writedblog_time)
		if isShutDown then return end
		--写文件
		TryCall(DbLog.DoOnceWriteLog)
	end
end

-- dispatch CMD --------------------
function CMD.writefilelog(filePath, level, logStr)
	assert(filePath and logStr, "writefilelog args invalid")
	if level == LOG_LEVEL.WRITE_NOW then
		local isOk, errMsg = TryCall(FileLog.WriteFile, filePath, logStr)
		if is_testserver and not isOk then
			-- 测试环境下才在控制台输出相关报错
			skynet.error("CMD.writefilelog: " .. tostring(errMsg))
		end
	else
		local fileCacheLogs = CacheLogs[filePath]
		if not fileCacheLogs then
			fileCacheLogs = {}
			CacheLogs[filePath] = fileCacheLogs
		end
		tinsert(fileCacheLogs, logStr)
	end
end

function CMD.writedblog(collName, level, doc)
	assert(collName and level and next(doc), "writedblog args invalid")
	if level == LOG_LEVEL.WRITE_NOW then
		local isOk = TryCall(DbLog.WriteDb, collName, doc)
		if is_testserver and not isOk then
			-- 测试环境下才在控制台输出相关报错
			skynet.error(sformat("CMD.writefilelog doc:%s", tool.dump(doc)))
		end
	else
		local collCacheLogs = CacheCollLogs[collName]
		if not collCacheLogs then
			collCacheLogs = {}
			CacheCollLogs[collName] = collCacheLogs
		end
		local bsonDoc = bson_encode(doc)
		if bsonDoc then
			tinsert(collCacheLogs, bsonDoc)
		end
	end
end

function CMD.shutdown()
	if isShutDown then return end
	isShutDown = true
	TryCall(FileLog.DoOnceWriteLog)
	TryCall(DbLog.DoOnceWriteLog)
end

-- start service --------------------
skynet.start(function()
	skynet.dispatch("lua", function(session, _, cmd, ...)
		local f = assert(CMD[cmd])
		if cmd == "shutdown" then
			skynet.ret(skynet.pack(f(...)))
		else
			assert(session == 0)
			f(...)
		end
	end)

	FileLog = Import("tool/service/basic/gamelog/filelog.lua")
	DbLog = Import("tool/service/basic/gamelog/dblog.lua")

	skynet.timeout(0, _G.DealWithTimer)
	skynet.timeout(0, _G.DealFopenTimer)
	skynet.timeout(0, _G.DealDbLogTimer)
end)
