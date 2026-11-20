local socket = require "skynet.socket"
local httpd = require "http.httpd"
local sockethelper = require "http.sockethelper"
local urllib = require "http.url"

local HTTPD_GET = "GET "
local HTTPD_POST = "POST "
local HTTPD_HEAD = "HEAD "

local ROUTER = Import("game/service/manage/router.lua")

local function _Response(id, ...)
	httpd.write_response(sockethelper.writefunc(id), ...)
end

function DealMcs(id, addr)
	socket.start(id)
	local cmdline = socket.readline(id, "\n")
	local hpType
	if cmdline then
		if cmdline:sub(1, 4) == HTTPD_GET then
			hpType = HTTPD_GET
		elseif cmdline:sub(1, 5) == HTTPD_POST then
			hpType = HTTPD_POST
		elseif cmdline:sub(1, 5) == HTTPD_HEAD then
			hpType = HTTPD_HEAD
		end
	end
	if not hpType then
		_ERROR_F("addr:%s request error! cmdline:%s", addr, cmdline)
		socket.close(id)
		return
	end

	local code, url, method, header, body = httpd.read_request(sockethelper.readfunc(id, cmdline .. "\n"), 8192)
	if code ~= 200 then
		_ERROR_F("code ~= 200, addr:%s request error!", addr)
		_Response(id, code)
		socket.close(id)
		return
	end

	if hpType == HTTPD_GET then
		-- get请求
		local path, query = urllib.parse(url)
		local args = query and urllib.parse_query(query) or {}
		local cmd = path and path:sub(2) and path:sub(2):upper()
		local mod = cmd and ROUTER[cmd]
		if cmd == "CLOSESVC" then
			if mod then
				TryCall(mod.Handle_Request, args)
				_Response(id, 200, "操作成功\n")
				socket.close(id)
				return
			else
				_Response(id, 500, "操作失败\n")
				socket.close(id)
				return
			end
		else
			if mod then
				local isOk1, responseMsg = TryCall(mod.Handle_Request, args)
				if isOk1 then
					_Response(id, 200, "操作成功\n")
				else
					_Response(id, 500, "操作失败\n")
					_ERROR_F("addr:%s path:%s args:%s fail:%s", addr, path, tool.dump(args), responseMsg)
				end
			else
				_Response(id, 500, "操作失败")
				_ERROR_F("path:%s, not find", path)
			end
		end
	else
		-- post请求
		-- 目前不支持,待完善
		_ERROR_F("not supported port! addr:%s", addr)
	end
	socket.close(id)
end
