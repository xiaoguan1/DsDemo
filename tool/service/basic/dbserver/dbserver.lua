local skynet = require "skynet"
require "skynet.manager"
local UTIL = require "util.core"
local table = table
local cell_num = tonumber(skynet.getenv("dbcell_num"))
assert(cell_num and cell_num > 0)

-- play 节点配置了 redis_info：dbcell 同时具备 Redis 热层能力；user 节点没有
local mem_enabled = (skynet.getenv("redis_info") ~= nil)

DBCELL_LIST = {}

IS_OPEN = true

-- 哈希运算，获取代工数据库服务地址
local function _GetCellAddr(eig)
	local maxLen = #DBCELL_LIST
	local eType = type(eig)
	local no
	if eType == "string" then
		no = UTIL.strhash(eig, maxLen)
	else
		no = eig % maxLen
	end
	if no == 0 then
		no = maxLen
	end
	return DBCELL_LIST[no]
end

-- db / mem 共用：按 eig（业务 key）路由到 cell；消息原始数据包不在这里释放，
-- 由接收的 cell 解码后释放（skynet.forward_type 语义）
local function _Redirect(session, source, command, eig, msg, sz)
	local addr = eig and _GetCellAddr(eig)
	if not addr then
		if msg then
			skynet.trash(msg, sz)
		end
		return
	end
	skynet.redirect(addr, source, "lua", session, msg, sz)
end

skynet.register_protocol({
	name = "db",
	id = skynet.PTYPE_DB,
	pack = skynet.pack,
	unpack = function (msg, sz)
		-- 提前反序列化2个
		local command, eig = skynet.unexpack(msg, sz, 2)
		return command, eig, msg, sz
	end,
})

skynet.register_protocol({
	name = "mem",
	id = skynet.PTYPE_MEM,
	pack = skynet.pack,
	unpack = function (msg, sz)
		-- 提前反序列化2个
		local command, eig = skynet.unexpack(msg, sz, 2)
		return command, eig, msg, sz
	end,
})

local forward_map = {[skynet.PTYPE_DB] = skynet.PTYPE_DB}
if mem_enabled then
	forward_map[skynet.PTYPE_MEM] = skynet.PTYPE_MEM
end

-- 使用skynet.forward_type的主要目的是 需要转发的协议类型的消息数据包不要进行内存释放，由对应接受处理的子服务去释放内存！
skynet.forward_type(forward_map, function ()
	dofile "./game/global/log.lua"
	dofile "game/global/dblog.lua"

	DBCELL_LIST = {}
	for i = 1, cell_num do
		local addr = skynet.newservice("dbcell", i)
		DBCELL_LIST[i] = addr
	end
	assert(#DBCELL_LIST == table.size(DBCELL_LIST))

	local function _Dispatch(session, source, command, eig, msg, sz)
		-- 特别注意：这里如果将消息转发出去，必须手动的销毁释放消息数据包的内存！！！！
		if not IS_OPEN then
			-- 数据库服务已经执行关服dump处理了，还有其他服务发消息过来？？？？？
			_ERROR_F("dbserver closed, drop command:%s", tostring(command))
			if msg then
				skynet.trash(msg, sz)
			end
			return
		end
		_Redirect(session, source, command, eig, msg, sz)
		skynet.ignoreret()
	end

	skynet.dispatch("db", _Dispatch)
	if mem_enabled then
		skynet.dispatch("mem", _Dispatch)
	end
end)
