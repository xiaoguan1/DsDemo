local skynet = require "skynet"
local SELF_ADDR = skynet.self()
local debug = debug

if not setfenv then
	-- 获取lua脚本的fenv环境
	local function findenv(f)
		local level = 1
		repeat
			local name, value = debug.getupvalue(f, level)
			if name == "_ENV" then
				return level, value
			end
			level = level + 1
		until name == nil
		return nil
	end
	getfenv = function (f)
		if type(f) == "number" then
			f = debug.getinfo(f + 1, "f").func
		end
		if f then
			return select(2, findenv(f))
		else
			return _G
		end
	end
	setfenv = function (f, t)
		local level = findenv(f)
		if level then
			debug.setupvalue(f, level, t)
			return f
		end
	end
end

getfsrc = function (f)
	if type(f) == "number" then
		return debug.getinfo(f + 1, "S").short_src
	end
end
