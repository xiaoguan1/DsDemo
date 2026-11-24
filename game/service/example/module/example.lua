-- 玩法服务骨架模块（playdata 方案 B 接入示例）
-- 无状态：函数只依赖入参、只读配置与 cell 内的 Redis/MySQL
--
-- 调用链（每次操作只挂起一次，回源/锁/CAS/持久化都在 cell 内）：
--   example → .DBSERVER("mem") → 按 key 路由到 dbcell → Redis / MySQL / 持久化队列
--
-- 客户端 API（game/global/playdata/client.lua）：
--   CLIENT.Read(key, ttl, default)            -- 热层→回源→回填，default 可自动初始化
--   CLIENT.Cas(key, version, data, ttl)       -- 版本 CAS + 原子投递持久化任务
--   CLIENT.AddScore(uid, game, actId, score)  -- 活动+档案+排行榜一次完成
--   CLIENT.RankAdd/RankTop/QueueInfo/QueueClear
--
-- 本节点调试：skynet.call(".EXAMPLE", "lua", "demo", "uid1001", "act1")

local skynet = require "skynet"
local sformat = string.format
local tonumber = tonumber

local CLIENT = Import("game/global/playdata/client.lua")
local BASE = Import("game/global/playdata/base.lua")
local MEM = Import("game/global/mem_common.lua")
local CFG = Import("game/global/playdata/config.lua")

local GAME = "example"

-- 静态配置（第一类数据：版本管理，实例本地只读）
local DEFAULT_CONFIG = {
	stage = 1,
	score_per_task = 10,
	rank_size = 10,
}

-- 返回本实例身份，用于验证"任意实例可处理同一请求"
function Ping(tag)
	return sformat("[EXAMPLE] recv:%s self=%s@%s cluster:%s",
		tostring(tag), HOST_ENV.nodename, skynet.getenv("server_id"), SELF_CLUSTERNAME)
end

---------------------- 静态配置 ----------------------

function InitConfig(version)
	return CFG.Call_CfgApply(GAME, version or 1, DEFAULT_CONFIG)
end

function GetConfig()
	return CFG.Call_CfgGet(GAME)
end

---------------------- 查询（单次 mem 调用） ----------------------

function GetActivity(activityId)
	local res = CLIENT.Read(BASE.MemKeyAct(GAME, activityId))
	if res.code == "ok" then
		return res.data, res.version
	end
	if res.code == "not_found" then
		return nil
	end
	return nil, res.err or res.code
end

function GetProfile(uid, activityId)
	local res = CLIENT.Read(BASE.MemKeyActProfile(GAME, activityId, uid))
	if res.code == "ok" then
		return res.data, res.version
	end
	if res.code == "not_found" then
		return nil
	end
	return nil, res.err or res.code
end

function GetRankTop(activityId, n)
	local res = CLIENT.RankTop(MEM.MemKeyRank(GAME, activityId), n or DEFAULT_CONFIG.rank_size)
	if res.code ~= "ok" then
		return nil, res.err or res.code
	end
	return res.list
end

function GetPersistInfo()
	return CLIENT.QueueInfo()
end

function ClearPersist()
	return CLIENT.QueueClear()
end

---------------------- 业务操作（复合，一次调用） ----------------------

-- 完成任务：全服积分 + 玩家档案 + 排行榜
-- 成功返回 { activity = {...}, profile = {...}, rank_score = n }
function AddScore(uid, activityId, score)
	local res = CLIENT.AddScore(uid, GAME, activityId, score or DEFAULT_CONFIG.score_per_task)
	if res.code ~= "ok" then
		return nil, res.err or res.code
	end
	return {
		activity = res.activity,
		profile = res.profile,
		rank_score = res.rank_score,
	}
end

---------------------- 一键演示 ----------------------

-- 配置 → 活动（读）→ 加分（活动+档案+榜单一次完成）→ 排行榜 → 持久化积压
function Demo(uid, activityId)
	uid = uid or "demo_uid"
	activityId = activityId or "demo_act"

	local report = {
		game = GAME,
		uid = uid,
		activity_id = activityId,
		keys = {
			activity = BASE.MemKeyAct(GAME, activityId),
			profile = BASE.MemKeyActProfile(GAME, activityId, uid),
			rank = MEM.MemKeyRank(GAME, activityId),
			persist_queue = "play:persist:queue",
		},
	}

	local cfg, cfgVersion = GetConfig()
	report.config = { version = cfgVersion, data = cfg }

	local activity, activityVersionOrErr = GetActivity(activityId)
	if activity then
		report.activity_before = { total_score = activity.total_score, version = activityVersionOrErr }
	else
		report.activity_before = { not_exists = true, err = activityVersionOrErr }
	end

	local added, addErr = AddScore(uid, activityId, DEFAULT_CONFIG.score_per_task)
	if not added then
		return nil, addErr
	end
	report.add = added

	local top, topErr = GetRankTop(activityId, DEFAULT_CONFIG.rank_size)
	if top then
		report.rank_top = top
	else
		report.rank_top = { err = topErr }
	end

	local pending, pendErr = GetPersistInfo()
	report.persist = (pending and pending.code == "ok") and pending or { err = pendErr or (pending and pending.code) }

	return report
end
