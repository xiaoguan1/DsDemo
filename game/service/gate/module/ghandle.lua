-- gate 连接处理模块：握手 -> 进入世界绑定 -> 双向转发
-- 连接状态机：WSocketConnect（未绑定，首包必须是 enter_world）-> WPlayerConnect（已绑定，全部转发 cell）
local skynet = require "skynet"
local websocket = require "http.websocket"
local PROTO = require "proto"
local _ERROR_F = _ERROR_F
local _INFO_F = _INFO_F
local _WARN_F = _WARN_F
local TryCall = TryCall

local sbyte = string.byte
local ssub = string.sub
local sformat = string.format
local pack = string.pack

local WSocketConnect = 1	-- 完成初始网络连接
local WPlayerConnect = 2	-- 完成玩家连接（已绑定 uid）

local MESSAGE_BINARY_TYPE = "binary"	-- 前后端仅支持 binary 消息类型

WScoketToInfo = {}		-- [sid] = { status, addr, url, uid, bind_id }
PlayerToSocket = {}		-- uid -> sid 索引
SocketToPlayer = {}		-- sid -> uid 索引
ConnCount = 0			-- 当前连接数

CellAddr = false		-- cell 服务地址（gate.lua 启动时注入）
GateName = ".GATE"		-- 网关实例名
MaxCount = 5000			-- 最大连接数（gate.lua 覆盖）

handle = {__ClassType = "ghandle"}

-- 打包下行协议帧：消息总长度（2字节）| 协议编号（2字节）| 协议内容
local function _PackFrame(proto_id, payload)
	local total = 4 + #payload
	return pack(">I2", total) .. pack(">I2", proto_id) .. payload
end

-- 绑定玩家与 socket 连接（顶号：同 uid 旧连接被关闭）
function Bind(id, uid, bind_id)
	local sinfo = WScoketToInfo[id]
	if not sinfo then
		return false
	end

	local old_id = PlayerToSocket[uid]
	if old_id and old_id ~= id then
		SocketToPlayer[old_id] = nil
		websocket.close(old_id, 4000, "replace by new connection")
		_INFO_F("uid:%s rebind, close old sid:%s", uid, old_id)
	end

	sinfo.uid = uid
	sinfo.bind_id = bind_id
	sinfo.status = WPlayerConnect

	PlayerToSocket[uid] = id
	SocketToPlayer[id] = uid
	return true
end

-- 客户端进入世界：向 cell 申请进入 -> 回进入结果 -> 下发视野内实体快照
local function _EnterWorld(id, payload)
	local sinfo = WScoketToInfo[id]
	if not sinfo then
		return
	end

	local uid = payload
	if uid == "" then
		uid = nil
	end
	-- 备用：握手 url 携带 ?uid=xxx
	if not uid and sinfo.url then
		uid = sinfo.url:match("[?&]uid=([^&]+)")
	end

	local bind_id = GateName .. ":" .. id
	local isOk, result = TryCall(skynet.call, CellAddr, "lua", "enter_world", uid, bind_id)
	if not isOk or not result then
		_ERROR_F("sid:%s enter_world fail err:%s", id, tostring(result))
		websocket.close(id, 4000, "enter_world fail")
		return
	end

	uid = result.uid
	if not Bind(id, uid, bind_id) then
		websocket.close(id, 4000, "bind fail")
		return
	end

	-- 回进入结果（uid 为 cell 分配后的最终值）
	websocket.write(id, _PackFrame(PROTO.S2C_ENTER_RESULT, sformat("0:%s:%s:%s", uid, result.x, result.y)), MESSAGE_BINARY_TYPE)
	-- 视野内实体快照
	for _, e in ipairs(result.snapshot) do
		websocket.write(id, _PackFrame(PROTO.S2C_ENTITY_ENTER, pack(">I4ff", e.uid, e.x, e.y)), MESSAGE_BINARY_TYPE)
	end
	_INFO_F("sid:%s enter world uid:%s pos:%s,%s snapshot:%s", id, uid, result.x, result.y, #result.snapshot)
end

function handle.warning()
end

function handle.connect(id)
end

function handle.handshake(id, header, url)
	if WScoketToInfo[id] then
		_ERROR_F("sid:%s is exist.", id)
		return
	end

	local addr = websocket.addrinfo(id)
	if ConnCount >= MaxCount then
		websocket.close(id, 403, "online gt max count")
		_ERROR_F("reject sid:%s addr:%s, gt max:%s", id, addr, MaxCount)
		return
	end

	ConnCount = ConnCount + 1
	WScoketToInfo[id] = {
		status = WSocketConnect,
		addr = addr,
		url = url,	-- 握手 url（可携带 ?uid=xxx）
		uid = nil,
		bind_id = nil,
	}
	_INFO_F("new client %s connect success.", addr)
end

-- 处理玩家上行协议帧
-- 消息总长度（2字节）| 协议编号（2字节）| 协议内容
local function _Message(id, msg, msg_type)
	assert(msg_type == MESSAGE_BINARY_TYPE)
	local sinfo = WScoketToInfo[id]
	if not sinfo then
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
		-- 已绑定：转发给 cell 裁决
		skynet.send(CellAddr, "client", "client_msg", sinfo.uid, proto_id, payload)
	else
		-- 未绑定：首包必须是进入世界
		if proto_id == PROTO.C2S_ENTER then
			skynet.fork(_EnterWorld, id, payload)
		else
			_ERROR_F("sid:%s unbound recv proto:%s, need enter_world", id, proto_id)
			websocket.close(id, 4000, "need enter_world")
		end
	end
end

function handle.message(id, msg, msg_type)
	-- 防止报错导致 websocket 失效
	TryCall(_Message, id, msg, msg_type)
end

function handle.ping(id)
end

function handle.pong(id)
end

-- 连接断开/出错时清理索引，并通知 cell 离线（带 bind_id，cell 校验一致才移除实体）
local function _Clean(id, code, reason)
	local sinfo = WScoketToInfo[id]
	if not sinfo then
		return
	end
	WScoketToInfo[id] = nil
	ConnCount = ConnCount - 1

	local uid = sinfo.uid
	if uid and sinfo.status == WPlayerConnect then
		if PlayerToSocket[uid] == id then
			PlayerToSocket[uid] = nil
		end
		SocketToPlayer[id] = nil
		TryCall(skynet.send, CellAddr, "lua", "leave_world", uid, sinfo.bind_id)
		_INFO_F("player:%s offline sid:%s code:%s reason:%s", uid, id, tostring(code), tostring(reason))
	end
end

function handle.close(id, code, reason)
	_Clean(id, code, reason)
end

function handle.error(id, reason)
	_Clean(id, reason)
end

function handle.othererror(id, reason)
	_Clean(id, reason)
end

---------------------- 供 gate 服务调用的对外接口 ----------------------

-- 向指定玩家推送下行协议帧（cell 调用；uid 不在本网关时静默丢弃）
function PushToClient(uid, proto_id, payload)
	local id = PlayerToSocket[uid]
	if not id then
		return false
	end
	return websocket.write(id, _PackFrame(proto_id, payload), MESSAGE_BINARY_TYPE)
end

-- 当前网关在线连接数
function GetGateCount()
	return ConnCount
end
