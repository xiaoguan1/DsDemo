local skynet = require "skynet"
local socket = require "skynet.socket"
local string = string
local table = table
local SERVICE_NAME = SERVICE_NAME

-- 先简单的挂在这里
if not _G.GCLOSURE then
	_G.GCLOSURE = Import("game/global/gclosure.lua")
end
local MCONSOLE = Import("game/service/manage/mconsole.lua")

-- wget -q -O - "http://127.0.0.1:8888/pings"

-- 网络端口信息
local mcsport = assert (tonumber(skynet.getenv("mcs_port")))
local listenPortIpv6 = "::"
-- local listenPortIpv4 = "127.0.0.1"
local backlog = 128
MGE_SOCKETID = nil

-- ip地址的白名单
local WHITE_IPLIST = {
	"127.0.0.1"
}

local function _IsAcceptIp(addr)
	if not addr then
		return
	end
	-- 正则表达式 $ 从字符串末尾开始匹配
	local host, port = string.match(addr, "([^:]+):?(%d*)$")
	if not host then
		return
	end
	if table.has_value(WHITE_IPLIST, host) then
		-- 白名单
		return true
	end
	local hlist = string.split(host, "%d+") or {}
	if #hlist ~= 4 then
		return
	end
	local h1 = tonumber(hlist[1])
	local h2 = tonumber(hlist[2])
	if h1 == 10 then
		-- 10.0.0.0 ~ 10.255.255.255
		return true
	elseif h1 == 172 and 16 <= h2 and h2 <= 31 then
		-- 172.16.0.0 ~ 172.31.255.255
		return true
	elseif h1 == 192 and h2 == 168 then
		-- 192.168.0.0 ~ 192.168.255.255
		return true
	end
end

skynet.start(function ()
	dofile "./game/global/log.lua"
	dofile "game/global/dblog.lua"

	-- 开启监听
	MGE_SOCKETID = socket.listen(listenPortIpv6, mcsport, backlog)
	if MGE_SOCKETID then
		skynet.error(SERVICE_NAME .. " open listen port " .. mcsport)
	end
	socket.start(MGE_SOCKETID, function(id, addr)
		-- LOG.LOG_EVEHT("mcs_connected.log", addr)

		_INFO_F("%s connected to %s", addr, SERVICE_NAME)
		-- skynet.error(string.format("%s connected to mcs", addr))	-- 需要判断addr的地址，防止不是内剖人员用mcs
		if _IsAcceptIp(addr) then
			MCONSOLE.DealMcs(id, addr)
		else
			-- LOG.LOG_EVENT("mcs_connected.log", addr, "not acceptip")
			socket.close_fd(id) -- Me haven't call socket.start, so use scoket.close_fd rather than socket.close.
		end
	end)
end)
