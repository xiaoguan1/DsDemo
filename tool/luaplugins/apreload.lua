------------------------------------
--- 加载游戏相关的数据
------------------------------------

local skynet = require "skynet"
local skynet_getenv = skynet.getenv
require "skynet.manager"
local string = string
local smatch = string.match
local sformat = string.format

local cluster_no = skynet_getenv("cluster_no")
local server_id = skynet_getenv("server_id")

local load = load
local assert = assert

-- 节点类型判断
function IsUser()
	return HOST_ENV.nodename == USER_NODE	-- user节点
end
function IsCross()
	return HOST_ENV.nodename == CROSS_NODE	-- 一般跨服节点
end
function IsJlogin()
	return HOST_ENV.nodename == JLOGIN_NODE	-- 仲裁登录节点
end

HOST_ENV = load("return " .. assert(skynet_getenv("host_env")))()
SELF_IPPORT = assert(HOST_ENV.ipport)
SERVER_CONFIG = load("return " .. assert(skynet_getenv("server_config")))()
SELF_CLUSTERNAME = sformat(CLUSTER_NAME_FMT, HOST_ENV.nodename, cluster_no, server_id)

-- 服务 -> 宿主节点信息
-- unique 服务（集群唯一）：{ hostId = 服务器id, clusterName = 节点名 }
-- 多实例服务：{ [serverId] = 节点名 }
SERVICE_CLUSTERNAME = {}
local function gen_serice_clutsername()
	for servicename, svrData in pairs(SERVICE_MAP) do
		if not svrData.unique and not svrData.basic then
			SERVICE_CLUSTERNAME[servicename] = {}
		end
	end

	local function regService(servicename, serverId, clustername)
		local svrData = SERVICE_MAP[servicename]
		if svrData and svrData.unique then
			SERVICE_CLUSTERNAME[servicename] = { hostId = serverId, clusterName = clustername }
		else
			SERVICE_CLUSTERNAME[servicename][serverId] = clustername
		end
	end

	-- 节点类型 -> 启动服务顺序表（由 START_SERVICE_LIST 派生，新增节点类型无需改此处）
	local NODE_SERVICE_ORDER = {}
	for _, st in ipairs(START_SERVICE_LIST) do
		NODE_SERVICE_ORDER[st.nodename] = st
	end

	for serverId, config in pairs(SERVER_CONFIG) do
		local serviceOrder = NODE_SERVICE_ORDER[config.nodename]
		if not serviceOrder then
			skynet.error("unknown node: " .. config.nodename)
		end

		if serviceOrder then
			local clustername  = sformat(CLUSTER_NAME_FMT, config.nodename, cluster_no, serverId)
			for _, servicename in pairs(serviceOrder.normal or {}) do
				regService(servicename, serverId, clustername)
			end

			for servicename, ipport in pairs(config.start_service) do
				if ipport == config.ipport then
					regService(servicename, serverId, clustername)
				end
			end
		end
	end
end
gen_serice_clutsername()

CLUSTER_MAP = false
function LoadNodeIpMap()
	CLUSTER_MAP = {}
	for serverId, cfg in pairs(SERVER_CONFIG) do
		if not CLUSTER_MAP[cfg.nodename] then
			CLUSTER_MAP[cfg.nodename] = {}
		end
		assert(not CLUSTER_MAP[cfg.nodename][serverId])
		CLUSTER_MAP[cfg.nodename][serverId] = {
			ipport = cfg.ipport,
			clustername= sformat(CLUSTER_NAME_FMT, cfg.nodename, cluster_no, serverId)
		}
	end
end
LoadNodeIpMap()

-- 添加rpc协议
if not skynet.get_proto(skynet.PTYPE_RPC) then
	skynet.register_protocol {
		name = "rpc",
		id = skynet.PTYPE_RPC,
		unpack = skynet.unpack,
		pack = skynet.pack,
	}
end
