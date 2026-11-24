--------------------
-- 玩家玩法档案访问（客户端薄封装）
-- 与活动数据同机制，键为 uid + activityId；资产类字段仍必须走结算链路
-- 返回：{ code = "ok", data, version } / not_found / source_error / redis_error
--------------------

local CLIENT = Import("game/global/playdata/client.lua")
local BASE = Import("game/global/playdata/base.lua")

-- 读档案；default 不为 nil 时，源确认无记录会自动初始化
function Call_ProfileGet(game, activityId, uid, ttl, default)
	return CLIENT.Read(BASE.MemKeyActProfile(game, activityId, uid), ttl, default)
end

-- CAS 更新：成功返回 ok/newVersion；版本冲突返回 conflict
function Call_ProfileUpdate(game, activityId, uid, version, data, ttl)
	return CLIENT.Cas(BASE.MemKeyActProfile(game, activityId, uid), version, data, ttl)
end
