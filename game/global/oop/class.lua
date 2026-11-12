--[[
	1. class.lua 不支持热更
	2. 通过NewClass生成的类模板，会支持热更！

	特别提示：类模板热更的时候，会再跑一次NewClass方法，目前的策略是无视它
			因为后续会将新类的内容inject到旧类中！！！
]]
local ostime = os.time

M = {}
local AllClasses = {}

function M.NewClass(className)
	assert(className)

	local c = {
		__ClassType = className,
		__CreateClass = ostime(),
	}

	if not AllClasses[className] then
		--[[
			只设置一次，因为热更时相同的类模板会再跑一次这里，
			目前的策略是无视它，因为后面是新类对旧类进行inject操作
		]]
		AllClasses[className] = c
	end

	return c
end

function M.GetAllClasses()
	return AllClasses
end

return M