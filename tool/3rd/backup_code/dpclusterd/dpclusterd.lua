local skynet = require "skynet"
local sc = require "skynet.socketchannel"
local socket = require "skynet.socket"
local string = string
local type = type
local pairs = pairs
local assert = assert
local tostring = tostring
local pcall = pcall
local xpcall = xpcall
local traceback = debug.traceback
local tinsert = table.insert

local dpcluster_auths = assert(skynet.getenv("dpcluster_auths"))
local ldpcluster = require "dpcluster.core"

-- 注意:通过dpcluster的client都只能是下面的类型
skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = skynet.unpack,
	pack = skynet.pack,
}
skynet.register_protocol({
	name = "rpc",
	id = skynet.PTYPE_RPC,
})
-- skynet.register_protocol({
-- 	name = "agent_client",
-- 	id = skynet.PTYPE_AGENT_CLIENT,
-- })
-- assert(skynet.PTYPE_MAX <= 0xff)

-- 注意：
-- 发送前应开启的当前接受的gate
-- dpcluster_name仅能一个，不然gate的处理就不会顺序了

local MSG_TYPE_REQUEST		= 1			-- 请求中
local MSG_TYPE_RESPONSE		= 2			-- 回应
local MSG_TYPE_RESPONSE_E	= 3			-- 回应（请求出错）
local MSG_TYPE_NOTIFY		= 4			-- 通知
local MSG_TYPE_W_PROTO		= 5			-- 发送协议
local MSG_TYPE_PINGPONG		= 6			-- 测试链接
local MSG_TYPE_MAX			= 0xff

local MULTI_F = 0x41
local MULTI_M = 0x42
local MULTI_E = 0x44

SENDERROR_OPEN = true

local dpclusterconfig_path = skynet.getenv "dpcluster"
if not dpclusterconfig_path then
	error("not dpcluster")
end

local node_session = {}
local node_session2co = {}
local command = {}
local cache_named = {}

local function read_response(sock)
    local msg = sock:read()
    error("only send in socketchannel")
end

local socket_close_event = nil
local connecting = {}

local function _auth_check(key)
	return function (sock)
		local authcode = string.pack(">I2", string.len(dpcluster_auths)) .. dpcluster_auths
		local retData = sock:request(authcode, function(_sock)
			local retData = _sock:read(1)
			if retData ~= "1" then
				local msg = string.format("error cross auth:%s, ip_port:%s", retData, key)
				error(msg)
			end
			return true, retData
		end)
	end
end

local function open_channel(t, key)           -- key可以为node名字也可以直接是ip:port
	local ct = connecting[key]
	if ct then
		local co = coroutine.running()
		table.insert(ct, co)
		skynet.wait(co)
		return assert(ct.channel)
	end
	ct = {}
	connecting[key] = ct
	local host, port = string.match(key, "([^:]+):(.*)$")
	local c = sc.channel {
		host = host,
		port = tonumber(port),
		-- response = read_response
        nodelay = true,
		close_event = socket_close_event,
		auth = _auth_check(key),
	}
    local succ, err = pcall(c.connect, c, true)
    if succ then
		t[key] = c
		ct.channel = c
	end
	connecting[key] = nil
    for _, co in ipairs(ct) do
		skynet.wakeup(co)
	end
	assert(succ, err)
	return c
end

local node_channel = setmetatable({}, { __index = open_channel })

local function _one_send(node, request, padding)
	-- node_channel[node] may yiled or throw error
	local c = node_channel[node]
	-- may write throw error
    c:request(request, nil, padding, true)	-- 都不用 lwrite
    return c:sockfd()
end

local function _double_send(node, notifyMsg, request, padding, notTips)
	local isOk, sock_fd = xpcall(_one_send, traceback, node, request, padding)
	if not isOk then
		if SENDERROR_OPEN and not notTips then
			skynet.error(sock_fd)
		end
		-- 再发一次, 因为报错只有链接不上或者发送错误。不会有发成功了又报错
		isOk, sock_fd = xpcall(_one_send, traceback, node, request, padding)
		if not isOk then
			if SENDERROR_OPEN and not notTips then
				skynet.error("_double_send error:", node, notifyMsg)
				assert (false, sock_fd)
			else
				return
			end
		end
	end
	return sock_fd
end

function command.close_senderror()
	SENDERROR_OPEN = false
end

function command.open_senderror()
	SENDERROR_OPEN = true
end

local function _not_pack(...)
	return ...
end

local function _merge_prototype(msgtype, prototype)
	local prototype_id = nil
	if type(prototype) == "string" then
		prototype_id = skynet.get_prototype_id(prototype)
	else
		prototype_id = prototype
	end
	assert(msgtype <= MSG_TYPE_MAX)
	return (prototype_id << 8) + msgtype
end

-- ret msgtype, prototype
local function _unmerge_prototype(mtype)
	return (mtype & 0xff), (mtype >> 8)
end

