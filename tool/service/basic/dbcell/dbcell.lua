local skynet = require "skynet"
require "skynet.manager"
local mysql = require "skynet.db.mysql"
local database_info = load("return " .. skynet.getenv("database_info"))
assert(database_info)
local no = ...
assert(no)

ACCEPT, RESPONSE = {}, {}
local MISC = Import("tool/service/basic/dbcell/dbcell_misc.lua")

-- 心跳方法
local HbTime = 1 * 100
function Heartbeat()
	while true do
		skynet.sleep(HbTime)
		local ntime = os.time()
		if ntime % 60 == 0 then
			-- local db = MISC.ConnDb()
			-- db:ping()
		end
		-- TryCall(MISC.DumpCache)
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







