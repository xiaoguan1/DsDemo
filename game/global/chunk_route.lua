-- 全局 chunk 路由表（外置 centerdata 中心库，多节点共享）
-- 记录：chunk_key -> {cell_name, cell_cn}
-- chunk_key 格式："cx_cy"，cx/cy 为 0 起始的 chunk 坐标（如 "3_5"）
-- 使用方式：Import("game/global/chunk_route.lua")，载入模块时自动调用 __init__ 建表。

local skynet = require "skynet"
local mysql = require "skynet.db.mysql"
local sformat = string.format
local mquote_sql_str = mysql.quote_sql_str

local CENTER_DATABASE = assert(load("return " .. skynet.getenv("centerdatadb_info"))())

local DB = false

-- 内存缓存（chunk 数量级很小，写透缓存可以大幅降低中心库压力；
-- 多节点短暂不一致可接受：cell 迁移完成前旧 cell 仍能兜底转发）
local CACHE = {}

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
		return false, sformat("chunk_route connect mysql(%s:%s) dbname:%s error!",
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
		create table if not exists chunk_route (
			chunk_key varchar(32) not null,
			cell_name varchar(64) not null default '',
			cell_cn varchar(64) not null default '',
			update_time int unsigned not null default 0,
			primary key (chunk_key)
		) engine=InnoDB default charset=utf8
	]])
end

-- 登记/更新 chunk 归属（replace into 天然支持 cell 迁移时的覆盖更新；同时写透内存缓存）
function Reg(chunk_key, cell_name, cell_cn)
	local isOk, db = _GetDb()
	if not isOk then
		return false
	end
	local res = db:query(sformat(
		"replace into chunk_route(chunk_key, cell_name, cell_cn, update_time) values(%s, %s, %s, %d)",
		mquote_sql_str(chunk_key), mquote_sql_str(cell_name), mquote_sql_str(cell_cn), os.time()))
	if not res or res.badresult then
		return false
	end
	CACHE[chunk_key] = { cell_name = cell_name, cell_cn = cell_cn }
	return true
end

-- 注销 chunk 归属（cell 正常迁出/关服时调用）
function UnReg(chunk_key)
	local isOk, db = _GetDb()
	if not isOk then
		return false
	end
	db:query(sformat("delete from chunk_route where chunk_key = %s", mquote_sql_str(chunk_key)))
	CACHE[chunk_key] = nil
	return true
end

-- 查询 chunk 归属，不存在返回 nil（优先内存缓存，未命中回源并回填）
function Get(chunk_key)
	local hit = CACHE[chunk_key]
	if hit then
		return hit
	end
	local isOk, db = _GetDb()
	if not isOk then
		return
	end
	local res = db:query(sformat("select * from chunk_route where chunk_key = %s", mquote_sql_str(chunk_key)))
	if not res or res.badresult or #res <= 0 then
		return
	end
	CACHE[chunk_key] = { cell_name = res[1].cell_name, cell_cn = res[1].cell_cn }
	return CACHE[chunk_key]
end