--------------------
-- playdata 业务键（客户端使用）
-- 真正的编解码与键规范在 tool/service/basic/dbcell/playdata_codec.lua，cell 与客户端共用
--------------------

local CODEC = Import("tool/service/basic/dbcell/playdata_codec.lua")

-- 全服活动数据：play:activity:{<game>}:<activity_id>
function MemKeyAct(game, activityId)
	return CODEC.MemKeyAct(game, activityId)
end

-- 玩家玩法档案：play:profile:{<game>}:<activity_id>:<uid>
function MemKeyActProfile(game, activityId, uid)
	return CODEC.MemKeyActProfile(game, activityId, uid)
end

-- 排行榜：play:rank:{<game>}:<period>
function MemKeyRank(game, period)
	return CODEC.MemKeyRank(game, period)
end
