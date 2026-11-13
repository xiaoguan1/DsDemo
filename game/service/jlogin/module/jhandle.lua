-- jlogin 客户端 websocket 连接处理（登录流程专用状态机）
-- 帧格式与 wgate 一致：消息总长度(2字节) | 协议号(2字节) | 协议内容
-- 协议号（demo，登录流程专用）：
--   10001 C->J 登录请求（payload = phone）
--   10002 C->J 确认创角（payload = phone）
--   20001 J->C 登录结果（payload = code:token:ip:port）
--     code 语义：0 成功（附带 token/ip/port）、1 需创角确认、2 登录决策中请稍后、
--     3 无可用 user 节点、4 无存活网关、5 非法协议/参数、6 创角失败
-- 连接状态：status=1 等登录首包 -> status=2 等创角确认 -> 完成后由客户端断开

local skynet = require "skynet"
local websocket = require "http.websocket"

local _ERROR_F = _ERROR_F
local _INFO_F = _INFO_F

local sbyte = string.byte
local ssub = string.sub
local sformat = string.format

local C2J_LOGIN = 10001		-- 登录请求
local C2J_CREATE = 10002	-- 确认创角
local J2C_RESULT = 20001	-- 登录结果

local STATUS_LOGIN = 1		-- 等登录首包
local STATUS_CREATE = 2		-- 等创角确认

local MESSAGE_BINARY_TYPE = "binary"

-- 连接状态表：sid -> { status }
local Clients = {}

-- 登录流程回调（由 global.lua 注入）
local LoginCb = false
local CreateCb = false

handle = { __ClassType = "jhandle" }

-- 打包下行协议帧
local function _PackFrame(proto_id, payload)
	local total = 4 + #payload
	return string.pack(">I2", total) .. string.pack(">I2", proto_id) .. payload
end

-- 登录结果回包：code 0成功(附带 token/ip/port) 1需创角确认 其他失败
function ReplyLoginResult(sid, code, token, ip, port)
	local payload = sformat("%d:%s:%s:%d", code, token or "", ip or "", port or 0)
	websocket.write(sid, _PackFrame(J2C_RESULT, payload), MESSAGE_BINARY_TYPE)
end

-- 标记连接进入"等创角确认"状态
function MarkCreate(sid)
	local info = Clients[sid]
	if info then
		info.status = STATUS_CREATE
	end
end

-- 注入登录/创角回调（global.lua 的 OnClientLogin/OnClientCreate）
function SetLoginCb(f_login, f_create)
	LoginCb = f_login
	CreateCb = f_create
end

function handle.warning()
end

function handle.connect(id)
	-- not do
end

function handle.handshake(id, header, url)
	local addr = websocket.addrinfo(id)
	Clients[id] = { status = STATUS_LOGIN, addr = addr }
	_INFO_F("jlogin client:%s handshake success.", addr)
end

-- 解析帧并分派（回调含阻塞调用，fork 到独立协程处理）
local function _Dispatch(id, proto_id, payload)
	local info = Clients[id]
	if not info then
		return
	end

	if info.status == STATUS_LOGIN then
		if proto_id == C2J_LOGIN and LoginCb then
			LoginCb(id, payload)
			return
		end
	elseif info.status == STATUS_CREATE then
		if proto_id == C2J_CREATE and CreateCb then
			CreateCb(id, payload)
			return
		end
	end

	-- 非法协议：提示失败并关闭
	_ERROR_F("jlogin sid:%s status:%s recv invalid proto:%s, close", id, info.status, proto_id)
	ReplyLoginResult(id, 5)
	websocket.close(id, 4000, "invalid proto")
end

local function _Message(id, msg, msg_type)
	assert(msg_type == MESSAGE_BINARY_TYPE)
	local info = Clients[id]
	if not info then
		websocket.close(id, 4000, "sid not exist")
		return
	end

	local size = #msg
	if size < 4 then
		return
	end

	local total = sbyte(msg, 1) * 256 + sbyte(msg, 2)
	if total ~= size then
		websocket.close(id, 4000, "frame total error")
		return
	end

	local proto_id = sbyte(msg, 3) * 256 + sbyte(msg, 4)
	local payload = ssub(msg, 5)

	skynet.fork(_Dispatch, id, proto_id, payload)
end

function handle.message(id, msg, msg_type)
	-- 防止报错而导致websocket失效
	TryCall(_Message, id, msg, msg_type)
end

function handle.ping(id)
	print("jlogin ws ping from: " .. tostring(id) .. "\n")
end

function handle.pong(id)
	print("jlogin ws pong from: " .. tostring(id))
end

local function _Clean(id)
	if Clients[id] then
		Clients[id] = nil
	end
end

function handle.close(id, code, reason)
	print("jlogin ws close from: " .. tostring(id), code, reason)
	_Clean(id)
end

function handle.error(id, reason)
	print("jlogin ws error from: " .. tostring(id))
	_Clean(id)
end

function handle.othererror(id, reason)
	print("jlogin ws othererror from: " .. tostring(id), " " .. tostring(reason))
	_Clean(id)
end
