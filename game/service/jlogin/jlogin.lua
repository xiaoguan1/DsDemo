-- 仲裁登录服务（集群内全局唯一，命名 .JLOGIN）：玩家登录第一步网络连接本服务
-- 1. 监听 :: 双栈端口（端口取自 server_config 宿主行 jlogin_port），客户端 websocket 接入
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

	-- Import 首载自动调 __init__（发号器注册、登录回调注入、定时清理）
	Import("game/service/jlogin/global.lua")
	-- 监听客户端接入地址：:: 双栈（IPv4/IPv6 通吃），端口取自中心库 server_config.jlogin_port
	if not HOST_ENV.jlogin_port then
		error("jlogin host must config jlogin_port")
	end
	local jport = tonumber(HOST_ENV.jlogin_port)
	local listend = socket.listen("::", jport, 128)
	_INFO_F("jlogin open listen:[::]:%s", jport)

	socket.start(listend, function (newsd, addr)
		skynet.fork(function ()
			_INFO_F("jlogin new client addr:%s connect beginning.", addr)
			local ok, err = websocket.accept(newsd, JHANDLE.handle, "ws", addr)
			if not ok then
				print(err)
			end
		end)
	end)

	-- __init__ 已由 Import 首载自动调用（SafeImport.CallInit），无需显式调用
	_INFO_F("jlogin start ok")
end)
