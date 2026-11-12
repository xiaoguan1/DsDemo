local skynet = require "skynet"
local string = string
local sformat = string.format
local debug = debug
local traceback = debug.traceback
local ostime = os.time

local PROXYSVR = Import("game/global/rpc/proxysvr.lua")
local GAMELOG_SVR = false

local LOG_LEVEL = LOG_LEVEL

local function LogToDb(collName, level, logDoc)
	GAMELOG_SVR = GAMELOG_SVR or PROXYSVR.GetProxyByServiceName("gamelog")
	if GAMELOG_SVR then
		GAMELOG_SVR.send.writedblog(collName, level, logDoc)
	else
		skynet.error(sformat("not find gamelog service, logDoc:%s traceback:%s",
			tool.dump(logDoc), traceback()))
	end
end

function _DBLOG(roleObj, collName, logDoc)
	-- 先搁置roleObj
	assert(not logDoc.log_time)	-- 该字段不能被占用
	assert(roleObj and collName)
	logDoc.time = logDoc.time or ostime()
	logDoc.log_time = ostime()
	LogToDb(collName, LOG_LEVEL.WRITE_DELAY, logDoc)
end

function _IMM_DBLOG(roleObj, collName, logDoc)
	-- 先搁置roleObj
	assert(not logDoc.log_time)	-- 该字段不能被占用
	assert(roleObj and collName)
	logDoc.time = logDoc.time or ostime()
	logDoc.log_time = ostime()
	LogToDb(collName, LOG_LEVEL.WRITE_NOW, logDoc)
end
