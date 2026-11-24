--------------------
-- 玩法实例注册表与发现模块（从 memserver 迁入 dbcell，供 cell 内 Redis 使用）
--
-- 负责《无状态分布式架构设计方案》7.4 的实例注册与发现：
--   键规划（7.7；注册表键使用 {<game>} hash tag，兼容 Redis Cluster 同槽约束）：
--     play:reg:{<game>}:<instance_id>   实例注册信息（TTL 心跳，超时自动消失）
--     play:reg:{<game>}:idx             实例 id 索引集合（发现时顺带清理过期成员）
--     play:reg:{<game>}:gen             实例代次计数器（INCR，保证新代次更大）
--   状态机：STARTING / READY / DRAINING / DEAD，发现方只选择 READY
--   注册约定：TTL 30 秒、心跳 10 秒一次；心跳返回 0 表示代次过期、-1 表示注册已过期需重新注册
--
-- 约定：
--   - 所有函数第一个参数 exec 为 cell 注入的命令执行器（exec(cmd, ...)），
--     本模块不持有连接、不 require skynet，便于独立热更与测试
--   - 无动态 local 数据，可随 Import 热更
--------------------

local ostime = os.time
local tonumber = tonumber
local tostring = tostring
local type = type

-- 实例状态机
REG_STATUS = {
	STARTING = "STARTING",
	READY = "READY",
	DRAINING = "DRAINING",
	DEAD = "DEAD",
}

-- 注册表默认 TTL（秒）
local REG_DEFAULT_TTL = 30

local REG_SCRIPT = [[
local old = redis.call('GET', KEYS[1])
if old then
	local oldGen = tonumber(string.match(old, '^(%d+)|'))
	if oldGen and oldGen > tonumber(ARGV[1]) then
		return 0
	end
end
redis.call('SET', KEYS[1], ARGV[2], 'EX', ARGV[3])
redis.call('SADD', KEYS[2], ARGV[4])
return 1
]]

