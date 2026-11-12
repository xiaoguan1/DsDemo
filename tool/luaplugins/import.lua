-- 加载和热更新模块
--	使用方法Import('base/util.lua')，代替Lua的require机制
local skynet = require "skynet"
local traceback = debug.traceback
local tequal = table.equal
local tempty = table.empty

local __ClassType = "__ClassType"
local __CreateClass = "__CreateClass"
local ClassIgnoreFields = {
	-- 类模板字段，不支持热更新
	[__ClassType] = true,
	[__CreateClass] = true,
}

local is_pool_service = false

_G._ImportModule = _G._ImportModule or {}
local _ImportModule = _G._ImportModule

local IMPORT_FILE = {}

local function tmember_key(Table, Value)
	for k, v in pairs(Table) do
		if v == Value then
			return k
		end
	end
end

-- 错误打印
local function _DUMP_ERROR(...)
	if _ERROR then
		_ERROR(...)
	else
		skynet.error(...)
	end
end

function ICopy(src, rel)
	local rel = rel or {}
	if type(src) ~= "table" then
		return rel
	end
	for k, v in pairs(src) do
		rel[k]=v
	end
	return rel
end

local function ReplaceTbl(Dest,Src)
	local function RealFun(Dest, Src, Depth)
		assert(type(Dest) == "table" and type(Src) == "table",
			"ReplaceTbl error data type", Dest, Src)

		Depth = Depth or 0
		if Depth >= 20 then
			error('too long Depth to replace')
			return
		end

		for k, v in pairs(Dest)do
			if type(v) == "table" then
				if type(Src[k]) == "table" then
					RealFun(v, Src[k], Depth + 1)
				else
					Dest[k] = Src[k]
				end
			else
				-- 对Dest[k]非table的更新或者删减，不支持热更新 类的__ClassType 字段
				if not ClassIgnoreFields[k] then
					Dest[k] = Src[k]
				end
			end
		end

		-- 把新增的数据或者方法引用进来
		for k, v in pairs(Src)do
			-- 目前项目中，类没有继承这一说法。
			if rawget(Dest, k) == nil then
				Dest[k] = v
			end
		end

		setmetatable(Dest, getmetatable(Src))
	end
	RealFun(Dest,Src)
end

-- Update以后必须保证两个事情：
-- 1. function env不会改变，因为有大量的逻辑是以来与fenv的，比如callout等
-- 2. module里面的table的引用继续有效，并且能够及时更新到

