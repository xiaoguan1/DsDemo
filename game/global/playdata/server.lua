--------------------
-- playdata 服务端实现（运行在 play 节点的 dbcell 内）
--
-- 设计目标（方案 B）：
--   1. 读缓存未命中时，cell 直接用本节点 database_info 的 MySQL 连接回源，
--      不再经 dbserver 转发，调用方只挂起一次
--   2. 同一业务 key 固定路由到同一 cell，配合 Redis NX 做全局单飞
--   3. CAS 更新与持久化任务入队放在同一个 Lua 脚本里，避免丢任务
--   4. 持久化消费者由 cell 自己承担：RPOPLPUSH → MySQL upsert → ack
--
-- 返回码（客户端必须区分）：
--   ok / not_found / conflict / source_error / redis_error / cas_retry_exhausted
--
-- 部署：仅 play 节点（配置了 redis_info）由 dbcell 加载，user 节点不加载
--------------------

local skynet = require "skynet"

local tostring = tostring
local tonumber = tonumber
local type = type
local ostime = os.time
local tserialise = tool.serialise	-- 序列化任意 Lua 值

local CODEC = Import("tool/service/basic/dbcell/playdata_codec.lua")
local DBMEM = Import("tool/service/basic/dbcell/dbcell_mem.lua")
local DB = Import("tool/service/basic/dbcell/dbcell_server.lua")

ACCEPT, RESPONSE = {}, {}

local DEFAULT_TTL = 300		-- 热层默认 5 分钟
local EMPTY_TTL = 30		-- 空值缓存短 TTL
local LOCK_TTL = 5			-- 全局单飞锁 TTL
local LOCK_RETRY = 3		-- 抢锁失败后的重读次数
local LOCK_RETRY_TICK = 20	-- 重读间隔（skynet.sleep 单位 1/100 秒）

local MAX_RETRY = 3			-- 持久化任务最大重试
local CONSUMER_TICK = 10	-- 消费轮询间隔（100ms）

-- 持久化队列（全局；Redis Cluster 下需改为同 hash tag 或使用 Stream）
local QUEUE_KEY = "play:persist:queue"
local DEAD_KEY = "play:persist:dead"
local PROCESSING_KEY

-- 释放锁：值相等才删，避免误删别人的锁
local RELEASE_SCRIPT = [[
if redis.call('GET', KEYS[1]) == ARGV[1] then
	return redis.call('DEL', KEYS[1])
end
return 0
]]

-- CAS + 持久化任务入队：原子完成，避免 CAS 成功但任务丢失
local CAS_PUSH_SCRIPT = [[
local cur = redis.call('GET', KEYS[1])
local expected = tonumber(ARGV[1])
if cur then
	local ver = tonumber(string.match(cur, '^(%d+)|'))
	if not ver or ver ~= expected then
		return 0
	end
elseif expected ~= 0 then
	return 0
end
redis.call('SET', KEYS[1], ARGV[2], 'EX', ARGV[3])
redis.call('RPUSH', KEYS[2], ARGV[4])
return 1
]]

local function _Result(code, data)
	data = data or {}
	data.code = code
	return data
end

local function _GenLockToken()
	return tostring(skynet.self()) .. ":" .. tostring(ostime()) .. ":" .. tostring(math.random(1, 1000000))
end

local function _AcquireLock(lockKey, ttl)
	local token = _GenLockToken()
	local ret, err = DBMEM.Exec("set", lockKey, token, "NX", "EX", ttl or LOCK_TTL)
	if err then
		return nil, err
	end
	if ret == "OK" then
		return token
	end
	return false
end

local function _ReleaseLock(lockKey, token)
	DBMEM.Exec("eval", RELEASE_SCRIPT, 1, lockKey, token)
end

local function _DecodeCache(payload)
	local version, data = CODEC.PD_Decode(payload)
	if data == nil then
		return nil, nil, "decode fail"
	end
	if data == false then
		return nil, version, "empty"
	end
	return data, version
end

-- 回源 MySQL：返回 data, version, err
local function _LoadDb(key)
	local raw, err = DB.GetModDataStrict(key)
	if err then
		return nil, nil, err
	end
	if not raw then
		return nil, nil, nil	-- 确定无记录
	end
	local payload = CODEC.PD_Unpack(raw)
	if type(payload) ~= "string" then
		return nil, nil, "db payload decode fail"
	end
	local version, data = CODEC.PD_Decode(payload)
	if data == nil then
		return nil, nil, "db payload invalid"
	end
	if data == false then
		return nil, nil, nil	-- 数据库里不应出现空值缓存，按无记录处理
	end
	return data, version or 0
