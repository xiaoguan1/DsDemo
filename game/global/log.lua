-- 相关资料笔记 有道云搜索："控制台终端颜色输出（日志）"
local skynet = require "skynet"
local posix = require "posix"
local debug = debug
local traceback = debug.traceback
local table = table
local tconcat = table.concat
local os_date = os.date
local print = print
local sformat = string.format
local logStdin = skynet.getenv("log_stdin") == "true"
local nodename = assert(skynet.getenv("node_name"))
local HEADER = "\27"
local END_FORMAT = "\27[0m"
local PROXYSVR = Import("game/global/rpc/proxysvr.lua")
local GAMELOG_SVR = false
local tpack = table.pack

-- 是否为测试服
local is_testserver = skynet.getenv("is_testserver") == "true"

local LOG_LEVEL = LOG_LEVEL

local _INFO_LOG_PATH = "./log/" .. nodename .. "/info/"
local _DEBUG_LOG_PATH = "./log/" .. nodename .. "/debug/"
local _WARN_LOG_PATH = "./log/" .. nodename .. "/warn/"
local _ERROR_LOG_PATH =	"./log/" .. nodename .. "/error/"
local _MEM_LOG_PATH = "./log/" .. nodename .. "/mem/"
local _ERROR_A_ALARM_PATH = "./log/" .. nodename .. "/runtime/login_alarm/"
local _LOG_EVENT_PATH = "./log/" .. nodename .. "/log_event/%s/%s"

local SERVICE_INFO = sformat("[:%08x %s] ", skynet.self(), SERVICE_NAME)

-- 被调用的函数信息
local _FILE_INFO_T = {
	SERVICE_INFO,
	"<", "nil", ":", "nil", ">",
}
local function FileInfo(deep)
	local dInfo = debug.getinfo(deep or 3, "Sl")
	_FILE_INFO_T[3] = dInfo.short_src
	_FILE_INFO_T[5] = dInfo.currentline
	return tconcat(_FILE_INFO_T)
end


-- 输出格式以及颜色
local _LEVEL_COLOR = {
	[1] = LOG_NORMAL,
	[2] = LOG_WARNING,
	[3] = LOG_ERROR,
	[4] = LOG_MEM,
	[5] = LOG_EVENT,
	[6] = LOG_DEBUG,
}
for k, color in pairs(_LEVEL_COLOR) do
	_LEVEL_COLOR[k] = HEADER .. color
end

local function _info_context(fileInfo, msg)
	return tconcat({
		os_date("[%Y-%m-%d %H:%M:%S]"),
		"[INFO]",
		fileInfo,
		msg,
	}, " ")
end
local function _debug_context(fileInfo, msg)
	return tconcat({
		os_date("[%Y-%m-%d %H:%M:%S]"),
		"[DEBUG]",
		fileInfo,
		msg,
	}, " ")
end
local function _warn_context(fileInfo, msg)
	return tconcat({
		os_date("[%Y-%m-%d %H:%M:%S]"),
		"[WARN]",
		fileInfo,
		msg,
	}, " ")
end
local function _error_context(fileInfo, msg)
	return tconcat({
		os_date("[%Y-%m-%d %H:%M:%S]"),
		"[ERROR]",
		fileInfo,
		msg,
	}, " ")
end
local function _mem_context(fileInfo, msg)
	return tconcat({
		os_date("[%Y-%m-%d %H:%M:%S]"),
		"[MEM_ALARM]",
		fileInfo,
		msg,
	}, " ")
end
local function _log_event_context(fileInfo, ...)
	local p = table.pack(...)
	local t = {
		os_date("[%Y-%m-%d %H:%M:%S]"),
		"[LOG_EVENT]",
		fileInfo,
	}
	for i = 1, p.n do
		table.insert(t, tostring(p[i]))
	end
	return tconcat(t, " ")
end

-- 控制台打印
local function _log_print(level, context)
	local color = level and _LEVEL_COLOR[level]
	assert(color, "level is error!")
	print(tconcat({ color, context, END_FORMAT, }))
end

local function LogToFile(pfile, level, logContext)
	GAMELOG_SVR = GAMELOG_SVR or PROXYSVR.GetProxyByServiceName("gamelog")
	if GAMELOG_SVR then
		GAMELOG_SVR.send.writefilelog(pfile, level, logContext)
	else
		skynet.error(sformat("not find gamelog service, log:%s traceback:%s", logContext, traceback()))
	end
end

---- 外部接口 ------------------------------------------------------------------------

function _INFO(...)
	local logContext = _info_context(FileInfo(), ...)
	if logStdin then
		_log_print(1, logContext)
	end
	local cfile = sformat("%s%s.log", _INFO_LOG_PATH, os_date("%Y%m%d"))
	LogToFile(cfile, LOG_LEVEL.WRITE_DELAY, logContext)
