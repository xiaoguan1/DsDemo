--------------------
-- Redis 通用调用封装（客户端）
--
-- memserver 已合并进 dbserver/dbcell：
--   - 协议：向 .DBSERVER 发 "mem" 消息，dbserver 按 eig（业务 key）路由到某个 cell
--   - cell 内同时持有 Redis 与 MySQL，playdata 的读穿透/CAS/持久化都在 cell 内完成
--   - user 节点没有 redis_info，mem 命令不可用（ddbug 已按节点跳过）
--
-- 返回约定：成功返回结果；失败返回 nil, err
-- 每个 mem 命令的第一个参数即路由键：
--   get/set/hget/zadd/reg_* 等本身第一个参数就是业务 key，直接作为 eig
--   ping/exec/eval 第一个参数不是 key，这里统一传 "mem" 作为路由键
--------------------

local skynet = require "skynet"
local PROXYSVR = Import("game/global/rpc/proxysvr.lua")

-- 发送侧需要注册 mem 协议（与 db_common 注册 db 协议同理）
skynet.register_protocol({
	name = "mem",
	id = skynet.PTYPE_MEM,
	pack = skynet.pack,
	unpack = skynet.unpack,
})

local DBSERVER = assert(PROXYSVR.GetProxyByServiceName("dbserver", "mem"), "dbserver service invalid")

-- 供 playdata/client.lua 复用同一个 mem 协议代理，避免重复创建
function GetMemProxy()
	return DBSERVER
end

---------------------- 键构造（统一前缀，避免散落硬编码） ----------------------

function MemKeyProfile(uid)
	assert(uid)
	return "play:profile:" .. uid
end

function MemKeySession(sessionId)
	assert(sessionId)
	return "play:session:" .. sessionId
end

function MemKeyRank(game, period)
	assert(game and period)
	return "play:rank:{" .. game .. "}:" .. period
end

---------------------- 通用 ----------------------

function Call_MemPing()
	return DBSERVER.call.mem_ping("mem")
end

-- 通用命令透传（不支持按 key 路由，统一落到 "mem" 路由键所在 cell）
function Call_MemExec(cmd, ...)
	return DBSERVER.call.exec("mem", cmd, ...)
end

-- 无需返回值的命令（fire-and-forget）
function Send_MemExec(cmd, ...)
	return DBSERVER.send.exec("mem", cmd, ...)
end

-- 原子 Lua 脚本：script、keyCount、key1..keyN、arg1..
function Call_MemEval(script, keyCount, ...)
	return DBSERVER.call.eval("mem", script, keyCount, ...)
end

---------------------- KV ----------------------

function Call_MemGet(key)
	return DBSERVER.call.get(key)
end

function Call_MemSet(key, value, ttl)
	return DBSERVER.call.set(key, value, ttl)
end

function Call_MemSetex(key, ttl, value)
	return DBSERVER.call.setex(key, ttl, value)
end

function Call_MemDel(key)
	return DBSERVER.call.del(key)
end

function Call_MemExists(key)
	return DBSERVER.call.exists(key)
end

function Call_MemExpire(key, ttl)
	return DBSERVER.call.expire(key, ttl)
end

function Call_MemTtl(key)
	return DBSERVER.call.ttl(key)
end

function Call_MemIncrBy(key, n)
	return DBSERVER.call.incrby(key, n)
end

-- 批量读取：keys = { "k1", "k2", ... }
function Call_MemMGet(keys)
	assert(type(keys) == "table" and #keys > 0)
	return DBSERVER.call.mget(table.unpack(keys))
end

---------------------- Hash ----------------------

function Call_MemHGet(key, field)
	return DBSERVER.call.hget(key, field)
end

function Call_MemHSet(key, field, value)
	return DBSERVER.call.hset(key, field, value)
end

function Call_MemHDel(key, field)
	return DBSERVER.call.hdel(key, field)
end

function Call_MemHIncrBy(key, field, n)
	return DBSERVER.call.hincrby(key, field, n)
end

function Call_MemHGetAll(key)
	return DBSERVER.call.hgetall_map(key)
end

function Call_MemHGetAllRaw(key)
	return DBSERVER.call.hgetall(key)
end

---------------------- ZSet（排行榜） ----------------------

function Call_MemZAdd(key, score, member)
	return DBSERVER.call.zadd(key, score, member)
end

function Call_MemZIncrBy(key, n, member)
	return DBSERVER.call.zincrby(key, n, member)
end

function Call_MemZRem(key, member)
	return DBSERVER.call.zrem(key, member)
end

function Call_MemZScore(key, member)
	return DBSERVER.call.zscore(key, member)
end

function Call_MemZRange(key, startIdx, stopIdx, withscores)
	return DBSERVER.call.zrange(key, startIdx, stopIdx, withscores)
end

function Call_MemZRevRange(key, startIdx, stopIdx, withscores)
	return DBSERVER.call.zrevrange(key, startIdx, stopIdx, withscores)
end

---------------------- 玩法实例注册与发现（设计 7.4） ----------------------

function Call_MemRegNextGeneration(game)
	return DBSERVER.call.reg_next_generation(game)
end

function Call_MemRegRegister(game, instanceId, generation, info, ttl)
	return DBSERVER.call.reg_register(game, instanceId, generation, info, ttl)
end

function Call_MemRegHeartbeat(game, instanceId, generation, load, ttl)
	return DBSERVER.call.reg_heartbeat(game, instanceId, generation, load, ttl)
end

function Call_MemRegSetStatus(game, instanceId, generation, status)
	return DBSERVER.call.reg_setstatus(game, instanceId, generation, status)
end

function Call_MemRegUnregister(game, instanceId, generation)
	return DBSERVER.call.reg_unregister(game, instanceId, generation)
end

function Call_MemRegGet(game, instanceId)
	return DBSERVER.call.reg_get(game, instanceId)
end

function Call_MemRegList(game)
	return DBSERVER.call.reg_list(game)
end

function Call_MemRegListReady(game)
	return DBSERVER.call.reg_list_ready(game)
end
