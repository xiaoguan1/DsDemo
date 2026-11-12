local skynet = require "skynet"
require "skynet.manager"
local UTIL = require "util.core"
local table = table
local cell_num = tonumber(skynet.getenv("dbcell_num"))
assert(cell_num and cell_num > 0)

DBCELL_LIST = {}
ACCEPT, RESPONSE = {}, {}

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

function ACCEPT.REDIRECT(session, source, command, eig, msg, sz)
	local addr = eig and _GetCellAddr(eig)
	if not addr then
		if msg then
			skynet.trash(msg, sz)
		end
		return
	end
	skynet.redirect(addr, source, "lua", session, msg, sz)
end

function RESPONSE.REDIRECT(session, source, command, eig, msg, sz)
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

-- 使用skynet.forward_type的主要目的是 需要转发的协议类型的消息数据包不要进行内存释放，由对应接受处理的子服务去释放内存！
skynet.forward_type({[skynet.PTYPE_DB] = skynet.PTYPE_DB}, function ()
	dofile "./game/global/log.lua"
	dofile "game/global/dblog.lua"

	DBCELL_LIST = {}
	for i = 1, cell_num do
		local addr = skynet.newservice("dbcell", i)
		DBCELL_LIST[i] = addr
	end
	assert(#DBCELL_LIST == table.size(DBCELL_LIST))

	skynet.dispatch("db", function (session, source, command, ...)
		-- 特别注意：这里如果将消息转发出去，必须手动的销毁释放消息数据包的内存！！！！
		if not IS_OPEN then
			-- 数据库服务已经执行关服dump处理了，还有其他服务发消息过来？？？？？
			_ERROR_F()
		end
		if session == 0 then
			ACCEPT.REDIRECT(session, source, command, ...)
		else
			RESPONSE.REDIRECT(session, source, command, ...)
		end
		skynet.ignoreret()
	end)
end)



