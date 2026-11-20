--import-
local string = string
local table = table
local tinsert = table.insert
local pairs = pairs
local ipairs = ipairs
local math = math
local assert = assert
local error = error
local type = type
local debug = debug
local rawget = rawget
local rawset = rawset
local getmetatable = getmetatable
local setmetatable = setmetatable
local xpcall = xpcall
local traceback = debug.traceback
-- local sys = sys
local skynet = require "skynet"
-- local codecache = require "skynet.codecache"
-- local tablemem = require "tablemem"

--使用方法Import('base/util.lua')
--代替Lua本身的module,require机制
_G._ImportModule = _G._ImportModule or {}
local _ImportModule = _G._ImportModule

is_pool_service = false		--如果是的话，不能在__init__,__update__,__startup__这几个函数中有CALLOUT

skynet.register_protocol {
	name = "update",
	id = skynet.PTYPE_UPDATE,
	unpack = skynet.unpack,
	pack =skynet.pack,
}

local UPDATE_CMD = {}
local IMPORT_FILE ={}
-- {
-- 	[co] = {
-- 		filePath = xxx,
-- 		child = {
-- 			filePath = xxx,
-- 			child = {},
-- 		},
-- 	},
-- 	...
-- }
local DEEP_IMPORT = {}
-- {
-- 	[filePath] = {
-- 		[1] = {[1] = filePath1, [2] = filePath2, ...},
-- 		[2] = {[1] = filePath1, [2] = filePath2, ...},
-- 	}
-- }
local AUTO_UPDATE_PARENTFILE = {}

function tempty(tbl)
	for k, v in pairs(tbl) do
		return false
	end
	return true
end

local function _InsertAutoUpdateFile(filePath, parentList)
	if not parentList or tempty(parentList) then return end

	if not AUTO_UPDATE_PARENTFILE[filePath] then
		AUTO_UPDATE_PARENTFILE[filePath] = {}
	end

	-- local msg = ""
	-- for k, v in ipairs(parentList) do
	-- 	msg = msg .. "->" .. v
	-- end
	-- skynet.error("---:", filePath, msg)

	tinsert(AUTO_UPDATE_PARENTFILE[filePath], parentList)
end

local function _InsertDeepImport(filePath)
	local co = coroutine.running()
	local cData = DEEP_IMPORT[co]
	if not cData then
		cData = {
			filePath = filePath,
			chiid = {},
		}
		DEEP_IMPORT[co] = cData
		return true
	end
	for i = 1, 100 do
		if i == 100 then
			error("deep import")
		end
		if cData.child then
			cData = cData.child
		else
			break
		end
	end
	cData.filePath = filePath
	cData.child = {}
	return true
end

local function _DeleteDeepImport(filePath)
	local co = coroutine.running()
	local cData = DEEP_IMPORT[co]
	if not cData then return end

	local fData = cData
	local parentList = {}
	for i = 1, 100 do
		if cData.filePath == filePath then
			cData.filePath = nil
			cData.child = nil
			if cData == fData then
				DEEP_IMPORT[co] = nil
			end
			break
		else
			tinsert(parentList, 1, cData.filePath)
			cData = cData.child
		end
	end
	_InsertAutoUpdateFile(filePath, parentList)
end

function UPDATE_CMD.update_file(service_name, updatefile)
	local isOk, err = nil, nil
	if service_name == SERVICE_NAME then
		isOk, err = Update(updatefile)
	end
	if isOk then	-- Update返回的是table，是一个环境Env
		isOk = true
	end
	return isOk, err
end

function UpdateAuto(updatefile)
	local oMod = _ImportModule[updatefile]
	if not oMod then return end
	local isOk, err = Update(updatefile)
	if not isOk then
		error(err)
	end
	skynet.error(string.format("auto update file:%s", updatefile))
	local parent = AUTO_UPDATE_PARENTFILE[updatefile]
	if parent then
		for _, _parentList in pairs(parent) do
			for _, _file in ipairs(_parentList) do
				local isOk, err = Update(_file)
				if not isOk then
					error(err)
				end
				skynet.error(string.format("auto update file:%s, prefile:%s", updatefile, _file))
			end
		end
	end
	return true
end

function UPDATE_CMD.update_auto(updatefile)
	UpdateAuto(updatefile)
end

