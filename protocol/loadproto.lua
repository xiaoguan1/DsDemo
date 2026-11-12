-----------------------------
--- 加载协议 和 更新协议
-----------------------------
local skynet = require "skynet"
local c = require "protobuf.c"
local posix = require "posix"
local pstat = posix.stat
local utilc = require "util.core"
local protobuf = require "protobuf"
local error = error
local string = string
local sformat = string.format
local table = table
local has_value = table.has_value

local _ERROR_F = _ERROR_F
local _INFO_F = _INFO_F
local SERVICE_NAME = SERVICE_NAME
local SELF_CLUSTERNAME = assert(SELF_CLUSTERNAME)

-- 需要预先加载协议文件，因为有些porto需要import其他协议文件
local preload_load = {
}

-- 记录已加载的协议文件
ALREADY_LOAD_PBS = false

local function _AllPbFiles()
	local pbfiles = posix.scandir("protocol/pbs", {ftype = ".pb"})
	local result = {}
	for file in pairs(pbfiles) do
		local fstat = pstat(file)
		if fstat then
			result[file] = fstat.mtime
		else
			error("error pb file " .. file)
		end
	end
	return result
end

-- 协议文件的校验
local function _Check()
	local filesMtime = _AllPbFiles()
	if not next(filesMtime or {}) then
		_ERROR_F("./protocol/pbs none pb files")
		return
	end

	-- 校验预先加载协议文件
	for _, filename in ipairs(preload_load) do
		local mtime = filesMtime[filename]
		if not mtime then
			_ERROR_F("%s preload file not exists", filename)
			return
		end
	end

	-- 起服阶段，忽略ALREADY_LOAD_PBS和filesMtime之间的校验
	-- 热更新阶段，进行ALREADY_LOAD_PBS和filesMtime之间的校验
	for filename in pairs(ALREADY_LOAD_PBS or {}) do
		if not filesMtime[filename] then
			_ERROR_F("proto hot update fail, because lost %s!", filename)
			return
		end
	end

	ALREADY_LOAD_PBS = filesMtime
	return ALREADY_LOAD_PBS
end

local function _DoLoad(filesMtime, oALREADY_LOAD_PBS)
	if not filesMtime then
		return
	end

	-- 先预先加载协议文件
	for _, filename in ipairs(preload_load) do
		protobuf.register_file(filename)

		-- 热更新阶段，新增pb文件提示
		if oALREADY_LOAD_PBS and not oALREADY_LOAD_PBS[filename] then
			skynet.error(sformat("----- %s update -----", filename))
		end
	end

	for filename, _ in pairs(filesMtime) do
		if not has_value(preload_load, filename) then
			protobuf.register_file(filename)

			-- 热更新阶段，新增pb文件提示
			if oALREADY_LOAD_PBS and not oALREADY_LOAD_PBS[filename] then
				skynet.error(sformat("----- %s update -----", filename))
			end
		end
	end

	return true
end

-- 加载协议
function LoadProto()
	local P = protobuf.P
	if not P then
		_ERROR_F("SERVICE_NAME:%s not P!", SERVICE_NAME)
		return
	end

	local filesMtime = _Check()
	if not filesMtime then
		return
	end

	-- 不返回true，会导致起服失败！
	return _DoLoad(filesMtime)
end

-- 热更新协议
function command.update()
	local PROXYSVR = Import("game/global/rpc/proxysvr.lua")
	local lsvr = PROXYSVR.GetProxy(".launcher", SELF_CLUSTERNAME)
	if not lsvr then
		_ERROR("proto hot update fail, because .launcher svr not exists!")
		return
	end

	-- pb文件校验（热更新协议中，仅能修改或者新增pb文件）
	local oALREADY_LOAD_PBS = ALREADY_LOAD_PBS
	local filesMtime = _Check()
	if not filesMtime then
		ALREADY_LOAD_PBS = oALREADY_LOAD_PBS
		_ERROR("proto hot update fail, because not find pb files!")
		return
	end

	-- 创建新P，并把所有的pb文件进行注册处理
	local newP = c._env_new()
	local OldP, OldGC = protobuf.P, protobuf.GC
	protobuf.P = newP
	protobuf.update_local_pgc()
	if not _DoLoad(filesMtime, oALREADY_LOAD_PBS) then
		-- 未知原因，热更新协议失败。回退旧的P
		ALREADY_LOAD_PBS = oALREADY_LOAD_PBS
		protobuf.P = OldP
		protobuf.update_local_pgc()
		c.pbc_delete(newP)

		_ERROR("proto hot update fail, unknown error!")
		return
	end

	-- newP热更新成功, 挂载最新的P
	utilc.add_pbenv(newP)
	utilc.load_pbenv()

	-- 通知所有服务进行协议更新
	if not lsvr.call.UPDATE_PROTO() then
		-- 其他服务更新失败,恢复原来的数据。回退旧的P
		ALREADY_LOAD_PBS = oALREADY_LOAD_PBS
		protobuf.P = OldP
		protobuf.update_local_pgc()

		utilc.add_pbenv(OldP)
		utilc.load_pbenv()
		c.pbc_delete(newP)

		_ERROR_F("%s update proto fail", SERVICE_NAME)
		return
	end

	-- 把本节点的protobuf.lua中的P和GC进行切换，目的是销毁旧的P！！！
	protobuf.GC = c._gc()
	protobuf.update_local_pgc()
	c._gc_load_env(OldGC, OldP)

	-- 置空,否则这一帧会gc不掉(当然后续会gc它，但个人倾向于这一帧gc掉它).
	OldP, OldGC = nil, nil
	collectgarbage()

	_INFO_F("[%s] hot update proto succeed! P:%s", SERVICE_NAME, protobuf.P)
	return true
end
