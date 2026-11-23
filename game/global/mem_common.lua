--------------------
-- memserver（Redis）通用调用封装
-- 与 db_common.lua 同风格：业务侧 Import 本文件后，直接调用本文件声明的全局函数
--
-- 返回约定：成功返回结果；失败返回 nil, err（不抛异常）
--   Redis 不可用时由 memserver 统一降级为 nil, err，业务侧按设计 8.2 自行决定
--   （无法确认可用玩法实例时暂拒新请求，已有玩家连接/资产操作不受影响）
--
-- 键规划（详见 memserver.lua 头部注释）：
--   play:session:<session_id>        会话路由（预留）
--   play:profile:<uid>               玩家玩法档案
--   play:rank:{<game>}:<period>      排行榜（ZSET）
--   play:reg:{<game>}:<instance_id>  实例注册（由 Call_MemReg* 系列维护）
--
-- 所有业务键必须设置 TTL 或清理策略：KV 写入请使用 Call_MemSet 的 ttl 参数
--------------------

local PROXYSVR = Import("game/global/rpc/proxysvr.lua")
local MEMSERVER = assert(PROXYSVR.GetProxyByServiceName("memserver", "lua"), "memserver service invalid")



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
	return MEMSERVER.call.ping()
end

-- 通用命令透传：cmd 为 redis 命令名（如 "scan"/"keys" 等未单独封装的命令）
function Call_MemExec(cmd, ...)
	return MEMSERVER.call.exec(cmd, ...)
end

-- 无需返回值的命令（fire-and-forget）
function Send_MemExec(cmd, ...)
	return MEMSERVER.send.exec(cmd, ...)
end

-- 原子 Lua 脚本：script、keyCount、key1..keyN、arg1..
function Call_MemEval(script, keyCount, ...)
	return MEMSERVER.call.eval(script, keyCount, ...)
end

---------------------- KV ----------------------

function Call_MemGet(key)
	return MEMSERVER.call.get(key)
end

-- ttl > 0 时带过期时间；业务键必须设置生命周期或清理策略
function Call_MemSet(key, value, ttl)
	return MEMSERVER.call.set(key, value, ttl)
end

function Call_MemSetex(key, ttl, value)
	return MEMSERVER.call.setex(key, ttl, value)
end

function Call_MemDel(key)
	return MEMSERVER.call.del(key)
end

function Call_MemExists(key)
	return MEMSERVER.call.exists(key)
end

function Call_MemExpire(key, ttl)
	return MEMSERVER.call.expire(key, ttl)
end

function Call_MemTtl(key)
	return MEMSERVER.call.ttl(key)
end

function Call_MemIncrBy(key, n)
	return MEMSERVER.call.incrby(key, n)
end

-- 批量读取：keys = { "k1", "k2", ... }
function Call_MemMGet(keys)
	assert(type(keys) == "table" and #keys > 0)
	return MEMSERVER.call.mget(table.unpack(keys))
end

---------------------- Hash ----------------------

function Call_MemHGet(key, field)
	return MEMSERVER.call.hget(key, field)
end

function Call_MemHSet(key, field, value)
	return MEMSERVER.call.hset(key, field, value)
end

function Call_MemHDel(key, field)
	return MEMSERVER.call.hdel(key, field)
end

function Call_MemHIncrBy(key, field, n)
	return MEMSERVER.call.hincrby(key, field, n)
end

-- 返回 map：{ [field] = value, ... }
function Call_MemHGetAll(key)
	return MEMSERVER.call.hgetall_map(key)
end

-- 返回原始数组：{ field1, value1, field2, value2, ... }
function Call_MemHGetAllRaw(key)
	return MEMSERVER.call.hgetall(key)
end

---------------------- ZSet（排行榜） ----------------------

function Call_MemZAdd(key, score, member)
	return MEMSERVER.call.zadd(key, score, member)
end

function Call_MemZIncrBy(key, n, member)
	return MEMSERVER.call.zincrby(key, n, member)
end

function Call_MemZRem(key, member)
	return MEMSERVER.call.zrem(key, member)
end

function Call_MemZScore(key, member)
	return MEMSERVER.call.zscore(key, member)
end

function Call_MemZRange(key, startIdx, stopIdx, withscores)
	return MEMSERVER.call.zrange(key, startIdx, stopIdx, withscores)
end

function Call_MemZRevRange(key, startIdx, stopIdx, withscores)
	return MEMSERVER.call.zrevrange(key, startIdx, stopIdx, withscores)
end

---------------------- 玩法实例注册与发现（设计 7.4） ----------------------
-- 约定：TTL 30 秒、心跳 10 秒一次
-- 心跳返回：1 成功、0 代次过期（被新实例覆盖）、-1 注册已过期（需重新注册）

-- 申请单调递增的实例代次
function Call_MemRegNextGeneration(game)
	return MEMSERVER.call.reg_next_generation(game)
end

-- 注册实例：info = {node_name, server_id, cluster_name, service_name, status, load, extra}
function Call_MemRegRegister(game, instanceId, generation, info, ttl)
	return MEMSERVER.call.reg_register(game, instanceId, generation, info, ttl)
end

function Call_MemRegHeartbeat(game, instanceId, generation, load, ttl)
	return MEMSERVER.call.reg_heartbeat(game, instanceId, generation, load, ttl)
end

-- 状态流转：STARTING / READY / DRAINING / DEAD
function Call_MemRegSetStatus(game, instanceId, generation, status)
	return MEMSERVER.call.reg_setstatus(game, instanceId, generation, status)
end

function Call_MemRegUnregister(game, instanceId, generation)
	return MEMSERVER.call.reg_unregister(game, instanceId, generation)
end

function Call_MemRegGet(game, instanceId)
	return MEMSERVER.call.reg_get(game, instanceId)
end

function Call_MemRegList(game)
	return MEMSERVER.call.reg_list(game)
end

-- agent 选实例：只返回 READY
function Call_MemRegListReady(game)
	return MEMSERVER.call.reg_list_ready(game)
end
