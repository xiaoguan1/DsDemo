-- 地图分块服务入口（无状态多实例，可按 chunk 负载横向扩展）
-- 命名规则与 startup/main.lua 保持一致：.MAPCELL、.MAPCELL2、.MAPCELL3...
-- 纯服务间交互按项目宗旨走 lua 协议（只有 socket 上行链路才用 client），故不注册 client 分发。
-- 启动参数：cell_index —— 实例编号（经 snlua/loader 字符串化，必须 tonumber）

local skynet = require "skynet"

ACCEPT = {}
RESPONSE = {}

skynet.start(function (cell_index)
	cell_index = tonumber(cell_index) or 1
	dofile "./game/global/log.lua"
	_G.MAPCELL_INDEX = cell_index

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

	dofile "game/service/mapcell/global.lua"
	_INFO_F("mapcell index:%s start ok", cell_index)
end)