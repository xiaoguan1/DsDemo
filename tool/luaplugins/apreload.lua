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

HOST_ENV = load("return " .. assert(skynet_getenv("host_env")))()
SELF_IPPORT = assert(HOST_ENV.ipport)
SERVER_CONFIG = load("return " .. assert(skynet_getenv("server_config")))()
SELF_CLUSTERNAME = sformat(CLUSTER_NAME_FMT, HOST_ENV.nodename, cluster_no, server_id)

SERVICE_CLUSTERNAME = {}
local function gen_serice_clutsername()
	for servicename in pairs(ALL_SERVICE_MAP) do
		SERVICE_CLUSTERNAME[servicename] = {}
	end

	for serverId, config in pairs(SERVER_CONFIG) do
		local serviceOrder
		if config.nodename == USER_NODE then
			serviceOrder = START_USER_SERVICE
		elseif config.nodename == CROSS_NODE then
			serviceOrder = START_CROSS_SERVICE
		else
			skynet.error("unknown node: " .. config.nodename)
		end

		if serviceOrder then
			local clustername  = sformat(CLUSTER_NAME_FMT, config.nodename, cluster_no, serverId)
			for _, servicename in pairs(serviceOrder.normal or {}) do
				SERVICE_CLUSTERNAME[servicename][serverId] = clustername
			end

			for servicename, ipport in pairs(config.start_service) do
				if ipport == config.ipport then
					SERVICE_CLUSTERNAME[servicename][serverId] = clustername
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
