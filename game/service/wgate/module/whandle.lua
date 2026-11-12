local skynet = require "skynet"
local websocket = require "http.websocket"
local max_wscoket_count = assert(tonumber(skynet.getenv("max_wscoket_count")))
local _ERROR_F = _ERROR_F
local _INFO_F = _INFO_F
local _WARN_F = _WARN_F
local TryCall = TryCall
local PROXYSVR = Import("game/global/rpc/proxysvr.lua")

local schar = string.char
local sbyte = string.byte
local ssub = string.sub
local smatch = string.match
local sformat = string.format

local WSocketConnect = 1	-- 完成初始网络连接
local WPlayerConnect = 2	-- 完成玩家连接

local MESSAGE_BINARY_TYPE = "binary"	-- 前后端仅支持binary消息类型

WScoketToInfo = false
-- {
	-- [socket_id] = {
	-- 	status = ..., 1:完成初始网络连接、2:完成玩家连接
	-- 	addr = ..., ip地址
	-- 	url = ..., 握手携带的url（可含 ?uid=xxx）
	-- 	uid = ..., 绑定后的玩家唯一uid
	-- 	agent_name = ..., 玩家逻辑服(agent)的服务名
	-- 	agent_clustername = ..., 玩家逻辑服所在节点
	-- },
	-- ...,
-- }

-- uid -> sid 索引（登录绑定后建立）
PlayerToSocket = {}

-- sid -> uid 索引
SocketToPlayer = {}

-- 当前网关实例的服务名/所在节点（wgate服务启动时注入）
GateName = ".WGATE"
GateClusterName = false

handle = {__ClassType = "whandle"} -- 加上 __ClassType 支持热更

-- 获取登录仲裁服务所在节点
local function GetJLoginClusterName()
	local data = SERVICE_CLUSTERNAME and SERVICE_CLUSTERNAME["jlogin"]
	if not data then
		return
	end
	for _, cn in pairs(data) do
		if cn then
			return cn
		end
	end
end

-- 打包下行协议帧：消息总长度（2字节）| 协议编号（2字节）| 协议内容
local function _PackFrame(proto_id, payload)
	local total = 4 + #payload
	return string.pack(">I2", total) .. string.pack(">I2", proto_id) .. payload
end

function handle.warning ()
end

function handle.connect(id)
	-- not do
end

function handle.handshake(id, header, url)
	local sinfo = WScoketToInfo[id]
	if sinfo then
		_ERROR_F("sid:%s is exist. info:%s", id, tool.dump(sinfo))
		return
	end

	local addr = websocket.addrinfo(id)
	if #WScoketToInfo >= max_wscoket_count then
		websocket.close(id, 403, "online player gt max count!")
		_ERROR_F("reject sid:%s addr:%s connect, because gt max_count:%s", id, addr, max_wscoket_count)
		return
	end

	WScoketToInfo[id] = {
		status = WSocketConnect,
		addr = addr,
		url = url,	-- 握手url（demo：可携带 ?uid=xxx）
		uid = nil,
		agent_name = nil,
		agent_clustername = nil,
	}
	_INFO_F("new client adds:%s connect success.", addr)
end

-- 处理玩家上行协议
-- 消息总长度（2字节）| 协议编号（2字节）| 协议内容
-- 注释：协议长度 = 消息总长度 - 4
local function _Message(id, msg, msg_type)
	assert(msg_type == MESSAGE_BINARY_TYPE)
	local sinfo = WScoketToInfo[id]
	if not sinfo then
		_ERROR_F("sid:%s not exist, msg discard", id)
		websocket.close(id, 4000, "sid not exist")
		return
	end

	local size = #msg
	if size < 4 then
		_ERROR_F("sid:%s recv frame too short, size:%s", id, size)
		return
	end

	local total = sbyte(msg, 1) * 256 + sbyte(msg, 2)
	if total ~= size then
		_ERROR_F("sid:%s frame total:%s ~= size:%s", id, total, size)
		websocket.close(id, 4000, "frame total error")
		return
	end

	local proto_id = sbyte(msg, 3) * 256 + sbyte(msg, 4)
	local payload = ssub(msg, 5)

	if sinfo.status == WPlayerConnect then
		-- 已绑定：转发给玩家逻辑服(agent)
		TryCall(PROXYSVR.GetProxy(sinfo.agent_name, sinfo.agent_clustername, "client").send,
			"client_msg", sinfo.uid, proto_id, payload)
	else
		-- 未绑定：首包视为登录请求，交给登录仲裁服务
		local jlogin_cn = GetJLoginClusterName()
		if not jlogin_cn then
			_ERROR_F("sid:%s jlogin not found, close", id)
			websocket.close(id, 4000, "jlogin not ready")
			return
		end
		-- 尝试从握手url解析uid（?uid=xxx），解析不到由jlogin兜底生成
		local uid = sinfo.url and smatch(sinfo.url, "uid=([%w_%-]+)")
		TryCall(PROXYSVR.GetProxy(".JLOGIN", jlogin_cn, "client").send,
			"login", id, uid, sinfo.url or "", proto_id, payload)
	end