function command.req(_, overtime, node, addr, prototype, msg, sz)
	if node == DPCLUSTER_NODE.node_ipport then
		error("req dpulsterd msg to self")
	end
	-- session, node, addr, type, msg, sz
	-- 把MSG_TYPE_REQUE5T混合一下访河类型
	-- msg可能为空也可以
	local request, _session, padding = ldpcluster.pack(nil, DPCLUSTER_NODE.node_ipport, addr, _merge_prototype(MSG_TYPE_REQUEST, prototype), msg, sz)	-- pack接口会释放msg内存
	local sock_fd = _double_send(node, addr, request, padding)
	if not sock_fd then
		local response_func = skynet.response()
		response_func(false, "socket error")
	else
		node_session2co[_session] = {
			overtime + skynet.now(),
			skynet.response(_not_pack),
			sock_fd,
		}
	end
end

function command.req_notips(_, overtime, node, addr, prototype, msg, sz)
	if node == DPCLUSTER_NODE.node_ipport then
		error(" req dpclsterd msg to self")
	end
	-- session, node, type, msg, sz
	-- MSG_TYPE_REQUEST混合一下访问类型
	-- msg可能为空也可以
	local request, _session, padding = ldpcluster.pack(nil, DPCLUSTER_NODE.node_ipport, addr, _merge_prototype(MSG_TYPE_REQUEST, prototype), msg, sz)	-- pack接口会释放msg内存
	local sock_fd = _double_send(node, addr, request, padding, true)
	if not sock_fd then
		local response_func = skynet.response()
		response_func(false, "socket error")
    else
		node_session2co[_session] = {
			overtime + skynet.now(),
			skynet.response(_not_pack),
			sock_fd,
		}
	end
end

function command.req_heartbeat(_, overtime, node, prototype, msg, sz)
	if node == DPCLUSTER_NODE.node_ipport then
		error ("req_heartbeat dpclsterd msg to self")
	end
	-- session, node, addr, type, msg, sz
	-- 把MSG_TYPE_REQUEST混合一下访问类型
	-- msg可常为显可以
	local request, _session, padding = ldpcluster.pack(nil, DPCLUSTER_NODE.node_ipport, nil, _merge_prototype(MSG_TYPE_PINGPONG, prototype), msg, sz)	-- pack接口会释放msg内存
	local sock_fd = _double_send(node, "req_heartbeat", request, padding, true)
	if not sock_fd then
        local response_func = skynet.response()
        response_func(false, "socket error")
	else
		node_session2co[_session] = {
			overtime + skynet.now(),
			skynet.response(_not_pack),
			sock_fd,
		}
	end
end

function command.push(_, node, addr, prototype, msg, sz)
	if node == DPCLUSTER_NODE.node_ipport then
		error("push dpclsterd msg to self")
	end

    local request, _session, padding = ldpcluster.pack(0, DPCLUSTER_NODE.node_ipport, addr, _merge_prototype(MSG_TYPE_NOTIFY, prototype), msg, sz)
	_double_send(node, addr, request, padding)
end

function command.push_notips(_, node, addr, prototype, msg, sz)
	if node == DPCLUSTER_NODE.node_ipport then
		error("push dpclsterd msg to self")
	end

    local request, _session, padding = ldpcluster.pack(0, DPCLUSTER_NODE.node_ipport, addr, _merge_prototype(MSG_TYPE_NOTIFY, prototype), msg, sz)
    _double_send(node, addr, request, padding, true)
end

function command.write_proto(_, node, msg, sz)
    if node == DPCLUSTER_NODE.node_ipport then
        error("write_proto dpclsterd msg to self")
    end

    local request, _session, padding = ldpcluster.pack(0, DPCLUSTER_NODE.node_ipport, nil, MSG_TYPE_W_PROTO, msg, sz)
	_double_send(node, "write_proto", request, padding)
end

local function node_listen(addr, port)
    local gate = skynet.newservice("gate")
    if port == nil then
        addr, port = string.match(addr, "([^:]+):(.*)$")
        assert(addr, port)
    end
    skynet.error("dpclusterd listen on:", port)
    skynet.call(gate, "lua", "open", { address = addr, port = port, nodelay = true, })	-- 肯定是当前节点的，所以不用代理了
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

local function _socket_close_event(sock_fd)
    if not sock_fd then return end
    for _session, _data in pairs(node_session2co) do
       if _data[3] == sock_fd then
           pcall(deal_response, _session, false, skynet.pack("socket close"))
	   end
	end
end

socket_close_event = _socket_close_event

local function rpc_response(node, session, ok, msg, sz)
	if ok then
		local request, session, padding = ldpcluster.pack_nf(session, DPCLUSTER_NODE.node_ipport, nil, MSG_TYPE_RESPONSE, msg, sz)
		_double_send(node, "rpc_response", request, padding)
	else
		-- 这里需要释放，因为他是自己打包的
		local request, session, padding = ldpcluster.pack(session, DPCLUSTER_NODE.node_ipport, nil, MSG_TYPE_RESPONSE_E, msg, sz)
		_double_send(node, "rpc_response", request, padding)
	end
end

local function _write_direct(msg, sz, ...)
    skynet.trash(msg, sz)				-- 释放内存
    write_snode(...)
end

