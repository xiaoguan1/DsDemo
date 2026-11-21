local skynet = require "skynet"

PROXYSVR = Import("game/global/rpc/proxysvr.lua")
PROTO = Import("game/global/proto.lua")
HANDLE = Import("game/service/agent/handle.lua")	-- 模块表即"协议名 -> 处理函数"
assert(CLIENT_ACCEPT)
assert(CLIENT_RESPONSE)

-- 实例编号与底座数量（agent.lua 启动时注入 AGENT_INDEX，已 tonumber 为数字）
local agent_index = AGENT_INDEX
local agent_default_num = ALL_SERVICE_MAP.agent.default_cnt or 8	-- 底座实例数（缩容回收判断用）

-- 本实例命名（与 startup/main.lua 的命名规则保持一致）
local AgentName
if agent_index == 1 then
	AgentName = ".AGENT"
else
	AgentName = ".AGENT" .. agent_index
end

-- 本实例在线玩家表：uid -> { gate_name = ..., gate_cn = ..., epoch = ... }
Players = {}

-- 玩家分配登记（网关/登录服务调用；幂等：重复 bind 覆盖旧归属）
-- epoch 为登录所有权纪元：顶号后旧网关的 unbind 携带旧 epoch，不能误删新绑定
function CLIENT_ACCEPT.bind(uid, gate_name, gate_cn, epoch)
	local old = Players[uid]
	if old and (old.gate_name ~= gate_name or old.gate_cn ~= gate_cn) then
		_WARN_F("agent:%s player:%s rebind gate:%s -> %s", AgentName, uid, tostring(old.gate_name), tostring(gate_name))
	end
	Players[uid] = { gate_name = gate_name, gate_cn = gate_cn, epoch = epoch }
	_INFO_F("agent:%s bind player:%s gate:%s epoch:%s", AgentName, uid, tostring(gate_name), tostring(epoch))
end

-- 玩家下线/被顶号解绑（wgate 断线联动调用）
function CLIENT_ACCEPT.unbind(uid, epoch)
	local info = Players[uid]
	if not info then
		return
	end
	-- 过期所有权的解绑直接忽略（顶号后旧连接可能晚于新连接断开）
	if epoch and info.epoch and info.epoch ~= epoch then
		_WARN_F("agent:%s ignore stale unbind uid:%s epoch:%s ~= %s",
			AgentName, uid, tostring(epoch), tostring(info.epoch))
		return
	end
	Players[uid] = nil
	_INFO_F("agent:%s unbind player:%s", AgentName, uid)

	-- 即刻落库：玩家下线时同步保存本服务所有脏模块（失败只告警，不影响下线流程）
	if MODULE_DB then
		local isOk, err = pcall(MODULE_DB.SaveDirtyNow)
		if not isOk then
			_ERROR_F("agent:%s unbind player:%s save fail:%s", AgentName, uid, tostring(err))
		end
	end

	-- 动态缩容：仅回收编号 > 底座数量的空实例（编号1~N为底座，永驻）
	if agent_index > agent_default_num and next(Players) == nil then
		_INFO_F("agent:%s empty and index:%s > default:%s, exit", AgentName, agent_index, agent_default_num)
		if MODULE_DB then
			pcall(MODULE_DB.Shutdown_SaveModule)	-- 实例退出前同步落库
		end
		skynet.exit()
	end
end

-- 处理玩家上行协议：帧头协议号查表 -> decode request -> 业务处理 -> 按类型回包
function CLIENT_ACCEPT.client_msg(uid, proto_id, payload)
	local info = Players[uid]
	if not info then
		_WARN_F("agent:%s client_msg fail, uid:%s not bind", AgentName, uid)
		return
	end

	local name = PROTO.NameById(proto_id)
	if not name then
		_WARN_F("agent:%s client_msg fail, unknown proto_id:%s uid:%s", AgentName, tostring(proto_id), uid)
		return
	end
	local body = PROTO.Body(name)
	if body.type == "push" then
		_WARN_F("agent:%s client_msg err, push proto:%s can not come from client", AgentName, name)
		return
	end

	local req, err = PROTO.DecodeRequest(name, payload)
	if not req then
		_WARN_F("agent:%s client_msg decode fail, proto:%s uid:%s err:%s", AgentName, name, uid, tostring(err))
		return
	end

	local f = rawget(HANDLE, name)	-- 模块表带 __index=_G，rawget 避免误查全局函数
	if not f then
		_WARN_F("agent:%s client_msg no handler, proto:%s uid:%s", AgentName, name, uid)
		return
	end

	local isOk, rsp = TryCall(f, uid, req)
	if not isOk then
		_ERROR_F("agent:%s handle proto:%s uid:%s error", AgentName, name, uid)
		return
	end

	-- notify 无回包；response 把业务结果编码后回推客户端
	if body.type == "response" then
		local out, encodeErr = PROTO.EncodeResponse(name, rsp)
		if not out then
			_ERROR_F("agent:%s encode proto:%s uid:%s err:%s", AgentName, name, uid, tostring(encodeErr))
			return
		end
		TryCall(PROXYSVR.GetProxy(info.gate_name, info.gate_cn, "lua").send, "push", uid, body.id, out)
	end
end

-- 业务主动下发：只写协议名，内部查编号 + protobuf 编码后经网关推送
function PushProto(uid, name, data)
	local info = Players[uid]
	if not info then
		_WARN_F("agent:%s PushProto fail, uid:%s not online", AgentName, uid)
		return false
	end
	local body = PROTO.Body(name)
	if not body or not body.response then
		_WARN_F("agent:%s PushProto err, proto:%s no response message", AgentName, name)
		return false
	end
	local out, err = PROTO.EncodeResponse(name, data)
	if not out then
		_ERROR_F("agent:%s PushProto encode fail, proto:%s uid:%s err:%s", AgentName, name, uid, tostring(err))
		return false
	end
	TryCall(PROXYSVR.GetProxy(info.gate_name, info.gate_cn, "lua").send, "push", uid, body.id, out)
	return true
end

-- 当前在线玩家数（登录分配时最小连接仲裁用；pairs 计数避免 table 空洞导致 # 不准）
function RESPONSE.player_count()
	local cnt = 0
	for _ in pairs(Players) do
		cnt = cnt + 1
	end
	return cnt
end

-- 关服落库（manage 关服流程调用）：同步保存全部模块后返回
function RESPONSE.shutdown_save()
	if MODULE_DB then
		MODULE_DB.Shutdown_SaveModule()
	end
	return true
end