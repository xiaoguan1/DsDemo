CALLOUT = Import("game/global/call_out.lua")
MODULE_DB = Import("game/global/module_db.lua")
CLSSAVE = Import("game/global/clssave.lua")

local PROXYSVR = Import("game/global/rpc/proxysvr.lua")
assert(CLIENT_ACCEPT)

-- 玩家所在网关信息（demo：以 display 充当 agent 逻辑服）
PlayerGate = {}

-- 玩家登录绑定（jlogin 调用）
function CLIENT_ACCEPT.bind(uid, gate_name, gate_cn)
	PlayerGate[uid] = { gate_name = gate_name, gate_cn = gate_cn }
	_INFO_F("player:%s bind gate:%s", uid, tostring(gate_name))
end

-- 玩家下线解绑（jlogin 调用）
function CLIENT_ACCEPT.unbind(uid)
	if PlayerGate[uid] then
		PlayerGate[uid] = nil
		_INFO_F("player:%s unbind gate", uid)
	end
end

-- 处理玩家上行协议（demo：原样回推，验证链路）
function CLIENT_ACCEPT.client_msg(uid, proto_id, payload)
	local info = PlayerGate[uid]
	if not info then
		_WARN_F("client_msg fail, uid:%s not bind gate", uid)
		return
	end
	TryCall(PROXYSVR.GetProxy(info.gate_name, info.gate_cn, "lua").send, "push", uid, proto_id, payload)
end