-- 暂时不考虑local func = xxx.foo这样的引用更新。
-- 目前的实现是把原来的module直接当成新的func的env来运行保证第一点
-- 第二点的实现不怎么优雅，继续使用replace的办法。SafeImport，traceback，pathFile，false
local function SafeImport(PathFile, Reload)
	local firstB = string.sub(PathFile, 1, 1)
	if firstB == "." or firstB == "/" then
		return nil, "forbidden import"
	end
	if IMPORT_FILE[PathFile] then
		local msg = string.format("double import:%s when use rpc to wait first import", PathFile)
		error(msg)
	end

	local Old = _ImportModule[PathFile]
    if Old and not Reload then
		return Old
	end

	-- 注意，skynet的loadfile是有缓存的，加载前务必先clear环境
	local FileEnv = Old or {}
	local func, err = loadfile(PathFile, "bt", FileEnv)
	if not func then
		return func, err
	end

	local function CallInit(Module)
		-- 载入模块时调用其构造函数
		if Module.__init__ then
			local oCallFunc = CALLOUT and ICopy(CALLOUT.callout_func) or {}
			Module.__init__()
			if is_pool_service then
				local nCallFunc = CALLOUT and CALLOUT.callout_func or {}
				if not tequal(oCallFunc, nCallFunc) then
					_DUMP_ERROR(string.format("**************use callout in %s.__init__ is error!! because is a pool service", PathFile))
				end
			end
		end
	end

	local function CallDestroy(Module)
		if Module.__destroy__ then
			Module.__destroy__()
		end

		local metatable = getmetatable(Old)
		if metatable then
			metatable["__newindex"] = nil
			metatable["__bound"] = nil
		end
	end

	local __update__ = "__update__"
	local function CallUpdate(Module)
		if Module[__update__] then
			local oCallFunc = CALLOUT and ICopy(CALLOUT.callout_func) or {}
			Module[__update__]()
			if is_pool_service then
				local nCallFunc = CALLOUT and CALLOUT.callout_func or {}
				if not tequal(oCallFunc, nCallFunc) then
					_DUMP_ERROR(string.format(
						"**************use callout in %s.__update__ is error!! because is a pool service",
						PathFile
					))
				end
			end
		end
	end

	local function CallProto(Module)
		if Module.__protocol__ then
			local oCallFunc = CALLOUT and ICopy(CALLOUT.callout_func) or {}
			Module.__protocol__()
			local nCallFunc = CALLOUT and ICopy(CALLOUT.callout_func) or {}
			if not tequal(oCallFunc, nCallFunc) then
				_DUMP_ERROR(string.format(
					"**************use callout in %s.__protocol__ is error!!",
					PathFile
				))
			end
		end
	end

	local function BindCheckLeak(Module)
		local metatable = assert(getmetatable(Module))
		if metatable["__bound"] then
			return
		end
		metatable["__bound"] = true

		local func = metatable["__newindex"]
		metatable["__newindex"] = function(t, n, v)
			local IgnoreList = {
				{["type"] = "table", ["name"] = "__AllTimers", },
				{["type"] = "string", ['name'] = "__SAVE_NAME", },
				{["type"] = "function"},
			}

			local info = debug.getinfo(2)
			local IsIgnore = nil

			local function equal_or_nil(v1, v2)
				if v1 == nil then return true end
				return string.find(v2, v1)
			end
			for _, x in pairs(IgnoreList) do
				if x["type"] == type(v)
					and equal_or_nil(x["name"], n) then
					IsIgnore = true
					break
				end
			end

			if not IsIgnore then
				skynet.error(string.format("WARNING:add global variable, %s:%d,%s %s %s", info["short_src"], info["currentline"], info["namewhat"], type(v), n))
			end
			if func then func(t,n,v) else rawset(t,n,v) end
		end
	end

	if not Old then
		-- 第一次载入，不存在更新的问题
		IMPORT_FILE[PathFile] = true
		-- 一定要先将模块的ENV设置进_ImportModule，因为__init__这类方法极有可能使用使用Call这类操作！
		_ImportModule[PathFile] = FileEnv
		local New = FileEnv
		-- 设置原始环境
		setmetatable(New, {__index = _G})
		local ok, err = xpcall(function ()
			func()
			BindCheckLeak(New)
			CallInit(New)
			CallProto(New)
		end, traceback)
		IMPORT_FILE[PathFile] = nil
		if not ok then
			-- 加载模块失败，清理_ImportModule中的内容
			_ImportModule[PathFile] = nil
			error(err)
		end

		return New
	end

	-- 热更新
	CallDestroy(Old)

	-- 先缓存原来的旧内容
	local OldCache = {}
	local OldUpdate = nil
	for k, v in pairs(Old) do
		if k == __update__ then
			OldUpdate = v
		else
			OldCache[k] = v
		end
		Old[k] = nil
	end

	-- 使用原来的module作为fenv，可以保证之前的引用可以更新到
	local ok, errmsg = xpcall(func, traceback)
	if not ok then
		-- 热更新失败
		-- 恢复旧模块内容（含旧 __update__）

		for k in pairs(Old) do
			-- 失败情况下，二次清空Old，是因为 func() 跑一半留下的新内容 ，保证回滚干净。
			Old[k] = nil
		end
		for k, v in pairs(OldCache) do Old[k] = v end
		if OldUpdate ~= nil then Old[__update__] = OldUpdate end
		error(errmsg)
	end

	-- 更新以后的模块，里面的table的reference将不再有效，需要还原
	local New = Old

	-- 协议立即处理，不考虑其他错误，防止global对象被改
	CallProto(New)

	-- 还原table(copy by value)
	for k, v in pairs(OldCache) do
		local TmpNewData = New[k]
		-- 默认不更新
		New[k] = v
		if TmpNewData then
			if type(v) == "table" then -- 原来的类型是table
				if type(TmpNewData) == "table" then	-- 更新之后的类型依然是table
					-- 如果是一个class则需要全部更新，其他则可能只是一些数据，不需要更新
					if rawget(v, "__ClassType") then
						ReplaceTbl(v, TmpNewData)
					end
					local mt = getmetatable(TmpNewData)
					if mt then setmetatable(v, mt) end
				end
			elseif type(v) == "function" then
				-- 函数必须用新的
				New[k] = TmpNewData
			end
		end
	end

	BindCheckLeak(New)
	if PathFile ~= "global/protocolevent.lua" and _ImportModule["global/protocolevent.lua"] then
		_ImportModule["global/protocolevent.lua"].ProtoUpdate(New)
	end
	CallUpdate(New)

	return New
end

function Import(pathFile)
	assert(pathFile, "Please input pathFile")
	local module = _ImportModule[pathFile]
	if module then
		return module
	end
	local ok, Module, err = xpcall(SafeImport, traceback, pathFile, false)
	if not ok then
		error(Module)
	end
	if not Module then
		error(err)
	end
	return Module
end

-- 并不是所有模块都能够Update，比如一些包含local动态数据的模块
-- 如果更新这些模块，则会导致数据丢失。
function Update(pathFile)
	local Ret, err
	if tmember_key(DOFILELIST or {},  pathFile) then
		if pathFile == "base/log.lua" then
			dofile(pathFile)
			Ret = true
			err = '(dofile dore)'
			Ret, err = SafeImport(pathFile, true)
			assert(Ret, err)
		end
	else
		Ret, err = SafeImport(pathFile, true)
		assert(Ret, err)
	end
   return Ret, err
end