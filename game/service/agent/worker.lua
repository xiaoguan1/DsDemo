-- agent worker（实例2~N，命名 .AGENTN）：承载玩家业务
-- 1. 启动时向管理者（.AGENT）注册
-- 2. bind/unbind 由管理者调用，返回实时玩家数供管理者汇总负载
-- 3. client_msg：玩家上行协议（demo：原样回推，验证链路）
-- 4. 编号 > agent_default_num 的空实例主动退出（动态缩容）

local skynet = require "skynet"

PROXYSVR = Import("game/global/rpc/proxysvr.lua")
assert(CLIENT_ACCEPT)
assert(CLIENT_RESPONSE)
assert(RESPONSE)

local agent_index = AGENT_INDEX
local agent_default_num = tonumber(skynet.getenv("agent_default_num")) or 8

local AgentName = ".AGENT" .. agent_index

-- 本实例在线玩家表：uid -> { gate_name, gate_cn }
Players = {}

local function PlayerCount()
	local cnt = 0
	for _ in pairs(Players) do
		cnt = cnt + 1
	end
	return cnt
end

-- 玩家绑定（管理者 alloc 调用）：记录归属网关，返回负载
function RESPONSE.bind(uid, gate_name, gate_cn)
	local old = Players[uid]
	if old and (old.gate_name ~= gate_name or old.gate_cn ~= gate_cn) then
		_WARN_F("worker:%s player:%s rebind gate:%s -> %s", AgentName, uid, tostring(old.gate_name), tostring(gate_name))
	end
	Players[uid] = { gate_name = gate_name, gate_cn = gate_cn }
	_INFO_F("worker:%s bind player:%s gate:%s", AgentName, uid, tostring(gate_name))
	return PlayerCount()
end

-- 玩家解绑（下线/被顶号）：返回负载；空实例且编号 > 底座则缩容退出
function RESPONSE.unbind(uid)
	if not Players[uid] then
		return PlayerCount()
	end
	Players[uid] = nil
	_INFO_F("worker:%s unbind player:%s", AgentName, uid)

	local count = PlayerCount()
	-- 动态缩容：仅回收编号 > 底座数量的空实例
	if agent_index > agent_default_num and count == 0 then
		TryCall(PROXYSVR.GetProxy(".AGENT", SELF_CLUSTERNAME, "lua").send, "worker_exit", agent_index)
		_INFO_F("worker:%s empty and index:%s > default:%s, exit", AgentName, agent_index, agent_default_num)
		skynet.exit()
	end
	return count
end

-- 处理玩家上行协议（demo：原样回推，验证链路）
function CLIENT_ACCEPT.client_msg(uid, proto_id, payload)
	local info = Players[uid]
	if not info then
		_WARN_F("worker:%s client_msg fail, uid:%s not bind", AgentName, uid)
		return
	end
	TryCall(PROXYSVR.GetProxy(info.gate_name, info.gate_cn, "lua").send, "push", uid, proto_id, payload)
end

-- 管理者缩容指令：当前确实无玩家才退出（有玩家则忽略，防止与绑定并发冲突）
function ACCEPT.shutdown()
	if PlayerCount() == 0 then
		TryCall(PROXYSVR.GetProxy(".AGENT", SELF_CLUSTERNAME, "lua").send, "worker_exit", agent_index)
		_INFO_F("worker:%s empty, shutdown by manager", AgentName)
		skynet.exit()
	end
	_WARN_F("worker:%s ignore manager shutdown, players:%s", AgentName, PlayerCount())
end

-- 当前在线玩家数（监控/仲裁查询）
function RESPONSE.player_count()
	return PlayerCount()
end

-- 启动注册到管理者（实例1，命名 .AGENT）
function __init__()
	TryCall(PROXYSVR.GetProxy(".AGENT", SELF_CLUSTERNAME, "lua").send, "worker_register", agent_index)
end
