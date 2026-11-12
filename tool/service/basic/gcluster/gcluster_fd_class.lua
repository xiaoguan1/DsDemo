----------------------------------
--- 作用：gcluster的 fd 类
----------------------------------

local skynet = require "skynet"
local padding_warn = tonumber(assert(skynet.getenv("gcluster_padding_warn")))
local is_testserver = skynet.getenv("is_testserver") == "test"

local driver = require "skynet.socketdriver"
local socket_write = assert(driver.send)

local table = table
local tinsert = table.insert
local assert = assert
local os = os
local os_time = os.time
local string = string
local sformat = string.format

local MsgPack = assert(MsgPack)

socket_err = false

-- 发送失败时通知 gcluster 主服务（真正的 SocketErr 由 gcluster_helper 注入到 FdClass.socket_err）
local function notify_socket_err(clusterName)
	if FdClass and FdClass.socket_err then
		FdClass.socket_err(clusterName)
	else
		skynet.error(sformat("gcluster socket write fail, clusterName:[%s], socket_err not bind!", clusterName))
	end
end

local authYes = "1"
local authNo = "0"
local gcluster_auths = assert(skynet.getenv("gcluster_auths"))
local authCode = MsgPack(gcluster_auths)
local authYesCode = MsgPack(authYes)
local authNoCode = MsgPack(authNo)

-- 集群中自己的节点名称
local SELF_CLUSTERNAME = assert(SELF_CLUSTERNAME)
local SELF_CLUSTERNAME_CODE = MsgPack(SELF_CLUSTERNAME)

-- 认证状态类型
local AUTH_STATIUS_DO 		= 1		-- 主动做认证（把本节点的认证码发送给对端）
local AUTH_STATIUS_WAIT 	= 2		-- 等待（等待对端把认证码发送过来）
local AUTH_STATIUS_YES 		= 3		-- 认证成功
local AUTH_STATIUS_NO 		= 4		-- 认证失败

local _ERROR_F = _ERROR_F
local _INFO_F = _INFO_F

FdClass = { __ClassType = "<<gcluster_fd_class>>" }

function FdClass:init(fd, extData)
	assert(fd)
	extData = extData or {}

	local o = {
		create_time = os_time(),
	}

	-- 设置验证状态
	o.auth = extData.auth and AUTH_STATIUS_DO or AUTH_STATIUS_WAIT
	extData.auth = nil

	for key, val in pairs(extData) do
		if is_testserver and FdClass[key] then
			error(sformat("fd obj not set key[%s] val[%s], because FdClass exist!", key, val))
		end
		o[key] = val
	end

	-- 在这里设置 防止覆盖。
	o.__ObjectType = "gcluster_fd_object"
	o.fd = fd
	o.connected = os_time()
	o.auth_finish = nil			-- 完成认证操作的时间戳
	o.auth_coroutine = nil		-- 主动做认证的协程
	o.auth_waitcoroutine = nil
	o.heartbeat_time = nil		-- 最近一次发送消息时间

	local m = {__index = self, }
	if is_testserver then
		m.__newindex = function (t, key, val)
			if FdClass[key] then
				error(sformat("fd obj not set key[%s] val[%s], because FdClass exist!", key, val))
			end
			rawset(t, key, val)
		end
	end
	return setmetatable(o, m)
end

function FdClass:update_heartbeat()
	self.heartbeat_time = os_time()
end

