-- world 节点启动入口：拉起 cell（世界权威）与 gate（连接网关），注入互连地址
local skynet = require "skynet"

-- 加载日志宏（服务启动最早期，保证后续所有日志可用）
dofile "./game/global/log.lua"

skynet.start(function ()
	-- 先起 cell：世界权威（gate 启动参数注入 cell 地址用于转发）
	local cell = skynet.newservice("cell")
	skynet.name(".cell", cell)

	-- 再起 gate：WebSocket 监听（启动参数 = cell 地址）
	local gate = skynet.newservice("gate", cell)
	skynet.name(".gate", gate)

	-- 向 cell 注入 gate 地址（下行推送用）
	skynet.send(cell, "lua", "set_gate", gate)

	_INFO_F("seamless world node up: gate=%08x cell=%08x", gate, cell)

	-- 可选：自动跑压测（config perf_auto = true）
	if skynet.getenv("perf_auto") == "true" then
		skynet.newservice("perf", cell)
	end

	skynet.exit()
end)
