local skynet = require "skynet"
local netpack = require "skynet.netpack"
local socketdriver = require "skynet.socketdriver"
local string = string
local sformat = string.format

local SERVICE_NAME = SERVICE_NAME

local queue		-- message queue
local maxclient = 2048	-- max client
local client_number = 0
local CMD = setmetatable({}, { __gc = function() netpack.clear(queue) end })

local FD_LISTEN = 1		-- fd的种类为监听
local FD_SCOKET = 2		-- fd的种类为socket

local FD_STATUS_PREPARED = 1	-- fd为就绪状态（仅仅发起未被得到响应）
local FD_STATUS_RUN = 2			-- fd为正常状态（已两边得到确认）
local FD_STATUS_CLOSE = 3		-- fd为关闭状态

local queue
local MSG = {}

-- socket缓存数据
-- { [fd] = {
		-- fake_addr,	主动发起连接的网络地址
		-- real_addr,	真实的网络地址(socket线程返回的)
		-- co,			若存在则表示本节点主动操作的（若没有则外部节点发起的）
		-- type,		端口类型 or socket类型
		-- status,		就绪状态（还不能用）、正常状态（可用）
		-- close,		关闭进度（nil、true，最后销毁该fd存储）
-- 	},
-- 	...
-- }
local socket_pool = setmetatable({}, {
	__gc = function(t)
		for id, _ in pairs(t) do
			socketdriver.close(id)
			t[id] = nil
		end
	end,
})

-- 网络地址与socket对应关系
-- 注意：主动连接操作，最多会有两个网络地址映射一个socket。被动连接则一个网络地址
-- {
-- 	[ip:port] = fd,
-- 	...
-- }
local addr_socket = { }

-- 监听
local listenId
local listenData

-- 网络数据下发的服务地址
local watchdog

----------  局部方法 ----------

local function syncWatchDog(isCall, ...)
	assert(watchdog)
	if isCall then
		return skynet.call(watchdog, "lua", "socket", ...)
	else
		skynet.send(watchdog, "lua", "socket", ...)
	end
end

local function getIpPort(ip, port)
	local address
	if port then
		address = sformat("%s:%s", ip, port)
	else
		address = ip
		ip, port = string.match(ip, "([^:]+):(.+)$")
		port = tonumber(port)
	end
	return ip, port, address
end

local function setAddrSocket(fd, ...)
	for _, addr in pairs({...}) do
		addr_socket[addr] = fd
	end
end

local function wakeup(s)
	local co = s and s.co
	if co then
		s.co = nil
		skynet.wakeup(co)
	end
end

local function dispatch_msg(fd, msg, sz)
	local s = socket_pool[fd]
	if s and s.type == FD_SCOKET and s.status == FD_STATUS_RUN then
		skynet.send(watchdog, "lua", "socket", "data", fd, s.fake_addr, skynet.tostring(msg, sz))
		skynet.trash(msg,sz)
	else
		skynet.error(sformat("Drop message from fd (%d) : %s", fd, netpack.tostring(msg,sz)))
	end
end

local function dispatch_queue()
	local fd, msg, sz = netpack.pop(queue)
	if fd then
		-- may dispatch even the handler.message blocked
		-- If the handler.message never block, the queue should be empty, so only fork once and then exit.
		skynet.fork(dispatch_queue)
		dispatch_msg(fd, msg, sz)

		for fd, msg, sz in netpack.pop, queue do
			dispatch_msg(fd, msg, sz)
		end
	end
end


---------- socket消息处理 ----------
MSG.data = dispatch_msg
MSG.more = dispatch_queue

function MSG.init(id, addr, port)
	if id == listenId then
		-- 监听
		if not listenData then
			skynet.error(sformat("id:%s listen[%s:%s] not find listenData!", id, addr, port))
			return
		end

		if not listenData.status then
			listenData.real_addr = addr .. ":" .. port
		end
		wakeup(listenData)
		return
	end

	local s = socket_pool[id]
	if s and s.co and s.type == FD_SCOKET then
		-- socket
		s.real_addr = addr .. ":" .. port
		wakeup(s)
		return
	end

	-- 未知错误
	skynet.error(sformat("%s MSG.init not find record!, id[%s] addr[%s] port[%s] s[%s]",
			SERVICE_NAME, id, addr, port, s))
end

