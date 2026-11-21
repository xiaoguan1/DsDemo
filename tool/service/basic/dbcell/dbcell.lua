local skynet = require "skynet"
require "skynet.manager"
local no = ...
assert(no)

-- 处理器定义在 dbcell_server 模块内，绑定到本服务的分发表
local DBServer = Import("tool/service/basic/dbcell/dbcell_server.lua")
-- 中心库逻辑：账号表操作，所有 cell 都承载，由 dbserver 按 uid/phone 哈希路由
local DBCenter = Import("tool/service/basic/dbcell/dbcell_center.lua")

ACCEPT, RESPONSE = {}, {}
local function _MergeCommand(dst, src)
	for k, v in pairs(src) do
		assert(not dst[k], "duplicate db command:" .. tostring(k))
		dst[k] = v
	end
end
_MergeCommand(ACCEPT, DBServer.ACCEPT)
_MergeCommand(RESPONSE, DBServer.RESPONSE)

-- 所有 dbcell 都承载中心库账号表；uid 由登录网关生成后传入
_MergeCommand(ACCEPT, DBCenter.ACCEPT)
_MergeCommand(RESPONSE, DBCenter.RESPONSE)

-- 心跳方法
local HbTime = 1 * 100
function Heartbeat()
	while true do
		skynet.sleep(HbTime)
		local ntime = os.time()
		if ntime % 60 == 0 then
			DBServer.CheckDb()	-- 连接保活：ping 失败则丢弃连接，下次查询自动重连
			DBCenter.CheckDb()
		end
	end
end

skynet.start(function ()
	dofile "./game/global/log.lua"
	dofile "game/global/dblog.lua"
	skynet.register(".DBCELL_" .. no)

	skynet.dispatch("lua", function (session, source, command, ...)
		if session == 0 then
			local func = ACCEPT[command]
			if not func then
				error("not find func:" .. command)
			end
			func(...)
		else
			local func = RESPONSE[command]
			if not func then
				error("not find func:" .. command)
			end
			skynet.retpack(func(...))
		end
	end)

	-- assert(MISC.ConnDb())
	local _Fenv = getfenv(1)
	skynet.timeout(0, _Fenv.Heartbeat)
end)







