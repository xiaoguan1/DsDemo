--------------------
-- 静态配置访问层（设计 1.6 第一类 / 7.9 config.lua）
-- 权威源：配置系统/配置版本管理；本模块只维护实例本地只读缓存
-- 原子切换：Apply 校验版本后整体替换缓存内容（纯内存操作无 yield，天然原子）
-- 热更注意：模块热更时 CONFIG_CACHE 保留旧值（普通 table 不注入），
--   __update__ 里重新 Call_CfgApply 装载新配置即可
--
-- 使用：local CFG = Import("game/global/playdata/config.lua") 后经 CFG.Call_CfgApply 调用
--------------------

local type = type

-- 本地配置缓存：{ [game] = { version = <number>, config = <table> } }
CONFIG_CACHE = {}

-- 校验并整体切换配置；版本回退/非法配置拒绝。返回 true / nil, err
function Call_CfgApply(game, version, config)
	assert(game)
	if type(version) ~= "number" then
		return nil, "invalid version"
	end
	if type(config) ~= "table" then
		return nil, "invalid config"
	end

	local cache = CONFIG_CACHE[game]
	if cache and version < cache.version then
		return nil, "config version rollback"
	end
	if not cache then
		cache = {
			version = 0,
			config = {},
		}
		CONFIG_CACHE[game] = cache
	end

	cache.version = version
	-- 清空后填充，保持 cache.config 引用不变（外部持有者始终看到同一 table）
	for k in pairs(cache.config) do
		cache.config[k] = nil
	end
	for k, v in pairs(config) do
		cache.config[k] = v
	end
	_INFO_F("cfg apply game:%s version:%s", tostring(game), tostring(version))
	return true
end

-- 读取当前配置：返回 config, version；未加载返回 nil, err
function Call_CfgGet(game)
	local cache = CONFIG_CACHE[game]
	if not cache then
		return nil, "config not loaded"
	end
	return cache.config, cache.version
end

-- 当前配置版本；未加载为 0
function Call_CfgVersion(game)
	local cache = CONFIG_CACHE[game]
	return cache and cache.version or 0
end