-- 外部节点 主动连接 本节点监听
function MSG.open(fd, address)
	if socket_pool[fd] then
		skynet.error(sformat("fd[%s] already exit, unknown error!", fd))
		return
	end
	client_number = client_number + 1
	if client_number >= maxclient then
		socketdriver.shutdown(fd)
		return
	end
	if addr_socket[address] then
		-- 警告，两端之间重复建立链接了。要想watchdog服务发起额外的消息，让它自行裁决。
		skynet.error(sformat("repeat connect! address[%s]", address))
	end
	socketdriver.nodelay(fd)

	local s = {
		type = FD_SCOKET,
		status = FD_STATUS_PREPARED, -- 就绪状态（未得到watchdog服务确定要不要accept，该外部链接）
		real_addr = address,
		fake_addr = address,
		create_time = os.time(),
	}
	socket_pool[fd] = s

	-- 通知watchdog服务，让watchdog服务决定accept操作。
	syncWatchDog(false, "accept", fd, address)
end

-- 关闭网络链接或者监听
function MSG.close(fd)
	-- 注意：当收到该关闭类型的信息的时候，其socket线程内部已经关闭了fd并清空对应缓存，即事后通知！
	if fd == listenId then
		-- 关闭监听
		assert(listenData, "listenId not have socket_pool data!")
		wakeup(listenData)
	else
		-- 关闭socket
		client_number = client_number - 1
		local s = socket_pool[fd]
		if not s then
			socketdriver.close(fd) -- 二次关闭，确保清理
			skynet.error(sformat("unknown fd[%s] close", fd))
			return
		end

		if s.co then
			-- 当前节点主动关闭（因为是主动关闭，故无需再通知watchdog服务了）
			wakeup(s)
		else
			-- 对方节点关闭，即当前节点被动关闭。
			-- socketdriver.close(fd)
			socket_pool[fd] = nil
			setAddrSocket(nil, s.fake_addr, s.real_addr)
			syncWatchDog(false, "close", fd, s.fake_addr)
		end
	end
end

-- socket线程返回的错误通知
function MSG.error(fd, msg)
	if fd == listenId then
		-- 一般是accept的错误
		skynet.error("gateserver_fdx listen accept error: ", msg)
	else
		local s = socket_pool[fd]
		if not s then
			-- 非法的socket，强行关闭。
			socketdriver.shutdown(fd)
			skynet.error("unknown fd, force socket shutdown!")
			return
		end

		if s.status == FD_STATUS_PREPARED then
			-- 一般是本节点发起网络连接的错误，强行关闭
			socket_pool[fd] = nil
			setAddrSocket(nil, s.fake_addr, s.real_addr)
			socketdriver.shutdown(fd)
			skynet.error(sformat("gcluster_gate shutdown fd[%s] msg[%s]", fd, msg))
			wakeup(s)
			syncWatchDog(false, "error", fd, msg)
		else
			skynet.error(sformat("gcluster_gate fd:[%s] error, status:[%s] msg:[%s]", fd, s.status, msg))
		end
	end
end

function MSG.warning(fd, size)
	if fd == listenId then
		skynet.error("listen warning ", size)
	else
		if socket_pool[fd] then
			syncWatchDog(false, "warning", fd, size)
		else
			skynet.error(sformat("illegal %s warning size[%s]", fd, size))
		end
	end
end
---------- lua协议的CMD处理 ----------

-- 设置网络数据的下发服务地址
function CMD.set_watchdog(source)
	watchdog = source
end

-- 开启监听
function CMD.listen(source, addrOrIp, port)
	if listenId then
		skynet.error("repeated open listen!")
		return
	end

	local ip, port, address = getIpPort(addrOrIp, port)
	if not (ip and port) then
		skynet.error("invalid address", ip, port)
		return
	end

	local isOk
	isOk, listenId = pcall(socketdriver.listen, ip, port)
	if not isOk then
		skynet.error(sformat("open listen fail, %s:%s [%s]", ip, port, listenId))
		return
	end

	local co = coroutine.running()
	listenData = {
		co = co,
		status = nil,
		fake_addr = address,
		real_addr = nil,
		type = FD_LISTEN,
		create_time = os.time(),
	}
	skynet.wait(co)

	assert(listenData and listenData.status == nil)

	-- socket线程响应，成功开启监听，设置就绪状态
	listenData.status = FD_STATUS_PREPARED

	-- 确认当前服务接收监听的链接信息（等待socket线程响应）
	socketdriver.start(listenId)
	listenData.co = coroutine.running()
	skynet.wait(co)

	-- socket线程响应，设置正常运行状态
	assert(listenData and listenData.status == FD_STATUS_PREPARED)
	listenData.status = FD_STATUS_RUN
	return true, listenId
end


