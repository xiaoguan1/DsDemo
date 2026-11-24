--------------------
-- 排行榜访问（客户端薄封装）
-- 实时排名在 cell 的 Redis ZSET 中；榜单可重建，发奖前必须校验 MySQL 权威成绩
--------------------

local CLIENT = Import("game/global/playdata/client.lua")
local MEM = Import("game/global/mem_common.lua")

function Call_RankAdd(game, period, member, score)
	local res = CLIENT.RankAdd(MEM.MemKeyRank(game, period), member, score)
	if res.code ~= "ok" then
		return nil, res.err or res.code
	end
	return res.score
end

function Call_RankTop(game, period, n)
	local res = CLIENT.RankTop(MEM.MemKeyRank(game, period), n)
	if res.code ~= "ok" then
		return nil, res.err or res.code
	end
	return res.list
end

function Call_RankScore(game, period, member)
	return MEM.Call_MemZScore(MEM.MemKeyRank(game, period), member)
end

function Call_RankRank(game, period, member)
	return MEM.Call_MemExec("zrevrank", MEM.MemKeyRank(game, period), member)
end

function Call_RankDel(game, period, member)
	return MEM.Call_MemZRem(MEM.MemKeyRank(game, period), member)
end

function Call_RankClear(game, period)
	return MEM.Call_MemDel(MEM.MemKeyRank(game, period))
end
