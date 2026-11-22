local skynet = require "skynet"
local posix = require "posix"
local protobuf = require "protobuf"
local skiplist = Import("game/global/algorithm/skiplist.lua")
local zlib = require "zlib"

--[[
wget -q -O - "http://127.0.0.1:40001/ddbug"
或者 curl "http://127.0.0.1:40001/ddbug"

携带参数：wget -q -O - "http://127.0.0.1:40001/ddbug?key1=value1&key2=value2。。。"
或者 curl "http://127.0.0.1:40001/ddbug?key1=value1&key2=value2。。。"
]]

local redis = require "skynet.db.redis"
local mongo = require "skynet.db.mongo"
local mysql = require "skynet.db.mysql"

MgConn = false

----------------------------------------------------------------
-- Redis 测试用例（初学者演示）
-- 触发方式：wget -q -O - "http://127.0.0.1:40001/ddbug"
-- 结果全部打印在 manage 服务的日志里
-- 覆盖：连接/ping、string、hash、list、set、zset、通用命令、pipeline、错误处理
----------------------------------------------------------------
local table = table

local function _Line(tag)
	skynet.error("========== " .. tag .. " ==========")
end

-- 1. string：缓存 / 计数器 / 限流
local function _TestString(db)
	_Line("string")
	db:set("demo:str", "hello redis")
	print("get demo:str", db:get("demo:str"))

	db:set("demo:count", 10)
	db:incr("demo:count")          -- 原子自增 +1
	db:incrby("demo:count", 5)     -- 原子加 5
	print("count(10+1+5)", db:get("demo:count"))

	db:setex("demo:temp", 60, "60秒后自动删除")
	print("demo:temp ttl(秒)", db:ttl("demo:temp"))
end

-- 2. hash：玩家属性（一个玩家一个 hash）
local function _TestHash(db)
	_Line("hash")
	db:hset("demo:user:1", "name", "张三")
	db:hset("demo:user:1", "level", 50)
	db:hset("demo:user:1", "gold", 9999)
	print("hget name", db:hget("demo:user:1", "name"))
	print("hgetall(field,value交替)", db:hgetall("demo:user:1"))
	print("hexists gold", db:hexists("demo:user:1", "gold"))
end

-- 3. list：消息队列 / 最近聊天
local function _TestList(db)
	_Line("list")
	db:del("demo:queue")
	db:rpush("demo:queue", "msg1", "msg2", "msg3")  -- 尾部入队
	db:lpush("demo:queue", "msg0")                  -- 头部入队
	print("lrange 0 -1", tool.dumptree(db:lrange("demo:queue", 0, -1)))
	print("llen", db:llen("demo:queue"))
	print("lpop", db:lpop("demo:queue"))
end

-- 4. set：好友 / 标签 / 去重
local function _TestSet(db)
	_Line("set")
	db:del("demo:tags")
	db:sadd("demo:tags", "战士", "法师", "牧师")
	db:sadd("demo:tags", "战士")                    -- 重复添加无效
	print("smembers", tool.dumptree(db:smembers("demo:tags")))
	print("scard", db:scard("demo:tags"))
	print("sismember 法师", db:sismember("demo:tags", "法师"))
end

-- 5. zset：排行榜（游戏后端最常用）
local function _TestZset(db)
	_Line("zset")
	db:del("demo:rank")
	db:zadd("demo:rank", 100, "player1")
	db:zadd("demo:rank", 300, "player2")
	db:zadd("demo:rank", 200, "player3")
	print("zrange(升序)", tool.dumptree(db:zrange("demo:rank", 0, -1)))
	print("zrevrange(降序=排行榜)", tool.dumptree(db:zrevrange("demo:rank", 0, -1)))
	print("zscore player2", tool.dumptree(db:zscore("demo:rank", "player2")))
	print("zrangebyscore 100~250", tool.dumptree(db:zrangebyscore("demo:rank", 100, 250)))
end

