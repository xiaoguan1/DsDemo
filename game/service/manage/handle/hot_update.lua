local skynet = require "skynet"
local posix = require "posix"
local pstat = posix.stat
local string = string
local table = table
local tinsert = table.insert
local tempty = table.empty
local has_value = table.has_value
local beginswith = string.beginswith
local endswith = string.endswith
local SELF_CLUSTERNAME = assert(SELF_CLUSTERNAME)

-- 执行命令：wget -q -O - "http://127.0.0.1:40001/hot_update"

--[[

热更新的具体逻辑：
	热更新后必须保证两个事情：
		1.function env不会改变，因为有大量的逻辑是以来与fenv的，比如callout等
		2.module里面的table的引用继续有效，并且能够及时更新到

	面向对象处理：
		类模板和对象，对象本质上就是一堆持久化和非持久化的数据，并附加一个元表实现的。
		所有，在热更新的时候只需要更新类的模板，并将最新的table和旧的table进行比对，进而修改旧的table即可。

	模块方法处理：
		使用loadfile加载，每个模块都有特定的env。所有热更新后得到的新的env和旧的env进行比对，并修改旧的env。

	此外，热更新若想新增一个模块则需要在旧的模块中使用Import。而不是在热更新中新增全新未加载的模块


热更新的流程：
	流程1：优先更新协议（因为目前还没有配置数据文件，故忽略）
	流程2：更新lua的逻辑文件

--优化点：
	hot_update.lua 若存在修改需要热更，则需要先对该文件进行热更处理再进行游戏内部的逻辑热更

-- ]]

TOOL_FILEMTIME = {}	-- 工具库文件的最近一次修改时间
MACRO_FILETIME = {}	-- 常量文件的最近一次修改时间
GAME_FILEMTIME = {}	-- game目录下的文件最近一次修改时间
PROTO_FILEMTIME = {} -- 协议文件(目的：判断协议文件是否有更新)

local function _ReadFile(path, ftype)
	path = path or "game"
	ftype = ftype or ".lua"

	local result = {}
	for file in pairs(posix.scandir(path, {ftype = ftype})) do
		local fstat = pstat(file)
		if fstat then
			result[file] = fstat.mtime
		else
			skynet.error("error file " .. file)
		end
	end
	return result
end

local function _GetFileMtimes()
	local fileMtimes1 = _ReadFile()
	local fileMtimes2 = _ReadFile("tool/luaplugins")
	local fileMtimes3 = _ReadFile("protocol/protos", ".proto")

	local toolfiles = {}	-- lua原生函数拓展文件
	local macroFiles = {}	-- 常量文件
	local gameFiles = {}	-- game目录下的lua逻辑文件
	local protoFiles = {}	-- 协议文件
	local function func(fileMtimes)
		for fileName, mtime in pairs(fileMtimes) do
			if has_value(TOOL_FILES, fileName) then
				toolfiles[fileName] = mtime
			elseif has_value(MACRO_FILES, fileName) then
				macroFiles[fileName] = mtime
			elseif beginswith(fileName, "game") and endswith(fileName, ".lua") then
				gameFiles[fileName] = mtime
			elseif endswith(fileName, ".proto") then
				protoFiles[fileName] = mtime
			end
		end
	end
	func(fileMtimes1)
	func(fileMtimes2)
	func(fileMtimes3)
	return toolfiles, macroFiles, gameFiles, protoFiles
end

function Handle_Request(data)
	local PROXYSVR = Import("game/global/rpc/proxysvr.lua")
	local lsvr = PROXYSVR.GetProxy(".launcher", SELF_CLUSTERNAME)
	if not lsvr then
		_ERROR("hot update fail, because .launcher svr not exists!")
		return true
	end

	local psvr = BASIC_SERVICE_MAP["protosvr"] and BASIC_SERVICE_MAP["protosvr"].named and
				PROXYSVR.GetProxy(BASIC_SERVICE_MAP["protosvr"].named, SELF_CLUSTERNAME)
	if not psvr then
		_ERROR("hot update fail, because psvr svr not exists!")
		return true
	end

	-- 获取当前各个文件的最近修改时间
	local toolfiles, macroFiles, gameFiles, protoFiles = _GetFileMtimes()

	-- 判断proto文件是否有新的加入或更新
	local isUpdateProto
	for pfileName, mtime in pairs(protoFiles) do
		local oldMtime = PROTO_FILEMTIME[pfileName]
		isUpdateProto = not oldMtime and true or mtime > oldMtime
		if isUpdateProto then
			break
		end
	end
	-- 错误码判断、协议编号是否有新增等等。。。。
	if isUpdateProto then
		if psvr.call.update() then
			PROTO_FILEMTIME = protoFiles
		end
	end

	-- 收集有改动的代码文件
	local UPDATE_TYPE = UPDATE_TYPE or {TOOL = 1, MACROS = 2, IMPORT = 3}
	local updateFiles = {
		[UPDATE_TYPE.TOOL] = {},
		[UPDATE_TYPE.MACROS] = {},
		[UPDATE_TYPE.IMPORT] = {},
	}
	for pathFile, mtime in pairs(toolfiles) do
		local omTime = TOOL_FILEMTIME[pathFile]
		if (omTime and mtime > omTime) or not omTime then
			tinsert(updateFiles[UPDATE_TYPE.TOOL], pathFile)
		end
	end
	for pathFile, mtime in pairs(macroFiles) do
		local omTime = MACRO_FILETIME[pathFile]
		if (omTime and mtime > omTime) or not omTime then
			tinsert(updateFiles[UPDATE_TYPE.MACROS], pathFile)
		end
	end
	for pathFile, mtime in pairs(gameFiles) do
		local omTime = GAME_FILEMTIME[pathFile]
		if omTime and mtime > omTime then -- 不做 not omTime，因为新模块需要旧模块里先`Import`
			tinsert(updateFiles[UPDATE_TYPE.IMPORT], pathFile)
		end
	end

	if tempty(updateFiles[UPDATE_TYPE.TOOL]) and
		tempty(updateFiles[UPDATE_TYPE.MACROS]) and
		tempty(updateFiles[UPDATE_TYPE.IMPORT]) and
		not isUpdateProto
	then
		_WARN("not anything hot update!")
		return true
	end

	if lsvr.call.UPDATE_FILES(updateFiles) then
		TOOL_FILEMTIME = toolfiles
		MACRO_FILETIME = macroFiles
		GAME_FILEMTIME = gameFiles
	end

	return true
end

function __init__()
	TOOL_FILEMTIME, MACRO_FILETIME, GAME_FILEMTIME, PROTO_FILEMTIME = _GetFileMtimes()
end
