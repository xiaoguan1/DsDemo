-- gate 网关服务：持有客户端 WebSocket 长连接，绑定后按 uid 直连转发到 Cell
-- M1 单 Cell：连接层薄，不做路由表，全部消息直达 cell 服务
local skynet = require "skynet"
local socket = require "skynet.socket"
local websocket = require "http.websocket"
local SERVICE_NAME = SERVICE_NAME

-- 启动参数：cell 服务地址（main.lua 经 skynet.newservice("gate", cell) 传入，
-- loader 以字符串形式传给服务主 chunk，skynet.start 回调本身不接收参数）
local launch_cell_addr = ...

-- 加载日志宏
dofile "./game/global/log.lua"

_G.WHANDLE = Import("game/service/gate/module/ghandle.lua")

ACCEPT = {}
RESPONSE = {}

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = skynet.unpack,
	pack = skynet.pack,
}

-- cell 下行推送入口（cell 服务通过 client 协议调用）
CLIENT_ACCEPT = {}
CLIENT_RESPONSE = {}

function CLIENT_ACCEPT.push(uid, proto_id, payload)
	TryCall(_G.WHANDLE.PushToClient, uid, proto_id, payload)
end

skynet.dispatch("client", function (session, source, cmd, ...)
	local f
	if session == 0 then
		f = assert(CLIENT_ACCEPT[cmd], cmd)
		f(...)
	else
		f = assert(CLIENT_RESPONSE[cmd], cmd)
		skynet.retpack(f(...))
	end
end)

skynet.start(function ()
	_G.WHANDLE.CellAddr = assert(tonumber(launch_cell_addr), "gate need cell addr")

	skynet.dispatch("lua", function (session, source, cmd, ...)
		local f
		if session == 0 then
			f = assert(ACCEPT[cmd], cmd)
			f(...)
		else
			f = assert(RESPONSE[cmd], cmd)
			skynet.retpack(f(...))
		end
	end)

	local wsocket_port = assert(tonumber(skynet.getenv("wsocket_port")))
	_G.WHANDLE.MaxCount = tonumber(skynet.getenv("max_wscoket_count")) or 5000

	local listend = socket.listen("::", wsocket_port, 128)
	_INFO_F("gate open listen:%s cell:%08x", wsocket_port, _G.WHANDLE.CellAddr)

	socket.start(listend, function (newsd, addr)
		skynet.fork(function ()
			-- 握手阻塞，放独立协程
			local ok, err = websocket.accept(newsd, WHANDLE.handle, "ws", addr)
			if not ok then
				_ERROR_F("ws accept fail addr:%s err:%s", addr, tostring(err))
			end
		end)
	end)
end)
