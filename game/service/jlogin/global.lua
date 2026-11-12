-- 仲裁登录服务逻辑（全局唯一，寄生 user 节点或独立 jlogin 节点均可）
-- 1. 收集集群内所有 user 节点（SERVER_CONFIG 中 node_name == "user"）
-- 2. pick_node：顶号复用已有落点，新玩家轮询分配 user 节点
-- 3. alloc：向选定节点的 agent 管理者（.AGENT）申请 worker 绑定，返回 (server_id, worker_name)
-- 4. unbind：玩家下线转发到落点节点解绑

local PROXYSVR = Import("game/global/rpc/proxysvr.lua")
assert(RESPONSE)
assert(ACCEPT)

local table = table
local pairs = pairs
local ipairs = ipairs

-- 集群内 user 节点列表（有序，用于轮询；跨节点调用需保持顺序一致）
local UserNodes = {}
for serverId, cfg in pairs(SERVER_CONFIG) do
	if cfg.nodename == USER_NODE then
		UserNodes[#UserNodes + 1] = serverId
	end
end
assert(#UserNodes > 0, "not find user node")
table.sort(UserNodes)

local RotateIndex = 0
local PlayerNode = {}	-- uid -> user 节点 server_id（落点缓存，顶号复用）

-- 轮询下一个 user 节点
local function NextNode()
	RotateIndex = RotateIndex % #UserNodes + 1
	return UserNodes[RotateIndex]
end

-- 调用指定 user 节点的 agent 管理者分配 worker（跨节点走 gcluster）
local function AllocOnNode(serverId, uid, gate_name, gate_cn)
	local clustername = SERVICE_CLUSTERNAME["agent"][serverId]
	if not clustername then
		return
	end
	local isOk, workerName = TryCall(PROXYSVR.GetProxy(".AGENT", clustername, "lua").call, "alloc", uid, gate_name, gate_cn)
	if not isOk or not workerName then
		return
	end
	return workerName
end

-- 玩家登录仲裁：返回落点 user 节点 server_id 与 worker 名；全部节点不可用返回 nil
function RESPONSE.alloc(uid, gate_name, gate_cn)
	local workerName
	local serverId = PlayerNode[uid] or NextNode()
	workerName = AllocOnNode(serverId, uid, gate_name, gate_cn)
	if not workerName then
		-- 首选节点不可用（agent 未起/节点未连上），轮询其余节点重试一轮
		for _ = 2, #UserNodes do
			serverId = NextNode()
			workerName = AllocOnNode(serverId, uid, gate_name, gate_cn)
			if workerName then
				break
			end
		end
	end
	if not workerName then
		_ERROR_F("jlogin alloc fail uid:%s, all user node unavailable", uid)
		return
	end
	PlayerNode[uid] = serverId
	_INFO_F("jlogin alloc uid:%s -> node:%s worker:%s", uid, serverId, tostring(workerName))
	return serverId, workerName
end

-- 查询/预选玩家落点节点（不产生绑定，网关可先取节点再决定后续流程）
function RESPONSE.pick_node(uid)
	local serverId = PlayerNode[uid]
	if not serverId then
		serverId = NextNode()
	end
	return serverId
end

-- 玩家下线解绑：转发到落点节点的 agent 管理者
function ACCEPT.unbind(uid)
	local serverId = PlayerNode[uid]
	if not serverId then
		return
	end
	PlayerNode[uid] = nil
	local clustername = SERVICE_CLUSTERNAME["agent"][serverId]
	if clustername then
		TryCall(PROXYSVR.GetProxy(".AGENT", clustername, "lua").send, "unbind", uid)
	end
end

-- 当前 user 节点数量（监控/仲裁查询用）
function RESPONSE.user_node_count()
	return #UserNodes
end
