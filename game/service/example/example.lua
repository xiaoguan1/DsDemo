-- 玩法服务骨架（无状态示例）
-- 启动方式：adhoc —— 由中心库 server_config 的 is_start_example 列开关（本节点行填 1 即启动），
--   nodeInfo 归一化为 start_service.example = 本节点 ipport
-- 实例命名：.EXAMPLE（N节点×1实例，实例序号恒为1）
-- 玩法铁律：进程内不存留跨请求业务数据，状态一律外置 Redis/MySQL

local skynet = require "skynet"

ACCEPT = {}
RESPONSE = {}

skynet.start(function (svr_index)
	svr_index = tonumber(svr_index) or 1	-- 启动参数经 snlua/loader 字符串化，必须转数字

	dofile "./game/global/log.lua"

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

	dofile "game/service/example/global.lua"
	_INFO_F("example index:%s start ok, cluster:%s", svr_index, SELF_CLUSTERNAME)
end)
