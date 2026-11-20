-- 单例类
local SuperClass = assert(SuperClass)

Singleton = newClass({Class}, {name = "Singleton"})
function Singleton:ins(...)
	local Class = self
	if not Class._ins then
		Class._ins = Class(...)
	end
	return Class._ins
end