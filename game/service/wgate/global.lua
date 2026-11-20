WHANDLE = Import("game/service/wgate/module/whandle.lua")

-- 绑定玩家连接（登录仲裁服务登录成功后调用，send/call均可）
function ACCEPT.bind(id, uid, agent_name, agent_cn)
	WHANDLE.Bind(id, uid, agent_name, agent_cn)
end

-- 向玩家推送下行协议帧（agent/登录仲裁服务调用）
function ACCEPT.push(uid, proto_id, payload)
	TryCall(WHANDLE.PushToClient, uid, proto_id, payload)
end

-- 踢下线（登录仲裁服务顶号时调用）
function ACCEPT.kick(uid)
	TryCall(WHANDLE.Kick, uid)
end

function RESPONSE.bind(id, uid, agent_name, agent_cn)
	return WHANDLE.Bind(id, uid, agent_name, agent_cn)
end

-- 查询在线连接数（登录仲裁服务最小连接仲裁用）
function RESPONSE.gate_count()
	return WHANDLE.GetGateCount()
end