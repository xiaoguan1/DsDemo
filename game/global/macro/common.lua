--------------------
-- 宏定义常量文件
-- 2025.1.30
--------------------

ONE_DAY_SEC = 86400	-- 一天秒数
ONE_HOUR_SEC = 3600	-- 一小时秒数
ONE_MIN_SEC = 60	-- 一分钟秒数

UPDATE_TYPE = {
	TOOL = 1,		-- tool拓展类型
	MACROS = 2,		-- macros类型 
	IMPORT = 3,		-- import类型 
}

UPDATE_DOFILE_FILE = {
	["service/agent/init/global.lua"] = SERVICE_NAME == "agent" and true or false,
    ["service/gameserver/init/global.lua"] = SERVICE_NAME == "gameserver" and true or false,
    ["service/activity/init/global.lua"] = string.find(SERVICE_NAME, "^actsvc/([%w_]+)") and true or false,
    ["service/cactivity/init/global.lua"] = string.find(SERVICE_NAME, "^crosssvc/([%w_]+)") and true or false,
}

-- 日志的写入方式
LOG_LEVEL = {
	WRITE_DELAY = 1,	-- 批量写入
	WRITE_NOW = 2,		-- 立即写入
}