end
function _INFO_F(fmt, ...)
	local logContext = _info_context(FileInfo(), sformat(fmt, ...))
	if logStdin then
		_log_print(1, logContext)
	end
	local cfile = sformat("%s%s.log", _INFO_LOG_PATH, os_date("%Y%m%d"))
	LogToFile(cfile, LOG_LEVEL.WRITE_DELAY, logContext)
end

function _DEBUG(...)
	if not is_testserver then
		return
	end
	local logContext = _debug_context(FileInfo(), ...)
	_log_print(6, logContext)
	local cfile = sformat("%s%s.log", _DEBUG_LOG_PATH, os_date("%Y%m%d"))
	LogToFile(cfile, LOG_LEVEL.WRITE_DELAY, logContext)
end
function _DEBUG_F(fmt, ...)
	if not is_testserver then
		return
	end
	local logContext = _debug_context(FileInfo(), sformat(fmt, ...))
	_log_print(6, logContext)
	local cfile = sformat("%s%s.log", _DEBUG_LOG_PATH, os_date("%Y%m%d"))
	LogToFile(cfile, LOG_LEVEL.WRITE_DELAY, logContext)
end


function _WARN(...)
	local logContext = _warn_context(FileInfo(), ...)
	if logStdin then
		_log_print(2, logContext)
	end
	local cfile = sformat("%s%s.log", _WARN_LOG_PATH, os_date("%Y%m%d"))
	LogToFile(cfile, LOG_LEVEL.WRITE_DELAY, logContext)
end
function _WARN_F(fmt, ...)
	local logContext = _warn_context(FileInfo(), sformat(fmt, ...))
	if logStdin then
		_log_print(2, logContext)
	end
	local cfile = sformat("%s%s.log", _WARN_LOG_PATH, os_date("%Y%m%d"))
	LogToFile(cfile, LOG_LEVEL.WRITE_DELAY, logContext)
end


-- local function _L_ERROR(deep, ...)
-- 	local cfile = sformat("%s%s.log", _ERROR_LOG_PATH, os_date("%Y%m%d"))
-- 	LogToFile(cfile, LOG_LEVEL.WRITE_DELAY, FileInfo(deep), ...)
-- end
function _ERROR(...)
	local logContext = _error_context(FileInfo(), ...)
	if logStdin then
		_log_print(3, logContext)
	end
	local cfile = sformat("%s%s.log", _ERROR_LOG_PATH, os_date("%Y%m%d"))
	LogToFile(cfile, LOG_LEVEL.WRITE_DELAY, logContext)
end
function _ERROR_F(fmt, ...)
	local logContext = _error_context(FileInfo(), sformat(fmt, ...))
	if logStdin then
		_log_print(3, logContext)
	end
	local cfile = sformat("%s%s.log", _ERROR_LOG_PATH, os_date("%Y%m%d"))
	LogToFile(cfile, LOG_LEVEL.WRITE_DELAY, logContext)
end


function _MEM_ALARM(...)
	local logContext = _mem_context(FileInfo(), ...)
	if logStdin then
		_log_print(4, logContext)
	end
	local cfile = sformat("%s%s.log", _MEM_LOG_PATH, os_date("%Y%m%d"))
	LogToFile(cfile, LOG_LEVEL.WRITE_DELAY, logContext)
end
function _MEM_ALARM_F(fmt, ...)
	local logContext = _mem_context(FileInfo(), sformat(fmt, ...))
	if logStdin then
		_log_print(4, logContext)
	end
	local cfile = sformat("%s%s.log", _MEM_LOG_PATH, os_date("%Y%m%d"))
	LogToFile(cfile, LOG_LEVEL.WRITE_DELAY, logContext)
end

-- 指定缓存文件名，记录信息！
function _LOG_EVENT(fileName, ...)
	assert(fileName)
	local logContext = _log_event_context(FileInfo(), ...)
	if logStdin then
		_log_print(5, logContext)
	end
	local cfile = sformat(_LOG_EVENT_PATH, os_date("%Y%m%d"), fileName)
	LogToFile(cfile, LOG_LEVEL.WRITE_DELAY, logContext)
end

function _LOG_EVENT_F(fileName, fmt, ...)
	assert(fileName)
	local logContext = _log_event_context(FileInfo(), sformat(fmt, ...))
	if logStdin then
		_log_print(5, logContext)
	end
	local cfile = sformat(_LOG_EVENT_PATH, os_date("%Y%m%d"), fileName)
	LogToFile(cfile, LOG_LEVEL.WRITE_DELAY, logContext)
end