-- play 节点启动入口（玩法节点：无状态玩法实例池，N节点×1实例）
-- 与 user 节点的差异：无 dbserver（玩法不直接读写 MySQL）、新增 redis、无客户端监听
-- 进程差异全部来自配置与环境变量（SERVER_ID/MCS_PORT），节点名固定为 play

local skynet = require "skynet"
local host_id = tonumber(assert(skynet.getenv("server_id")))
require "skynet.manager"
local nodename = assert(skynet.getenv("node_name"))

local table = table

function abort(msg)
	skynet.error(msg)
	skynet.sleep(100)
	skynet.abort()
end

local function doGamePreload()
	assert(not skynet.getenv("game_preload"))
	local aPreload = assert(skynet.getenv("apreload"))
	skynet.setenv("game_preload", aPreload)
	dofile(aPreload)
end

skynet.start(function ()
	assert(nodename == PLAY_NODE, string.format("play.lua can not start node[%s]", nodename))

	local nodeInfo = Import("game/global/nodeInfo.lua")
	local hostConfig, SERVER_CONFIG = nodeInfo.GetAllNodeData()
	if not hostConfig then
		abort(SERVER_CONFIG)
	end
	skynet.setenv("host_env", tool.dumptree(hostConfig))
	skynet.setenv("server_config", tool.dumptree(SERVER_CONFIG))
	doGamePreload()

	dofile "./game/global/log.lua"
	dofile "game/global/dblog.lua"

	local startOrder = assert(NODE_START_SERVICE[PLAY_NODE], "unknown node: " .. PLAY_NODE)

	-- 基础服务（按节点名在代码内固定）：manage → protosvr → gamelog → stimer → gcluster → redis
	for _, svrname in ipairs(startOrder.unique) do
		local isOk, id = pcall(skynet.uniqueservice, svrname)
		if not isOk or not id then
			abort(string.format("start service[%s] fail", svrname))
		end
		skynet.name(ALL_SERVICE_MAP[svrname].named, id)
	end

	-- 一般服务（玩法）：按节点启动表 normal 段在代码内固定，不经过数据库
	-- 实例数取 ALL_SERVICE_MAP.default_cnt（缺省1）；N节点×1实例，扩容靠加节点
	for _, svrname in ipairs(startOrder.normal or {}) do
		local namedData = assert(ALL_SERVICE_MAP[svrname],
			string.format("normal service[%s] not in ALL_SERVICE_MAP", svrname))
		assert(not namedData.unique,
			string.format("unique service[%s] can not in normal list", svrname))
		local svrNum = namedData.default_cnt or 1
		for i = 1, svrNum do
			local id = skynet.newservice(svrname, i)
			if not id then
				abort(string.format("start service[%s] fail", svrname))
			end
			skynet.name((i == 1) and namedData.named or (namedData.named .. i), id)
		end
	end

	-- 寄生服务（adhoc）：由中心库 is_start_xxx 列驱动（nodeInfo 归一化为 start_service：服务名 -> 本节点 ipport）
	local startService = hostConfig.start_service
	for _, svrname in ipairs(startOrder.adhoc or {}) do
		if startService[svrname] == SELF_IPPORT then
			local id = skynet.newservice(svrname)
			if not id then
				abort(string.format("start service[%s] fail", svrname))
			end
			skynet.name(ADHOC_SERVICE_MAP[PLAY_NODE][svrname].named, id)
		end
	end

	_INFO_F("node[%s] server_id[%s] start ok, start_service:%s",
		nodename, host_id, tool.dump(hostConfig.start_service))
end)
