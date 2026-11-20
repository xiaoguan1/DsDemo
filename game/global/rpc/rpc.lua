local skynet = require "skynet"
local RPCTIMEOUT_CHECKTIME = 200
local os_time = os.time
local sfind = string.find
local sformat = string.format
local table = table
local thas_value = table.has_value
local RPCTIMEOUT_SEC = 2
local MEAT_READONLY = {__newindex = function (t, k, v)
	error("read only")
end}

local PROXYSVR = Import("game/global/rpc/proxysvr.lua")

local nodename = assert(skynet.getenv("node_name"))
local SERVER_CONFIG = assert(SERVER_CONFIG)
local SELF_IPPORT = assert(SELF_IPPORT)
local NODE_LIST = NODE_LIST
local ADHOC_SERVICE_MAP = assert(ADHOC_SERVICE_MAP)
local BASIC_SERVICE_MAP = assert(BASIC_SERVICE_MAP)
local SERVICE_CLUSTERNAME = assert(SERVICE_CLUSTERNAME)
local ALL_SERVICE_MAP = assert(ALL_SERVICE_MAP)

mod_call = {}
-- mod_send = {}

local function isSameServer(serverId)
	assert(serverId)

end

local function isVaildSvr(svr)
	if not svr then
		return
	end
	local mData = BASIC_SERVICE_MAP[svr] or ALL_SERVICE_MAP[svr]
	-- 这里有问题，因为namedsvr.lua没有限制svr重名！！！
	return mData and mData.named
end

local function isOtherNode(serverId)
	local cfg = serverId and SERVER_CONFIG[serverId]
	if cfg and cfg.ipport ~= SELF_IPPORT then
		return true
	end
end

local function getClusterName(service, serverId)
	if not service or not serverId then
		return
	end
	print("SERVICE_CLUSTERNAME ", tool.dumptree(SERVICE_CLUSTERNAME))
	local sId2name = SERVICE_CLUSTERNAME[service]
	if type(sId2name) == "table" then
		return sId2name[serverId]
	end
	return sId2name
end

-- rpc.mod_call.服务名[区服编号].模块名.函数名(参数1, ....)
local function initModCall()
	-- rpc.mod_call.服务名[区服编号].模块名.函数名(参数1, ....)
	local cache = {}
	local self_cache = {}
	local self_cache2 = {}
	local other_cache = {}
	local other_cache2 = {}
	local other_cache3 = {}
	local function __newIndexFun(_, key, val)
		error(string.format("not modify key[%s] val[%s]", key, val))
	end
	setmetatable(mod_call, {
		__index = function (_, svr)
			if not cache[svr] then
				-- service的检查校验
				local addr = assert(isVaildSvr(svr))
				cache[svr] = setmetatable({}, {
					__index = function (_, sidOrmod)
						local serverId = tonumber(sidOrmod)
						if serverId and isOtherNode(serverId) then
							local clustername = assert(getClusterName(svr, serverId))
							-- 跨服发消息(校验是否为本服，若是则禁止 或者 走的skynet.send or call)
							if not other_cache[serverId] then
								other_cache[serverId] = setmetatable({}, {
									__index = function (_, modName)
										if not other_cache2[modName] then
											other_cache2[modName] = setmetatable({}, {
												__index = function (_, funcName)
													if not other_cache3[funcName] then
														other_cache3[funcName] = function (...)
															return PROXYSVR.GetProxy(addr, clustername, "rpc").call(modName, funcName, ...)
														end
													end
													return other_cache3[funcName]
												end,
												__newindex = __newIndexFun,
											})
										end
										return other_cache2[modName]
									end,
									__newindex = __newIndexFun,
								})
							end
							return other_cache[serverId]
						else
							local modName = sidOrmod
							if not self_cache[modName] then
								self_cache[modName] = setmetatable({}, {
									__index = function (_, funcName)
										if not self_cache2[funcName] then
											self_cache2[funcName] = function (...)
												return PROXYSVR.GetProxy(addr, SELF_CLUSTERNAME, "rpc").call(modName, funcName, ...)
											end
										end
										return self_cache2[funcName]
									end,
									__newindex = __newIndexFun,
								})
							end
							return self_cache[modName]
						end
					end,
					__newindex = __newIndexFun,
				})
			end
			return cache[svr]
		end,
		__newindex = __newIndexFun,
	})
end

-- local function ModSend()
	
-- end


-- function BindAllFunc()
-- 	BindFunc(mod_call, "mod", "call")
-- 	-- BindFunc(obj_call, "obj", "call")
-- 	BindFunc(mod_send, "mod", "send")
-- 	-- BindFunc(obj_send, "obj", "send")
-- 	-- BindFunc(obj_cb_send, "obj_cb", "send")
-- 	-- BindFunc(obj_recall_send, "obj_recall", "send")

-- 	setmetatable(mod_call, MEAT_READONLY)
-- 	-- setmetatable(obj_call, MEAT_READONLY)
-- 	setmetatable(mod_send, MEAT_READONLY)
-- 	-- setmetatable(obj_send, MEAT_READONLY)
-- 	-- setmetatable(obj_cb_send, MEAT_READONLY)
-- 	-- setmetatable(obj_recall_send, MEAT_READONLY)
-- end

function __init__()
	-- BindAllFunc()
	-- -- 注意：检测是否有rpc网络断开所有才使用fork替代callout，一般不能使用fork
	-- --		用fork需要告诉主程，让主程来判断
	-- local ENV = getfenv(1)
	-- assert(ENV.FCheck)
	-- skynet.fork(function ()
	-- 	while true do
	-- 		skynet.sleep(RPCTIMEOUT_CHECKTIME)
	-- 		TryCall(ENV.FCheck)		-- 一定要有ENV，这样可以达到热更FCheck(这是使用skynet.fork的缺陷)
	-- 	end
	-- end)

	initModCall()
end