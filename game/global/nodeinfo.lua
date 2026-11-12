local skynet = require "skynet"
local mysql = require "skynet.db.mysql"
local assert = assert
local table = table
local pairs = pairs
local string = string
local sformat = string.format

local nodename = skynet.getenv("node_name")
local CENTER_DATABASE = assert(load("return " .. skynet.getenv("centerdatadb_info"))())

local host_id = assert(tonumber(skynet.getenv("server_id")))
local cluster_no = assert(tonumber(skynet.getenv("cluster_no")))
local merge_hosts = skynet.getenv("merge_hosts")
if merge_hosts then
	merge_hosts = assert(load("return " .. merge_hosts))()
end

-- 连接数据库（注意：协程会堵塞）
local function _GetDb()
	local function on_connect(db)
		db:query("set charset utf8")
	end

	local host = CENTER_DATABASE.dbhost
	local port = CENTER_DATABASE.dbport
	local database = CENTER_DATABASE.dbname
	local db = mysql.connect({
		host = host,
		port = port,
		database = database,
		user = CENTER_DATABASE.dbuser,
		password = CENTER_DATABASE.dbpasswd,
		max_pack_size = 2^30,	-- 1GB，设置一个很大的数值，但实际没作用，因为有max_pack_size 4MB限制
		on_connect = on_connect,
	})
	-- 询问query的时候如果是断开的还是会继续连接，直到连接上
	if not db then
		return false, string.format("connect mysql(%s:%s) dbname:%s error!", host, port, database)
	end
	return true, db
end

local selectSql_1 = "select * from server_config where cluster_no = %d;"
local selectSql_2 = "select * from server_config where cluster_no = %d and server_id = %d;"

local function getAllNodeData(db)
	assert(db)
	local sql = sformat(selectSql_1, cluster_no)
	local dbRes = db:query(sql)
	if dbRes["badresult"] or #dbRes <= 0 then
		return false, sformat("query:%s database error!, res:%s", sql, tool.dump(dbRes))
	end

	local hostDbRes, otherDbRes = nil, {}
	for _, res in ipairs(dbRes) do
		if res.server_id == host_id then
			hostDbRes = res
		else
			otherDbRes[res.server_id] = res
		end
	end

	if not hostDbRes then
		return false, "not find self server config"
	end
	if hostDbRes.node_name ~= nodename then
		return false, sformat("centerdatabase server_config node_name error! %s ~= %s", hostDbRes.node_name, nodename)
	end

	local SERVER_CONFIG = {}	-- 全部区服的配置，包括自己

	local startSvc = {}
	local selfIpPort = hostDbRes.ipport
	local hostConfig = {	-- 本服数据信息
		server_id = host_id,
		nodename = nodename,
		ipport = selfIpPort,
		jlogin_ipport = hostDbRes.jlogin_ipport ~= "" and hostDbRes.jlogin_ipport or nil,
		start_service = startSvc
	}
	for key, val in pairs(hostDbRes) do
		local isOk, sIdx, eIdx = string.beginswith(key, "is_start_")
		if isOk then
			local svriceName = string.sub(key, eIdx + 1)
			if val == 1 then
				if not ADHOC_SERVICE_MAP[nodename][svriceName] then
					return false, sformat("ADHOC_SERVICE_MAP11 [%s] [%s] not find!", nodename, svriceName)
				end
				startSvc[svriceName] = selfIpPort
			elseif val ~= 0 then
				local res = otherDbRes[val]
				if val == host_id or not res then
					return false, sformat("centerdatabase server_config[%s] error! %s ~= %s", host_id)
				end
				startSvc[svriceName] = res.ipport
			end
		end
	end
	SERVER_CONFIG[host_id] = hostConfig

	-- 其他服数据信息
	for serverId, config in pairs(otherDbRes) do
		local startSvc = {}
		local serverConfig = {
			server_id = serverId,
			nodename = config.node_name,
			ipport = config.ipport,
			jlogin_ipport = config.jlogin_ipport ~= "" and config.jlogin_ipport or nil,
			start_service = startSvc
		}
		for key, val in pairs(config) do
			local isOk, sIdx, eIdx = string.beginswith(key, "is_start_")
			if isOk then
				local svriceName = string.sub(key, eIdx + 1)
				if val == 1 then
					if not ADHOC_SERVICE_MAP[config.node_name][svriceName] then
						return false, sformat("ADHOC_SERVICE_MAP22 [%s] [%s] not find!", config.node_name, svriceName)
					end
					startSvc[svriceName] = config.ipport
				elseif val ~= 0 then
					local res = otherDbRes[val] or SERVER_CONFIG[val]
					if (val == config.server_id) or not res then
							return false, sformat("centerdatabase server_config[%s] error! %s ~= %s", config.server_id)
					end
					startSvc[svriceName] = res.ipport
				end
			end
		end
		SERVER_CONFIG[serverId] = serverConfig
	end

	-- 校验SERVER_CONFIG的网络地址唯一性
	local ipPort2ServerId = {}
	for serverId, config in pairs(SERVER_CONFIG) do
		assert(not ipPort2ServerId[config.ipport])
		if ipPort2ServerId[config.ipport] then
			return false, sformat("centerdatabase server_config ipport repeated [%s] [%s]", ipPort2ServerId[config.ipport], serverId)
		end
		ipPort2ServerId[config.ipport] = serverId
	end

	-- print("dbRes ", tool.dumptree(dbRes))
	-- print("hostEnv ", tool.dumptree(hostConfig))
	-- print("SERVER_CONFIG ", tool.dumptree(SERVER_CONFIG))

	return hostConfig, SERVER_CONFIG
end

-- 注意：里面有协程的，会阻塞当前协程，需要处理重入问题
function GetAllNodeData()
	local ok, db = _GetDb()
	if not ok then
		return false, db
	end
	local hostConfig, SERVER_CONFIG = getAllNodeData(db)
	db:disconnect()
	return hostConfig, SERVER_CONFIG
end
