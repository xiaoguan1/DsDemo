------------------------------
--- 作用：文件日志
--- guanguowei/20260721
------------------------------
local skynet = require "skynet"
require "skynet.manager"
local os = os
local ostime = os.time
local io = io
local ioopen = io.open
local string = string
local sformat = string.format
local posix = require "posix"
assert(posix.mkdir_p)

local closefopen_time = tonumber(skynet.getenv("closefopen_time")) or 1	-- 默认3分钟
local is_testserver = skynet.getenv("is_testserver") == "true"
CacheFopen = assert(CacheFopen)
CacheLogs = assert(CacheLogs)

-- local function ------------------------------

-- 缓存文件路径的句柄f
local function GetFopen(filePath)
	if type(filePath) ~= "string" then
		return nil, "invalid filePath"
	end
	local temp = CacheFopen[filePath]
	if temp then
		temp.utime = ostime()	-- 更新时间
		return temp.f
	end
	posix.mkdir_p(filePath)
	local f, errMsg = ioopen(filePath, "a")
	if not f then
		return nil, errMsg
	end
	CacheFopen[filePath] = {
		ctime = ostime(), utime = ostime(),	-- 创建、更新时间
		f = f,
	}
	return f
end

function WriteFile(filePath, logStr)
	local f, errMsg = GetFopen(filePath)
	assert(f, errMsg)
	f:write(logStr)
	f:write("\n")
	f:flush()
end

function DoOnceWriteLog()
	for filePath, fileCacheLogs in pairs(CacheLogs) do
		for _, logStr in ipairs(fileCacheLogs) do
			local isOk, errMsg = TryCall(WriteFile, filePath, logStr)
			if is_testserver and not isOk then
				-- 测试环境下才在控制台输出相关报错
				skynet.error("gamelog DoOnceWriteLog: " .. tostring(errMsg))
			end
		end
		CacheLogs[filePath] = nil
	end
end

function DoCloseFopen()
	local ntime = ostime()
	for filename, temp in pairs(CacheFopen) do
		if (ntime - temp.utime) >= closefopen_time then
			CacheFopen[filename] = nil
			temp.f:flush()
			temp.f:close()
			-- if is_testserver then
			-- 	skynet.error(sformat("%s close file", filename))
			-- end
		end
	end
end

