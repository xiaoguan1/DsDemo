-- 全局网关路由表（外置 centerdata 中心库，多节点共享）
-- 记录：uid -> {gate_name, gate_cn, agent_name, agent_cn}
-- 使用方式：Import("game/global/gateway_route.lua")，
-- 载入模块时自动调用 __init__ 建表。

local skynet = require "skynet"
local mysql = require "skynet.db.mysql"
local sformat = string.format
local mquote_sql_str = mysql.quote_sql_str

local CENTER_DATABASE = assert(load("return " .. skynet.getenv("centerdatadb_info"))())

local DB = false

-- 获取中心库连接（注意：协程会阻塞；驱动会在断线后自动重连）
local function _GetDb()
	if DB then
		return true, DB
	end
	local db = mysql.connect({
		host = CENTER_DATABASE.dbhost,
		port = CENTER_DATABASE.dbport,
		database = CENTER_DATABASE.dbname,
		user = CENTER_DATABASE.dbuser,
		password = CENTER_DATABASE.dbpasswd,
		max_pack_size = 2^30,	-- 1GB，设置一个很大的数值，但实际没作用，因为有max_pack_size 4MB限制
		on_connect = function (conn)
			conn:query("set charset utf8")
		end,
	})
	if not db then
		return false, sformat("gateway_route connect mysql(%s:%s) dbname:%s error!",
			CENTER_DATABASE.dbhost, CENTER_DATABASE.dbport, CENTER_DATABASE.dbname)
	end
	DB = db
	return true, DB
end

-- 建路由表（Import 加载本模块时自动调用）
function __init__()
	local isOk, db = _GetDb()
	if not isOk then
		-- 中心库暂不可用时不阻塞服务启动，_GetDb 后续会自行重连
		if _ERROR_F then
			_ERROR_F("%s", db)
		else
			skynet.error(db)
		end
		return
	end

	db:query([[
		create table if not exists online_route (
			uid varchar(64) not null,
			gate_name varchar(64) not null default '',
			gate_cn varchar(64) not null default '',
			agent_name varchar(64) not null default '',
			agent_cn varchar(64) not null default '',
			update_time int unsigned not null default 0,
			primary key (uid)
		) engine=InnoDB default charset=utf8
	]])
end

-- 登记/更新路由（replace into 天然支持顶号更新）
function Reg(uid, gate_name, gate_cn, agent_name, agent_cn)
	local isOk, db = _GetDb()
	if not isOk then
		return false
	end
	local res = db:query(sformat(
		"replace into online_route(uid, gate_name, gate_cn, agent_name, agent_cn, update_time) values(%s, %s, %s, %s, %s, %d)",
		mquote_sql_str(uid), mquote_sql_str(gate_name), mquote_sql_str(gate_cn),
		mquote_sql_str(agent_name), mquote_sql_str(agent_cn), os.time()))
	if not res or res.badresult then
		return false
	end
	return true
end

-- 注销路由
function UnReg(uid)
	local isOk, db = _GetDb()
	if not isOk then
		return false
	end
	db:query(sformat("delete from online_route where uid = %s", mquote_sql_str(uid)))
	return true
end

-- 查询玩家路由，不存在返回nil
function Get(uid)
	local isOk, db = _GetDb()
	if not isOk then
		return
	end
	local res = db:query(sformat("select * from online_route where uid = %s", mquote_sql_str(uid)))
	if not res or res.badresult or #res <= 0 then
		return
	end
	return res[1]
end