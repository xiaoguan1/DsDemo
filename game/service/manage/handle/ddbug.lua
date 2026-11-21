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

-- 取一个启动了 example 的节点：adhoc 服务只有它的宿主节点会登记在 SERVICE_CLUSTERNAME
local function _PickExampleServerId()
	for serverId in pairs(SERVICE_CLUSTERNAME["example"] or {}) do
		return serverId
	end
end

local function _TestRpcToExample(args)
	local serverId = 55001
	if not serverId then
		serverId = _PickExampleServerId()
	end
	if not serverId then
		_ERROR("ddbug rpc test: no node started example, check server_config.is_start_example")
		return false, "no example node"
	end

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

function Handle_Request(data)
	return _TestRpcToExample(data)
end





function __init__()
end

function __update__()
end
