local skynet = require "skynet"
local ldpcluster = require "dpcluster.core"
local pcall = pcall
local assert = assert
local pairs = pairs
local type = type
local string = string
local sformat = string.format
local debug = debug
local traceback = debug.traceback

local MSG_TYPE_PUSH 		= 1 -- 异步类型
local MSG_TYPE_REQUEST 		= 2 -- 同步类型的发起
local MSG_TYPE_RESPONSE 	= 3 -- 同步类型的回应
local MSG_TYPE_RESPONSE_E 	= 4 -- 同步类型的回应（请求出错）
local MSG_TYPE_PINGPONG 	= 6 -- 心跳/保活

local MSG_TYPE_MAX = 0xff

-- 心跳/保活参数（单位：秒）
local HEARTBEAT_INTERVAL 	= 5		-- 空闲超过该时长则主动发送心跳
local HEARTBEAT_DEAD 		= 45		-- 超过该时长无任何收发则判定为死链并断开

-- 大包分包缓存回收阈值（单位：秒）
local LARGE_REQ_TIMEOUT 	= 30

--[[
local MSG_TYPE_REQUEST		= 1			-- 请求中
local MSG_TYPE_RESPONSE		= 2			-- 回应
local MSG_TYPE_RESPONSE_E	= 3			-- 回应（请求出错）
local MSG_TYPE_NOTIFY		= 4			-- 通知
local MSG_TYPE_W_PROTO		= 5			-- 发送协议
local MSG_TYPE_PINGPONG		= 6			-- 测试链接
local MSG_TYPE_MAX			= 0xff
]]

-- 加载该文件模块时的判断，且这些方法和变量原则上不能热更的！！！
local GetChannel = assert(GetChannel)
local SyncGate = assert(SyncGate)
local node_session2co = assert(node_session2co)
local connecting = assert(connecting)
local command = assert(command)

local SELF_CLUSTERNAME = assert(SELF_CLUSTERNAME)

local MULTI_ONE	=	0x0			-- 整包
local MULTI_F 	=	0x41		-- 多包的包头新信息
local MULTI_M 	=	0x42		-- 多包的包体数据
local MULTI_E 	=	0x44		-- 多包的最后一个包体数据

-- fd的类
local FdClass = Import("tool/service/basic/gcluster/gcluster_fd_class.lua")
local MISC = Import("game/global/rpc/misc.lua")

-- 大型消息的分包缓存
LARGE_REQUEST = setmetatable({}, {
	__index = function (t, clustername)
		local largeReq = {}
		rawset(t, clustername, largeReq)
		return largeReq
	end
})

local HOSTADDR_M = setmetatable({}, {
	__index = function (t, desAddr)
		if type(desAddr) == "string" then
			local addrNum = skynet.localname(desAddr)
			if addrNum then
				rawset(t, desAddr, addrNum)
				rawset(t, addrNum, desAddr)
			end
			return addrNum or desAddr
		end
		return desAddr
	end,
})

----- 局部方法 ------------------------------

local function mergeProtoType(msgType, protoType)
	local prototypeId = nil
	if type(protoType) == "string" then
		prototypeId = skynet.get_prototype_id(protoType)
	else
		prototypeId = protoType
	end
	assert(msgType <= MSG_TYPE_MAX)
	return (prototypeId << 8) + msgType
end

local function unmergeProtoType(protocolId)
	if not protocolId then
		return
	end
	return (protocolId & 0xff), protocolId >> 8
end

local function socketCloseEvent(sockFd)
    if not sockFd then return end
    for _session, _data in pairs(node_session2co) do
       if _data[3] == sockFd then
           pcall(DealResponse, _session, false, skynet.pack("socket close"))
	   end
	end
end

local function _send(clustername, reqMsg, padding)
	local fdObj = GetChannel(clustername, true)
	fdObj:write(reqMsg, padding)
    return fdObj.fd
end

local function deal_response(session, ok, msg, sz)
    local response_data = node_session2co[session]
    assert(response_data)
    node_session2co[session] = nil
    if not ok then
        skynet.error("deal_response not ok:", session, skynet.unpack(msg, sz))
	end
	response_data[2](ok, msg, sz)
end

local function rpc_response(source, session, isOk, msg, sz)
	if isOk then
		-- msg的内存释放交给引擎完成
		local request, session, padding = ldpcluster.pack_nf(session, SELF_CLUSTERNAME, nil, MSG_TYPE_RESPONSE, msg, sz)
		_send(source, request, padding)
	else
		-- 这里需要释放，因为他是自己打包的
		local request, session, padding = ldpcluster.pack(session, SELF_CLUSTERNAME, nil, MSG_TYPE_RESPONSE_E, msg, sz)
		_send(source, request, padding)
	end
end

