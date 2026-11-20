local skynet = require "skynet"
local skynet_getenv = skynet.getenv
local SELF_CLUSTERNAME = assert(SELF_CLUSTERNAME)
local BASIC_SERVICE_MAP = assert(BASIC_SERVICE_MAP)
local CLUSTER_NAME_MATCH = assert(CLUSTER_NAME_MATCH)
local CLUSTER_MAP = assert(CLUSTER_MAP)

local is_testserver = (skynet.getenv("is_testserver") == "true") and true or false

local assert = assert
local type = type
local pairs = pairs
local xpcall = xpcall
local traceback = debug.traceback
local error = error
local getmetatable = getmetatable
local select = select
local string = string
local sformat = string.format

local OVERTIME = 	300 	-- 3秒
local MAX_OVERTIME = 600 	-- 6秒

local cluster_no = skynet_getenv("cluster_no")

GCLUSTER_GATE = false

local function gClusterGate()
	if GCLUSTER_GATE then
		return GCLUSTER_GATE
	end
	local named = BASIC_SERVICE_MAP["gcluster"].named
	GCLUSTER_GATE = assert(skynet.localname(named))
	return GCLUSTER_GATE
end

-- 结果检查，不支持userdata作为返回结果！
local function _ret_func(msg, sz, ok, ...)
	skynet.trash(msg, sz)	-- 释放内存
	if not ok then
		error((...))
	end

	if is_testserver then
		for _n, _v in pairs({...}) do
			if type(_v) == "userdata" then
				error("dpcluster ret has point error!")
			end
		end
	end
	return ...
end

local function __call(overtime, clustername, address, prototype, ...)
	-- skynet.error("--__call:", overtime, node, address, prototype, ...)
	-- ...不能有userdata, 判断一下
	for _n, _v in pairs({...}) do
		if type(_v) == "userdata" then
			error(sformat("clustername:%s, address:%s, elem no:%d is userdata", clustername, address, _n))
		end
	end

	local pack_func = skynet.get_prototype_pack(prototype)
	local unpack_func = skynet.get_prototype_unpack(prototype)
	assert(pack_func and unpack_func)

	local gclusterd = assert(gClusterGate())
	local msg, sz = skynet.call(gclusterd, "lua", "request", overtime, clustername, address, prototype, pack_func(...)) -- 肯定是当前节点，所以不用代理了
	return _ret_func(msg, sz, xpcall(unpack_func, traceback, msg, sz))
end

local function __send(clustername, address, prototype, ...)
	-- skynet.error("--__send:", overtime, node, address, prototype, ...)
	-- ...不能有userdata, 判断一下
	for _n, _v in pairs({...}) do
		if type(_v) == "userdata" then
			error(sformat("node:%s, address:%s, elem no:%d is userdata", clustername, address, _n))
		end
	end

	local pack_func = assert(skynet.get_prototype_pack(prototype))
	local gclusterd = assert(gClusterGate())
	skynet.send(gclusterd, "lua", "push", clustername, address, prototype, pack_func(...)) -- 肯定是当前节点，所以不用代理了
end

-- 不允许无限时长等待
function call_o(overtime, clustername, address, ...)
	assert(overtime >= OVERTIME and overtime <= MAX_OVERTIME)
	assert(clustername ~= SELF_CLUSTERNAME)
	return __call(overtime, clustername, address, ...)
end

function call(clustername, address, ...)
	assert(clustername ~= SELF_CLUSTERNAME)
	return __call(OVERTIME, clustername, address, ...)
end

-- 异步跨节点发消息
function send(clustername, address, ...)
	assert(clustername ~= SELF_CLUSTERNAME)
	__send(clustername, address, ...)
end



function GetAddrByClusterName(clusterName)
	if not clusterName then
		return
	end
	local ipport
	local nodename, no, serverId = string.match(clusterName, CLUSTER_NAME_MATCH)
	if nodename and serverId and cluster_no == no then
		serverId = tonumber(serverId)
		ipport = CLUSTER_MAP[nodename] and
				CLUSTER_MAP[nodename][serverId] and
				CLUSTER_MAP[nodename][serverId].ipport
	end
	return ipport
end

function GetClusterName(nodename, serverId)
	if not nodename or not serverId then
		return
	end
	return CLUSTER_MAP[nodename] and
		CLUSTER_MAP[nodename][serverId] and
		CLUSTER_MAP[nodename][serverId].clustername
end

function IsValidClusterName(clusterName)
	if not clusterName then
		return
	end
	local nodename, no, serverId = string.match(clusterName, CLUSTER_NAME_MATCH)
	if no ~= cluster_no then
		return
	end
	serverId = tonumber(serverId)
	return CLUSTER_MAP[nodename] and CLUSTER_MAP[nodename][serverId]
end


---------- 注册协议回调处理 ----------

if not skynet.dispatch("rpc") then
	skynet.dispatch("rpc", function (session, source, modname, funcname, ...)
		local f = _G[modname] and _G[modname][funcname]
		if session == 0 then
			f(...)
		else
			skynet.retpack(f(...))
		end
	end)
end
