--------------------
-- 模块作用：服务代理，替代skynet的send与call，拓展成不单单对当前节点的send与call
--------------------

local skynet = require "skynet"
local setmetatable = setmetatable
local assert = assert
local error = error
local type = type
local string = string
local sformat = string.format

local SELF_CLUSTERNAME = assert(SELF_CLUSTERNAME)
local SERVER_CONFIG = SERVER_CONFIG
local host_id = tonumber(assert(skynet.getenv("server_id")))
local nodename = assert(skynet.getenv("node_name"))
local cluster_no = tonumber(assert(skynet.getenv("cluster_no")))
local CLUSTER_NAME_FMT = assert(CLUSTER_NAME_FMT)
local SERVICE_CLUSTERNAME = assert(SERVICE_CLUSTERNAME)

local MISC = Import("game/global/rpc/misc.lua")

local skynet_send = skynet.send
local skynet_call = skynet.call
local READONLY_META = { __newindex = function () error("read only") end }

local is_testserver = (skynet.getenv("is_testserver") == "true") and true or false
local function _obj_check(...)
	if not is_testserver then
		return
	end
	local n = select("#", ...)
	local arg = {...}
	for i = 1, n do
		if type(arg[i]) == "table" then
			local mt = getmetatable(arg[i])
			if mt and mt.__ObjectType then	-- 是对象
				error("param can not be obj")
			end
		end
	end
end

ALL_PROXYSVR = {
	self_node = {},
	othernode = {},
	-- ....
}

local function gen_send(addr, clustername, prototype)
	prototype = prototype or "lua"
	if clustername == SELF_CLUSTERNAME then
		local addrtype = type(addr)
		local addr_num = nil
		local cache_func = {}
		return setmetatable({},  {
			__index = function (t, k)
				if addrtype == "string" then
					if not addr_num then
						addr_num = skynet.localname(addr)
						if not addr_num then error("not service by name" .. addr) end
					end
				else
					addr_num = addr
				end
				if not cache_func[k] then
					cache_func[k] = function(...)
						_obj_check(...)
						return skynet_send(addr_num, prototype, k, ...)		-- skynet.send那里有返回是否有那个节点的信息
					end
				end
				return cache_func[k]
			end,
			__call = function (t, ...)
				if addrtype == "string" then
					if not addr_num then
						addr_num = skynet.localname(addr)
						if not addr_num then error("not service by name" .. addr) end
					end
				else
					addr_num = addr
				end
				_obj_check(...)
				return skynet_send(addr_num, prototype, ...)				-- skynet.send那里有返回是否有那个节点的信息
			end
		})
	else
		if not MISC.IsValidClusterName(clustername) then
			error("clustername error: " .. clustername)
		end
		local cache_func = {}
		return setmetatable({}, {
			__index = function (t, k)
				if not cache_func[k] then
					cache_func[k] = function (...)
						_obj_check(...)
						return MISC.send(clustername, addr, prototype, k, ...)	-- skynet.send那里有返回是否有那个节点的信息
					end
				end
				return cache_func[k]
			end,
			__call = function (t, ...)
				_obj_check(...)
				return MISC.send(clustername, addr, prototype, ...)				-- skynet.send那里有返回是否有那个节点的信息
			end
		})
	end
end

