--------------------
-- Redis 接入基础设施服务（对应《无状态分布式架构设计方案》第七、八章）
--
-- 职责：
--   1. 连接管理：节点内唯一 Redis 连接，连接失败懒重连（冷却 1 秒），不 abort 进程
--      注意：单次连接尝试会阻塞调用协程；失败后冷却期内直接返回错误，避免反复阻塞
--   2. 常用操作封装：KV / Hash / ZSet / 原子 Lua 脚本
--   3. 玩法实例注册与发现（7.4）：注册、CAS 心跳续期、状态流转、注销、列表
--
-- 配置：redis_info（见 config/main_node、config/play_node）
--       redis_info = [[{ host = "127.0.0.1", port = 6379, db = 0, auth = "xxx", username = "xxx" }]]
--       HA：当前直连单实例；生产建议 host/port 指向 VIP/代理，或由运维层接 Sentinel 保障主从切换
--
-- 键规划（7.7，按用途分区；所有业务键必须带 TTL 或清理策略）：
--   play:reg:{<game>}:<instance_id>   实例注册信息（TTL 心跳，超时自动消失）
--   play:reg:{<game>}:idx             实例 id 索引集合（发现时顺带清理过期成员）
--   play:reg:{<game>}:gen             实例代次计数器（INCR，保证新代次更大）
--   play:session:<session_id>         会话路由（预留，出现会话型玩法时启用）
--   play:profile:<uid>                玩家玩法档案
--   play:rank:{<game>}:<period>       排行榜（ZSET）
--   说明：注册表三类键使用 {<game>} hash tag，兼容 Redis Cluster 的同槽约束
--
-- 实例状态机（7.4）：STARTING / READY / DRAINING / DEAD，发现方只选择 READY
-- 注册约定：TTL 30 秒、心跳 10 秒一次；心跳返回 0 表示代次过期、-1 表示注册已过期需重新注册
--
-- 故障语义（8.2）：Redis 不可用时本服务返回 nil, err，不中断调用方；
--   user 节点仍可启动（memserver 启动自检失败仅告警），由业务侧决定拒绝新的玩法请求
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

local command = {}

-- 注册表与发现的键、原子脚本、CAS 逻辑见 misc.lua（无状态，可独立热更）
local MISC = Import("tool/service/basic/memserver/misc.lua")

local function _LogFail(cmd, err)
	local now = skynet.now()
	if now - lastFailLogTime >= 100 then	-- 失败日志 1 秒最多一条，避免 Redis 故障时刷屏
		lastFailLogTime = now
		_ERROR_F("redis %s fail:%s", tostring(cmd), tostring(err))
	end
end

-- 建立连接并自检；失败进入冷却，返回 nil, err
local function _Connect()
	local now = skynet.now()
	-- 刚发生过连接/通信失败：冷却期内直接返回，避免每个请求都阻塞在重连上
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
	_INFO_F("redis connected, host:%s port:%s db:%s", tostring(conf.host), tostring(conf.port), tostring(conf.db))
	return client
end

-- 统一命令执行：成功返回命令结果；失败返回 nil, err（不向调用方抛错）
-- redis 库约定：命令成功返回 (true, value)、命令错误返回 (false, errmsg)、连接错误抛异常
-- 由此：get/zscore 等未命中时 value 为 nil，本函数返回 nil（与故障的 nil, err 区分开）
local function _Exec(cmd, ...)
	local c = _Connect()
	if not c then
		return nil, "redis unavailable"
	end
	local isOk, ok, value = pcall(c[cmd], c, ...)
	if not isOk then
		-- 通信层失败进入冷却；Redis 命令错误（如 WRONGTYPE）不影响后续请求
		if ok == SOCKET_ERROR then
			hasFailed = true
			lastFailTime = skynet.now()
		end
		_LogFail(cmd, ok)
		return nil, tostring(ok)
	end
	if ok == false then
		-- redis 返回 '-' 错误响应，value 为错误信息
		_LogFail(cmd, value)
		return nil, tostring(value)
	end
	return value
end

---------------------- 通用操作封装 ----------------------

function command.ping()
	return _Exec("ping")
end

-- 通用命令透传：cmd 为 redis 命令名（如 "get"/"set"/"expire"/"scan"）
function command.exec(cmd, ...)
	return _Exec(cmd, ...)
end

-- 原子 Lua 脚本：script、keyCount、key1..keyN、arg1..
function command.eval(script, keyCount, ...)
	return _Exec("eval", script, keyCount, ...)
end

-- KV
function command.get(key)
	return _Exec("get", key)
end

-- ttl > 0 时带过期时间，强制业务键设置生命周期（7.7）
function command.set(key, value, ttl)
	if ttl and ttl > 0 then
		return _Exec("set", key, value, "EX", ttl)
	end
	return _Exec("set", key, value)
