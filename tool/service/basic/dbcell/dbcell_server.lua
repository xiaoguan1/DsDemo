local skynet = require "skynet"
local mysql = require "skynet.db.mysql"
local skynet_queue = require "skynet_queue"
local sformat = string.format
local database_info = assert(load("return " .. assert(skynet.getenv("database_info")))())

local mquote_sql_str = mysql.quote_sql_str
local MODDATA_DEFAULT = mquote_sql_str("{}")

ACCEPT, RESPONSE = {}, {}

-- 所有 SQL 串行执行：单连接 + 事务（modsave_multi）必须独占，不能按 saveName 分队列
local DB_CS = skynet_queue()

DB_HLE = false
function ConnDb()
	if DB_HLE then
		return DB_HLE
	end

	local function on_connect(db)
		db:query("set charset utf8mb4");
	end
	local isOk, db = pcall(mysql.connect, {
		host = database_info.dbhost,
		port = database_info.dbport,
		database = database_info.dbname,
		user = database_info.dbuser,
		password = database_info.dbpasswd,
		charset = "utf8mb4",
		max_packet_size = 1024 * 1024 * 1024,
		on_connect = on_connect
	})
	if not isOk or not db then
		_ERROR_F("conn db(%s:%s/%s) fail:%s", database_info.dbhost, database_info.dbport,
			database_info.dbname, tostring(db))
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
	-- ping 也走查询队列，避免与事务交叉
	local isOk, result = pcall(DB_CS, function ()
		return DB_HLE and DB_HLE:ping()
	end)
	if not isOk or not result or result.badresult then
		_WARN_F("dbcell mysql ping fail:%s, drop connection",
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
			error("no db connection")
		end
		return db:query(sql)
	end)
	if not isOk then
		_ERROR_F("query fail:%s name:%s sql:%s", tostring(result), tostring(name), sql)
		DB_HLE = false
		return
	end
	return result
end

-- 存在则更新、不存在则插入：不再依赖先 modcreatenexist，避免 0 行更新静默丢数据
local function _UpsertSql(saveName, saveData)
	return sformat("insert into module(mod_name, data) values (%s, %s) on duplicate key update data = values(data);",
		mquote_sql_str(saveName), saveData)
end

-- accept
function ACCEPT.modcreatenexist(saveName)
	if not saveName then
		return
	end
	-- INSERT IGNORE : 在唯一索引或主键冲突时什么都不做
	local sql = sformat('insert ignore into module(mod_name, data) values (%s, %s);',
							mquote_sql_str(saveName), MODDATA_DEFAULT)
	local result = _Query(saveName, sql)
	if not result or result.badresult then
		_ERROR_F("saveName:%s result:%s", saveName, tool.dumptree(result))
		return
	end
	return true
end

function ACCEPT.modsave(saveName, saveData)
	if not saveName or not saveData then
		_ERROR_F("modsave saveName:%s saveData:%s fail", saveName, saveData)
		return
	end
	local result = _Query(saveName, _UpsertSql(saveName, saveData))
	if not result or result.badresult then
		_ERROR_F("saveName:%s result:%s", saveName, tool.dumptree(result))
	end
end


-- reponse
function RESPONSE.showtables()
	local result = _Query("showtables", "show tables;")
	if not result or result.badresult then
		_ERROR_F("show tables fail:%s", tool.dumptree(result))
		return
	end
	return result
end

function RESPONSE.modgetdata(saveName)
	if not saveName then
		return
	end
	local sql = sformat("select data from module where mod_name = %s;",
							mquote_sql_str(saveName))
	local result = _Query(saveName, sql)
	if not result or table.empty(result) or result.badresult then
		_ERROR_F("saveName:%s result:%s", saveName, tool.dumptree(result))
		return
	end
	return result[1].data
end

function RESPONSE.modsave(saveName, saveData)
	if not saveName or not saveData then
		_ERROR_F("modsave saveName:%s saveData:%s fail", saveName, saveData)
		return false
	end
	local result = _Query(saveName, _UpsertSql(saveName, saveData))
	if not result or result.badresult then
		_ERROR_F("saveName:%s result:%s", saveName, tool.dumptree(result))
		return false
	end
	return true
end

-- 批量保存：同批在单个事务内提交，供关服等需要一次性落库的场景使用
-- key 仅用于路由/队列名；saveList = { {saveName, salData}, ... }
function RESPONSE.modsave_multi(key, saveList)
	if type(saveList) ~= "table" or #saveList == 0 then
		_ERROR_F("modsave_multi invalid saveList")
		return false
	end

	-- 整个事务必须在同一个队列槽内完成，避免其他查询插入 BEGIN/COMMIT 之间
	local isOk, err = pcall(DB_CS, function ()
		local db = ConnDb()
		if not db then
			error("no db connection")
		end
		local function _RunQuery(sql)
			local result = db:query(sql)
			if not result or result.badresult then
				error(tool.dumptree(result))
			end
			return result
		end

		local isTranOk, tranErr = pcall(function ()
			_RunQuery("start transaction;")
			for _, item in ipairs(saveList) do
				_RunQuery(_UpsertSql(item[1], item[2]))
			end
			_RunQuery("commit;")
		end)
		if not isTranOk then
			pcall(function ()
				db:query("rollback;")
			end)
			error(tranErr)
		end
	end)
	if not isOk then
		DB_HLE = false	-- 事务失败按连接状态未知处理，下次查询重连
		_ERROR_F("modsave_multi fail:%s", tostring(err))
		return false
	end
	return true
end

function RESPONSE.modsave_replace(saveName, saveData)
	if not saveName or not saveData then
		_ERROR_F("modsave saveName:%s saveData:%s fail", saveName, saveData)
		return false
	end

	-- 谨慎使用！
	-- replace into语句会先删除违反唯一性约束的旧记录，然后插入新记录。这种方法适用于你想要替换旧记录的情况。
	local sql = sformat("replace into module(mod_name, data) values (%s, %s);",
							mquote_sql_str(saveName), saveData)
	local result = _Query(saveName, sql)
	if not result or result.badresult then
		_ERROR_F("saveName:%s result:%s", saveName, tool.dumptree(result))
		return false
	end
	return true
end
