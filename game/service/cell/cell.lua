-- Cell 服务：单 Cell 世界权威（M1 单格）
-- 服务内消息串行处理，世界状态免锁；下行统一经 gate 推送
local skynet = require "skynet"
local SERVICE_NAME = SERVICE_NAME

-- 加载日志宏
dofile "./game/global/log.lua"

_G.PROTO = require "proto"
_G.AOI = Import("game/service/cell/module/aoi.lua")
_G.WORLD = Import("game/service/cell/module/world.lua")

ACCEPT = {}
RESPONSE = {}
CLIENT_ACCEPT = {}
CLIENT_RESPONSE = {}

-- gate 服务地址（main 启动后注入）
local GateAddr = false

-- 下行广播：转发给 gate 推送给客户端
local function _Broadcast(uid, proto_id, payload)
	if not GateAddr then
		return
	end
	skynet.send(GateAddr, "client", "push", uid, proto_id, payload)
end

-- main 启动后注入 gate 地址
function ACCEPT.set_gate(addr)
	GateAddr = addr
	WORLD.Broadcast = _Broadcast
	_INFO_F("cell bind gate:%08x", addr)
end

-- 玩家离线通知（gate 转发，带 bind_id 防误删）
function ACCEPT.leave_world(uid, bind_id)
	TryCall(WORLD.Leave, uid, bind_id)
end

-- 玩家进入世界（gate 同步调用）
function RESPONSE.enter_world(uid, bind_id)
	return WORLD.Enter(uid, bind_id)
end

-- 压测入口（perf 服务调用）
function RESPONSE.perf_run(n, frames, step_size)
	return WORLD.PerfRun(n, frames, step_size)
end

-- 客户端移动上报解包："x,y" 或 "x,y,vx,vy,t"
local function _UnpackMove(payload)
	local len = #payload
	if len == 8 then
		local x, y = string.unpack(">ff", payload)
		return true, x, y
	elseif len == 20 then
		local x, y, vx, vy, t = string.unpack(">ffffI4", payload)
		return true, x, y, vx, vy, t
	end
	return false
end

-- gate 转发来的玩家上行消息
function CLIENT_ACCEPT.client_msg(uid, proto_id, payload)
	if proto_id == PROTO.C2S_MOVE then
		local ok, x, y, vx, vy, t = _UnpackMove(payload)
		if not ok then
			_WARN_F("bad move payload uid:%s len:%s", tostring(uid), #payload)
			return
		end
		WORLD.Move(uid, x, y, vx, vy, t)
	else
		_WARN_F("unknown client proto:%s from uid:%s", tostring(proto_id), tostring(uid))
	end
end

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = skynet.unpack,
	pack = skynet.pack,
}

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
	_INFO("cell service ready")
end)