end

function command.setex(key, ttl, value)
	return _Exec("setex", key, ttl, value)
end

function command.del(key)
	return _Exec("del", key)
end

function command.exists(key)
	return _Exec("exists", key)
end

function command.expire(key, ttl)
	return _Exec("expire", key, ttl)
end

function command.ttl(key)
	return _Exec("ttl", key)
end

function command.incrby(key, n)
	return _Exec("incrby", key, n or 1)
end

function command.mget(...)
	return _Exec("mget", ...)
end

-- Hash
function command.hget(key, field)
	return _Exec("hget", key, field)
end

function command.hset(key, field, value)
	return _Exec("hset", key, field, value)
end

function command.hdel(key, field)
	return _Exec("hdel", key, field)
end

function command.hincrby(key, field, n)
	return _Exec("hincrby", key, field, n or 1)
end

-- 原始数组（field1, value1, field2, value2, ...）
function command.hgetall(key)
	return _Exec("hgetall", key)
end

-- 转成 map 返回
function command.hgetall_map(key)
	local list, err = _Exec("hgetall", key)
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
function command.zadd(key, score, member)
	return _Exec("zadd", key, score, member)
end

function command.zincrby(key, n, member)
	return _Exec("zincrby", key, n, member)
end

function command.zrem(key, member)
	return _Exec("zrem", key, member)
end

function command.zscore(key, member)
	return _Exec("zscore", key, member)
end

function command.zrange(key, startIdx, stopIdx, withscores)
	if withscores then
		return _Exec("zrange", key, startIdx, stopIdx, "WITHSCORES")
	end
	return _Exec("zrange", key, startIdx, stopIdx)
end

function command.zrevrange(key, startIdx, stopIdx, withscores)
	if withscores then
		return _Exec("zrevrange", key, startIdx, stopIdx, "WITHSCORES")
	end
	return _Exec("zrevrange", key, startIdx, stopIdx)
end

---------------------- 玩法实例注册与发现 ----------------------
-- 键、原子脚本与 CAS 逻辑统一放在 misc.lua，本文件只做命令入口

local function _RegCall(f, ...)
	return f(_Exec, ...)
end

-- 申请新代次：实例启动时调用，返回单调递增的 generation
function command.reg_next_generation(game)
	return _RegCall(MISC.RegNextGeneration, game)
end

-- 注册实例：info = {node_name, server_id, cluster_name, service_name, status, load, extra}
-- 返回 1 成功、0 代次过期（被更新代次覆盖）
function command.reg_register(game, instanceId, generation, info, ttl)
	return _RegCall(MISC.RegRegister, game, instanceId, generation, info, ttl)
end

-- 心跳续期并更新负载：返回 1 成功、0 代次过期、-1 注册已过期（需重新注册）
function command.reg_heartbeat(game, instanceId, generation, load, ttl)
	return _RegCall(MISC.RegHeartbeat, game, instanceId, generation, load, ttl)
end

-- 状态流转：STARTING / READY / DRAINING / DEAD（只选 READY 接收新请求）
function command.reg_setstatus(game, instanceId, generation, status)
	return _RegCall(MISC.RegSetStatus, game, instanceId, generation, status)
end

-- 注销实例：优雅下线时调用
function command.reg_unregister(game, instanceId, generation)
	return _RegCall(MISC.RegUnregister, game, instanceId, generation)
end

-- 查单个实例，返回解码后的信息表（不存在返回 nil）
function command.reg_get(game, instanceId)
	return _RegCall(MISC.RegGet, game, instanceId)
end

-- 查全部实例：返回解码后的数组，并顺带清理心跳过期后残留的索引成员
function command.reg_list(game)
	return _RegCall(MISC.RegList, game)
end

-- 只返回 READY 实例（agent 选实例用）
function command.reg_list_ready(game)
	return _RegCall(MISC.RegListReady, game)
end

skynet.start(function ()
	dofile "./game/global/log.lua"
	dofile "game/global/dblog.lua"

	-- 启动自检失败不 abort：user 层不应因 Redis 故障而无法启动（设计 8.2），
	-- 首次业务调用时按冷却间隔懒重连
	local c, err = _Connect()
	if not c then
		_WARN_F("redis not ready at startup:%s (will retry on demand)", tostring(err))
	end

	skynet.dispatch("lua", function (session, source, cmd, ...)
		local f = command[cmd]
		if not f then
			_ERROR_F("memserver unknown command:%s", tostring(cmd))
			if session ~= 0 then
				skynet.retpack(nil, "unknown command")
			end
			return
		end

		if session == 0 then
			f(...)
		else
			skynet.retpack(f(...))
		end
	end)

	_INFO_F("memserver service ready")
end)