function UpdateLog(pathFile,var_name,log_name)
	local mod = _ImportModule[pathFile]
	if not mod then return end

	local rawLog=_ImportModule["base/log.lua"]
	if not rawLog then skynet.error("no rawLog"); return end

	if not mod[var_name] then skynet.error("no pre_log"); return end
	if not rawLog[log_name] then skynet.error("no mod_log"); return end
	mod[var_name] = rawLog[log_name]
	skynet.error(string.format("update log ok~ pathFile:%s, var_name:%s, log_name:%s", tostring(pathFile), tostring(var_name), tostring(log_name)))
	return true
end

function UPDATE_CMD.update_log(service_name, updatefile, var_name, log_name)
	return UpdateLog(updatefile, var_name, log_name)
end

local function _TableState(dump, tbl, preName, dLayer, nLayer, dumpsize)
	--[[
	if dLayer ==nLayer then
		local narr, nrec = tablemem.arraynode_size(tbl)
		if narr >= dumpsize or nrec >= dumpsize then
			dump[preName] = {
				narr = narr,
				nrec = nrec,
			}
		end
	else
		for _key, _value in pairs(tbl) do
			if type(_value) == "table" then
				_TableState(dump, _value, preName .. "." .. tostring(_key), dLayer, nLayer +1, dumpsize)
			end
		end
	end
	]]--
end

function ImportGTablestate(file, tname, layer, dumpsize)
	local layer = layer or 1
	assert(layer <=20)
	local dumpsize = dumpsize or 0

	local im = {}
	for k, v in pairs(_ImportModule)do
		im[k] = v
	end

	local dump = {}
	for _file, _mod in pairs(im) do
		if not file or _file == file then
			dump[_file] = {}
			for key, _value in pairs(_mod)do
				if type(_value) == "table"and (not tname or tname == key) then
					_TableState(dump[_file],_value,tostring(key),layer,1,dumpsize)
				end
			end
			if tempty(dump[_file]) then
				dump[_file] = nil
			end
		end
	end
	if tempty(dump)then
		return nil
	end
	return dump
end

function UPDATE_CMD.gtable_state(file, tname, layer, dumpsize)
	return ImportGTablestate(file, tname, layer, dumpsize)
end

local oDispatch = skynet.dispatch("update", function(session, source, cmd, ...)
	local f = assert(UPDATE_CMD[cmd])
	if session == 0 then
		f(...)
	else
		skynet.retpack(f(...))
	end
end)
assert(not oDispatch)		-- 必定没有注册过

function tequal(ele1,ele2)
	for _k1, _v1 in pairs(ele1)do
		local _v2 = ele2[_k1]
		local v1Type = type(_v1)
		local v2Type = type(_v2)
		if v1Type ~= v2Type then return false end
		if v1Type == "table"then
			if not table.equal(_v1, _v2) then
				return false
			end
		else
			if _v1 ~= _v2 then
				return false
			end
		end
	end
	for _k1, _v1 in pairs(ele2)do
		local _v2 = ele1[_k1]
		local v1Type = type(_v1)
		local v2Type = type(_v2)
		if v1Type ~= v2Type then return false end
		if v1Type == "table" then
			if not table.equal(_v1, _v2) then
				return false
			end
		else
			if _v1 ~= _v2 then
				return false
			end
		end
	end
	return true
end

local function ReplaceTbl(Dest,Src)
	local function RealFun(Dest, Src, Depth)
		assert(type(Dest)=='table'and type(Src)=='table',
			'ReplaceTbl error data type', Dest, Src)

		if not Depth then
			Depth = 0
		end
		if Depth>=20 then
			error('too long Depth to replace')
			return
		end

		for k, v in pairs(Dest)do
			if type(v) == 'table' then
				--不更新 SubClass
				if k ~= '__SubClass' then
					-- __index and __SuperClass 不做deep替换
					if type(Src[k]) == 'table' and k ~= '__index' and k ~= '__SuperClass' then
						RealFun(v, Src[k], Depth + 1)
					else
						Dest[k] = Src[k]
					end
				end

			else
				Dest[k] = Src[k]
			end
		end

		-- 把新增的数据或者方法引用进来
		for k, v in pairs(Src)do
			-- 注意一定要使用rawget,否则在以下情况更新会失败.
			-- 父类A实现了test函数，子类A1未实现，然后在线添加A1.test的实现并更新。
			-- 这时候Dest[k]实际上防问了metatable中父类的实现，所以不为nil,于是更新失败
			if rawget(Dest, k) == nil then
				Dest[k] = v
			end
		end
		setmetatable(Dest,getmetatable(Src))
	end
	RealFun(Dest,Src)
