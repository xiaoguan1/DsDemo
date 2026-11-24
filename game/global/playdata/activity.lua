--------------------
-- 全服活动数据访问（客户端薄封装）
-- 编码/回源/CAS/单飞都在 play 节点的 cell 内完成，这里只发一条 mem 消息
-- 返回：{ code = "ok", data, version } / not_found / source_error / redis_error
--------------------

local CLIENT = Import("game/global/playdata/client.lua")
local BASE = Import("game/global/playdata/base.lua")

-- 读活动；default 不为 nil 时，源确认无记录会自动初始化
function Call_ActGet(game, activityId, ttl, default)
	return CLIENT.Read(BASE.MemKeyAct(game, activityId), ttl, default)
end

-- CAS 更新：成功返回 ok/newVersion；版本冲突返回 conflict
function Call_ActUpdate(game, activityId, version, data, ttl)
	return CLIENT.Cas(BASE.MemKeyAct(game, activityId), version, data, ttl)
end
