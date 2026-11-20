local skynet = require "skynet"
local mongo = require "skynet.db.mongo"
local assert = assert
local sformat = string.format
local MongoCenterDb = assert(load("return " .. skynet.getenv("mongo_log_db"))())
local is_testserver = skynet.getenv("is_testserver") == "true"

local queue = require "skynet.queue"
CS = queue()

CacheCollLogs = assert(CacheCollLogs)

DbObj = false
local function _GetDb()
	if DbObj then
		return DbObj
	end
	local mgClient = mongo.client({
		host = MongoCenterDb.host,
		port = MongoCenterDb.port,
	})
	DbObj = mgClient[MongoCenterDb.dbname]
	return DbObj
end
function GetDb()
	return CS(_GetDb)
end

function WriteDb(collName, doc, isNotBson)
	local collObj = GetDb()[collName]
	if isNotBson then
		return collObj:raw_safe_insert(doc)
	else
		return collObj:safe_insert(doc)
	end
end

function DoOnceWriteLog()
	for collName, collCacheLogs in pairs(CacheCollLogs) do
		local collObj = GetDb()[collName]
		if collObj then
			-- 先试一下 collObj 能不能get出来，若不能则跳过该集合的日志dump操作。
			for _, bsonDoc in ipairs(collCacheLogs) do
				-- 一般来讲，不存在因为bsonDoc的报错。
				TryCall(WriteDb, collName, bsonDoc, true)
			end
			CacheCollLogs[collName] = nil
			if is_testserver then
				skynet.error(sformat("logdb collection:[%s] logs:[%s] dump finish", collName, #collCacheLogs))
			end
		end
	end
end