end

local function GetAllClass(Module)
	local ClassList = {}
	for k, v in pairs(Module) do
		if type(v) == 'table'then
			-- 如果是一个class则需要全部更新，其他则可能只是一些数据，不需要更新
			if v.__ClassType then
				local mt = getmetatable(v)
				-- 如果是一个对家数据则不需要更新
				if not (mt and mt.__ObjectType)then
					ClassList[k] = v
				end
			end
		end
	end

	return ClassList
end

local function PropagateInherit (NewClassList, OldClassList)
	-- for k,v in pairs (NewClassList) do
	-- 	v:Update(OldClassList[k])
	-- end
end

function ICopy(src, rel)
	local rel = rel or {}
	if type(src) ~= 'table' then
		return rel
	end
	for k, v in pairs(src) do
		rel[k]=v
	end
	return rel
end

local function _DUMP_ERROR(...)
	if _ERROR then
		_ERROR(...)
	else
		skynet.error(...)
	end
end

-- Update以后必须保证两个事情：
-- 1. function env不会改变，因为有大量的逻辑是以来与fenv的，比如callout等
-- 2. module里面的table的引用继续有效，并且能够及时更新到

-- 暂时不考虑local func = xxx.foo这样的引用更新。
-- 目前的实现是把原来的module直接当成新的func的env来运行保证第一点
-- 第二点的实现不怎么优雅，继续使用replace的办法。SafeImport，traceback，pathFile，false
local function SafeImport(PathFile, Reload, LoadMethod)
	local firstB = string.sub(PathFile, 1, 1)
	if firstB == '.' or firstB == '/' then
		return nil, 'forbidden import'
	end

	if IMPORT_FILE[PathFile] then
		local msg = string.format("double import:%s when use rpc to wait first import", PathFile)
		error(msg)
	end

	local Old = _ImportModule[PathFile]
    if Old and not Reload then
		return Old
	end

	local LoadMethod = LoadMethod or loadfile
	-- 先loadfile再clear环境
	-- local func, err = loadfile(PathFile)
	local FileEnv = Old or {}
	local func, err
	if Reload then	-- skynet 需要用load，因为skynet有缓存
		func, err = LoadMethod(PathFile, 'bt', FileEnv)
	else
		func, err = LoadMethod(PathFile, 'bt', FileEnv)
	end

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
		if metatable['__newindex'] then
			metatable['__newindex'] = nil
		end
	end

	local function CallUpdate(Module)
		if Module.__update__ then
			local oCallFunc = CALLOUT and ICopy(CALLOUT.callout_func) or {}
			Module.__update__()
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
		local metatable = getmetatable(Module)
		if metatable['__bound'] then
			return
		end
		metatable['__bound'] = true

		local func = metatable['__newindex']
		metatable['__newindex'] = function(t, n, v)
			local IgnoreList = {
				{['type'] = 'table', ['name'] = '__AllTimers', },
				{['type'] = 'string', ['name'] = '__SAVE_NAME', },
				{['type'] = 'function'},
			}

			local info = debug.getinfo(2)
			local IsIgnore = nil

			local function equal_or_nil(v1, v2)
				if v1 == nil then return true end
				return string.find(v2, v1)
			end
			for _, x in pairs(IgnoreList) do
				if x['type'] == type(v)
					and equal_or_nil(x['name'], n) then
					IsIgnore = true
					break
				end
			end

			if not IsIgnore then
				skynet.error(string.format('WARNING:add global variable, %s:%d,%s %s %s', info['short_src'], info['currentline'], info['namewhat'], type(v), n))
			end
			if func then func(t,n,v) else rawset(t,n,v) end
		end
	end
	-- 第一次载入，不存在更新的问题
	if not Old then
		IMPORT_FILE[PathFile] = true
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
			error(err)
		end

		local ClassList = GetAllClass(New)
		-- 一定要放在函数的最后出口
		-- 虽然是新的模块，但是在这里把模块或者类的继承依赖传播下去，可以处理一个class写在几个文件里面，比如：
		-- Import(Parent1)
		-- Import(Child)
		-- Import(Parent2)
		PropagateInherit(ClassList, ClassList)
		return New
	end

	-- if CALLOUT then
	--	CALLOUT.RemoveAll(Old)
	-- end
	CallDestroy(Old)

	-- 先缓存原来的旧内容
	local OldCache = {}
	for k, v in pairs(Old) do
		OldCache[k] = v
		Old[k] = nil
	end

	-- 使用原来的module作为fenv，可以保证之前的引用可以更新到
	func()

	-- 更新以后的模块，里面的table的reference将不再有效，需要还原
	local New = Old

	CallProto(New)		-- 协议立即处理，不考虑其他错误，防止global对象被改

	local NewClassList = {}
	local OldClassList = {}
	-- 还原table(copy by value)
	-- print(PrePathFile, Reload)
	for k,v in pairs(OldCache) do
	   local TmpNewData = New[k]
	   -- 默认不更新
	   New[k] = v
	   if TmpNewData then
			if type(v) == 'table' then -- 原来的类型是table
				if type(TmpNewData) == 'table' then	-- 更新之后的类型依然是table
					-- 如果是一个class则需要全部更新，其他则可能只是一些数据，不需要更新
					if v.__ClassType then
						local mt = getmetatable(v)
						-- 如果是一个对象数据则不需要更新
						if not (mt and mt.__ObjectType) then
							OldClassList[k] = ICopy(v)
							ReplaceTbl(v, TmpNewData)
							NewClassList[k] = v
						end
					--[[
					-- 如果是以 _NoUpdate_打头的变量名，就不更新
					elseif not string.find(k, '^_NoUpdate_') then
						ReplaceTbl(v, TmpNewData)
					]]--
					end
					local mt = getmetatable(TmpNewData)
					if mt then setmetatable(v, mt) end
				end
			-- 函数段必须用新的
			elseif type(v) == "function" then
				New[k] = TmpNewData
			end
		end
	end

	BindCheckLeak(New)
	-- Calllnit(New)
	if PathFile ~= "global/protocolevent.lua" and _ImportModule["global/protocolevent.lua"] then
		_ImportModule["globa上/protocolevent.lua"].ProtoUpdate(New)
	end
	CallUpdate(New)

	-- 一定要放在函数的最后出口
	PropagateInherit(NewClassList, OldClassList)
	return New