-- 本节点主动连接对方监听
function CMD.connect(source, addrOrIp, port)
	local ip, port, address = getIpPort(addrOrIp, port)
	if not ip or not port then
		skynet.error("invalid address", address)
		return
	end

	if addr_socket[address] then
		skynet.error("forbidden repeat connect, because already", address)
		return
	end

	-- 不允许链接相同节点内的监听
	if listenData and
		(listenData.fake_addr == address or listenData.real_addr == address)
	then
		skynet.error("forbidden connection self node listen!", address)
		return
	end

	local fd = socketdriver.connect(ip, port)
	local co = coroutine.running()
	local s = {
		fake_addr = address,
		real_addr = nil,				-- 以socket线程返回的地址作为真的地址
		co = co,
		type = FD_SCOKET,
		status = FD_STATUS_PREPARED, 	-- 就绪状态（未得到socket线程的响应）
		create_time = os.time(),
	}
	socket_pool[fd] = s
	skynet.wait(co)

	-- 重新获取缓存s，因为有可能连接失败而清空缓存。
	s = socket_pool[fd]
	if not s then
		skynet.error("connection fail", address)
		return
	end
	assert(s.status == FD_STATUS_PREPARED)

	s.status = FD_STATUS_RUN -- 正常状态
	setAddrSocket(fd, s.fake_addr, s.real_addr)
	return fd, address
end

-- 关闭监听listen_fd
function CMD.close_listen()
	if not listenId or not listenData then
		skynet.error("not find listen, close listen fail!")
		return
	end

	if listenData.status ~= FD_STATUS_RUN then
		skynet.error("listen opening, rejuect close!")
		return
	end

	listenData.status = FD_STATUS_CLOSE
	listenData.co = coroutine.running()
	socketdriver.close(listenId)

	-- 挂起当前协程，等待socket线程响应
	skynet.wait(listenData.co)

	listenId, listenData = nil, nil
	skynet.error("success close listenId!")
	return true
end

-- 当前节点主动关闭网络连接socket
function CMD.close_connect(fd)
	local s = fd and socket_pool[fd]
	if not s or (s.status == FD_STATUS_RUN and not s.co) then
		skynet.error("close connect fail. fd", fd)
		return
	end

	s.status = FD_STATUS_CLOSE
	s.co = coroutine.running()
	socketdriver.close(fd)

	-- 挂起当前协程，等待socket线程响应
	skynet.wait(s.co)

	socket_pool[fd] = nil
	setAddrSocket(nil, s.fake_addr, s.real_addr)
	skynet.error("success close connect fd:" .. fd)
	return true
end

-- watchdog接收外部链接
function CMD.accept(source, fd)
	local s = socket_pool[fd]
	if s and not s.co and
		s.type == FD_SCOKET and s.status == FD_STATUS_PREPARED
	then
		s.co = coroutine.running()
		socketdriver.start(fd)
		skynet.wait(s.co)

		-- 重新获取缓存s，因为协程挂起期间有可能丢失缓存。
		if not socket_pool[fd] then
			skynet.error(sformat("fd[%s] try open client error! co[%s] type[%s] status[%s]",
				fd, s and s.co, s and s.type, s and s.status))
			return
		end
		socket_pool[fd].status = FD_STATUS_RUN
		setAddrSocket(fd, socket_pool[fd].real_addr)
		return fd
	end
	skynet.error(sformat("fd[%s] try open client error! co[%s] type[%s] status[%s]",
		fd, s and s.co, s and s.type, s and s.status))
end

---------- 服务的启动和消息类型的注册 ----------

skynet.register_protocol {
	name = "socket",
	id = skynet.PTYPE_SOCKET,	-- PTYPE_SOCKET = 6
	unpack = function ( msg, sz )
		return netpack.filter( queue, msg, sz)
	end,
	dispatch = function (_, _, q, type, ...)
		print("type ", type)
		queue = q
		if type then
			MSG[type](...)
		end
	end
}

local fatherAddr = ...
skynet.start(function ()
	-- 若启动的时候有传，则直接设置watchdog
	watchdog = tonumber(fatherAddr)

	skynet.dispatch("lua", function (session, source, cmd, ...)
		if cmd ~= "set_watchdog" and not watchdog then
			skynet.error("please set watchdog!")
			if session > 0 then
				skynet.ret(skynet.pack(nil))
				return
			end
		end

		local f = assert(CMD[cmd])
		if session == 0 then
			f(source, ...)
		else
			skynet.ret(skynet.pack(f(source, ...)))
		end
	end)
end)