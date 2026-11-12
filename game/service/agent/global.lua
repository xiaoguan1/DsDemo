local skynet = require "skynet"

PROXYSVR = Import("game/global/rpc/proxysvr.lua")
assert(CLIENT_ACCEPT)
assert(CLIENT_RESPONSE)

-- 实例编号与底座数量（agent.lua 启动时注入 AGENT_INDEX，已 tonumber 为数字）
local agent_index = AGENT_INDEX
local agent_default_num = tonumber(skynet.getenv("agent_default_num")) or 8

-- 本实例命名（与 startup/main.lua、jlogin 的命名规则保持一致）
local AgentName
if agent_index == 1 then
	AgentName = ".AGENT"
else
	AgentName = ".AGENT" .. agent_index
end

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

-- 本实例在线玩家表：uid -> { gate_name = ..., gate_cn = ... }
Players = {}

-- 玩家分配登记（jlogin 调用；幂等：重复 bind 覆盖旧归属）
function CLIENT_ACCEPT.bind(uid, gate_name, gate_cn)
	local old = Players[uid]
	if old and (old.gate_name ~= gate_name or old.gate_cn ~= gate_cn) then
		_WARN_F("agent:%s player:%s rebind gate:%s -> %s", AgentName, uid, tostring(old.gate_name), tostring(gate_name))
	end
	Players[uid] = { gate_name = gate_name, gate_cn = gate_cn }
	_INFO_F("agent:%s bind player:%s gate:%s", AgentName, uid, tostring(gate_name))
end

-- 玩家下线/被顶号解绑（jlogin 或 wgate 断线联动调用）
function CLIENT_ACCEPT.unbind(uid)
	if not Players[uid] then
		return
	end
	Players[uid] = nil
	_INFO_F("agent:%s unbind player:%s", AgentName, uid)

	-- 动态缩容：仅回收编号 > 底座数量的空实例（编号1~N为底座，永驻）
	if agent_index > agent_default_num and next(Players) == nil then
		local jlogin_cn = GetJLoginClusterName()
		if jlogin_cn then
			TryCall(PROXYSVR.GetProxy(".JLOGIN", jlogin_cn, "lua").send, "agent_exit", agent_index)
		end
		_INFO_F("agent:%s empty and index:%s > default:%s, exit", AgentName, agent_index, agent_default_num)
		skynet.exit()
	end
end

-- 处理玩家上行协议（demo：原样回推，验证链路）
function CLIENT_ACCEPT.client_msg(uid, proto_id, payload)
	local info = Players[uid]
	if not info then
		_WARN_F("agent:%s client_msg fail, uid:%s not bind", AgentName, uid)
		return
	end
	TryCall(PROXYSVR.GetProxy(info.gate_name, info.gate_cn, "lua").send, "push", uid, proto_id, payload)
end

-- 当前在线玩家数（jlogin 最小连接仲裁用；pairs 计数避免 table 空洞导致 # 不准）
function RESPONSE.player_count()
	local cnt = 0
	for _ in pairs(Players) do
		cnt = cnt + 1
	end
	return cnt
end