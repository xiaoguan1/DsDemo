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

local CLIENT_C2W_TOKEN_LOGIN = 10003	-- C->W token 登录（payload = token）
local W2C_LOGIN_RESULT = 20001		-- W->C 登录结果（payload = code:msg）

WScoketToInfo = false
-- {
	-- [socket_id] = {
	-- 	status = ..., 1:完成初始网络连接、2:完成玩家连接
	-- 	addr = ..., ip地址
	-- 	url = ..., 握手携带的url（可含 ?uid=xxx）
	-- 	uid = ..., 绑定后的玩家唯一uid
	-- 	agent_name = ..., 玩家逻辑服(agent)的服务名
	-- 	agent_clustername = ..., 玩家逻辑服所在节点
	-- 	bind_id = ..., 绑定流水号（GateName: sid，下线通知凭此校验，防止误踢新连接）
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

-- 客户端 token 登录：校验凭证 -> 本地 agent 分配绑定 -> 回登录成功 -> 通知 jlogin 登录完成
local function _TokenLogin(id, token)
	local jlogin_cn = GetJLoginClusterName()
	if not jlogin_cn then
		websocket.close(id, 4000, "jlogin not ready")
		return
	end
	local isOk, uid, server_id = TryCall(PROXYSVR.GetProxy(".JLOGIN", jlogin_cn, "lua").call, "verify_token", token)
	if not isOk or not uid then
		_ERROR_F("sid:%s verify token fail, close", id)
		websocket.close(id, 4000, "token invalid")
		return
	end
	-- token 是发给指定落点节点网关的，连错网关直接拒绝
	if tonumber(server_id) ~= HOST_ENV.server_id then
		_ERROR_F("sid:%s token server_id:%s ~= self:%s, close", id, tostring(server_id), HOST_ENV.server_id)
		websocket.close(id, 4000, "wrong gate")
		return
	end

	-- wgate 与 agent 必为同节点：直接调用本节点 .AGENT 分配 worker
	local bind_id = GateName .. ":" .. id
	local isOk2, workerName = TryCall(PROXYSVR.GetProxy(".AGENT", SELF_CLUSTERNAME, "lua").call,
		"alloc", uid, GateName, GateClusterName, bind_id)
	if not isOk2 or not workerName then
		_ERROR_F("sid:%s alloc fail, close", id)
		websocket.close(id, 4000, "alloc fail")
		return
	end

	local isOk3 = Bind(id, uid, workerName, SELF_CLUSTERNAME, bind_id)
	if not isOk3 then
		websocket.close(id, 4000, "bind fail")
		return
	end

	-- 回登录成功
	websocket.write(id, _PackFrame(W2C_LOGIN_RESULT, "0:ok"), MESSAGE_BINARY_TYPE)
	_INFO_F("sid:%s token login success uid:%s agent:%s bind_id:%s", id, uid, workerName, bind_id)

	-- 通知 jlogin 登录完成：清 Logging 占位，跨节点顶号则踢旧节点连接
	TryCall(PROXYSVR.GetProxy(".JLOGIN", jlogin_cn, "lua").send, "login_done", uid)
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
		-- 未绑定：首包必须是 token 登录（登录决策由 jlogin 完成，网关只认 token）
		if proto_id == CLIENT_C2W_TOKEN_LOGIN then
			skynet.fork(_TokenLogin, id, payload)
		else
			_ERROR_F("sid:%s unbound recv proto:%s, need token login", id, proto_id)
			websocket.close(id, 4000, "need token login")
		end
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

		-- 通知玩家逻辑服(agent)解绑（带 bind_id，agent 校验一致才解绑，防止旧连接下线误踢新连接）
		if sinfo.agent_name and sinfo.agent_clustername then
			TryCall(PROXYSVR.GetProxy(sinfo.agent_name, sinfo.agent_clustername, "lua").send,
				"unbind", uid, sinfo.bind_id)
		end
		_INFO_F("player:%s offline, gate:%s sid:%s bind_id:%s code:%s reason:%s", uid, GateName, id, tostring(sinfo.bind_id), tostring(code), tostring(reason))
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

-- 绑定玩家与socket连接（token 登录成功后调用）
function Bind(id, uid, agent_name, agent_cn, bind_id)
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

	-- 同网关顶号：先记旧连接，写新索引后关闭（跨网关顶号由 worker rebind 时 kick）
	local old_id = PlayerToSocket[uid]

	sinfo.uid = uid
	sinfo.agent_name = agent_name
	sinfo.agent_clustername = agent_cn
	sinfo.bind_id = bind_id
	sinfo.status = WPlayerConnect

	PlayerToSocket[uid] = id
	SocketToPlayer[id] = uid

	if old_id and old_id ~= id then
		websocket.close(old_id, 4000, "replace by new connection")
		_INFO_F("uid:%s rebind same gate, close old sid:%s", uid, old_id)
	end
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

-- 向 jlogin 注册本网关监听地址并维持心跳（10秒一次，jlogin 30秒无心跳剔除）
function StartGateRegister(wsocket_port)
	local jlogin_cn = GetJLoginClusterName()
	if not jlogin_cn then
		_ERROR_F("gate:%s jlogin not found, register skip", GateName)
		return
	end
	local ip = assert(smatch(SELF_IPPORT, "^(.-):%d+$"))
	local server_id = HOST_ENV.server_id
	skynet.fork(function ()
		while true do
			TryCall(PROXYSVR.GetProxy(".JLOGIN", jlogin_cn, "lua").send,
				"register_gate", server_id, GateName, GateClusterName, ip, wsocket_port)
			skynet.sleep(10 * 100)
		end
	end)
end