end

function Import(pathFile)
	local isInsert = false
	local oMod = _ImportModule[pathFile]
	if not oMod then
		isInsert = true
	else
		local co = coroutine.running()
		if DEEP_IMPORT[co] then
			isInsert = true
		end
	end
	if isInsert then
		-- 添加自动更新层级，如果之前就加载过那么就不用处理了
		_InsertDeepImport(pathFile)
	end
	local ok, Module, err = xpcall(SafeImport, traceback, pathFile, false)
	if isInsert then
		-- 删除自动更新层级，获取列表信息，如果之前就加载过那么就不用处理了
		_DeleteDeepImport(pathFile)
	end
	if not ok then
		error(Module)
	end
	if not Module then
		error(err)
	end
	return Module
end

local function tmember_key(Table, Value)
	for k, v in pairs(Table) do
		if v == Value then
			return k
		end
	end

	return nil
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

-- 系统启动时执行此函数，调用_ImportModule中所有预载入的Startup函数
function ExeMaduleStartup()
   -- 注意:先复制一份Module表，因为调用__startup__的时候有可能改变这个table。
   local _copy = {}
   for k, v in pairs(_ImportModule) do
		_copy[k] = v
   end

   for File, ModuleObj in pairs(_copy) do
		if ModuleObj.__startup__ then
			local oCallFunc = CALLOUT and ICopy(CALLOUT.callout_func) or {}
			ModuleObj.__startup__()
			if is_pool_service then
				local nCallFunc = CALLOUT and CALLOUT.callout_func or {}
				if not tequal(oCallFunc, nCallFunc) then
					skynet.error(string.format(
						"use callout in %s.__startup__ is error!! because is a pool service",
						File
					))
				end
			end
		end
	end
end

function pool_service(isPoolService)
	is_pool_service = isPoolService
end

function is_poolservice()
	return is_pool_service
end