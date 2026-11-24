--------------------
-- dbcell 的 Redis 能力模块（由 memserver 合并而来）
--
-- 背景：play 节点把 Redis 热层与 MySQL 放在同一个 cell 内，
--   读缓存未命中时可直接查本 cell 的 database_info，不再经 dbserver 转发。
-- 协议：dbserver 的 "mem" 协议按 eig（业务 key）把消息路由到 cell，
--   cell 仍用 lua 分发表处理；每个 mem 命令的第一个参数即 eig（路由键）。
--
-- 命令签名说明：
--   get/set/hget/zadd/reg_* 等：第一个参数本身就是业务 key，天然作为路由键
--   ping/exec/eval：第一个参数不是 key，调用方需显式传一个路由键（mem_common 已处理）
--   ping 命名为 mem_ping，避免与 dbcell_center 的 RESPONSE.ping 冲突
--
-- 故障语义：Redis 不可用时返回 nil, err，不抛错；连接失败进入 1 秒冷却
--------------------

local skynet = require "skynet"
local redis = require "skynet.db.redis"
local socketchannel = require "skynet.socketchannel"

local tostring = tostring

local SOCKET_ERROR = socketchannel.error

local conf = assert(load("return " .. assert(skynet.getenv("redis_info"))))()

-- 连接失败后的重试冷却（skynet.now 单位为 1/100 秒）
local CONNECT_RETRY_COOLDOWN = 100

local client
local hasFailed = false
local lastFailTime = 0
local lastFailLogTime = 0

ACCEPT, RESPONSE = {}, {}

local MISC = Import("tool/service/basic/dbcell/mem_registry.lua")

local function _LogFail(cmd, err)
	local now = skynet.now()
	if now - lastFailLogTime >= 100 then
		lastFailLogTime = now
		_ERROR_F("redis %s fail:%s", tostring(cmd), tostring(err))
	end
end

local function _Connect()
	local now = skynet.now()
	if hasFailed and now - lastFailTime < CONNECT_RETRY_COOLDOWN then
		return nil, "redis unavailable"
	end
	if client then
		return client
	end

	local isOk, result = pcall(redis.connect, {
		host = conf.host,
		port = conf.port,
		db = conf.db,
		auth = conf.auth,
		username = conf.username,
	})
	if not isOk or not result then
		hasFailed = true
		lastFailTime = now
		return nil, "redis connect fail:" .. tostring(result)
	end

	local pingOk, pong = pcall(result.ping, result)
	if not pingOk or pong ~= "PONG" then
		hasFailed = true
		lastFailTime = now
		pcall(result.disconnect, result)
		return nil, "redis ping fail:" .. tostring(pong)
	end

	hasFailed = false
	client = result
	_INFO_F("dbcell redis connected, host:%s port:%s db:%s",
		tostring(conf.host), tostring(conf.port), tostring(conf.db))
	return client
end

-- 统一命令执行：成功返回结果值；失败返回 nil, err（不抛错）
function Exec(cmd, ...)
	local c = _Connect()
	if not c then
		return nil, "redis unavailable"
	end
	local isOk, result = pcall(c[cmd], c, ...)
	if not isOk then
		if result == SOCKET_ERROR then
			hasFailed = true
			lastFailTime = skynet.now()
		end
		_LogFail(cmd, result)
		return nil, tostring(result)
	end
	return result
end

-- 心跳保活：失败由连接冷却接管
function CheckMem()
	local pong, err = Exec("ping")
	if pong ~= "PONG" then
		_WARN_F("dbcell redis ping fail:%s", tostring(err or pong))
	end
end

---------------------- 通用命令（mem 协议入口） ----------------------

-- 路由键 + 命令透传
function RESPONSE.exec(routingKey, cmd, ...)
	return Exec(cmd, ...)
end
-- 异步透传（Send_MemExec）走 session=0，也要能命中
ACCEPT.exec = RESPONSE.exec

