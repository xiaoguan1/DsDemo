local skynet = require "skynet"
local host_id = tonumber(assert(skynet.getenv("server_id")))
require "skynet.manager"
local util = require "util.core"
local nodename = assert(skynet.getenv("node_name"))	-- 节点名即节点类型（user/play）

function abort(msg)
	skynet.error(msg)
	skynet.sleep(100)
	skynet.abort()
end

local function _OpenLogPath()
	local alogpath = skynet.getenv("alogpath") -- logpath 日志文件
	if not alogpath then
		-- 设置alogpath
		alogpath = "./log/" .. nodename .. "/logpath/"
		skynet.setenv("alogpath", alogpath)
	end

	local logpath = skynet.getenv("logpath")
	if not logpath then
		local lpath = os.date("%Y-%m-%d %H-%M-%S", util.realtime())
		lpath = alogpath .. lpath .. "/"
		skynet.setenv("logpath", lpath)
	end

	skynet.send(".launcher", "lua", "ALL_LOGLAUNCH")
end

local function doGamePreload()
	assert(not skynet.getenv("game_preload"))
	local aPreload = assert(skynet.getenv("apreload"))
	skynet.setenv("game_preload", aPreload)
	dofile(aPreload)
end

skynet.start(function ()
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

	-- 节点名即节点类型（user/play），按节点名选择启动表
	local startOrder = assert(NODE_START_SERVICE[nodename], "unknown node_name: " .. nodename)

	for _, svrname in ipairs(startOrder.unique) do
		local isOk, id = pcall(skynet.uniqueservice, svrname)
		if not isOk or not id then
			abort(string.format("start service[%s] fail", svrname))
		end
		skynet.name(ALL_SERVICE_MAP[svrname].named, id)
	end

	-- 一般服务：按节点启动表 normal 段在代码内固定，不经过数据库
	-- 实例数取 ALL_SERVICE_MAP.default_cnt（缺省1），实例命名 .XXX/.XXX2/...
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

	-- _OpenLogPath()

	-- print("hostConfig ", tool.dumptree(hostConfig))
	-- print("SERVER_CONFIG:", tool.dumptree(SERVER_CONFIG))
	-- print("SERVICE_CLUSTERNAME ", tool.dumptree(SERVICE_CLUSTERNAME))
	_INFO_F("node[%s] server_id[%s] start ok", nodename, host_id)
end)