function FdClass:write(request, padding)
	local fd = assert(self.fd)
	if padding then
		-- 分包发送
		if not socket_write(fd , request) then
			notify_socket_err(self.cluster_name)
		end
		for _, v in ipairs(padding) do
			if not socket_write(fd , v) then
				notify_socket_err(self.cluster_name)
			end
		end
		if #padding >= padding_warn then
			_WARN_F("fd send cluster_name:[%s] padding message:[%s] > %s", #padding, padding_warn)
		end
	else
		if not socket_write(fd , request) then
			notify_socket_err(self.cluster_name)
		end
	end
	self:update_heartbeat()

	return true
end

function FdClass:is_auth_yes()
	return self.auth == AUTH_STATIUS_YES
end

function FdClass:is_auth_wait()
	return self.auth == AUTH_STATIUS_WAIT
end

function FdClass:is_auth_do()
	return self.auth == AUTH_STATIUS_DO
end

-- 主动做认证操作
function FdClass:do_auth()
	local authStatus = self.auth
	if not self:is_auth_do() then
		return authStatus
	end

	local fd = assert(self.fd)
	local co = coroutine.running()
	if self.auth_coroutine then
		tinsert(self.auth_waitcoroutine, co)
		skynet.wait(co)
	else
		self.auth_coroutine = co
		self.auth_waitcoroutine = {}

		local msg = MsgPack(authCode .. SELF_CLUSTERNAME_CODE)
		if not socket_write(fd, msg) then -- 发送认证码
			notify_socket_err(self.cluster_name)
		end

		local stime = os_time()
		skynet.wait(co)
		self.auth_finish = os_time()
		if (self.auth_finish - stime) >= 3 then
			skynet.error(sformat("fd[%s] do auth opt, maybe network congestion!", fd))
		end

		-- 唤醒因认证操作而被挂起的协程
		for _, _co in ipairs(self.auth_waitcoroutine) do
			skynet.wakeup(_co)
		end
		self.auth_waitcoroutine = nil
	end

	-- 获取最新的认证状态
	local nauthStatus = self.auth
	if nauthStatus == AUTH_STATIUS_YES then
		_INFO_F("fd[%s] auth succeed", fd)
	elseif nauthStatus == AUTH_STATIUS_NO then
		_ERROR_F("fd[%s] auth fail", fd)
	else
		_ERROR_F("fd[%s] auth status[%s] error!", fd, nauthStatus)
	end
	return nauthStatus
end

function FdClass:deal_auth(msg)
	local fd = assert(self.fd)
	if self.auth_finish then
		return self.auth
	end

	if self:is_auth_wait() then
		local authIdx2, authIdx1 = string.unpack(">I2", msg)
		local clientAuth = string.sub(msg, authIdx1, authIdx1 + authIdx2 - 1)	-- 客户端发来的认证码

		local response, clientName
		-- 比对认证码
		if clientAuth == gcluster_auths then
			local msg1 = msg:sub(authIdx1 + authIdx2)
			local nameIdx2, nameIdx1 = string.unpack(">I2", msg1)
			clientName = string.sub(msg1, nameIdx1, nameIdx1 + nameIdx2 - 1)	-- 客户端的节点名
			if string.match(clientName, CLUSTER_NAME_MATCH) then
				if GetChannel(clientName) then
					-- 该节点名已存在连接，强行关闭当前连接。
					self.auth = AUTH_STATIUS_NO
					response = authNoCode
					skynet.error(sformat("clientName[%s] repeated connected!", clientName))
				else
					self.cluster_name = clientName
					self.auth = AUTH_STATIUS_YES
					response = MsgPack(authYesCode .. SELF_CLUSTERNAME_CODE)
				end
			else
				self.auth = AUTH_STATIUS_NO
				response = authNoCode
				skynet.error(sformat("clientName[%s] fmt error!", clientName))
			end
		else
			self.auth = AUTH_STATIUS_NO
			response = authNoCode
		end
		self.auth_finish = os_time()

		local ct = connecting[self.address]
		connecting[self.address] = nil
		if self:is_auth_yes() then
			ct.channel = self
			SetChannel(self.cluster_name, self)
			skynet.error(sformat("gcluster scoket:%s auth succeed, from address:%s", self.fd, self.address))
		end
		for _, co in ipairs(ct.co) do
			skynet.wakeup(co)
		end
		if not socket_write(fd, response) then
			notify_socket_err(self.cluster_name)
		end
	elseif self:is_auth_do() then
		-- 认证码的比对结果
		local authIdx2, authIdx1 = string.unpack(">I2", msg)
		local serverAuth = string.sub(msg, authIdx1, authIdx1 + authIdx2 - 1)	-- 服务端发来的认证码

		local serverName
		if serverAuth == authYes then
			local msg1 = msg:sub(authIdx1 + authIdx2)
			local nameIdx2, nameIdx1 = string.unpack(">I2", msg1)
			serverName = string.sub(msg1, nameIdx1, nameIdx1 + nameIdx2 - 1)	-- 服务端的节点名

			if string.match(serverName, CLUSTER_NAME_MATCH) and self.cluster_name == serverName then
				self.auth = AUTH_STATIUS_YES
			else
				self.auth = AUTH_STATIUS_NO
			end
		else
			self.auth = AUTH_STATIUS_NO
		end

		local co = self.auth_coroutine
		self.auth_coroutine = nil
		skynet.wakeup(co)
	else
		skynet.error(sformat("fd[%s] auth status[%s] invalid!!!", self.fd, self.auth))
	end
	return self:is_auth_yes()
end