-- 6. 通用命令：过期 / 存在性 / 删除
local function _TestCommon(db)
	_Line("通用命令")
	db:set("demo:expire", "i will die")
	db:expire("demo:expire", 30)                   -- 30 秒后过期
	print("ttl(秒)", db:ttl("demo:expire"))
	print("exists", db:exists("demo:expire"))
	print("keys demo:* (生产禁用, 用scan)", tool.dumptree(db:keys("demo:*")))
	db:del("demo:expire")
	print("exists after del", db:exists("demo:expire"))
end

-- 7. pipeline：一次打包多个命令，减少网络往返
local function _TestPipeline(db)
	_Line("pipeline")
	local ops = {
		{ "set", "demo:p1", "a" },
		{ "set", "demo:p2", "b" },
		{ "get", "demo:p1" },
	}
	local resp = {}
	local ok = db:pipeline(ops, resp)
	skynet.error("pipeline ok = " .. tool.dumptree(ok))
	for i, r in ipairs(resp) do
		skynet.error("resp[" .. i .. "] ok=" .. tostring(r.ok) .. " out=" .. tostring(r.out))
	end
end

-- 8. 错误处理：命令出错返回 false + 错误信息，服务不会崩
local function _TestError(db)
	_Line("错误处理")
	-- local ok, err = db:set("demo:err")             -- 故意少传参数
	local ok, err = TryCall(db.set, db, "demo:err")	-- 故意少传参数
	skynet.error("set 缺参数: ok = " .. tostring(ok) .. " err = " .. tostring(err))
	print("get 不存在的key", db:get("demo:no_such_key"))
end

----------------------------------------------------------------
-- rpc 跨节点测试：user 节点 -> play 节点的 example 服务
-- 触发方式：wget -q -O - "http://127.0.0.1:40001/ddbug"
--          可选参数指定目标 play 节点："http://127.0.0.1:40001/ddbug?server_id=55001"
-- 前置条件：目标 play 行 is_start_example = 1（example 是 adhoc 服务），user/play 均已启动
-- 返回：成功打印 example 的实例身份，失败在 manage 日志里输出原因
----------------------------------------------------------------
local rpc = Import("game/global/rpc/rpc.lua")	-- 装载 rpc：定义全局 mod_call 并注册 rpc 协议分发

local function _TestRpcToExample(args)
	local serverId = 55001
	local sId2name = SERVICE_CLUSTERNAME["example"]
	local clustername = sId2name and sId2name[serverId]
	if not clustername then
		_ERROR_F("ddbug rpc test: server_id[%s] not started example", serverId)
		return false, "target not started example"
	end

	local tag = string.format("hello from %s@%s", HOST_ENV.nodename, skynet.getenv("server_id"))
	-- 跨节点调用：rpc.mod_call.服务名[serverId].模块名.函数名(...)
	local isOk, ret = TryCall(function ()
		return rpc.mod_call.example[serverId].EXAMPLE.Ping(tag)
	end)
	if isOk then
		_INFO_F("ddbug rpc test -> %s ok: %s", clustername, tostring(ret))
	else
		_ERROR_F("ddbug rpc test -> %s fail: %s", clustername, tostring(ret))
	end
	return isOk, ret
end

----------------------------------------------------------------
-- mem_common 封装测试：game/global/mem_common.lua
-- 触发方式：wget -q -O - "http://127.0.0.1:40001/ddbug?case=mem"
-- 前置条件：本节点已启动 memserver（unique 基础服务）且 Redis 可用
-- 覆盖：键构造、KV、Hash、ZSet、eval、异步 Send、实例注册/心跳/发现/注销
-- 结果全部打印在 manage 服务日志里：PASS/FAIL 逐项输出，最后汇总
----------------------------------------------------------------
local MEM = Import("game/global/mem_common.lua")

local _PASS, _FAIL = 0, 0