local function _addr_number(des_addr)
	if type(des_addr) == "string" then
		local addr_num = cache_named[des_addr]
		if not addr_num then
			addr_num = skynet.localname(des_addr)
			if addr_num then
				cache_named[des_addr] = addr_num
           else
               return des_addr
           end
       end
       return addr_num
    end
    return des_addr
end

local function deal_rpc(source_node, des_addr, session, msg_type, proto_type, msg, sz)
	if msg_type == MSG_TYPE_REQUEST then
		-- 这里要确认好本节点是否启动成功了，若启动成功了才能接收外部的链接操作（可以在启动节点逻辑中，完成时先该服务发送消息 打标记）
		-- if not skynet.isstartDk() then
		-- 	skynet.error("dpclusterd not ready for rpc request!! des_addr, session, msg_type:", des_addr, session, msg_type)
		-- 	return
		-- end

		des_addr = _addr_number(des_addr)
		local isOk, msg, sz = xpcall(skynet.rawcall, traceback, des_addr, proto_type, msg, sz)	-- 肯定是当前节点的，所以不用代理了
	   	if not isOk then
           msg, sz = skynet.pack(msg)
		end
    	rpc_response(source_node, session, isOk, msg, sz)
    elseif msg_type == MSG_TYPE_RESPONSE then
		-- 由于msg, sz是可能别的打包方式所以加一个skynet.pack在外层，因为外层是由dpcluste穿过来的，必定是lua类型
		deal_response(session, true, skynet.pack(msg, sz))
    elseif msg_type == MSG_TYPE_RESPONSE_E then
		deal_response(session, false, msg, sz)
	elseif msg_type == MSG_TYPE_NOTIFY then
		des_addr = _addr_number(des_addr)
		skynet.rawsend(des_addr, proto_type, msg, sz)
	elseif msg_type == MSG_TYPE_W_PROTO then
		_write_direct(msg, sz, skynet.unpack(msg, sz))
    elseif msg_type == MSG_TYPE_PINGPONG then
		rpc_response(source_node, session, true, msg, sz)
	else
		skynet.trash(msg, sz)	-- 释放内存
		error(string.format("dealrpc error, form:%s, addr:%s, session:%s, msg_type:%d",
			source_node, tostring(des_addr), session, msg_type
		))
	end
end

large_request = {}
accept_fd = {}

function command.socket(source, subcmd, fd, msg)
    if subcmd == "data" then
		if accept_fd[fd] then
			-- multInfo, session, node, addr, type, sz, msg
			-- multInfo, session, node, addr, type, sz
			-- multinfo, session, node, msg
            assert(#msg >= 0)
			local mult_type, session, source_node, des_addr, msg_type, sz, msg = ldpcluster.unpack(msg)
			if mult_type == 0 then
				local msg_type, proto_type = _unmerge_prototype(msg_type)
				deal_rpc(source_node, des_addr, session, msg_type, proto_type, msg, sz)
			elseif mult_type == MULTI_F then
				if not large_request[source_node] then
					large_request[source_node] = {}
				end
                large_request[source_node][session] = {
					des_addr = des_addr,
					msg_type = msg_type,
					sz = sz,
					msg_list = {},
				}
			elseif mult_type == MULTI_M then
				local msg_list = large_request[source_node][session].msg_list
				tinsert(msg_list, des_addr)
			elseif mult_type == MULTI_E then
				local l_req = large_request[source_node][session]
				large_request[source_node][session] = nil

				local msg_list = l_req.msg_list
				tinsert(msg_list, des_addr)
				local msg, sz = ldpcluster.concat(msg_list, l_req.sz)
				local msg_type, proto_type = _unmerge_prototype(l_req.msg_type)
				deal_rpc(source_node, l_req.des_addr, session, msg_type, proto_type, msg, sz)
			end
		elseif accept_fd[fd] == false then
			-- 验证一下
			if msg == dpcluster_auths then
				accept_fd[fd] = true
				socket.write(fd, "1")
			else
				socket.write(fd, "0")
			end
		end
	elseif subcmd == "open" then
		skynet.error(string.format("dpclsterd socket accept from %s", msg))
		skynet.call(source, "lua", "accept", fd)
		accept_fd[fd] = false
	elseif subcmd == "close" or subcmd == "error" then
		accept_fd[fd] = nil
		skynet.error(string.format("dpclusterd socket %s %d : %s", subcmd, fd, msg))
	else
		skynet.error(string.format("dpclusterd socket %s %d : %s", subcmd, fd, msg))
	end
end

local function deal_overtime()
	while true do
		skynet.sleep(100) -- 每秒执行
		local n = skynet.now()
		for _session, _data in pairs(node_session2co) do
			if n >= _data[1] then
				pcall(deal_response, _session, false, skynet.pack("time out"))
			end
		end
	end
end

skynet.start(function ()
	local dpcluster = skynet.getenv("dpcluster")
	DPCLUSTER_NODE = load("return " .. dpcluster)()

	skynet.dispatch("lua", function (session, source, cmd, ...)
		local f = assert(command[cmd])
		f(source, ...)
	end)

	node_listen(DPCLUSTER_NODE.node_ipport)		-- 开启当前节点 gate
	skynet.timeout(0, deal_overtime)
end)
