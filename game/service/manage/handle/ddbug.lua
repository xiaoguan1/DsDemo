local skynet = require "skynet"
local posix = require "posix"
local protobuf = require "protobuf"
local skiplist = Import("game/global/algorithm/skiplist.lua")
local zlib = require "zlib"

--[[
wget -q -O - "http://127.0.0.1:40001/ddbug"
或者 curl "http://127.0.0.1:40001/ddbug"

携带参数：wget -q -O - "http://127.0.0.1:40001/ddbug?key1=value1&key2=value2。。。"
或者 curl "http://127.0.0.1:40001/ddbug?key1=value1&key2=value2。。。"
]]

-- local ROLECLASS = Import("game/global/oop/roleclass.lua")
-- Obj = {uid = "1111111111111"}

local mongo = require "skynet.db.mongo"

MgConn = false
local function TestMg()
	if not MgConn then
		local host = '127.0.0.1'
		local port = 27017
		-- local username = "admin"
		-- local password = 123456
		MgConn = mongo.client( { host = host, port = port, } )
	end

	if not MgConn then
		_ERROR("1111111111111111111111")
		return
	end
print("MgConn ", MgConn)
	local db_name = "test"
	local db = MgConn[db_name]
	-- print("db ", db)
	-- if type(db) == "table" then
	-- 	for k, v in pairs(db) do
	-- 		print("--------", k, v)
	-- 	end
	-- end

	db.users:insert({_id = 3 , uid = 9007199254740993})

	-- local cursor = db.test:find()
	-- print("ret ", cursor, cursor:count())
	-- while cursor:hasNext() do
	-- 	local doc = cursor:next()
	-- 	-- 处理doc
	-- 	print("doc ", tool.dump(doc))
	-- end


	-- db:auth(username, password)

	-- db.testcoll:dropIndex("*")
	-- db.testcoll:drop()

	-- local ok, err, ret = db.testcoll:safe_insert({test_key = 1});
	-- assert(ok and ret and ret.n == 1, err)

	-- local ok, err, ret = db.testcoll:safe_insert({test_key = 1});
	-- assert(ok and ret and ret.n == 1, err)
end


function __update__()
end

function Handle_Request(data)
	-- Import("tool/3rd/lua-zlib/test_nocompat.lua")
	-- Import("tool/3rd/lua-zlib/test_compat.lua")

	-- Import("tool/battle_report_demo/battle_sim.lua")
	-- Import("game/global/battle/battle_main.lua")











	-- 弱值表示例
	-- local t = setmetatable({}, { __mode = "v" })
	-- t.key = { big = "data" }   -- 值只被 t 引用
	-- t.a = 1
	-- print(tool.dumptree(t))
	-- collectgarbage()
	-- print(tool.dumptree(t))               --> nil，值已被回收，但键 "key" 还在（"key" 是强键字符串）
	-- print(tool.dumptree(data))
	-- print("111---------- ", Obj:GetHaha(), "----------------2222")
	-- TestMg()

	-- print("111111111111 ", protobuf.verifyP())
	-- print("wwwwwwwww", protobuf.check("role.S2c_role", "uid"))

	-- print("wwwwwwwww", protobuf.P, protobuf.check("role.S2c_role", "aaa"))

	-- local RPROTOMAP = Import("game/global/rprotomap.lua")
	-- print("rprotomap ", tool.dumptree(RPROTOMAP.RPROTOMAP))
	-- local f = io.open("protocol/record-protocol-id", "a+")
	-- -- local c = f:read("a")

	-- for c in f:lines("l") do
	-- 	print("---", c)
	-- end

	-- print("cccccccc ", f:lines("l"))


-- ---------- 使用示例 ----------
-- local t = createTrackedTable()

-- t.foo = "hello"     -- 新增 → 计数+1
-- t.bar = 42          -- 新增 → 计数+1
-- print(t.getCount()) --> 2
-- print(t.foo)        --> hello

-- t.foo = "world"     -- 更新（已存在） → 计数不变
-- print(t.getCount()) --> 2

-- t.bar = nil         -- 删除 → 计数-1
-- print(t.getCount()) --> 1
-- print(t.bar)        --> nil

-- t.baz = nil         -- 删除不存在的键 → 什么也不发生
-- print(t.getCount()) --> 1
	-- _INFO("1111111111111111111")
	-- _WARN("1111111111111111111")
	-- _ERROR("1111111111111111111")
	-- _MEM_ALARM("1111111111111111111")
	-- _ERROR_ALARM("1111111111111111111")
	-- _LOG_EVENT("aaaa.lua", "ahshdhasdhas")
	-- _DEBUG("qqqqqqqqqqqqqqqqqqqqq")

	-- local t = {}
	-- for i = 1, 55555 do
	-- 	t[i] = "s"
	-- end
	local RPC = Import("game/global/rpc/rpc.lua")
	RPC.mod_call.display[55001].MODULE_DB.IsShutDown({})
end

function __init__()
	-- ROLECLASS.RoleClass:New(Obj)
	-- print("------", Obj.GetHaha, Obj.GetHaha and Obj:GetHaha())
end

