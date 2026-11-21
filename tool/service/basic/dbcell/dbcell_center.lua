--------------------
-- 中心库（centerdatadb_info）接入模块
-- 所有 dbcell 实例都合并本模块的指令，由 dbserver 按第一个参数哈希路由：
--   createaccount(uid, phone, serverId) —— 按 uid 哈希选 DBCELL_X
--   getaccount(phone) / setaccountstatus(phone, status) —— 按 phone 哈希选 DBCELL_X
-- 说明：中心库操作频率低（创角等），复用 dbcell 承载，不单独起服务；
--       玩家 uid 由登录网关 .WGATE 生成后作为参数传入，本模块只负责落库
--       中心库连接与队列独立于 dbcell_server 的区服库连接，互不阻塞
--------------------

local skynet = require "skynet"
local mysql = require "skynet.db.mysql"
local skynet_queue = require "skynet_queue"

local sformat = string.format
local mquote_sql_str = mysql.quote_sql_str
local ostime = os.time

local center_db_info = assert(load("return " .. assert(skynet.getenv("centerdatadb_info")))())

ACCEPT, RESPONSE = {}, {}

-- 中心库 SQL 串行队列（与 dbcell_server 的 DB_CS 相互独立）
local DB_CS = skynet_queue()

DB_HLE = false		-- 中心库连接

-- 连接中心库（协程会堵塞，调用方统一经 DB_CS 串行）
function ConnDb()
	if DB_HLE then
		return DB_HLE
	end

	local function on_connect(db)
		db:query("set charset utf8mb4")
	end

	local isOk, db = pcall(mysql.connect, {
		host = center_db_info.dbhost,
		port = center_db_info.dbport,
		database = center_db_info.dbname,
		user = center_db_info.dbuser,
		password = center_db_info.dbpasswd,
		charset = "utf8mb4",
		max_packet_size = 1024 * 1024 * 1024,
		on_connect = on_connect,
	})
	if not isOk or not db then
		_ERROR_F("conn center db(%s:%s/%s) fail:%s", center_db_info.dbhost, center_db_info.dbport,
			center_db_info.dbname, tostring(db))
		return
	end
	DB_HLE = db
	return DB_HLE
end

-- 连接保活：由 dbcell 心跳定期调用；ping 失败丢弃连接，下次查询自动重连
function CheckDb()
	if not DB_HLE then
		return
	end
	local isOk, result = pcall(DB_CS, function ()
		return DB_HLE and DB_HLE:ping()
	end)
	if not isOk or not result or result.badresult then
		_WARN_F("dbcell_center mysql ping fail:%s, drop connection",
			tostring(isOk and tool.dump(result) or result))
		pcall(DB_HLE.disconnect, DB_HLE)
		DB_HLE = false
	end
end

-- 统一查询入口：连接不可用自动重连；查询异常按连接失效处理
local function _Query(name, sql)
	local isOk, result = pcall(DB_CS, function ()
		local db = ConnDb()
		if not db then
			error("no center db connection")
		end
		return db:query(sql)
	end)
	if not isOk then
		_ERROR_F("center query fail:%s name:%s sql:%s", tostring(result), tostring(name), sql)
		DB_HLE = false
		return
	end
	return result
end

-- 按手机号查账号（不存在返回 nil）
function RESPONSE.getaccount(phone)
	if type(phone) ~= "string" or phone == "" then
		return nil, "invalid phone"
	end
	local sql = sformat("select uid, phone, server_id, create_time, status from account where phone = %s limit 1;",
		mquote_sql_str(phone))
	local result = _Query("getaccount", sql)
	if not result or result.badresult then
		return nil, sformat("query fail:%s", tool.dump(result))
	end
	return result[1]
end

-- 创建账号：uid 由登录网关（.WGATE）生成后传入（全平台唯一）
-- 第一个参数 uid 同时是 dbserver 的哈希路由 key，保证同 uid 落到同一 dbcell
-- 返回：uid, isNew（唯一键冲突时返回已存在账号的 uid 与 false）
function RESPONSE.createaccount(uid, phone, serverId)
	if type(uid) ~= "string" or uid == "" or type(phone) ~= "string" or phone == ""
		or type(serverId) ~= "number" then
		return nil, "invalid param"
	end

	local sql = sformat("insert into account(uid, phone, server_id, create_time, status) values(%s, %s, %d, %d, 0);",
		mquote_sql_str(uid), mquote_sql_str(phone), serverId, ostime())
	local result = _Query("createaccount", sql)
	if not result or result.badresult then
		-- 唯一键冲突：账号已被并发创建，返回已有 uid
		local row = RESPONSE.getaccount(phone)
		if row then
			return row.uid, false
		end
		return nil, sformat("insert fail:%s", tool.dump(result))
	end
	return uid, true
end

-- 更新账号状态（0 正常、1 封禁）
function RESPONSE.setaccountstatus(phone, status)
	if type(phone) ~= "string" or phone == "" or (status ~= 0 and status ~= 1) then
		return false
	end
	local sql = sformat("update account set status = %d where phone = %s;", status, mquote_sql_str(phone))
	local result = _Query("setaccountstatus", sql)
	if not result or result.badresult then
		return false
	end
	return true
end

-- 连通性自检
function RESPONSE.ping()
	return ConnDb() and true or false
end
