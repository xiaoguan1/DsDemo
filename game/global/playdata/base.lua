--------------------
-- playdata 公共层（设计 7.8/7.9 的统一数据访问层基础）
-- 职责：
--   1. 热层数据编解码：格式 "<version>|<tool.serialise(data)>"，version 做乐观锁
--   2. CAS 原子更新脚本（Lua 脚本比较版本，禁止普通 GET 后 SET）
--   3. 回源单飞锁（set NX EX，防止大量请求同时穿透）
--   4. MySQL 数据源 Load/Save（经 db_common 走 dbserver）
--   5. 业务键构造（统一前缀 + hash tag 兼容 Redis Cluster）
--
-- 回源说明（Cache-Aside）：
--   Load/Save 默认经 db_common 访问 dbserver；play 节点无 dbserver（设计 7.8 不直连 MySQL），
--   Load 调用失败返回 nil，访问层统一按"无记录"写空值缓存（源故障日志由 dbcell 侧输出），
--   跨节点回源随 user 节点持久化服务落地（设计方案十二章第 9 项）
--
-- 使用：local BASE = Import("game/global/playdata/base.lua") 后经 BASE.xxx 调用
--------------------

local tonumber = tonumber
local tostring = tostring
local type = type
local pcall = pcall
local sfind = string.find
local ssub = string.sub

local MEMCOMMON = Import("game/global/mem_common.lua")	-- Redis 调用封装（Call_Mem* 系列）
local DBCOMMON = Import("game/global/db_common.lua")	-- dbserver 调用封装（Call_Mod* 系列）

-- CAS 原子更新：版本一致才替换，并刷新 TTL
local CAS_SET_SCRIPT = [[
local cur = redis.call('GET', KEYS[1])
local expected = tonumber(ARGV[1])
if cur then
	local ver = tonumber(string.match(cur, '^(%d+)|'))
	if not ver or ver ~= expected then
		return 0
	end
elseif expected ~= 0 then
	return 0
end
redis.call('SET', KEYS[1], ARGV[2], 'EX', ARGV[3])
return 1
]]

---------------------- 编解码 ----------------------

-- 序列化任意 Lua 值为 Redis/MySQL 可存字符串
function PD_Pack(value)
	return tool.serialise(value)
end

-- 反序列化；失败返回 nil（注意：load 只编译不执行，必须再调用一次 chunk）
function PD_Unpack(payload)
	if type(payload) ~= "string" or payload == "" then
		return nil
	end
	local loadOk, chunk = pcall(load, "return " .. payload)
	if not loadOk or not chunk then
		return nil
	end
	local isOk, value = pcall(chunk)
	if not isOk then
		return nil
	end
	return value
end

-- 编码为热层值：<version>|<serialised(data)>
function PD_Encode(version, data)
	assert(type(version) == "number")
	return tostring(version) .. "|" .. tool.serialise(data)
end

-- 解码热层值：返回 version, data；脏数据返回 nil
function PD_Decode(payload)
	if type(payload) ~= "string" or payload == "" then
		return nil
	end
	local sep = sfind(payload, "|", 1, true)
	if not sep then
		return nil
	end
	local version = tonumber(ssub(payload, 1, sep - 1))
	local data = PD_Unpack(ssub(payload, sep + 1))
	if version == nil or data == nil then
		return nil
	end
	return version, data
end

-- CAS 更新热层：返回 true；版本冲突 false, "cas conflict"；Redis 故障 nil, err
function Call_PDCasSet(key, version, data, ttl)
	assert(key and type(version) == "number" and ttl and ttl > 0)
	local result, err = MEMCOMMON.Call_MemEval(CAS_SET_SCRIPT, 1, key, version, PD_Encode(version + 1, data), ttl)
	if result == nil then
		return nil, err
	end
	if result == 0 then
		return false, "cas conflict"
	end
	return true
end

-- 单飞锁（回源互斥，跨实例生效）：抢到返回 true，否则 false
function Call_PDAcquireLock(lockKey, ttl)
	local result = MEMCOMMON.Call_MemExec("set", lockKey, "1", "NX", "EX", ttl or 5)
	return result == "OK"
end

---------------------- MySQL 数据源 ----------------------

-- 读持久化快照：返回 payload 字符串（version|data）；无记录/不可用返回 nil
function Load(saveName)
	-- play 节点没有 dbserver，代理调用会直接报"not service by name"，这里统一降级为 nil
	local isOk, data = pcall(DBCOMMON.Call_ModGetData, saveName)
	if not isOk or not data then
		return nil
	end
	-- dbcell 的 module 表存的是 tool.serialise 代码串，先还原为 payload 字符串
	local payload = PD_Unpack(data)
	if type(payload) ~= "string" then
		return nil
	end
	return payload
end

-- 写持久化快照（upsert，同 key 末次写胜）：返回 true / nil, err
function Save(saveName, payload)
	local isOk, salData, err = pcall(DBCOMMON.ModDataSerialise, payload)
	if not isOk or not salData then
		return nil, err or "serialise fail"
	end
	local callOk, ret, callErr = pcall(DBCOMMON.Call_ModSave, saveName, salData)
	if not callOk then
		return nil, ret
	end
	return ret, callErr
end

---------------------- 业务键构造 ----------------------

-- 全服活动数据：play:activity:{<game>}:<activity_id>
function MemKeyAct(game, activityId)
	assert(game and activityId)
	return "play:activity:{" .. game .. "}:" .. activityId
end

-- 玩家玩法档案：play:profile:{<game>}:<activity_id>:<uid>
function MemKeyActProfile(game, activityId, uid)
	assert(game and activityId and uid)
	return "play:profile:{" .. game .. "}:" .. activityId .. ":" .. uid
end
