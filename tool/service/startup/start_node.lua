-- 节点通用启动逻辑：main/cross/jlogin_node 等节点入口共用
-- StartNode(serviceOrder)：加载节点数据 -> 预加载 -> 启动基础服务 -> 启动一般服务(可多实例) -> 启动自由服务
-- serviceOrder 结构见 game/global/macro/namedsvr.lua 的 START_XXX_SERVICE

local skynet = require "skynet"
require "skynet.manager"
local nodename = assert(skynet.getenv("node_name"))

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

local function startBasicSvr(uniqueList)
	for _, svrname in ipairs(uniqueList) do
		local isOk, id = pcall(skynet.uniqueservice, svrname)
		if not isOk or not id then
			abort(string.format("start service[%s] fail", svrname))
		end
		skynet.name(BASIC_SERVICE_MAP[svrname].named, id)
	end
end

local function startNormalSvr(normalList)
	for _, svrname in ipairs(normalList or {}) do
		-- 无状态多实例服务：按配置数量启动多个实例，便于水平扩展
		local svr_num
		if svrname == "wgate" then
			svr_num = tonumber(skynet.getenv("gateway_num")) or 1
		elseif svrname == "agent" then
			svr_num = tonumber(skynet.getenv("agent_default_num")) or 1
		end
		if svr_num then
			for i = 1, svr_num do
				local id = skynet.newservice(svrname, i)
				if not id then
					abort(string.format("start service[%s] fail", svrname))
				end
				local named = NORMAL_SERVICE_MAP[nodename][svrname].named
				local svrName = (i == 1) and named or (named .. i)
				skynet.name(svrName, id)
			end
		else
			local id = skynet.newservice(svrname)
			if not id then
				abort(string.format("start service[%s] fail", svrname))
			end
			skynet.name(NORMAL_SERVICE_MAP[nodename][svrname].named, id)
		end
	end
end

local function startAdhocSvr(startService, adhocList)
	for _, svrname in ipairs(adhocList or {}) do
		if startService[svrname] == SELF_IPPORT then
			local id = skynet.newservice(svrname)
			if not id then
				abort(string.format("start service[%s] fail", svrname))
			end
			skynet.name(ADHOC_SERVICE_MAP[nodename][svrname].named, id)
		end
	end
end

function StartNode(serviceOrder)
	assert(serviceOrder and serviceOrder.unique)
	skynet.start(function ()
		local nodeInfo = Import("game/global/nodeInfo.lua")
		local hostConfig, SERVER_CONFIG = nodeInfo.GetAllNodeData()
		if not hostConfig then
			abort(SERVER_CONFIG)
		end
		print("hostConfig ", tool.dumptree(hostConfig), SERVER_CONFIG)
		skynet.setenv("host_env", tool.dumptree(hostConfig))
		skynet.setenv("server_config", tool.dumptree(SERVER_CONFIG))
		doGamePreload()

		dofile "./game/global/log.lua"
		dofile "./game/global/dblog.lua"

		startBasicSvr(serviceOrder.unique)
		startNormalSvr(serviceOrder.normal)
		startAdhocSvr(hostConfig.start_service, serviceOrder.adhoc)
	end)
end
