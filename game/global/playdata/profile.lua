--------------------
-- 玩家玩法档案访问层（设计 7.1 玩家玩法档案 / 7.9 profile.lua）
-- 与 activity.lua 同机制：Cache-Aside 读 + 单飞回源 + CAS 原子更新 + 异步持久化
-- 键：play:profile:{<game>}:<activity_id>:<uid>
--
-- 纪律：
--   1. 档案与玩家核心数据分离（核心数据归 agent）；档案中代表货币/付费道具的字段
--      必须拆到资产结算链路，禁止当普通数据走本模块（文档 1.6 纪律 2）
--   2. 多实例并发写同一玩家档案：CAS version 防止整对象覆盖
--
-- 使用：local PROFILE = Import("game/global/playdata/profile.lua") 后经 PROFILE.xxx 调用
--------------------

local skynet = require "skynet"

local tostring = tostring

local BASE = Import("game/global/playdata/base.lua")
local PERSIST = Import("game/global/playdata/persistence.lua")
local MEMCOMMON = Import("game/global/mem_common.lua")

local DEFAULT_TTL = 600		-- 档案热层默认 10 分钟
local EMPTY_TTL = 30		-- 空值缓存短 TTL
local LOCK_TTL = 5			-- 回源单飞锁 TTL
local LOCK_RETRY = 3		-- 抢锁失败重读次数
local LOCK_RETRY_TICK = 20	-- 重读间隔（1/100 秒）

local function _Decode(payload, key)
	local version, data = BASE.PD_Decode(payload)
	if data == nil then
		_WARN_F("profile cache decode fail key:%s", tostring(key))
		return nil
	end
	if data == false then
		return nil	-- 空值缓存：确定不存在
	end
	return version, data
end

-- 回源 MySQL：返回 data, version；源无记录/不可用返回 nil（说明同 activity.lua）
local function _LoadSource(key)
	local payload = BASE.Load(key)
	if not payload then
		return nil
	end
	local version, data = BASE.PD_Decode(payload)
	if data == nil then
		_WARN_F("profile source decode fail key:%s", tostring(key))
		return nil
	end
	return data, version
end

-- 读玩家玩法档案：返回 data, version；不存在返回 nil；故障返回 nil, err
function Call_ProfileGet(game, activityId, uid, ttl)
	local key = BASE.MemKeyActProfile(game, activityId, uid)

	local payload, err = MEMCOMMON.Call_MemGet(key)
	if err then
		return nil, err
	end
	if payload then
		return _Decode(payload, key)
	end

	local lockKey = key .. ":lock"
	if not BASE.Call_PDAcquireLock(lockKey, LOCK_TTL) then
		for _ = 1, LOCK_RETRY do
			skynet.sleep(LOCK_RETRY_TICK)
			payload, err = MEMCOMMON.Call_MemGet(key)
			if err then
				return nil, err
			end
			if payload then
				return _Decode(payload, key)
			end
		end
		return nil, "source loading"
	end

	local data, version = _LoadSource(key)
	MEMCOMMON.Call_MemDel(lockKey)
	if data == nil then
		MEMCOMMON.Call_MemSet(key, BASE.PD_Encode(0, false), EMPTY_TTL)
		return nil
	end
	MEMCOMMON.Call_MemSet(key, BASE.PD_Encode(version or 0, data), ttl or DEFAULT_TTL)
	return data, version or 0
end

-- 更新玩家玩法档案（全量 + version 乐观锁）：
-- 成功返回 true, newVersion；版本冲突 false, "cas conflict"；Redis 故障 nil, err
function Call_ProfileUpdate(game, activityId, uid, version, data, ttl)
	assert(type(data) == "table" and type(version) == "number")
	local key = BASE.MemKeyActProfile(game, activityId, uid)

	local isOk, ret = BASE.Call_PDCasSet(key, version, data, ttl or DEFAULT_TTL)
	if isOk == nil then
		return nil, ret
	end
	if isOk == false then
		return false, ret
	end

	local newVersion = version + 1
	local isPushOk, pushErr = PERSIST.Send_PersistPush(game, key, newVersion, data)
	if not isPushOk then
		_WARN_F("persist push fail key:%s err:%s", tostring(key), tostring(pushErr))
	end
	return true, newVersion
end
