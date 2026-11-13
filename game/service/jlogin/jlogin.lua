-- 仲裁登录服务（集群内全局唯一，命名 .JLOGIN）：玩家登录第一步网络连接本服务
-- 1. 监听 jlogin_ipport（server_config 宿主行配置），客户端 websocket 接入
-- 2. 账号判断/创角、登录落点决策、token 发放（逻辑见 global.lua）
-- 3. wgate 注册/心跳、token 校验、login_done 等内部 RPC 接口

local skynet = require "skynet"
local socket = require "skynet.socket"
local websocket = require "http.websocket"

CLIENT_ACCEPT = {}
CLIENT_RESPONSE = {}

ACCEPT = {}
RESPONSE = {}

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = skynet.unpack,
	pack = skynet.pack,
	dispatch = function (session, _, command, ...)
		local f
		if session == 0 then
			f = assert(CLIENT_ACCEPT[command], command)
			f(...)
		else
			f = assert(CLIENT_RESPONSE[command], command)
			skynet.retpack(f(...))
		end
	end
}

skynet.start(function ()
	dofile "./game/global/log.lua"
	dofile "./game/global/dblog.lua"

	skynet.dispatch("lua", function (session, _, command, ...)
		local f
		if session == 0 then
			f = assert(ACCEPT[command], command)
			f(...)
		else
			f = assert(RESPONSE[command], command)
			skynet.retpack(f(...))
		end
	end)

	dofile "game/service/jlogin/global.lua"

	-- 监听客户端接入地址（本节点为宿主时 HOST_ENV.jlogin_ipport 必填）
	local jip, jport = string.match(assert(HOST_ENV.jlogin_ipport, "jlogin host must config jlogin_ipport"), "^(.+):(%d+)$")
	local listend = socket.listen(jip, tonumber(jport), 128)
	_INFO_F("jlogin open listen:%s:%s", jip, jport)

	socket.start(listend, function (newsd, addr)
		skynet.fork(function ()
			_INFO_F("jlogin new client addr:%s connect beginning.", addr)
			local ok, err = websocket.accept(newsd, JHANDLE.handle, "ws", addr)
			if not ok then
				print(err)
			end
		end)
	end)

	if __init__ then
		__init__()
	end
	_INFO_F("jlogin start ok")
end)
