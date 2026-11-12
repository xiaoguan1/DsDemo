-- 玩家逻辑服 agent：管理者/worker 两级架构
-- 实例1 = 管理者（.AGENT）：worker 注册、负载汇总、玩家分配、动态扩缩容，自身不承载玩家
-- 实例2~N = worker（.AGENT2...）：承载玩家业务，启动时向管理者注册，绑定/解绑时上报负载
-- 命名规则：与 startup/main.lua 保持一致（实例1 .AGENT，实例N .AGENTN）
-- 玩家分配：登录服务调用管理者 alloc，管理者挑选最空闲 worker（全满自动扩容）
-- 动态缩容：管理者每 10 秒扫描，回收编号 > agent_default_num 的空 worker；底座 worker 常驻

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
	_G.AGENT_INDEX = agent_index	-- 注入实例编号给 manager.lua/worker.lua 使用

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

	if agent_index == 1 then
		-- 实例1：管理者，管理其余 agent 实例（自身不承载玩家）
		dofile "game/service/agent/manager.lua"
		_INFO_F("agent manager index:%s start ok", agent_index)
	else
		-- 实例2~N：worker，向管理者注册并上报负载
		dofile "game/service/agent/worker.lua"
		_INFO_F("agent worker index:%s start ok", agent_index)
	end
end)
