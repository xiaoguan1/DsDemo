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

-- 解析 is_start_xxx 列：列名即服务名，值为 1 表示本行节点启动该 adhoc 服务（0/空为不启动）
-- normal 服务按节点启动表在代码内固定，不经过数据库
-- 返回：start_service —— 服务名 -> 本节点 ipport
local IS_START_MATCH = "^is_start_([%w_]+)$"
local function parseStartService(row, nodeName)
	local aStartService = {}
	local adhocMap = ADHOC_SERVICE_MAP[nodeName] or {}
	for colName, value in pairs(row) do
		local svrname = string.match(colName, IS_START_MATCH)
		if svrname and adhocMap[svrname] and (tonumber(value) or 0) > 0 then
			aStartService[svrname] = row.ipport
		end
	end
	return aStartService
end

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

	local hostConfig = {	-- 本服数据信息
		server_id = host_id,
		nodename = nodename,
		ipport = hostDbRes.ipport,
		start_service = parseStartService(hostDbRes, nodename),	-- 寄生服务（adhoc）的启动列表：服务名 -> ipport
	}
	SERVER_CONFIG[host_id] = hostConfig

	-- 其他服数据信息
	for serverId, config in pairs(otherDbRes) do
		SERVER_CONFIG[serverId] = {
			server_id = serverId,
			nodename = config.node_name,
			ipport = config.ipport,
			start_service = parseStartService(config, config.node_name),
		}
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
