--------------------
-- 排行榜访问层（设计 8.1 / 7.9 ranking.lua）
-- 实时排名用 Redis ZSET（MEMCOMMON.MemKeyRank 构造键，hash tag 兼容 Cluster）
-- 键：play:rank:{<game>}:<period>
--
-- 纪律：
--   1. 榜单是可重建的展示投影，不是发奖权威：涉及发奖时必须重新校验
--      MySQL 权威成绩/结算记录（文档第十章/14 章故障测试）
--   2. 榜期结束的旧榜必须清理（del/归档），防僵尸数据
--
-- 使用：local RANK = Import("game/global/playdata/ranking.lua") 后经 RANK.xxx 调用
--------------------

local type = type
local tonumber = tonumber

local MEMCOMMON = Import("game/global/mem_common.lua")

-- 增加积分（原子递增）：返回新积分；Redis 故障返回 nil, err
function Call_RankAdd(game, period, member, score)
	return MEMCOMMON.Call_MemZIncrBy(MEMCOMMON.MemKeyRank(game, period), score, member)
end

-- 查积分；无记录返回 nil
function Call_RankScore(game, period, member)
	return MEMCOMMON.Call_MemZScore(MEMCOMMON.MemKeyRank(game, period), member)
end

-- 查名次（0 起，从高到低）；无记录返回 nil
function Call_RankRank(game, period, member)
	return MEMCOMMON.Call_MemExec("zrevrank", MEMCOMMON.MemKeyRank(game, period), member)
end

-- 前 N 名（从高到低）：返回 { {member, score}, ... }；Redis 故障返回 nil, err
function Call_RankTop(game, period, n)
	assert(type(n) == "number" and n > 0)
	local list, err = MEMCOMMON.Call_MemZRevRange(MEMCOMMON.MemKeyRank(game, period), 0, n - 1, true)
	if not list then
		return nil, err
	end
	local top = {}
	for i = 1, #list, 2 do
		top[#top + 1] = { member = list[i], score = tonumber(list[i + 1]) }
	end
	return top
end

-- 移除成员（玩家退出活动/违规清除等）
function Call_RankDel(game, period, member)
	return MEMCOMMON.Call_MemZRem(MEMCOMMON.MemKeyRank(game, period), member)
end

-- 清理整榜（榜期切换；调用方须保证该榜不再被读写）
function Call_RankClear(game, period)
	return MEMCOMMON.Call_MemDel(MEMCOMMON.MemKeyRank(game, period))
end