local function deal_rpc(source, des_addr, session, msg_type, proto_type, msg, sz)
	if msg_type == MSG_TYPE_REQUEST then
		-- 这里要确认好本节点是否启动成功了，若启动成功了才能接收外部的链接操作（可以在启动节点逻辑中，完成时先该服务发送消息 打标记）
		-- if not skynet.isstartDk() then
		-- 	skynet.error("dpclusterd not ready for rpc request!! des_addr, session, msg_type:", des_addr, session, msg_type)
		-- 	return
		-- end
		-- local tag = des_addr
		des_addr = HOSTADDR_M[des_addr]
		local isOk, responseMsg, sz = xpcall(skynet.rawcall, traceback, des_addr, proto_type, msg, sz)	-- 肯定是当前节点的，所以不用代理了
		-- local isOk, responseMsg, sz = xpcall(skynet.tracecall, traceback, HOST_ADDR_NUM[des_addr], des_addr, proto_type, msg, sz)
		if not isOk then
			responseMsg, sz = skynet.pack(responseMsg)
		end
		rpc_response(source, session, isOk, responseMsg, sz)
	elseif msg_type == MSG_TYPE_PUSH then
		des_addr = HOSTADDR_M[des_addr]
		skynet.rawsend(des_addr, proto_type, msg, sz)
	elseif msg_type == MSG_TYPE_PINGPONG then
		-- 心跳包：仅用于保活，不转发给业务，直接释放消息内存
		skynet.trash(msg, sz)
	elseif msg_type == MSG_TYPE_RESPONSE then
		deal_response(session, true, msg, sz)
	elseif msg_type == MSG_TYPE_RESPONSE_E then
		deal_response(session, false, msg, sz)
	else
		skynet.trash(msg, sz)	-- 释放内存
		error(string.format("dealrpc error, form:%s, addr:%s, session:%s, msg_type:%d",
			source, tostring(des_addr), session, msg_type
		))
	end
end



