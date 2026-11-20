-- 通过该模块获得的闭包，将支持热更！

local getfenv = assert(getfenv)

-- 关于闭包id重置的问题，如果做成动态重置为0的效果。
--	必须考虑到外部获得的id 在丢弃闭包的时候 一定要将引用的id置为nil
AutoId = 0

ClosureList = {
	-- [src] = {
	-- 	[funcName] = {
	-- 		[id] = {f = closure, args = pack},
	-- 		...
	-- 	},
	-- 	...
	-- },
	-- ...
}

function CreateClosure(funcName, ...)
	-- 检查
	local module = getfenv(2)
	local src = getfsrc(2)
	if not (funcName and module[funcName]) then
		_ERROR_F("src:%s not function:%s", src, funcName)
		return
	end

	local f = module[funcName](...)
	if not f or type(f) ~= "function" then
		-- 返回值必须是一个闭包
		_ERROR_F("src:%s function:%s return not closure", src, funcName)
		return
	end

	if not ClosureList[src] then
		ClosureList[src] = {}
	end

	if not ClosureList[src][funcName] then
		ClosureList[src][funcName] = {}
	end

	local t = { f = f }
	if next({ ... }) then
		t.args = table.pack(...)
	end
	AutoId = AutoId + 1
	ClosureList[src][funcName][AutoId] = t

	return f
end

function DelClosure(funcName, id)
	if not funcName or not id then
		return
	end

	-- 检查
	local module = getfenv(2)
	local src = getfsrc(2)
	if not (funcName and module[funcName]) then
		_ERROR_F("src:%s not function:%s", src, funcName)
		return
	end

	if not ClosureList[src] then
		_ERROR_F("ClosureList not find src:%s", src)
		return
	end

	if not ClosureList[src][funcName] then
		_ERROR_F("ClosureList src:%s not find funcName", src, funcName)
		return
	end

	ClosureList[src][funcName][id] = nil
end






--- 闭包的热更新

local function UpdateUpvalueByType(oldTable, newTable, deep)
	deep = (deep or 0) + 1
	if deep >= 50 then
		error("===================")
	end

	for k, v in pairs(newTable) do
		if type(v) == "function" and type(oldTable[k]) == "function" then
			UpdateUpvalue(oldTable[k], v, deep)
			oldTable[k] = v
		elseif type(v) == "table" and type(oldTable[k]) == "table" then
			UpdateUpvalueByType(oldTable[k], v, deep)
		end
	end
end

function UpdateUpvalue(OldFunction, NewFunction, deep)
	deep = (deep or 0) + 1
	if deep >= 20 then
		error("===================")
	end

	local function _CollectInfo(closeFunc, cIndexInfo, cNameInfo)
		cIndexInfo = cIndexInfo or {}
		cNameInfo = cNameInfo or {}
		local index = 1
		for i = 1, math.huge do
			index = i
			local name, value = debug.getupvalue(closeFunc, i)
			if not name then
				return cIndexInfo, cNameInfo, i
			end
			table.insert(cIndexInfo, {name = name, value = value})
			cNameInfo[name] = {index = i, value = value}
		end
		return cIndexInfo, cNameInfo, index
	end

	local ocIndexInfo, ocNameInfo, omaxIndex = _CollectInfo(OldFunction)
	local ncIndexInfo, ncNameInfo, nmaxIndex = _CollectInfo(NewFunction)

	for index, info in ipairs(ncIndexInfo) do
		local name = info.name
		local oldInfo = ocNameInfo[name]

		if oldInfo then
			local oldVale, newValue = oldInfo.value, info.value
			if type(oldVale) ~= type(newValue) then
				-- 新的upvalue类型不一致时，用旧的upvalue（原则上是要一样的类型）
				debug.setupvalue(NewFunction, index, oldVale)
			elseif oldVale == newValue then
				-- 相同则不操作

			elseif type(oldVale) == "function" then
				UpdateUpvalue(oldVale, newValue, deep)
			elseif type(oldVale) == "table" then
				UpdateUpvalueByType(oldVale, newValue)
				debug.setupvalue(NewFunction, index, oldVale)
			else
				debug.setupvalue(NewFunction, index, oldVale)
			end
		else
			print(string.format("close func add key:%s value:%s", name, info.value))
		end
	end
end

local function _ClosureUpdate(cList, preClosure)
	for id, cInfo in pairs(cList) do
		local oldClosure = cInfo.f
		local args = cInfo.args
		local newClosure
		if args then
			newClosure = preClosure(table.unpack(args))
		else
			newClosure = preClosure( )
		end
		UpdateUpvalue(oldClosure, newClosure, 0)
		cList[id] = newClosure
	end
end

function __update__(src)
	if not src then
		_ERROR("gclosure __update__ fail, because src is nil!!!")
		return
	end
	local module = _G._ImportModule[src]
	if not module then
		_ERROR_F("gclosure __update__ fail, because src:[%s] not find module!!!", src)
		return
	end

	for funcName, cList in pairs(ClosureList[src] or {}) do
		local preClosure = module[funcName]
		if preClosure then
			local newClosure = preClosure()
			if type(newClosure) == "function" then
				_ClosureUpdate(cList, preClosure)
			else
				_ERROR_F("src:[%s] hot_update funcName:[%s], return not closure!",
					src, funcName)
			end
		else
			_ERROR_F("src:[%s] hot_update not find funcName:[%s], closure update fail!",
				src, funcName)
		end
	end
end
