--------------------
-- 全服活动数据访问层（设计 7.8 读/写链路 / 7.9 activity.lua）
-- 读（Cache-Aside）：热层命中直接返回；未命中单飞回源 MySQL 并回填；空值缓存防穿透
-- 写：CAS 原子更新热层（version 乐观锁），成功后投递可恢复持久化队列
-- 键：play:activity:{<game>}:<activity_id>
--
-- 纪律：
--   1. 本模块只承载普通动态玩法数据（允许丢失最近几秒）；含资产字段必须走结算链路（第六章）
--   2. 所有键带 TTL（DEFAULT_TTL/EMPTY_TTL），防僵尸数据
--   3. Redis 故障（err 非 nil）按设计 8.2 由调用方降级，本模块不吞错误
--
-- 使用：local ACT = Import("game/global/playdata/activity.lua") 后经 ACT.Call_ActGet 调用
--------------------

local skynet = require "skynet"

local tostring = tostring

local BASE = Import("game/global/playdata/base.lua")
local PERSIST = Import("game/global/playdata/persistence.lua")
local MEMCOMMON = Import("game/global/mem_common.lua")

local DEFAULT_TTL = 300		-- 热层默认 5 分钟
local EMPTY_TTL = 30		-- 空值缓存短 TTL（防穿透）
local LOCK_TTL = 10			-- 回源单飞锁 TTL
local LOCK_RETRY = 3		-- 抢锁失败重读次数
local LOCK_RETRY_TICK = 20	-- 重读间隔（skynet.sleep 单位 1/100 秒）

local function _Decode(payload, key)
	local version, data = BASE.PD_Decode(payload)
	if data == nil then
		_WARN_F("act cache decode fail key:%s", tostring(key))
		return nil
	end
	if data == false then
		return nil	-- 空值缓存：确定不存在
	end
	return version, data
end

-- 回源 MySQL：返回 data, version；源无记录/不可用返回 nil
-- 骨架期说明：BASE.Load 不区分"确定无记录"与"源故障"（play 节点无 dbserver 同样返回 nil），
--   统一按不存在写空值缓存；源故障日志由 dbcell 侧输出
local function _LoadSource(key)
	local payload = BASE.Load(key)
	if not payload then
		return nil
	end
	local version, data = BASE.PD_Decode(payload)
	if data == nil then
		_WARN_F("act source decode fail key:%s", tostring(key))
		return nil
	end
	return data, version
end

-- 读活动数据：返回 data, version；不存在返回 nil；故障返回 nil, err
function Call_ActGet(game, activityId, ttl)
	local key = BASE.MemKeyAct(game, activityId)

	local payload, err = MEMCOMMON.Call_MemGet(key)
	if err then
		return nil, err	-- Redis 故障
	end
	if payload then
		-- 热层有值：命中数据 / 空值缓存 / 脏数据（已告警），均直接结束
		return _Decode(payload, key)
	end

	-- 未命中：单飞回源，防大量请求同时穿透
	local lockKey = key .. ":lock"
	if not BASE.Call_PDAcquireLock(lockKey, LOCK_TTL) then
		-- 他人回源中：短等待后重读
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
	-- 抢到锁：回源 + 回填
	local data, version = _LoadSource(key)
	MEMCOMMON.Call_MemDel(lockKey)	-- 无论成败都释放单飞锁
	if data == nil then
		-- 源无记录/不可用：写空值缓存防穿透
		MEMCOMMON.Call_MemSet(key, BASE.PD_Encode(0, false), EMPTY_TTL)
		return nil
	end
	MEMCOMMON.Call_MemSet(key, BASE.PD_Encode(version or 0, data), ttl or DEFAULT_TTL)
	return data, version or 0
end

-- 更新活动数据（全量 + version 乐观锁）：
-- 成功返回 true, newVersion；版本冲突 false, "cas conflict"；Redis 故障 nil, err
function Call_ActUpdate(game, activityId, version, data, ttl)
	assert(type(data) == "table" and type(version) == "number")
	local key = BASE.MemKeyAct(game, activityId)

	local isOk, ret = BASE.Call_PDCasSet(key, version, data, ttl or DEFAULT_TTL)
	if isOk == nil then
		return nil, ret
	end
	if isOk == false then
		return false, ret
	end

	-- 热层更新成功：变更投递可恢复持久化队列（不留在实例内存）
	local newVersion = version + 1
	local isPushOk, pushErr = PERSIST.Send_PersistPush(game, key, newVersion, data)
	if not isPushOk then
		_WARN_F("persist push fail key:%s err:%s", tostring(key), tostring(pushErr))
	end
	return true, newVersion
end