-- 路由键 + 原子 Lua 脚本
function RESPONSE.eval(routingKey, script, keyCount, ...)
	return Exec("eval", script, keyCount, ...)
end

-- 注意：dbcell_center 已占用 RESPONSE.ping（MySQL 连通性），这里改名
function RESPONSE.mem_ping(routingKey)
	return Exec("ping")
end

-- KV
function RESPONSE.get(key)
	return Exec("get", key)
end

function RESPONSE.set(key, value, ttl)
	if ttl and ttl > 0 then
		return Exec("set", key, value, "EX", ttl)
	end
	return Exec("set", key, value)
end

function RESPONSE.setex(key, ttl, value)
	return Exec("setex", key, ttl, value)
end

function RESPONSE.del(key)
	return Exec("del", key)
end

function RESPONSE.exists(key)
	return Exec("exists", key)
end

function RESPONSE.expire(key, ttl)
	return Exec("expire", key, ttl)
end

function RESPONSE.ttl(key)
	return Exec("ttl", key)
end

function RESPONSE.incrby(key, n)
	return Exec("incrby", key, n or 1)
end

function RESPONSE.mget(...)
	return Exec("mget", ...)
end

-- Hash
function RESPONSE.hget(key, field)
	return Exec("hget", key, field)
end

function RESPONSE.hset(key, field, value)
	return Exec("hset", key, field, value)
end

function RESPONSE.hdel(key, field)
	return Exec("hdel", key, field)
end

function RESPONSE.hincrby(key, field, n)
	return Exec("hincrby", key, field, n or 1)
end

function RESPONSE.hgetall(key)
	return Exec("hgetall", key)
end

function RESPONSE.hgetall_map(key)
	local list, err = Exec("hgetall", key)
	if not list then
		return nil, err
	end
	local map = {}
	for i = 1, #list, 2 do
		map[list[i]] = list[i + 1]
	end
	return map
end

-- ZSet（排行榜）
function RESPONSE.zadd(key, score, member)
	return Exec("zadd", key, score, member)
end

function RESPONSE.zincrby(key, n, member)
	return Exec("zincrby", key, n, member)
end

function RESPONSE.zrem(key, member)
	return Exec("zrem", key, member)
end

function RESPONSE.zscore(key, member)
	return Exec("zscore", key, member)
end

function RESPONSE.zrange(key, startIdx, stopIdx, withscores)
	if withscores then
		return Exec("zrange", key, startIdx, stopIdx, "WITHSCORES")
	end
	return Exec("zrange", key, startIdx, stopIdx)
end

function RESPONSE.zrevrange(key, startIdx, stopIdx, withscores)
	if withscores then
		return Exec("zrevrange", key, startIdx, stopIdx, "WITHSCORES")
	end
	return Exec("zrevrange", key, startIdx, stopIdx)
end

---------------------- 玩法实例注册与发现（7.4） ----------------------

local function _RegCall(f, ...)
	return f(Exec, ...)
end

function RESPONSE.reg_next_generation(game)
	return _RegCall(MISC.RegNextGeneration, game)
end

function RESPONSE.reg_register(game, instanceId, generation, info, ttl)
	return _RegCall(MISC.RegRegister, game, instanceId, generation, info, ttl)
end

function RESPONSE.reg_heartbeat(game, instanceId, generation, load, ttl)
	return _RegCall(MISC.RegHeartbeat, game, instanceId, generation, load, ttl)
end

function RESPONSE.reg_setstatus(game, instanceId, generation, status)
	return _RegCall(MISC.RegSetStatus, game, instanceId, generation, status)
end

function RESPONSE.reg_unregister(game, instanceId, generation)
	return _RegCall(MISC.RegUnregister, game, instanceId, generation)
end

function RESPONSE.reg_get(game, instanceId)
	return _RegCall(MISC.RegGet, game, instanceId)
end

function RESPONSE.reg_list(game)
	return _RegCall(MISC.RegList, game)
end

function RESPONSE.reg_list_ready(game)
	return _RegCall(MISC.RegListReady, game)
end
