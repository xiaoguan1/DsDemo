--------------------
-- Redis 接入基础设施服务
-- 职责：节点内统一管理 Redis 连接，为玩法状态、实例注册表、排行榜等提供读写入口
-- 配置依赖：redis_info（连接信息，见 config/play_node）
-- 说明：play 节点要求 Redis 可用，连接失败将导致节点启动失败（unique 段启动失败即 abort）
--------------------

local skynet = require "skynet"
local redis = require "skynet.db.redis"

local conf = assert(load("return " .. assert(skynet.getenv("redis_info"))))()

local client
local command = {}

-- 通用命令执行：cmd 为 redis 命令名（如 "get"/"set"/"expire"/"zadd"），其余为命令参数
function command.exec(cmd, ...)
	assert(client and cmd)
	return client[cmd](client, ...)
end

skynet.start(function ()
	dofile "./game/global/log.lua"
	dofile "game/global/dblog.lua"

	client = redis.connect({
		host = conf.host,
		port = conf.port,
		db = conf.db,
		overload = true,
		auth = conf.auth,
	})
	-- 连通性自检：启动即暴露连接问题，避免玩法实例启动后才报错
	assert(client:ping() == "PONG", "redis ping fail")
	_INFO_F("redis service ready, host:%s port:%s db:%s",
		tostring(conf.host), tostring(conf.port), tostring(conf.db))

	skynet.dispatch("lua", function (session, source, cmd, ...)
		local f = command[cmd]
		if not f then
			_ERROR_F("unknown command %s", cmd)
			return
		end

		if session then
			skynet.ret(skynet.pack(f(...)))
		else
			f(...)
		end
	end)
end)
