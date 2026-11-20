local skynet = require "skynet"
local sformat = string.format
local os_time = os.time

PROXYSVR = Import("game/global/rpc/proxysvr.lua")
GATEWAY_ROUTE = Import("game/global/gateway_route.lua")
assert(CLIENT_ACCEPT)

-- 网关多实例命名规则（与 startup/main.lua 保持一致：.WGATE、.WGATE2、.WGATE3...）
local function GateName(i)
	if i == 1 then
		return ".WGATE"
	end
	return ".WGATE" .. i
end

-- agent 多实例命名规则（与 startup/main.lua 保持一致：.AGENT、.AGENT2、.AGENT3...）
local function AgentName(i)
	if i == 1 then
		return ".AGENT"
	end
	return ".AGENT" .. i
end

-- 在线 agent 实例集合与扩容游标（存内存；jlogin 重启后重置为底座数量，可接受）
local agent_default_num = tonumber(skynet.getenv("agent_default_num")) or 8
local agent_max_player = tonumber(skynet.getenv("agent_max_player")) or 50
local AGENT_LIVE = {}
local AGENT_NEXT_INDEX = agent_default_num + 1
for i = 1, agent_default_num do
	AGENT_LIVE[i] = i
end

-- 动态扩容：新建一个 agent 实例并命名注册
local function ExtendAgent(cn)
	local next_index = AGENT_NEXT_INDEX
	local id = skynet.newservice("agent", next_index)
	if not id then
		_ERROR_F("extend agent index:%s fail", next_index)
		return
	end
	skynet.name(AgentName(next_index), id)
	AGENT_LIVE[#AGENT_LIVE + 1] = next_index
	AGENT_NEXT_INDEX = next_index + 1
	_INFO_F("extend agent:%s", AgentName(next_index))
	return AgentName(next_index)
end

-- 最小连接仲裁：选当前节点里玩家数最少的未满 agent（全满则扩容；死实例惰性剔除）
local function PickAgent(cn)
	local min_name, min_count
	local live = {}
	for _, idx in ipairs(AGENT_LIVE) do
		local name = AgentName(idx)
		local isOk, count = TryCall(PROXYSVR.GetProxy(name, cn, "lua").call, "player_count")
		if not isOk or type(count) ~= "number" then
			-- 惰性剔除：服务已退出，不再参与仲裁
			_WARN_F("agent:%s not alive, remove from live", name)
		else
			live[#live + 1] = idx
			if count < agent_max_player and (not min_count or count < min_count) then
				min_name, min_count = name, count
			end
		end
	end
	AGENT_LIVE = live
	if min_name then
		return min_name
	end
	-- 所有存活实例均满载（或已无存活实例），横向扩展新实例
	return ExtendAgent(cn)
end

-- 最小连接仲裁：选当前节点里连接数最少的网关实例
local function PickGate(cn)
	local gateway_num = tonumber(skynet.getenv("gateway_num")) or 1
	local min_name, min_count
	for i = 1, gateway_num do
		local name = GateName(i)
		local isOk, count = TryCall(PROXYSVR.GetProxy(name, cn, "lua").call, "gate_count")
		if isOk and type(count) == "number" then
			if not min_count or count < min_count then
				min_name, min_count = name, count
			end
		end
	end
	return min_name or GateName(1)
end

-- 玩家登录：wgate 收到未绑定连接的首包后转交到这里
-- id: sockid, uid: 从握手url解析出（可为nil）, url: 握手url, proto_id/payload: 登录首包
function CLIENT_ACCEPT.login(id, uid, url, proto_id, payload)
	-- demo实现：玩家固定落在本节点。真实项目可在此按节点压力选择user节点
	local cn = SELF_CLUSTERNAME

	-- uid 兜底生成（demo：实际项目应做账号校验）
	if not uid or uid == "" then
		uid = sformat("%d_%s", os_time(), tostring(id))
	end

	-- 选网关实例（最小连接）
	local gate_name = PickGate(cn)

	-- 选玩家逻辑服 agent（最小连接，满载自动扩容）
	local agent_name = PickAgent(cn)
	if not agent_name then
		_ERROR_F("login fail, uid:%s pick agent error", uid)
		TryCall(PROXYSVR.GetProxy(gate_name, cn, "lua").send, "kick", uid)
		return
	end

	-- 1. 绑定网关连接（agent_name 写入网关侧 sinfo，上行消息转发到该 agent）
	local isOk, isBind = TryCall(PROXYSVR.GetProxy(gate_name, cn, "lua").call, "bind", id, uid, agent_name, cn)
	if not isOk or not isBind then
		_ERROR_F("login fail, uid:%s bind gate:%s error", uid, gate_name)
		TryCall(PROXYSVR.GetProxy(gate_name, cn, "lua").send, "kick", uid)
		return
	end

	-- 2. 登记玩家到 agent（记录其所在网关；上行链路 wgate->jlogin->agent 统一走 client 协议）
	TryCall(PROXYSVR.GetProxy(agent_name, cn, "client").send, "bind", uid, gate_name, cn)

	-- 3. 顶号：旧路由存在且不在当前网关，则踢掉旧连接
	local ok2, oldRoute = TryCall(GATEWAY_ROUTE.Get, uid)
	if ok2 and oldRoute then
		if oldRoute.gate_name ~= gate_name or oldRoute.gate_cn ~= cn then
			TryCall(PROXYSVR.GetProxy(oldRoute.gate_name, oldRoute.gate_cn, "lua").send, "kick", uid)
		end
	end

	-- 4. 登记全局路由（中心库）
	TryCall(GATEWAY_ROUTE.Reg, uid, gate_name, cn, agent_name, cn)

	-- 5. 登录回包（demo：原样回推首包，客户端可据此确认登录成功）
	TryCall(PROXYSVR.GetProxy(gate_name, cn, "lua").send, "push", uid, proto_id, payload)

	_INFO_F("login ok uid:%s gate:%s agent:%s", uid, gate_name, agent_name)
end

-- 玩家下线：wgate 连接断开时通知，校验后注销路由
function CLIENT_ACCEPT.logout(uid, gate_name, gate_cn)
	local isOk, route = TryCall(GATEWAY_ROUTE.Get, uid)
	if not isOk or not route then
		-- 没有路由信息，无需处理
		return
	end

	-- 仅当断开的是当前路由所在网关才注销（避免顶号后旧连接断开误删新路由）
	if route.gate_name == gate_name and route.gate_cn == gate_cn then
		TryCall(GATEWAY_ROUTE.UnReg, uid)
		TryCall(PROXYSVR.GetProxy(route.agent_name, route.agent_cn, "client").send, "unbind", uid)
	end
end

-- agent 空实例缩容主动退出通知（agent→jlogin 管理消息，走 lua 协议），从仲裁表剔除，避免仲裁到已死实例
function ACCEPT.agent_exit(agent_index)
	agent_index = tonumber(agent_index)
	if not agent_index then
		return
	end
	for i, idx in ipairs(AGENT_LIVE) do
		if idx == agent_index then
			table.remove(AGENT_LIVE, i)
			_INFO_F("agent:%s exit, remove from live", AgentName(agent_index))
			return
		end
	end
end