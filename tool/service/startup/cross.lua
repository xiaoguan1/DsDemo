local skynet = require "skynet"
local nodename = assert(skynet.getenv("node_name"))
require "skynet.manager"
local util = require "util.core"
local posix = require "posix"
local dpcluster = require "dpcluster.core"
local queue = require "queueplus"
CS = queue()

local table = table
local thas_value = table.has_value

function abort(msg)
	skynet.error(msg)
	skynet.sleep(100)
	skynet.abort()
end

local function _GetAllFiles(path, result)
	result = result or {}
	path = path or "./game"
	for file in posix.files(path) do
		if file ~= "." and file ~= ".." and file ~= ".git" and file ~= ".svn" then
			file = path .. "/" .. file
			local t = posix.stat(file) or {}
			if t.type == "directory" then				-- 目录
				_GetAllFiles(file, result)
			elseif t.type == "regular" then				-- 文件
				if string.endswith(file, ".lua") then
					result[file] = t.mtime
				end
			else
				skynet.error("error file type " .. file)
			end
		end
	end
	return result
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
	dofile "./game/global/dblog.lua"
	for _, svrname in ipairs(START_CROSS_SERVICE.unique) do
		local id = skynet.uniqueservice(svrname)
		if not id then
			abort(string.format("start service[%s] fail", svrname))
		end
		skynet.name(BASIC_SERVICE_MAP[svrname].named, id)
	end

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
	startOterSvr(START_CROSS_SERVICE.adhoc)

	Import("game/global/rpc/rpc.lua")
	_DEBUG_F("hostConfig %s", tool.dumptree(hostConfig))
	_DEBUG_F("SERVER_CONFIG %s", tool.dumptree(SERVER_CONFIG))
	_DEBUG_F("SELF_IPPORT %s", SELF_IPPORT)
	_DEBUG_F("SELF_CLUSTERNAME ", tool.dumptree(SELF_CLUSTERNAME))
	_DEBUG_F("CLUSTER_MAP %s", tool.dumptree(CLUSTER_MAP))
	_DEBUG_F("ADHOC_SERVICE_MAP %s", tool.dumptree(ADHOC_SERVICE_MAP))
	_DEBUG_F("SERVICE_CLUSTERNAME %s", tool.dumptree(SERVICE_CLUSTERNAME))
end)