end

-- 用默认值初始化（CAS 0）；返回与 Read 相同结构
local function _InitDefault(key, default, ttl)
	local ret = Cas(key, 0, default, ttl)
	if ret.code == "ok" then
		return _Result("ok", { data = default, version = ret.version })
	end
	if ret.code ~= "conflict" then
		return ret
	end
	-- 别的实例已初始化：回读
	local payload, err = DBMEM.Exec("get", key)
	if err then
		return _Result("redis_error", { err = err })
	end
	if not payload then
		return _Result("not_found")
	end
	local data, version, decErr = _DecodeCache(payload)
	if decErr == "empty" then
		return _Result("not_found")
	end
	if data == nil then
		return _Result("source_error", { err = "cache decode fail" })
	end
	return _Result("ok", { data = data, version = version })
end

-- CAS 更新：版本匹配才写，并原子投递持久化任务
function Cas(key, version, data, ttl)
	assert(key and type(version) == "number" and type(data) == "table")
	ttl = ttl or DEFAULT_TTL
	local payload = CODEC.PD_Encode(version + 1, data)
	local task = tserialise({
		saveName = key,
		version = version + 1,
		data = data,
		ts = ostime(),
		retry = 0,
	})
	local ret, err = DBMEM.Exec("eval", CAS_PUSH_SCRIPT, 2, key, QUEUE_KEY,
		version, payload, ttl, task)
	if err then
		return _Result("redis_error", { err = err })
	end
	if ret == 0 then
		return _Result("conflict")
	end
	return _Result("ok", { version = version + 1 })
end

-- 读：热层 → 全局 NX 单飞 → 本 cell 直查 MySQL → 回填
-- default 不为 nil 时，not_found 会自动初始化并返回 ok
function Read(key, ttl, default)
	ttl = ttl or DEFAULT_TTL

	local payload, err = DBMEM.Exec("get", key)
	if err then
		return _Result("redis_error", { err = err })
	end
	if payload then
		local data, version, decErr = _DecodeCache(payload)
		if decErr == "empty" then
			if default ~= nil then
				return _InitDefault(key, default, ttl)
			end
			return _Result("not_found")
		end
		if data ~= nil then
			return _Result("ok", { data = data, version = version })
		end
		-- 脏数据：删掉后按未命中回源，避免后续每次读都命中脏值
		DBMEM.Exec("del", key)
	end

	local lockKey = key .. ":lock"
	local token, lockErr = _AcquireLock(lockKey, LOCK_TTL)
	if lockErr then
		return _Result("redis_error", { err = lockErr })
	end
	if not token then
		-- 别人正在回源：短暂等待后重读
		for _ = 1, LOCK_RETRY do
			skynet.sleep(LOCK_RETRY_TICK)
			payload, err = DBMEM.Exec("get", key)
			if err then
				return _Result("redis_error", { err = err })
			end
			if payload then
				local data, version, decErr = _DecodeCache(payload)
				if decErr == "empty" then
					if default ~= nil then
						return _InitDefault(key, default, ttl)
					end
					return _Result("not_found")
				end
				if data ~= nil then
					return _Result("ok", { data = data, version = version })
				end
			end
		end
		-- 兜底：锁竞争超时后直接回源，避免请求永久失败
	end

	local data, version, loadErr = _LoadDb(key)
	if token then
		_ReleaseLock(lockKey, token)
	end
	if loadErr then
		return _Result("source_error", { err = loadErr })
	end

	if data == nil then
		-- 空值缓存也用 NX：期间若有并发写入，不能把真实值覆盖成"不存在"
		local emptyRet, emptyErr = DBMEM.Exec("set", key, CODEC.PD_Encode(0, false), "NX", "EX", EMPTY_TTL)
		if emptyErr then
			return _Result("redis_error", { err = emptyErr })
		end
		if not emptyRet then
			local cur = DBMEM.Exec("get", key)
			if cur then
				local curData, curVersion, decErr = _DecodeCache(cur)
				if curData ~= nil then
					return _Result("ok", { data = curData, version = curVersion })
				end
				if decErr == "empty" then
					if default ~= nil then
						return _InitDefault(key, default, ttl)
					end
					return _Result("not_found")
				end
			end
		end
		if default ~= nil then
			return _InitDefault(key, default, ttl)
		end
		return _Result("not_found")
	end

	-- 回填用 NX：避免覆盖并发写入的新值
	local setRet, setErr = DBMEM.Exec("set", key, CODEC.PD_Encode(version or 0, data), "NX", "EX", ttl)
	if setErr then
		return _Result("redis_error", { err = setErr })
	end
	if not setRet then
		local cur = DBMEM.Exec("get", key)
		if cur then
			local curData, curVersion = _DecodeCache(cur)
			if curData ~= nil then
				return _Result("ok", { data = curData, version = curVersion })
			end
		end
	end
	return _Result("ok", { data = data, version = version or 0 })