----- 全局方法 ------------------------------
function SocketErr(clutsername, isPassive)
	assert(clutsername)
	local channelObj = GetChannel(clutsername)
	if channelObj then
		SetChannel(clutsername)
		skynet.error(sformat("%s [%s] clear node_channel!", clutsername, channelObj.address))
	else
		skynet.error(sformat("%s node_channel not data!", clutsername))
	end

	local ct = connecting[clutsername]
	local ctChannelObj
	if ct then
		ctChannelObj = ct.channel or ct.pre_channel
		ct.channel = nil
		ct.pre_channel = nil
		for _, co in ipairs(ct.co) do
			skynet.wakeup(co)
		end
		skynet.error(sformat("%s clear connecting, co len[%s]", clutsername, #ct.co))
	end

	local fd
	if channelObj then
		fd = channelObj.fd
	elseif ctChannelObj and not channelObj then
		fd = ctChannelObj.fd
	end
	if not isPassive then
		SyncGate(false, "close_connect", fd)
	end
	socketCloseEvent(fd)
	skynet.error(sformat("gcluster socket finished! close fd[%s] passive[%s]", fd, isPassive))
end
FdClass.socket_err = SocketErr


function DealResponse(session, ok, msg, sz)
    local response_data = node_session2co[session]
    assert(response_data)
    node_session2co[session] = nil
    if not ok then
        skynet.error("DealResponse not ok:", session, skynet.unpack(msg, sz))
	end
	response_data[2](ok, msg, sz)
end

-- 心跳保活：空闲连接定时发心跳，长期无任何收发则判定死链并主动断开
function HeartbeatTick()
	local now = os.time()

	-- node_channel 同时以 clustername 和 address 为 key，需要按 fdObj 去重
	local channels = {}
	local seen = {}
	for _, fdObj in pairs(node_channel) do
		if not seen[fdObj] then
			seen[fdObj] = true
			channels[#channels + 1] = fdObj
		end
	end

	for _, fdObj in ipairs(channels) do
		if fdObj:is_auth_yes() then
			local last = fdObj.heartbeat_time or fdObj.connected or now
			local gap = now - last
			if gap >= HEARTBEAT_DEAD then
				skynet.error(sformat("gcluster heartbeat timeout, clusterName:[%s] address:[%s] gap:[%s]s",
						fdObj.cluster_name, fdObj.address, gap))
				local isOk, err = pcall(SocketErr, fdObj.cluster_name, false)
				if not isOk then
					skynet.error(sformat("gcluster heartbeat disconnect fail, clusterName:[%s] err:[%s]",
							fdObj.cluster_name, err))
				end
			elseif gap >= HEARTBEAT_INTERVAL then
				-- 空闲超过阈值才发心跳，消息体本身无业务含义
				local msg, sz = skynet.pack(nil)
				local reqMsg, _, padding = ldpcluster.pack(0, SELF_CLUSTERNAME, "",
						mergeProtoType(MSG_TYPE_PINGPONG, 0), msg, sz)
				local isOk, err = pcall(fdObj.write, fdObj, reqMsg, padding)
				if not isOk then
					skynet.error(sformat("gcluster send heartbeat fail, clusterName:[%s] err:[%s]",
							fdObj.cluster_name, err))
				end
			end
		end
	end
end

-- 回收长时间未收齐的大包分包缓存
function CheckLargeRequest()
	local now = os.time()
	for clusterName, largeReq in pairs(LARGE_REQUEST) do
		local expired = {}
		for session, req in pairs(largeReq) do
			local createTime = req.create_time or now
			if now - createTime >= LARGE_REQ_TIMEOUT then
				expired[#expired + 1] = session
			end
		end
		for _, session in ipairs(expired) do
			local req = largeReq[session]
			largeReq[session] = nil
			-- padding里的元素是普通Lua字符串，置nil后由GC回收
			_ERROR_F("gcluster large request timeout, clusterName:[%s] session:[%s] wait:[%s]s",
					clusterName, session, now - (req.create_time or now))
		end
		if next(largeReq) == nil then
			rawset(LARGE_REQUEST, clusterName, nil)
		end
	end
end

function OpenChannel(_node_channel, clusterName)           -- key集群名称（例：cross@1_55001）
	local address = MISC.GetAddrByClusterName(clusterName)
	if not address then
		error(sformat("%s not find address", clusterName))
	end
	local ct = connecting[clusterName]
	if ct then
		local co = coroutine.running()
		table.insert(ct.co, co)
		skynet.wait(co)
		return assert(ct.channel)
	end
	ct = {
		co = {},
		channel = nil,			-- 已完成认证的fd对象
		address = address,		-- 网络地址(ip:port)
		clusterName = clusterName,

		-- 未完成认证的fd对象(socket消息处理需要临时使用到该对象数据)
		pre_channel = nil,
	}
	connecting[clusterName] = ct
	connecting[address] = ct	-- 映射作用
	local fd = SyncGate(true, "connect", address)
	if fd then
		local fdObj = FdClass.FdClass:init(fd, {
				auth = true,
				address = address,
				cluster_name = clusterName,
			})
		ct.pre_channel = fdObj
		fdObj:do_auth()
		ct.pre_channel = nil
		if fdObj:is_auth_yes() then
			local oldFdObj = GetChannel(clusterName)
			if oldFdObj then
				-- 强行关闭最新fd，并将已有的fdObj返回给被沉睡的协程
				fdObj.fd = nil
				ct.channel = oldFdObj
				SyncGate(false, "close_connect", fd)
			else
				SetChannel(clusterName, fdObj)
				ct.channel = fdObj
			end
		else
			skynet.error(sformat("%s auth fail!", clusterName))
		end
	end
	connecting[clusterName] = nil
	connecting[address] = nil
	for _, co in ipairs(ct.co) do
		skynet.wakeup(co)
	end
	assert(GetChannel(clusterName), clusterName .. " connect fail")
	skynet.error("gclusterd succeed connect", clusterName)
	return GetChannel(clusterName)
end

-- 异步发消息
-- node：对方节点信息（ip:port）
-- addr：对方节点的某个服务地址 string
function command.push(_, clustername, addr, prototype, msg, sz)
	if clustername == SELF_CLUSTERNAME then
		error("push gclsterd msg to self")
	end
    local reqMsg, _session, padding = ldpcluster.pack(0, SELF_CLUSTERNAME, addr,
			mergeProtoType(MSG_TYPE_PUSH, prototype), msg, sz)	-- ldpcluster.pack接口会释放msg内存
	_send(clustername, reqMsg, padding)
end


-- 同步发消息
-- overtime：超时时间
-- node：对方节点信息（ip:port）
-- addr：对方节点的某个服务地址 string
function command.request(_, overtime, clustername, addr, prototype, msg, sz)
    if clustername == SELF_CLUSTERNAME then
		error("request dpulsterd msg to self")
	end
	local reqMsg, _session, padding = ldpcluster.pack(nil, SELF_CLUSTERNAME, addr,
			mergeProtoType(MSG_TYPE_REQUEST, prototype), msg, sz)	-- ldpcluster.pack接口会释放msg内存
	local sock_fd = _send(clustername, reqMsg, padding)
	if not sock_fd then
		local response_func = skynet.response()
		response_func(false, "socket error")
		return
	end
	node_session2co[_session] = {
		overtime + skynet.now(),
		skynet.response(),
		sock_fd,
	}
end

-- gate服务发来的消息处理
function command.socket(source, subcmd, fd, ...)
	if subcmd == "accept" then
		-- 外部节点主动连接本节点
		-- 因为被链接进来的网络地址是无法确认其身份的，只能在进行认证的过程中确认身份。故只有认证的过程中是否是真正的接受或者拒绝
		local address = ...
		local isOk = skynet.call(source, "lua", "accept", fd)
		if not isOk then
			skynet.error(sformat("gcluster socket accept from %s fail", address))
			return
		end

		-- 仅仅只是完成了网络上的连接，未进行认证处理。先放在connecting，不设置node_channel(若设置，则有可能未认证而被使用)
		-- 并且也不知道该网络地址address，是哪一个节点的(即cluster_name)
		connecting[address] = {
			co = {},
			channel = nil,
			address = address,
			clusterName = nil,
			pre_channel = FdClass.FdClass:init(fd, {address = address}),
		}
		skynet.error(sformat("gcluster socket accept from %s succeed", address))
	elseif subcmd == "close" then
		-- 外部节点主动关闭本节点链接
		local address = ...
		local fdObj = LoopFindChannel(address)
		if not fdObj then
			skynet.error(sformat("gcluster socket close fail. because %s not find fdObj!", address))
			return
		end
		SocketErr(fdObj.cluster_name, true)
	elseif subcmd == "data" then
		local address, netMsg  = ...
		local channelObj = GetChannel(address)
		if not channelObj then
			channelObj = connecting[address] and connecting[address].pre_channel
			 if not channelObj then
				SyncGate(false, "close_connect", fd)
				skynet.error(sformat("%s not find nodeData, gcluster socket:%s recv data:%s", address, fd, netMsg))
				return
			 end
			 -- 处理验证
			 channelObj:deal_auth(netMsg)
			 return
		end

		if not channelObj:is_auth_yes() then
			-- 未认证就处理消息？
			skynet.error("not auth!!!!!", tool.dumptree(channelObj))
			return
		end

		-- 处理消息
		local multType, session, sourceName, addrOrMsg, protocolId, sz, msg = ldpcluster.unpack(netMsg)
		if multType == MULTI_ONE then
			-- 整包
			channelObj:update_heartbeat()
			local msgType, prototypeId = unmergeProtoType(protocolId)
			deal_rpc(sourceName, addrOrMsg, session, msgType, prototypeId, msg, sz)
		elseif multType == MULTI_F then
			-- 分包包头
			local msgType, prototypeId = unmergeProtoType(protocolId)
			local largeReq = LARGE_REQUEST[sourceName]
			if largeReq[session] then
				local oReq = largeReq[session]
				largeReq[session] = nil
				-- 若出现某个节点的session重复，则丢弃旧的msg缓存，否则会内存堆积。
				-- 注意：padding里的元素是普通Lua字符串，置nil后交给GC回收即可
				_ERROR_F("clustername:[%s] session:[%s] repeated! addr:[%s] msgType:[%s] prototypeId:[%s] sz:[%s]",
						sourceName, session, oReq.addr, oReq.msgType, oReq.prototypeId, oReq.sz)
			end
			largeReq[session] = {
				clusterName = sourceName,
				addr = addrOrMsg,
				msgType = msgType,
				prototypeId = prototypeId,
				sz = sz,
				padding = {},
				create_time = os.time(),	-- 用于超时回收未收齐的分包缓存
			}
		elseif multType == MULTI_M or multType == MULTI_E then
			local largeReq = LARGE_REQUEST[sourceName]
			local req = largeReq[session]
			if req then
				table.insert(req.padding, addrOrMsg)
			else
				skynet.packstring(addrOrMsg, #addrOrMsg)	-- 字节流
				_ERROR_F("clustername:[%s] session:[%s] not find req!", sourceName, session)
				return
			end

			if multType == MULTI_E and req then
				-- 最后一个分包数据
				channelObj:update_heartbeat()
				largeReq[session] = nil
				local msg, sz = ldpcluster.concat(req.padding, req.sz)
				deal_rpc(req.clusterName, req.addr, session, req.msgType, req.prototypeId, msg, sz)
			end
		else
			_ERROR_F("clustername:[%s] session:[%s] unknown multType:[%s]! ",
						sourceName, session, multType)
		end
	elseif subcmd == "error" then
	else
		skynet.error("gclusterd subcmd no matching!", subcmd, fd, ...)
	end
end

function command.close_listen()
	-- 关闭监听（关闭监听不影响现有的socket链接！！！）
	return SyncGate(true, "close_listen")
end

function command.close()
	-- 主动关闭socket链接(非粗暴的方式关闭，等待现有被挂起的协程全部响应完。)
end

function command.kick()
	-- 主动关闭socket链接(粗暴的方式关闭)
	print("kickkickkickkickkickkick")
	for k, v in pairs(connecting) do
		print("connecting ", k, v)
	end
	print()
	for k, v in pairs(node_channel) do
		print("node_channel ", k, v)
	end
end

function __update__()
end
