local skynet = require "skynet"
local host_id = tonumber(assert(skynet.getenv("server_id")))
require "skynet.manager"
local util = require "util.core"
local posix = require "posix"
local dpcluster = require "dpcluster.core"
local queue = require "queueplus"
local nodename = assert(skynet.getenv("node_name"))
CS = queue()

local table = table
local thas_value = table.has_value

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
	print("hostConfig ", tool.dumptree(hostConfig), SERVER_CONFIG)
	skynet.setenv("host_env", tool.dumptree(hostConfig))
	skynet.setenv("server_config", tool.dumptree(SERVER_CONFIG))
	doGamePreload()

	dofile "./game/global/log.lua"
	dofile "game/global/dblog.lua"
	for _, svrname in ipairs(START_USER_SERVICE.unique) do
		local isOk, id = pcall(skynet.uniqueservice, svrname)
		if not isOk or not id then
			abort(string.format("start service[%s] fail", svrname))
		end
		skynet.name(BASIC_SERVICE_MAP[svrname].named, id)
	end

	for _, svrname in ipairs(START_USER_SERVICE.normal) do
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
				if i == 1 then
					skynet.name(named, id)
				else
					skynet.name(named .. i, id)
				end
			end
		else
			local id = skynet.newservice(svrname)
			if not id then
				abort(string.format("start service[%s] fail", svrname))
			end
			skynet.name(NORMAL_SERVICE_MAP[nodename][svrname].named, id)
		end
	end

	-- 启动寄生服务
	local startService = hostConfig.start_service
	local function startOterSvr(nodeSvrSeq)
		for _, svrname in ipairs(nodeSvrSeq) do
			if startService[svrname] == SELF_IPPORT then
				local id = skynet.newservice(svrname)
				if not id then
					abort(string.format("start service[%s] fail", svrname))
				end
				skynet.name(ADHOC_SERVICE_MAP[nodename][svrname].named, id)
			end
		end
	end
	startOterSvr(START_USER_SERVICE.adhoc)

	-- _OpenLogPath()

	-- print("HOST_ENV ", tool.dumptree(HOST_ENV))
	-- print("SERVER_CONFIG:", tool.dumptree(SERVER_CONFIG))
	-- print("BASIC_SERVICE_MAP ", tool.dumptree(BASIC_SERVICE_MAP))
	-- print("ADHOC_SERVICE_MAP ", tool.dumptree(ADHOC_SERVICE_MAP))
	-- print("SERVICE_CLUSTERNAME ", tool.dumptree(SERVICE_CLUSTERNAME))
	_DEBUG("1111111111111")
	_INFO("2222222222222")
	-- print("ADHOC_SERVICE_MAP ", tool.dumptree(ADHOC_SERVICE_MAP))
	-- print("NORMAL_SERVICE_MAP ", tool.dumptree(NORMAL_SERVICE_MAP))
end)