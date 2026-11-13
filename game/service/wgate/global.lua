WHANDLE = Import("game/service/wgate/module/whandle.lua")

-- 绑定玩家连接（token 登录成功后由 whandle 内部调用，此处保留供外部 RPC 调用）
function ACCEPT.bind(id, uid, agent_name, agent_cn, bind_id)
	WHANDLE.Bind(id, uid, agent_name, agent_cn, bind_id)
end

-- 向玩家推送下行协议帧（agent 调用）
function ACCEPT.push(uid, proto_id, payload)
	TryCall(WHANDLE.PushToClient, uid, proto_id, payload)
end

-- 踢下线（顶号等场景调用）
function ACCEPT.kick(uid)
	TryCall(WHANDLE.Kick, uid)
end

function RESPONSE.bind(id, uid, agent_name, agent_cn, bind_id)
	return WHANDLE.Bind(id, uid, agent_name, agent_cn, bind_id)
end

-- 查询在线连接数（监控/调试用）
function RESPONSE.gate_count()
	return WHANDLE.GetGateCount()
end
