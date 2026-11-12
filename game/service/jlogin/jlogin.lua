-- 仲裁登录服务（集群内全局唯一，命名 .JLOGIN）：所有 user 节点玩家登录统一访问本服务
-- 1. pick_node：挑选玩家落点的 user 节点（顶号复用原节点，新玩家轮询分配）
-- 2. alloc：选定节点后调用该节点 agent 管理者分配 worker，返回节点 server_id 与 worker 名
-- 3. unbind：玩家下线/顶号，转发到落点节点解绑
-- 4. 玩家落点缓存：uid -> user 节点 server_id（本服务全局唯一，进程内缓存即可）

local skynet = require "skynet"

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
	_INFO_F("jlogin start ok")
end)
