-- 玩家逻辑服 agent：无状态、可横向扩展
-- 多实例规则：编号1命名为 .AGENT，编号N(N>1)命名为 .AGENT..N（与 wgate 一致）
-- 上行链路：wgate -> agent.client_msg    下行链路：agent -> wgate.push
-- 扩缩容：jlogin 仲裁，满载时新建实例（编号>默认数），空实例（编号>默认数）自退

local skynet = require "skynet"

CLIENT_ACCEPT = {}
CLIENT_RESPONSE = {}

ACCEPT = {}
RESPONSE = {}

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = skynet.unpack,
	pack = skynet.pack,
	dispatch = function (session, _, command, ...)
		local f
		if session == 0 then
			f = assert(CLIENT_ACCEPT[command], command)
			f(...)
		else
			f = assert(CLIENT_RESPONSE[command], command)
			skynet.retpack(f(...))
		end
	end
}

skynet.start(function (agent_index)
	agent_index = tonumber(agent_index) or 1	-- 启动参数经 snlua/loader 字符串化，必须转数字

	dofile "./game/global/log.lua"
	_G.AGENT_INDEX = agent_index	-- 注入实例编号给 global.lua 使用

	skynet.dispatch("lua", function (session, _, command, ...)
		local f
		if session == 0 then
			f = assert(ACCEPT[command], command)
			f(...)
		else
			f = assert(RESPONSE[command], command)
			skynet.retpack(f(...))
		end
	end)

	dofile "game/service/agent/global.lua"
	_INFO_F("agent index:%s start ok", agent_index)
end)