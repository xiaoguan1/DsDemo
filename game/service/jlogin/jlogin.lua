-- 登录仲裁服务：仲裁玩家登录哪个user节点，登记全局网关路由

local skynet = require "skynet"
require "skynet.manager"

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
	_INFO_F("jlogin start ok")
end)