-- 控制台日志（无缝世界架构精简版：仅输出到 stdout，带颜色）
-- 相关笔记：有道云搜索 "控制台终端颜色输出（日志）"
local skynet = require "skynet"
local debug = debug
local tconcat = table.concat
local os_date = os.date
local print = print
local sformat = string.format
local logStdin = skynet.getenv("log_stdin") ~= "false"
local is_testserver = skynet.getenv("is_testserver") == "true"
local SERVICE_NAME = rawget(_G, "SERVICE_NAME") or "unknown"

local HEADER = "\27"
local END_FORMAT = "\27[0m"

local SERVICE_INFO = sformat("[:%08x %s] ", skynet.self(), SERVICE_NAME)

-- 被调用的函数信息（文件:行号）
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

-- 控制台打印
local function _log_print(level, context)
	local color = _LEVEL_COLOR[level]
	assert(color, "level is error!")
	print(tconcat({ color, context, END_FORMAT }))
end

local function _context(levelName, fileInfo, ...)
	local p = table.pack(...)
	local t = {
		os_date("[%Y-%m-%d %H:%M:%S]"),
		levelName,
		fileInfo,
	}
	for i = 1, p.n do
		t[#t + 1] = tostring(p[i])
	end
	return tconcat(t, " ")
end

---- 外部接口 ------------------------------------------------------------------------

function _INFO(...)
	if logStdin then
		_log_print(1, _context("[INFO]", FileInfo(), ...))
	end
end
function _INFO_F(fmt, ...)
	if logStdin then
		_log_print(1, _context("[INFO]", FileInfo(), sformat(fmt, ...)))
	end
end

function _DEBUG(...)
	if logStdin and is_testserver then
		_log_print(6, _context("[DEBUG]", FileInfo(), ...))
	end
end
function _DEBUG_F(fmt, ...)
	if logStdin and is_testserver then
		_log_print(6, _context("[DEBUG]", FileInfo(), sformat(fmt, ...)))
	end
end

function _WARN(...)
	if logStdin then
		_log_print(2, _context("[WARN]", FileInfo(), ...))
	end
end
function _WARN_F(fmt, ...)
	if logStdin then
		_log_print(2, _context("[WARN]", FileInfo(), sformat(fmt, ...)))
	end
end

function _ERROR(...)
	if logStdin then
		_log_print(3, _context("[ERROR]", FileInfo(), ...))
	end
end
function _ERROR_F(fmt, ...)
	if logStdin then
		_log_print(3, _context("[ERROR]", FileInfo(), sformat(fmt, ...)))
	end
end

function _MEM_ALARM(...)
	if logStdin then
		_log_print(4, _context("[MEM_ALARM]", FileInfo(), ...))
	end
end
function _MEM_ALARM_F(fmt, ...)
	if logStdin then
		_log_print(4, _context("[MEM_ALARM]", FileInfo(), sformat(fmt, ...)))
	end
end

function _LOG_EVENT(fileName, ...)
	if logStdin then
		_log_print(5, _context("[LOG_EVENT]" .. tostring(fileName), FileInfo(), ...))
	end
end
function _LOG_EVENT_F(fileName, fmt, ...)
	if logStdin then
		_log_print(5, _context("[LOG_EVENT]" .. tostring(fileName), FileInfo(), sformat(fmt, ...)))
	end
end
