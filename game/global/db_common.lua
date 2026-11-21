local skynet = require "skynet"
local PROXYSVR = Import("game/global/rpc/proxysvr.lua")
local DBSERVER = PROXYSVR.GetProxyByServiceName("dbserver", "db")
local mysql = require "skynet.db.mysql"

skynet.register_protocol({
	name = "db",
	id = skynet.PTYPE_DB,
	pack = skynet.pack,
	unpack = skynet.unpack,
})

-- 对module的data数据进行序列化
function ModDataSerialise(saveData)
	local salData = mysql.quote_sql_str(tool.serialise(saveData))
	return salData, #salData
end

function Send_ModCreateNexist(saveName)
	DBSERVER.send.modcreatenexist(saveName)
end

function Call_ModGetData(saveName)
	return DBSERVER.call.modgetdata(saveName)
end

function Send_ModSave(saveName, salData)
	assert(saveName and salData)
	DBSERVER.send.modsave(saveName, salData)
end

function Call_ModSave(saveName, salData)
	assert(saveName and salData)
	return DBSERVER.call.modsave(saveName, salData)
end

function Call_ModSaveReplace(saveName, salData)
	assert(saveName and salData)
	return DBSERVER.call.modsave_replace(saveName, salData)
end

-- 批量保存（单事务）：saveList = { {saveName, salData}, ... }
-- key 仅用于路由哈希，保证同批落到同一个 dbcell
function Call_ModSaveMulti(saveList)
	assert(type(saveList) == "table" and #saveList > 0)
	return DBSERVER.call.modsave_multi("module_batch", saveList)
end