end

function handle.message(id, msg, msg_type)
	-- 防止报错而导致websocket失效
	TryCall(_Message, id, msg, msg_type)
end

function handle.ping(id)
	print("ws ping from: " .. tostring(id) .. "\n")
end

function handle.pong(id)
	print("ws pong from: " .. tostring(id))
end

-- 连接断开/出错时清理索引，并通知登录仲裁与agent
local function _Clean(id, code, reason)
	local sinfo = WScoketToInfo[id]
	if not sinfo then
		return
	end
	WScoketToInfo[id] = nil

	local uid = sinfo.uid
	if uid and sinfo.status == WPlayerConnect then
		if PlayerToSocket[uid] == id then
			PlayerToSocket[uid] = nil
		end
		SocketToPlayer[id] = nil

		-- 通知登录仲裁服务校验并注销路由
		local jlogin_cn = GetJLoginClusterName()
		if jlogin_cn then
			TryCall(PROXYSVR.GetProxy(".JLOGIN", jlogin_cn, "client").send,
				"logout", uid, GateName, GateClusterName)
		end
		-- 通知玩家逻辑服(agent)解绑
		if sinfo.agent_name and sinfo.agent_clustername then
			TryCall(PROXYSVR.GetProxy(sinfo.agent_name, sinfo.agent_clustername, "client").send,
				"unbind", uid)
		end
		_INFO_F("player:%s offline, gate:%s sid:%s code:%s reason:%s", uid, GateName, id, tostring(code), tostring(reason))
	end
end

function handle.close(id, code, reason)
	print("ws close from: " .. tostring(id), code, reason)
	_Clean(id, code, reason)
end

function handle.error(id, reason)
	print("ws error from: " .. tostring(id))
	_Clean(id, reason)
end

function handle.othererror(id, reason)
	print("ws othererror from: " .. tostring(id), " " .. tostring(reason))
	_Clean(id, reason)
end

---------------------- 供 wgate 服务调用的对外接口 ----------------------

-- 绑定玩家与socket连接（登录仲裁服务调用）
function Bind(id, uid, agent_name, agent_cn)
	local sinfo = WScoketToInfo[id]
	if not sinfo then
		return false, "sid not exist"
	end

	-- 该连接此前已绑定过，先清理旧索引
	local old_uid = sinfo.uid
	if old_uid then
		if PlayerToSocket[old_uid] == id then
			PlayerToSocket[old_uid] = nil
		end
		SocketToPlayer[id] = nil
	end

	sinfo.uid = uid
	sinfo.agent_name = agent_name
	sinfo.agent_clustername = agent_cn
	sinfo.status = WPlayerConnect

	PlayerToSocket[uid] = id
	SocketToPlayer[id] = uid
	return true
end

-- 向指定玩家推送下行协议帧
function PushToClient(uid, proto_id, payload)
	local id = PlayerToSocket[uid]
	if not id then
		_WARN_F("push fail, uid:%s not on gate:%s", uid, GateName)
		return false
	end
	return websocket.write(id, _PackFrame(proto_id, payload), MESSAGE_BINARY_TYPE)
end

-- 踢下线（顶号等场景）
function Kick(uid)
	local id = PlayerToSocket[uid]
	if not id then
		return false
	end
	websocket.close(id, 4000, "kick by server")
	return true
end

-- 当前网关在线连接数（最小连接仲裁用）
function GetGateCount()
	return #WScoketToInfo
end