end

-- 排行榜
local RANK_TTL = 7 * 24 * 3600	-- 榜单兜底 TTL，防止旧榜无限堆积

function RankAdd(key, member, score)
	local ret, err = DBMEM.Exec("zincrby", key, score, member)
	if err then
		return _Result("redis_error", { err = err })
	end
	DBMEM.Exec("expire", key, RANK_TTL)
	return _Result("ok", { score = tonumber(ret) or ret })
end

function RankTop(key, n)
	n = tonumber(n) or 10
	local list, err = DBMEM.Exec("zrevrange", key, 0, n - 1, "WITHSCORES")
	if err then
		return _Result("redis_error", { err = err })
	end
	local top = {}
	for i = 1, #list, 2 do
		top[#top + 1] = { member = list[i], score = tonumber(list[i + 1]) }
	end
	return _Result("ok", { list = top })
end

-- 持久化积压
function QueueInfo()
	local queueLen, err1 = DBMEM.Exec("llen", QUEUE_KEY)
	if err1 then
		return _Result("redis_error", { err = err1 })
	end
	local deadLen, err2 = DBMEM.Exec("llen", DEAD_KEY)
	if err2 then
		return _Result("redis_error", { err = err2 })
	end

	local oldestAge
	local oldest = DBMEM.Exec("lindex", QUEUE_KEY, 0)
	if oldest then
		local task = CODEC.PD_Unpack(oldest)
		if type(task) == "table" and task.ts then
			oldestAge = ostime() - task.ts
		end
	end
	return _Result("ok", { queue = queueLen, dead = deadLen, oldest_age = oldestAge })
end

function QueueClear()
	DBMEM.Exec("del", QUEUE_KEY)
	DBMEM.Exec("del", DEAD_KEY)
	if PROCESSING_KEY then
		DBMEM.Exec("del", PROCESSING_KEY)
	end
	return _Result("ok")
end

-- 完成一次任务：活动 + 档案 + 排行榜，全部在 cell 内完成（调用方只发一次消息）
function AddScore(uid, game, activityId, score)
	assert(uid and game and activityId)
	score = tonumber(score) or 10
	if score <= 0 then
		return _Result("invalid_param", { err = "invalid score" })
	end

	local actKey = CODEC.MemKeyAct(game, activityId)
	local profileKey = CODEC.MemKeyActProfile(game, activityId, uid)
	local rankKey = CODEC.MemKeyRank(game, activityId)
	local now = ostime()

	-- 1. 全服活动
	local actRes = Read(actKey, DEFAULT_TTL, { stage = 1, total_score = 0, update_time = now })
	if actRes.code ~= "ok" then
		return actRes
	end
	local activity, actVersion = actRes.data, actRes.version

	local actOk = false
	for _ = 1, 3 do
		activity.total_score = (activity.total_score or 0) + score
		activity.update_time = ostime()
		local casRes = Cas(actKey, actVersion, activity, DEFAULT_TTL)
		if casRes.code == "ok" then
			actVersion = casRes.version
			actOk = true
			break
		elseif casRes.code == "conflict" then
			local rr = Read(actKey, DEFAULT_TTL, { stage = 1, total_score = 0, update_time = now })
			if rr.code ~= "ok" then
				return rr
			end
			activity, actVersion = rr.data, rr.version
		else
			return casRes
		end
	end
	if not actOk then
		return _Result("cas_retry_exhausted", { target = "activity" })
	end

	-- 2. 玩家档案
	local proRes = Read(profileKey, DEFAULT_TTL, {
		uid = uid, score = 0, join_count = 0, update_time = now,
	})
	if proRes.code ~= "ok" then
		return proRes
	end
	local profile, proVersion = proRes.data, proRes.version

	local proOk = false
	for _ = 1, 3 do
		profile.score = (profile.score or 0) + score
		profile.join_count = (profile.join_count or 0) + 1
		profile.update_time = ostime()
		local casRes = Cas(profileKey, proVersion, profile, DEFAULT_TTL)
		if casRes.code == "ok" then
			proVersion = casRes.version
			proOk = true
			break
		elseif casRes.code == "conflict" then
			local rr = Read(profileKey, DEFAULT_TTL, {
				uid = uid, score = 0, join_count = 0, update_time = now,
			})
			if rr.code ~= "ok" then
				return rr
			end
			profile, proVersion = rr.data, rr.version
		else
			return casRes
		end
	end
	if not proOk then
		return _Result("cas_retry_exhausted", { target = "profile" })
	end

	-- 3. 排行榜（可重建的展示投影）
	local rankRes = RankAdd(rankKey, uid, score)
	if rankRes.code ~= "ok" then
		return rankRes
	end

	return _Result("ok", {
		activity = { total_score = activity.total_score, version = actVersion },
		profile = { score = profile.score, join_count = profile.join_count, version = proVersion },
		rank_score = rankRes.score,
	})
end

---------------------- mem 协议命令入口 ----------------------

-- 第一个参数即 eig（路由键），也就是业务 key
function RESPONSE.mem_read(key, ttl, default)
	return Read(key, ttl, default)
end

function RESPONSE.mem_cas(key, version, data, ttl)
	return Cas(key, version, data, ttl)
end

function RESPONSE.mem_rank_add(key, member, score)
	return RankAdd(key, member, score)
end

function RESPONSE.mem_rank_top(key, n)
	return RankTop(key, n)
end

-- eig 为 uid，按玩家分散到不同 cell
function RESPONSE.mem_add_score(uid, game, activityId, score)
	return AddScore(uid, game, activityId, score)
end

function RESPONSE.mem_queue_info(routingKey)
	return QueueInfo()
end

function RESPONSE.mem_queue_clear(routingKey)
	return QueueClear()
end

---------------------- 持久化消费者 ----------------------

function Init(no)
	PROCESSING_KEY = "play:persist:processing:" .. tostring(skynet.getenv("server_id")) .. "_" .. tostring(no)
end

-- 处理单个任务：done / drop / retry
local function _ProcessTask(task)
	local t = CODEC.PD_Unpack(task)
	if type(t) ~= "table" or type(t.saveName) ~= "string"
		or t.data == nil or type(t.version) ~= "number" then
		_WARN_F("persist drop invalid task")
		return "drop"
	end

	-- 版本检查：数据库已有更新的版本则跳过，防止旧任务覆盖新数据
	local raw, err = DB.GetModDataStrict(t.saveName)
	if err then
		return "retry", err
	end
	if raw then
		local payload = CODEC.PD_Unpack(raw)
		if type(payload) == "string" then
			local curVersion = CODEC.PD_Decode(payload)
			if curVersion and curVersion >= t.version then
				return "done"
			end
		end
	end

	local isOk = DB.SaveModData(t.saveName, CODEC.PD_Encode(t.version, t.data))
	if isOk then
		return "done"
	end
	return "retry", "save fail"
end

local function _RequeueOrDead(task)
	local t = CODEC.PD_Unpack(task)
	if type(t) ~= "table" then
		return
	end
	t.retry = (t.retry or 0) + 1
	if t.retry > MAX_RETRY then
		DBMEM.Exec("rpush", DEAD_KEY, tserialise(t))
	else
		DBMEM.Exec("rpush", QUEUE_KEY, tserialise(t))
	end
end

function StartConsumer()
	assert(PROCESSING_KEY, "playdata server not init")

	skynet.fork(function ()
		-- 崩溃恢复：把本 cell 上次未确认的任务移回主队列
		local recovered = 0
		while true do
			local task = DBMEM.Exec("rpoplpush", PROCESSING_KEY, QUEUE_KEY)
			if not task then
				break
			end
			recovered = recovered + 1
		end
		if recovered > 0 then
			_INFO_F("playdata persist recovered %d tasks", recovered)
		end

		while true do
			local isOk, task, err = pcall(DBMEM.Exec, "rpoplpush", QUEUE_KEY, PROCESSING_KEY)
			if not isOk then
				_WARN_F("persist pop fail:%s", tostring(task))
			elseif err then
				_WARN_F("persist queue unavailable:%s", tostring(err))
			elseif task then
				local procOk, status, procErr = pcall(_ProcessTask, task)
				if not procOk then
					_ERROR_F("persist process fail:%s", tostring(status))
					_RequeueOrDead(task)
					DBMEM.Exec("lrem", PROCESSING_KEY, 1, task)
				elseif status == "done" or status == "drop" then
					DBMEM.Exec("lrem", PROCESSING_KEY, 1, task)
				else
					_WARN_F("persist retry:%s", tostring(procErr))
					_RequeueOrDead(task)
					DBMEM.Exec("lrem", PROCESSING_KEY, 1, task)
				end
			end
			skynet.sleep(CONSUMER_TICK)
		end
	end)
	_INFO_F("playdata persist consumer start, %s", PROCESSING_KEY)
end