local HEARTBEAT_SCRIPT = [[
local cur = redis.call('GET', KEYS[1])
if not cur then
	return -1
end
local curGen = tonumber(string.match(cur, '^(%d+)|'))
if curGen and curGen > tonumber(ARGV[1]) then
	return 0
end
local fields = {}
for v in string.gmatch(cur, '([^|]*)') do
	fields[#fields+1] = v
end
fields[7] = ARGV[2]
fields[8] = ARGV[3]
redis.call('SET', KEYS[1], table.concat(fields, '|'), 'EX', ARGV[4])
return 1
]]

local STATUS_SCRIPT = [[
local cur = redis.call('GET', KEYS[1])
if not cur then
	return -1
end
local curGen = tonumber(string.match(cur, '^(%d+)|'))
if curGen and curGen > tonumber(ARGV[1]) then
	return 0
end
local fields = {}
for v in string.gmatch(cur, '([^|]*)') do
	fields[#fields+1] = v
end
fields[2] = ARGV[2]
local payload = table.concat(fields, '|')
local ttl = redis.call('TTL', KEYS[1])
if ttl and ttl > 0 then
	redis.call('SET', KEYS[1], payload, 'EX', ttl)
else
	redis.call('SET', KEYS[1], payload)
end
return 1
]]

local UNREGISTER_SCRIPT = [[
local cur = redis.call('GET', KEYS[1])
if cur then
	local curGen = tonumber(string.match(cur, '^(%d+)|'))
	if curGen and curGen > tonumber(ARGV[1]) then
		return 0
	end
end
redis.call('DEL', KEYS[1])
redis.call('SREM', KEYS[2], ARGV[2])
return 1
]]

local function _RegKey(game, instanceId)
	return "play:reg:{" .. game .. "}:" .. instanceId
end

local function _RegIndexKey(game)
	return "play:reg:{" .. game .. "}:idx"
end

local function _RegGenKey(game)
	return "play:reg:{" .. game .. "}:gen"
end

-- game / instance_id 不允许包含分隔符，且不能占用注册表保留名
local function _CheckName(game, instanceId)
	if type(game) ~= "string" or game == "" or game:find("[|:]") then
		return false
	end
	if type(instanceId) ~= "string" or instanceId == "" or instanceId:find("[|:]") then
		return false
	end
	if instanceId == "idx" or instanceId == "gen" then
		return false
	end
	return true
end

local function _Val(v)
	return (tostring(v or ""):gsub("|", "/"))
end

-- 注册信息序列化：generation|status|node_name|server_id|cluster_name|service_name|load|timestamp|extra
local function _Encode(generation, status, info)
	info = info or {}
	return table.concat({
		tostring(generation),
		_Val(status),
		_Val(info.node_name),
		_Val(info.server_id),
		_Val(info.cluster_name),
		_Val(info.service_name),
		_Val(info.load or 0),
		tostring(ostime()),
		_Val(info.extra),
	}, "|")
end

local function _Decode(payload)
	if type(payload) ~= "string" or payload == "" then
		return nil
	end
	local fields = {}
	for v in payload:gmatch("([^|]*)") do
		fields[#fields + 1] = v
	end
	return {
		generation = tonumber(fields[1]),
		status = fields[2],
		node_name = fields[3],
		server_id = tonumber(fields[4]),
		cluster_name = fields[5],
		service_name = fields[6],
		load = tonumber(fields[7]) or 0,
		timestamp = tonumber(fields[8]),
		extra = fields[9],
	}
end

-- 申请新代次：实例启动时调用，返回单调递增的 generation
function RegNextGeneration(exec, game)
	if type(game) ~= "string" or game == "" or game:find("[|:]") then
		return nil, "invalid game"
	end
	return exec("incr", _RegGenKey(game))
end

-- 注册实例：info = {node_name, server_id, cluster_name, service_name, status, load, extra}
-- 返回 1 成功、0 代次过期（被更新代次覆盖）
function RegRegister(exec, game, instanceId, generation, info, ttl)
	if not _CheckName(game, instanceId) or type(generation) ~= "number" then
		return nil, "invalid param"
	end
	local status = (info and info.status) or REG_STATUS.STARTING
	local payload = _Encode(generation, status, info)
	local regTtl = (ttl and ttl > 0) and ttl or REG_DEFAULT_TTL
	return exec("eval", REG_SCRIPT, 2,
		_RegKey(game, instanceId), _RegIndexKey(game),
		generation, payload, regTtl, instanceId)
end

-- 心跳续期并更新负载：返回 1 成功、0 代次过期、-1 注册已过期（需重新注册）
function RegHeartbeat(exec, game, instanceId, generation, load, ttl)
	if not _CheckName(game, instanceId) or type(generation) ~= "number" then
		return nil, "invalid param"
	end
	return exec("eval", HEARTBEAT_SCRIPT, 1,
		_RegKey(game, instanceId),
		generation, load or 0, ostime(), (ttl and ttl > 0) and ttl or REG_DEFAULT_TTL)
end

-- 状态流转：STARTING / READY / DRAINING / DEAD（只选 READY 接收新请求）
function RegSetStatus(exec, game, instanceId, generation, status)
	if not _CheckName(game, instanceId) or type(generation) ~= "number" or type(status) ~= "string" then
		return nil, "invalid param"
	end
	return exec("eval", STATUS_SCRIPT, 1,
		_RegKey(game, instanceId), generation, status)
end

-- 注销实例：优雅下线时调用；返回 1 成功、0 代次过期
function RegUnregister(exec, game, instanceId, generation)
	if not _CheckName(game, instanceId) or type(generation) ~= "number" then
		return nil, "invalid param"
	end
	return exec("eval", UNREGISTER_SCRIPT, 2,
		_RegKey(game, instanceId), _RegIndexKey(game),
		generation, instanceId)
end

-- 查单个实例，返回解码后的信息表（不存在返回 nil）
function RegGet(exec, game, instanceId)
	if not _CheckName(game, instanceId) then
		return nil, "invalid param"
	end
	local payload, err = exec("get", _RegKey(game, instanceId))
	if not payload then
		return nil, err
	end
	local info = _Decode(payload)
	if info then
		info.instance_id = instanceId
	end
	return info
end

-- 查全部实例：返回解码后的数组，并顺带清理心跳过期后残留的索引成员
function RegList(exec, game)
	if type(game) ~= "string" or game == "" or game:find("[|:]") then
		return nil, "invalid game"
	end

	local ids, err = exec("smembers", _RegIndexKey(game))
	if not ids then
		return nil, err
	end
	if #ids == 0 then
		return {}
	end

	local keys = {}
	for i, id in ipairs(ids) do
		keys[i] = _RegKey(game, id)
	end
	local values, mgetErr = exec("mget", table.unpack(keys))
	if not values then
		return nil, mgetErr
	end

	local list = {}
	local stale = {}
	for i, id in ipairs(ids) do
		local info = _Decode(values[i])
		if info then
			info.instance_id = id
			list[#list + 1] = info
		else
			stale[#stale + 1] = id
		end
	end

	-- 实例崩溃后 key 已过期，索引里的成员在此清理
	if #stale > 0 then
		exec("srem", _RegIndexKey(game), table.unpack(stale))
	end
	return list
end

-- 只返回 READY 实例（agent 选实例用）
function RegListReady(exec, game)
	local list, err = RegList(exec, game)
	if not list then
		return nil, err
	end
	local ready = {}
	for _, info in ipairs(list) do
		if info.status == REG_STATUS.READY then
			ready[#ready + 1] = info
		end
	end
	return ready
end