local function _Check(name, condition, detail)
	if condition then
		_PASS = _PASS + 1
		_INFO_F("[mem_common] PASS %s | %s", name, tostring(detail))
		return true
	end
	_FAIL = _FAIL + 1
	_ERROR_F("[mem_common] FAIL %s | %s", name, tostring(detail))
	return false
end

-- 日志展示用：表用 tool.dump，标量用 tostring
local function _Dump(v)
	if type(v) == "table" then
		return tool.dump(v)
	end
	return tostring(v)
end

local function _TestMemCommon()
	_PASS, _FAIL = 0, 0
	local tag = string.format("%d_%d", os.time(), math.random(1000, 9999))
	_Line("mem_common test start tag=" .. tag)

	-- 0. 连通性：Redis 不可用时直接终止，避免后续全是误导性 FAIL
	local pong, pingErr = MEM.Call_MemPing()
	if not _Check("Call_MemPing", pong == "PONG", pingErr or pong) then
		_ERROR_F("[mem_common] redis unavailable, abort test:%s", tostring(pingErr))
		return false, "redis unavailable:" .. tostring(pingErr)
	end

	-- 1. 键构造
	local profileKey = MEM.MemKeyProfile("ddbug_" .. tag)
	_Check("MemKeyProfile", profileKey == "play:profile:ddbug_" .. tag, profileKey)
	local sessionKey = MEM.MemKeySession("s_" .. tag)
	_Check("MemKeySession", sessionKey == "play:session:s_" .. tag, sessionKey)
	local rankKey = MEM.MemKeyRank("ddbug", tag)
	_Check("MemKeyRank", rankKey == "play:rank:{ddbug}:" .. tag, rankKey)

	-- 2. KV
	local kvKey = "ddbug:mem:kv:" .. tag
	local setRet = MEM.Call_MemSet(kvKey, "v1", 60)
	_Check("Call_MemSet", setRet ~= nil, setRet)
	local v1 = MEM.Call_MemGet(kvKey)
	_Check("Call_MemGet", v1 == "v1", v1)
	local existsRet = MEM.Call_MemExists(kvKey)
	_Check("Call_MemExists", existsRet == 1, existsRet)
	local ttl = MEM.Call_MemTtl(kvKey)
	_Check("Call_MemTtl", type(ttl) == "number" and ttl > 0, ttl)
	local expireRet = MEM.Call_MemExpire(kvKey, 120)
	_Check("Call_MemExpire", expireRet == 1, expireRet)

	local cntKey = "ddbug:mem:cnt:" .. tag
	local c1 = MEM.Call_MemIncrBy(cntKey, 5)
	local c2 = MEM.Call_MemIncrBy(cntKey, 3)
	MEM.Call_MemExpire(cntKey, 300)	-- 测试键兜底 TTL，避免中途失败残留
	_Check("Call_MemIncrBy", c1 == 5 and c2 == 8, tostring(c1) .. "/" .. tostring(c2))

	local mget = MEM.Call_MemMGet({ kvKey, cntKey })
	_Check("Call_MemMGet", type(mget) == "table" and mget[1] == "v1" and mget[2] == "8", _Dump(mget))

	local tmpKey = "ddbug:mem:tmp:" .. tag
	local setexRet = MEM.Call_MemSetex(tmpKey, 60, "tmp")
	_Check("Call_MemSetex", setexRet ~= nil, setexRet)
	local delRet = MEM.Call_MemDel(tmpKey)
	_Check("Call_MemDel", delRet == 1, delRet)

	-- 3. 异步命令：send 不等待回包，短暂 sleep 后再校验
	local ffKey = "ddbug:mem:ff:" .. tag
	MEM.Send_MemExec("set", ffKey, "ff", "EX", 60)
	skynet.sleep(10)	-- 0.1 秒
	local ffVal = MEM.Call_MemGet(ffKey)
	_Check("Send_MemExec", ffVal == "ff", ffVal)

	-- 4. 原子 Lua
	local evalKey = "ddbug:mem:eval:" .. tag
	local evalRet = MEM.Call_MemEval("return redis.call('SET', KEYS[1], ARGV[1])", 1, evalKey, "evalv")
	_Check("Call_MemEval", evalRet == "OK", evalRet)
	local evalVal = MEM.Call_MemGet(evalKey)
	_Check("Call_MemEval get", evalVal == "evalv", evalVal)
	MEM.Call_MemExpire(evalKey, 300)

	-- 5. Hash
	local hashKey = "ddbug:mem:hash:" .. tag
	MEM.Call_MemHSet(hashKey, "name", "张三")
	MEM.Call_MemHSet(hashKey, "level", 50)
	MEM.Call_MemExpire(hashKey, 300)	-- 测试键兜底 TTL
	local hname = MEM.Call_MemHGet(hashKey, "name")
	_Check("Call_MemHGet", hname == "张三", hname)
	local hinc = MEM.Call_MemHIncrBy(hashKey, "level", 5)
	_Check("Call_MemHIncrBy", hinc == 55, hinc)
	local hmap = MEM.Call_MemHGetAll(hashKey)
	_Check("Call_MemHGetAll", type(hmap) == "table" and hmap.name == "张三" and hmap.level == "55", _Dump(hmap))
	local hraw = MEM.Call_MemHGetAllRaw(hashKey)
	_Check("Call_MemHGetAllRaw", type(hraw) == "table" and #hraw >= 4, _Dump(hraw))
	local hdel = MEM.Call_MemHDel(hashKey, "name")
	_Check("Call_MemHDel", hdel == 1, hdel)

	-- 6. ZSet（排行榜）
	MEM.Call_MemZAdd(rankKey, 100, "p1")
	MEM.Call_MemZAdd(rankKey, 300, "p2")
	MEM.Call_MemZAdd(rankKey, 200, "p3")
	MEM.Call_MemExpire(rankKey, 300)	-- 测试键兜底 TTL
	local zscore = MEM.Call_MemZScore(rankKey, "p2")
	_Check("Call_MemZScore", tonumber(zscore) == 300, zscore)
	local zinc = MEM.Call_MemZIncrBy(rankKey, 50, "p1")
	_Check("Call_MemZIncrBy", tonumber(zinc) == 150, zinc)
	local zrange = MEM.Call_MemZRange(rankKey, 0, -1, true)
	_Check("Call_MemZRange", type(zrange) == "table" and #zrange == 6, _Dump(zrange))
	local zrev = MEM.Call_MemZRevRange(rankKey, 0, 2, false)
	_Check("Call_MemZRevRange", type(zrev) == "table" and zrev[1] == "p2", _Dump(zrev))
	local zrem = MEM.Call_MemZRem(rankKey, "p1")
	_Check("Call_MemZRem", zrem == 1, zrem)

	-- 7. 实例注册与发现（独立 game 名，避免污染真实玩法注册表）
	local game = "ddbugtest"
	local instId = "ddbug_" .. tag
	local gen, genErr = MEM.Call_MemRegNextGeneration(game)
	_Check("Call_MemRegNextGeneration", type(gen) == "number" and gen >= 1, genErr or gen)

	local regOk, regErr = MEM.Call_MemRegRegister(game, instId, gen, {
		node_name = HOST_ENV.nodename,
		server_id = tonumber(skynet.getenv("server_id")),
		cluster_name = SELF_CLUSTERNAME,
		service_name = ".DDBUG",
		status = "STARTING",
		load = 0,
	}, 60)
	_Check("Call_MemRegRegister", regOk == 1, regErr or regOk)

	local info = MEM.Call_MemRegGet(game, instId)
	_Check("Call_MemRegGet", info and info.status == "STARTING" and info.instance_id == instId, _Dump(info))

	-- 旧代次注册必须被 CAS 拒绝，且不能覆盖新代次内容
	local staleReg = MEM.Call_MemRegRegister(game, instId, gen - 1, { status = "READY", load = 99 }, 60)
	_Check("Call_MemRegRegister stale -> 0", staleReg == 0, staleReg)
	local infoAfterStale = MEM.Call_MemRegGet(game, instId)
	_Check("stale register not overwrite", infoAfterStale and infoAfterStale.load == 0, _Dump(infoAfterStale))

	local setStatus = MEM.Call_MemRegSetStatus(game, instId, gen, "READY")
	_Check("Call_MemRegSetStatus", setStatus == 1, setStatus)

	local readyList = MEM.Call_MemRegListReady(game)
	local foundReady = false
	for _, item in ipairs(readyList or {}) do
		if item.instance_id == instId then
			foundReady = true
			break
		end
	end
	_Check("Call_MemRegListReady", foundReady, _Dump(readyList))

	local hbRet = MEM.Call_MemRegHeartbeat(game, instId, gen, 7, 60)
	_Check("Call_MemRegHeartbeat", hbRet == 1, hbRet)

	-- 旧代次心跳返回 0（被新代次覆盖）
	local staleHbGen = MEM.Call_MemRegHeartbeat(game, instId, gen - 1, 1, 60)
	_Check("Call_MemRegHeartbeat stale -> 0", staleHbGen == 0, staleHbGen)

	local allList = MEM.Call_MemRegList(game)
	local foundAll
	for _, item in ipairs(allList or {}) do
		if item.instance_id == instId then
			foundAll = item
			break
		end
	end
	_Check("Call_MemRegList", foundAll and foundAll.load == 7, _Dump(foundAll))

	local unregRet = MEM.Call_MemRegUnregister(game, instId, gen)
	_Check("Call_MemRegUnregister", unregRet == 1, unregRet)

	local goneInfo = MEM.Call_MemRegGet(game, instId)
	_Check("Call_MemRegGet after unregister", goneInfo == nil, _Dump(goneInfo))
	local staleHb = MEM.Call_MemRegHeartbeat(game, instId, gen, 1, 60)
	_Check("Call_MemRegHeartbeat missing -> -1", staleHb == -1, staleHb)

	-- 8. 清理测试键（注册键已注销；其余删除）
	MEM.Call_MemDel(kvKey)
	MEM.Call_MemDel(cntKey)
	MEM.Call_MemDel(ffKey)
	MEM.Call_MemDel(evalKey)
	MEM.Call_MemDel(hashKey)
	MEM.Call_MemDel(rankKey)
	MEM.Call_MemDel(profileKey)

	_Line(string.format("mem_common test done PASS=%d FAIL=%d", _PASS, _FAIL))
	if _FAIL > 0 then
		return false, string.format("mem_common test fail, pass=%d fail=%d", _PASS, _FAIL)
	end
	return true, string.format("mem_common test pass, %d checks", _PASS)
end

----------------------------------------------------------------
-- playdata 接入示例：调用 example 服务的 demo（设计 7.8/7.9）
-- 触发：play 节点 wget -q -O - "http://127.0.0.1:40101/ddbug"
-- 前置：play 行 is_start_example=1，memserver/Redis 可用
-- 输出：配置 → 活动 → 加分（活动+档案）→ 排行榜 → 持久化积压
----------------------------------------------------------------
local function _TestExamplePlayData()
	if not IsPlay() then
		return false, "skip: not play node"
	end

	local isOk, report = pcall(skynet.call, ".EXAMPLE", "lua", "demo", "ddbug_uid", "ddbug_act")
	if not isOk then
		_ERROR_F("[playdata] example demo fail: %s", tostring(report))
		return false, report
	end
	_INFO_F("[playdata] example demo ok: %s", _Dump(report))
	return true, report
end

-- 调试入口：默认跑 mem_common 测试；?case=rpc 保留原跨节点 rpc 测试
function Handle_Request(data)
	-- _TestRpcToExample()
	-- _TestMemCommon()
	_TestExamplePlayData()
	return true
end





function __init__()
end

function __update__()
end
