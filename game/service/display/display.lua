local skynet = require "skynet"
require "skynet.manager"
local table = table
local string = string
local load = load
local assert = assert
local PROFILE_CMD = Import("game/global/profile_cmd.lua")

local SELF_ADDR = skynet.self()

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

skynet.start(function ()
	-- wgate 上行转发的消息统一走 client 类型，与 lua 复用同一分发表
	skynet.dispatch("lua", function (session, _, command, ...)
		local f
		local isRecord = PROFILE_CMD.CmdCal_S()
		if session == 0 then
			f = assert(ACCEPT[command], command)
			f(...)
		else
			f = assert(RESPONSE[command], command)
			if command == "shutdown" then
				f(...)
			else
				skynet.retpack(f(...))
			end
		end
		if isRecord then
			PROFILE_CMD.CmdCal_E(command)
		end
	end)

	dofile "game/global/log.lua"
	dofile "game/global/dblog.lua"
	dofile "game/service/display/global.lua"
end)