local function gen_call(addr, clustername, prototype)
	prototype = prototype or "lua"
	if clustername == SELF_CLUSTERNAME then
		local addrtype = type(addr)
		local addr_num = nil
		local cache_func = {}
		return setmetatable({},  {
			__index = function (t, k)
				if addrtype == "string" then
					if not addr_num then
						addr_num = skynet.localname(addr)
						if not addr_num then error("not service by name" .. addr) end
					end
				else
					addr_num = addr
				end
				if not cache_func[k] then
					cache_func[k] = function(...)
						_obj_check(...)
						return skynet_call(addr_num, prototype, k, ...)		-- skynet.send那里有返回是否有那个节点的信息
					end
				end
				return cache_func[k]
			end,
			__call = function (t, ...)
				if addrtype == "string" then
					if not addr_num then
						addr_num = skynet.localname(addr)
						if not addr_num then error("not service by name" .. addr) end
					end
				else
					addr_num = addr
				end
				_obj_check(...)
				return skynet_call(addr_num, prototype, ...)				-- skynet.send那里有返回是否有那个节点的信息
			end
		})
	else
		if not MISC.IsValidClusterName(clustername) then
			error("clustername error: " .. clustername)
		end
		local cache_func = {}
		return setmetatable({}, {
			__index = function (t, k)
				if not cache_func[k] then
					cache_func[k] = function (...)
						_obj_check(...)
						return MISC.call(clustername, addr, prototype, k, ...)
					end
				end
				return cache_func[k]
			end,
			__call = function (t, ...)
				_obj_check(...)
				return MISC.call(clustername, addr, prototype, ...)
			end
		})
	end
end

local function create_proxysvr(addr, clustername, prototype)
	return setmetatable({
		addr = addr,
		clustername = clustername,
		prototype = prototype,

		send = gen_send(addr, clustername, prototype),
		call = gen_call(addr, clustername, prototype),
	}, READONLY_META)
end


-- 外部接口 ------------------------------
function GetProxy(addr, clustername, prototype)
	if clustername == SELF_CLUSTERNAME then
		-- 本服节点
		if ALL_PROXYSVR.self_node[addr] and ALL_PROXYSVR.self_node[addr].prototype == prototype then
			return ALL_PROXYSVR.self_node[addr]
		else
			local proxy = create_proxysvr(addr, clustername, prototype)
			ALL_PROXYSVR.self_node[addr] = proxy
			return proxy
		end
	else
		-- 跨服节点
		assert(clustername)
		local proxy = ALL_PROXYSVR.othernode[addr] and ALL_PROXYSVR.othernode[addr][clustername]
		if proxy and proxy.prototype == prototype then
			return proxy
		end
		proxy = create_proxysvr(addr, clustername, prototype)
		ALL_PROXYSVR.othernode[addr] = ALL_PROXYSVR.othernode[addr] or {}
		ALL_PROXYSVR.othernode[addr][clustername] = ALL_PROXYSVR.othernode[addr][clustername] or {}
		ALL_PROXYSVR.othernode[addr][clustername] = proxy
		return proxy
	end
end

-- 获取当前节点的服务代理
function GetProxyByServiceName(serviceName, ...)
	local count = select("#", ...)
	local targetnode, prototype, serverId = nodename, "lua", host_id -- 默认值
	if count == 1 then
		-- 1个参数
		prototype  = ...
	elseif count == 2 then
		-- 2个参数
		prototype, serverId = ...
	elseif count == 3 then
		-- 3个参数
		targetnode, prototype, serverId = ...
	end
	assert(targetnode and prototype and serverId)

	-- 目前仅仅支持同一个集群内进行消息发送
	local clusterName = MISC.GetClusterName(targetnode, serverId)
	if not clusterName then
		_ERROR_F("%s %s not exists", targetnode, serverId)
		return
	end

	local namedData = BASIC_SERVICE_MAP[serviceName]
	if namedData then
		-- 基础设施服务，不支持跨节点通信
		assert(namedData.named and clusterName == SELF_CLUSTERNAME)
		return GetProxy(namedData.named, SELF_CLUSTERNAME, prototype)
	end

	-- 优先查找一般性服务，找不到再找adhoc服务
	namedData = NORMAL_SERVICE_MAP[targetnode] and NORMAL_SERVICE_MAP[targetnode][serviceName]
	if not namedData then
		namedData = ADHOC_SERVICE_MAP[targetnode] and ADHOC_SERVICE_MAP[targetnode][serviceName]
	end
	assert(namedData and namedData.named)
	if clusterName ~= SELF_CLUSTERNAME then
		-- 若是跨节点则检查对方节点是否启动了该服务（暂时不考虑normal的情况）
		assert(SERVICE_CLUSTERNAME[serviceName] and SERVICE_CLUSTERNAME[serviceName][serverId])
	end
	return GetProxy(namedData.named, clusterName, prototype)
end