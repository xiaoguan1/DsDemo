local skynet = require "skynet"
local socket = require "skynet.socket"
local websocket = require "http.websocket"
local max_wscoket_count = assert(tonumber(skynet.getenv("max_wscoket_count")))
local _ERROR_F = _ERROR_F
local _INFO_F = _INFO_F
local _WARN_F = _WARN_F
local TryCall = TryCall
local PROXYSVR = Import("game/global/rpc/proxysvr.lua")
local PROTO = Import("game/global/proto.lua")

local schar = string.char
local sbyte = string.byte
local ssub = string.sub

local WSocketConnect = 1	-- 完成初始网络连接
local WPlayerConnect = 2	-- 完成玩家连接

local MESSAGE_BINARY_TYPE = "binary"	-- 前后端仅支持binary消息类型

WScoketToInfo = false
-- {
	-- [socket_id] = {
	-- 	status = ..., 1:完成初始网络连接、2:完成玩家连接
	-- 	addr = ..., ip地址
	-- 	url = ..., 握手携带的url（可含 ?uid=xxx）
	-- 	header = ..., 握手请求头（socket 移交给其他网关时复用）
	-- 	uid = ..., 绑定后的玩家唯一uid
	-- 	agent_name = ..., 玩家逻辑服(agent)的服务名
	-- 	agent_clustername = ..., 玩家逻辑服所在节点
	-- 	login_epoch = ..., 登录所有权纪元（断线注销在线表时校验）
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
GateIndex = 1
IsLoginGate = false		-- 仅 .WGATE（编号1）处理登录首包

-- 待接管的移交上下文：fd -> {uid, phone, epoch, reply_proto}
local ADOPT_CTX = {}

handle = {__ClassType = "whandle"} -- 加上 __ClassType 支持热更

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
		header = header,	-- 移交 socket 时供目标网关恢复 websocket 会话
		uid = nil,
		agent_name = nil,
		agent_clustername = nil,
		login_epoch = nil,
	}
	_INFO_F("new client adds:%s connect success.", addr)

	-- 被登录网关移交过来的连接：握手恢复后立即完成 agent 绑定并回登录成功包
	local ctx = ADOPT_CTX[id]
	if ctx then
		ADOPT_CTX[id] = nil
		local isOk = TryCall(WLOGIN.OnAdopted, id, ctx)
		if not isOk then
			Close(id, 4000, "login complete fail")
		end
	end
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
		-- 未绑定：首包走登录流程（仅登录网关 .WGATE 处理）
		if IsLoginGate then
			WLOGIN.HandleClientMessage(id, proto_id, payload)
		else
			_ERROR_F("sid:%s connect non-login gate:%s, close", id, GateName)
			websocket.close(id, 4000, "please connect login gate")
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

-- 连接断开/出错时清理索引，并通知 agent 解绑
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

		-- 通知玩家逻辑服(agent)解绑（携带登录纪元，避免顶号后旧连接误删新绑定）
		if sinfo.agent_name and sinfo.agent_clustername then
			TryCall(PROXYSVR.GetProxy(sinfo.agent_name, sinfo.agent_clustername, "client").send,
				"unbind", uid, sinfo.login_epoch)
		end
		-- 通知登录网关注销节点在线表（登录网关本地直接调用）
		if sinfo.login_epoch then
			if IsLoginGate then
				TryCall(WLOGIN.OnOffline, uid, sinfo.login_epoch)
			else
				TryCall(skynet.send, ".WGATE", "lua", "offline", uid, sinfo.login_epoch)
			end
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

-- 绑定玩家与socket连接（登录流程调用）
function Bind(id, uid, agent_name, agent_cn, login_epoch)
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
	sinfo.login_epoch = login_epoch
	sinfo.status = WPlayerConnect

	PlayerToSocket[uid] = id
	SocketToPlayer[id] = uid
	return true
end

-- 按协议名编码并下发一帧（登录流程使用）
function PushFrame(id, protoName, data)
	local protoId = PROTO.Id(protoName)
	if not protoId then
		return false, "proto not exist:" .. tostring(protoName)
	end
	local payload, err = PROTO.EncodeResponse(protoName, data)
	if not payload then
		return false, err
	end
	local isOk, writeErr = pcall(websocket.write, id, _PackFrame(protoId, payload), MESSAGE_BINARY_TYPE)
	if not isOk then
		return false, writeErr
	end
	return true
end

-- 关闭连接（登录阶段使用：先摘除索引，避免断线回调误触发下线流程）
function Close(id, code, reason)
	WScoketToInfo[id] = nil
	ADOPT_CTX[id] = nil
	pcall(websocket.close, id, code, reason)
end

-- 把 socket 移交给本节点另一个网关实例
-- 说明：socket.abandon 后 fd 脱离本服务，由目标网关 socket.start + 恢复握手；
--       客户端在移交期间不应急于发送下一包（移交前已读走登录请求的完整帧）
function Transfer(id, targetGate, ctx)
	local sinfo = WScoketToInfo[id]
	if not sinfo then
		return false, "sid not exist"
	end
	local addr, url, header = sinfo.addr, sinfo.url, sinfo.header

	-- 先摘除索引：abandon 会唤醒读取协程，不能让它按断线流程解绑
	WScoketToInfo[id] = nil
	websocket.detach(id)	-- 解除本服务对 ws 会话的跟踪，消息循环随即退出
	socket.abandon(id)

	local isOk, ret = pcall(skynet.send, targetGate, "lua", "adopt", id, addr, url, header, ctx)
	if not isOk or ret == false then
		pcall(socket.close_fd, id)
		return false, isOk and "target gate not found" or ret
	end
	_INFO_F("handoff sid:%s uid:%s -> gate:%s", tostring(id), tostring(ctx.uid), targetGate)
	return true
end

-- 接管其他网关移交过来的 socket（目标网关调用）
function Adopt(id, addr, url, header, ctx)
	if ADOPT_CTX[id] then
		_ERROR_F("adopt sid:%s repeat", tostring(id))
		return
	end
	ADOPT_CTX[id] = ctx

	skynet.fork(function ()
		local isOk, err = pcall(socket.start, id)
		if not isOk then
			_ERROR_F("adopt sid:%s socket start fail:%s", tostring(id), tostring(err))
			ADOPT_CTX[id] = nil
			pcall(socket.close_fd, id)
			return
		end

		-- 握手已在登录网关完成，这里跳过握手读取直接恢复 websocket 会话
		-- （websocket.adopt 为项目新增接口，见 skynet/lualib/http/websocket.lua 注释）
		local ok, acceptErr = websocket.adopt(id, handle, "ws", addr, header, url)
		if not ok then
			_ERROR_F("adopt sid:%s websocket adopt fail:%s", tostring(id), tostring(acceptErr))
		end
		ADOPT_CTX[id] = nil
	end)
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