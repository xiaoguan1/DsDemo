------------------------------------
--- 加载游戏相关的数据
------------------------------------

local skynet = require "skynet"
local skynet_getenv = skynet.getenv
require "skynet.manager"
local sformat = string.format

local cluster_no = skynet_getenv("cluster_no")
local server_id = skynet_getenv("server_id")

local load = load
local assert = assert

-- 节点类型判断
function IsUser()
	return HOST_ENV.nodename == USER_NODE	-- user节点
end
function IsPlay()
	return HOST_ENV.nodename == PLAY_NODE	-- 玩法节点（多进程共用节点名play）
end

HOST_ENV = load("return " .. assert(skynet_getenv("host_env")))()
SELF_IPPORT = assert(HOST_ENV.ipport)
SERVER_CONFIG = load("return " .. assert(skynet_getenv("server_config")))()
SELF_CLUSTERNAME = sformat(CLUSTER_NAME_FMT, HOST_ENV.nodename, cluster_no, server_id)

-- 服务所在节点表：只登记 adhoc（寄生）服务——只有它的宿主节点随 is_start_xxx 变化
-- unique 服务各节点本地唯一、normal 服务按节点启动表固定，均无需登记
-- 结构：
-- SERVICE_CLUSTERNAME = {
-- 	[servicename] = {					-- 服务名（节点启动表 adhoc 段登记且 is_start_xxx = 1）
-- 		[serverId] = "play@1_55001",	-- 集群名：节点名@cluster_no_server_id
-- 		-- ...
-- 	},
-- 	-- ...
-- }
-- 示例：SERVICE_CLUSTERNAME["example"][55001] = "play@1_55001"
SERVICE_CLUSTERNAME = {}
local function gen_serice_clutsername()
	for serverId, config in pairs(SERVER_CONFIG) do
		if not NODE_START_SERVICE[config.nodename] then
			skynet.error("unknown node: " .. config.nodename)
		end

		local clustername  = sformat(CLUSTER_NAME_FMT, config.nodename, cluster_no, serverId)

		-- 寄生服务（adhoc）：由各节点 is_start_xxx 列驱动
		for servicename, ipport in pairs(config.start_service) do
			if ipport == config.ipport then
				SERVICE_CLUSTERNAME[servicename] = SERVICE_CLUSTERNAME[servicename] or {}
				SERVICE_CLUSTERNAME[servicename][serverId] = clustername
			end
		end
	end
end
gen_serice_clutsername()

-- 节点网络地址映射（rpc 寻址用：节点名 + serverId -> 网络地址与集群名）
-- 结构：
-- CLUSTER_MAP = {
-- 	[nodename] = {						-- 节点名（即节点类型）：user / play
-- 		[serverId] = {					-- 数字键，server_config.server_id
-- 			ipport = "127.0.0.1:32527",	-- gcluster 监听地址（server_config.ipport）
-- 			clustername = "play@1_55001",	-- 集群名：节点名@cluster_no_server_id
-- 		},
-- 		-- ...
-- 	},
-- 	-- ...
-- }
-- 示例：CLUSTER_MAP["play"][55001] = {ipport = "127.0.0.1:32527", clustername = "play@1_55001"}
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
