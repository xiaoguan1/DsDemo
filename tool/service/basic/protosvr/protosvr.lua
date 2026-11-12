----------------------------
--- 目标：节点内共享一个protobuf管理数据
---     1.加载协议和更新协议
----------------------------

local skynet = require "skynet"
require "skynet.manager"
local string = string
local sformat = string.format
local error = error

command = {}
skynet.start(function (...)
	dofile "./game/global/log.lua"
	dofile "game/global/dblog.lua"

	LoadP = Import("protocol/loadproto.lua")
	if not LoadP.LoadProto() then
		skynet.abort()
	end

	skynet.dispatch("lua", function (session, source, cmd, ...)
		local f = command[cmd]
		if not f then
			_ERROR_F("unknown command %s", cmd)
			return
		end

		if session then
			skynet.ret(skynet.pack(f(...)))
		else
			f(...)
		end
	end)
end)
