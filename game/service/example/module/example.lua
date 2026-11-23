-- 玩法服务骨架模块（playdata 接入示例）
-- 无状态：函数只依赖入参、只读配置与外部存储（Redis/MySQL），不保留跨请求数据
--
-- playdata 使用方式（设计 7.8/7.9，模块经 Import 后以表调用）：
--   local CFG = Import("game/global/playdata/config.lua")
--   local ACT = Import("game/global/playdata/activity.lua")
--   local cfg, ver = CFG.Call_CfgGet(GAME)                       -- 本地只读配置
--   local data, ver = ACT.Call_ActGet(GAME, activityId)          -- 热层→回源→回填
--   local ok, newVer = ACT.Call_ActUpdate(GAME, activityId, ver, data) -- CAS+投递持久化
--
-- 本节点调试：skynet.call(".EXAMPLE", "lua", "demo", "uid1001", "act1")
-- 跨节点调用：rpc.mod_call.example[serverId].EXAMPLE.Ping("tag")

local skynet = require "skynet"
local sformat = string.format
local tonumber = tonumber

local CFG = Import("game/global/playdata/config.lua")
local ACT = Import("game/global/playdata/activity.lua")
local PROFILE = Import("game/global/playdata/profile.lua")
local RANK = Import("game/global/playdata/ranking.lua")
local PERSIST = Import("game/global/playdata/persistence.lua")
local BASE = Import("game/global/playdata/base.lua")
local MEM = Import("game/global/mem_common.lua")

local GAME = "example"
local CAS_RETRY = 3

-- 静态配置（第一类数据：版本管理，实例本地只读）
local DEFAULT_CONFIG = {
	stage = 1,
	score_per_task = 10,
	rank_size = 10,
}

local function _DefaultActivity()
	return {
		stage = DEFAULT_CONFIG.stage,
		total_score = 0,
		update_time = os.time(),
	}
end

local function _DefaultProfile(uid)
	return {
		uid = uid,
		score = 0,
		join_count = 0,
		update_time = os.time(),
	}
end

-- 返回本实例身份，用于验证"任意实例可处理同一请求"（无状态寻址）
function Ping(tag)
	return sformat("[EXAMPLE] recv:%s self=%s@%s cluster:%s",
		tostring(tag), HOST_ENV.nodename, skynet.getenv("server_id"), SELF_CLUSTERNAME)
end

---------------------- 静态配置 ----------------------

-- 装载配置（服务启动 / 配置更新后调用；版本回退会被拒绝，整体切换）
function InitConfig(version)
	return CFG.Call_CfgApply(GAME, version or 1, DEFAULT_CONFIG)
end

-- 返回 config, version
function GetConfig()
	return CFG.Call_CfgGet(GAME)
end

---------------------- 全服活动数据 ----------------------

-- 读活动；不存在则初始化。返回 data, version / nil, err
-- play 节点无 dbserver：回源不可用被访问层按"无记录"处理，首次访问即初始化
function EnsureActivity(activityId)
	for _ = 1, CAS_RETRY do
		local data, versionOrErr = ACT.Call_ActGet(GAME, activityId)
		if data then
			return data, versionOrErr
		end
		if versionOrErr ~= nil then
			return nil, versionOrErr	-- Redis 故障等真实错误（不存在时该值为 nil）
		end

		-- 不存在：以 version=0 初始化（CAS 允许"key 不存在 + expected=0"）
		local default = _DefaultActivity()
		local isOk, newVersionOrErr = ACT.Call_ActUpdate(GAME, activityId, 0, default)
		if isOk then
			return default, newVersionOrErr
		end
		if isOk == nil then
			return nil, newVersionOrErr
		end
		-- isOk == false：CAS 冲突（别的实例已初始化），重读
	end
	return nil, "activity init conflict"
end

function GetActivity(activityId)
	return ACT.Call_ActGet(GAME, activityId)
end

---------------------- 玩家玩法档案 ----------------------

-- 读档案；不存在则初始化
function EnsureProfile(uid, activityId)
	for _ = 1, CAS_RETRY do
		local data, versionOrErr = PROFILE.Call_ProfileGet(GAME, activityId, uid)
		if data then
			return data, versionOrErr
		end
		if versionOrErr ~= nil then
			return nil, versionOrErr
		end

		local default = _DefaultProfile(uid)
		local isOk, newVersionOrErr = PROFILE.Call_ProfileUpdate(GAME, activityId, uid, 0, default)
		if isOk then
			return default, newVersionOrErr
		end
		if isOk == nil then
			return nil, newVersionOrErr
		end
	end
	return nil, "profile init conflict"
end

function GetProfile(uid, activityId)
	return PROFILE.Call_ProfileGet(GAME, activityId, uid)
end

---------------------- 业务操作 ----------------------

-- 完成一次任务：全服活动积分 + 玩家档案 + 排行榜（普通数据，不含资产）
-- 成功返回结果表；失败返回 nil, err
function AddScore(uid, activityId, score)
	assert(uid and activityId)
	score = tonumber(score) or DEFAULT_CONFIG.score_per_task
	if score <= 0 then
		return nil, "invalid score"
	end

	-- 1. 全服活动数据：CAS 更新（冲突重读重试）
	local activity, activityVersion = EnsureActivity(activityId)
	if not activity then
		return nil, activityVersion
	end

	local newActivityVersion
	for _ = 1, CAS_RETRY do
		activity.total_score = (activity.total_score or 0) + score
		activity.update_time = os.time()
		local isOk, ret = ACT.Call_ActUpdate(GAME, activityId, activityVersion, activity)
		if isOk then
			newActivityVersion = ret
			break
		elseif isOk == nil then
			return nil, ret
		end
		activity, activityVersion = ACT.Call_ActGet(GAME, activityId)
		if not activity then
			return nil, activityVersion
		end
	end
	if not newActivityVersion then
		return nil, "activity cas retry exhausted"
	end

	-- 2. 玩家玩法档案：CAS 更新
	local profile, profileVersion = EnsureProfile(uid, activityId)
	if not profile then
		return nil, profileVersion
	end

	local newProfileVersion
	for _ = 1, CAS_RETRY do
		profile.score = (profile.score or 0) + score
		profile.join_count = (profile.join_count or 0) + 1
		profile.update_time = os.time()
		local isOk, ret = PROFILE.Call_ProfileUpdate(GAME, activityId, uid, profileVersion, profile)
		if isOk then
			newProfileVersion = ret
			break
		elseif isOk == nil then
			return nil, ret
		end
		profile, profileVersion = PROFILE.Call_ProfileGet(GAME, activityId, uid)
		if not profile then
			return nil, profileVersion
		end
	end
	if not newProfileVersion then
		return nil, "profile cas retry exhausted"
	end

	-- 3. 排行榜：ZSET 原子递增（可重建的展示投影，不是发奖权威）
	local rankScore, rankErr = RANK.Call_RankAdd(GAME, activityId, uid, score)
	if not rankScore then
		return nil, rankErr
	end

	return {
		activity = { total_score = activity.total_score, version = newActivityVersion },
		profile = { score = profile.score, join_count = profile.join_count, version = newProfileVersion },
		rank_score = tonumber(rankScore) or rankScore,
	}
end

-- 排行榜前 N：返回 { {member, score}, ... } / nil, err
function GetRankTop(activityId, n)
	return RANK.Call_RankTop(GAME, activityId, n or DEFAULT_CONFIG.rank_size)
end

-- 持久化积压：{ queue, dead, oldest_age } / nil, err
function GetPersistInfo()
	return PERSIST.Call_PersistPending(GAME)
end

-- 清空持久化队列（仅调试用；play 节点无消费服务时避免测试任务堆积）
function ClearPersist()
	return PERSIST.Call_PersistClear(GAME)
end

-- 资产结算示例（agent 结算入口属第 3 阶段，未实现前不要实际调用）：
--   local SETTLE = Import("game/global/playdata/settlement.lua")
--   local settle = SETTLE.MakeSettle(GAME, uid, requestId, {
--       { type = "currency", id = 1, amount = 100, reason = "pve" },
--   })
--   SETTLE.Call_SettleRequest(agentName, agentCn, settle)	-- 超时用同一 settle 重试

---------------------- 一键演示 ----------------------

-- 完整走一遍：配置 → 活动 → 加分（活动+档案）→ 排行榜 → 持久化积压
-- 调用：skynet.call(".EXAMPLE", "lua", "demo", "uid1001", "act1")
function Demo(uid, activityId)
	uid = uid or "demo_uid"
	activityId = activityId or "demo_act"

	local report = { game = GAME, uid = uid, activity_id = activityId }

	-- 本次演示涉及的 Redis 键（方便用 redis-cli 直接观察）
	report.keys = {
		activity = BASE.MemKeyAct(GAME, activityId),
		profile = BASE.MemKeyActProfile(GAME, activityId, uid),
		rank = MEM.MemKeyRank(GAME, activityId),
		persist_queue = PERSIST.MemKeyPersistQueue(GAME),
	}

	local cfg, cfgVersion = GetConfig()
	report.config = { version = cfgVersion, data = cfg }

	local activity, activityVersion = EnsureActivity(activityId)
	print("activity ", tool.dumptree(activity))
print("activityVersion ", activityVersion)
	if not activity then
		return nil, activityVersion
	end
	report.activity_before = { total_score = activity.total_score, version = activityVersion }

	local added, addErr = AddScore(uid, activityId, DEFAULT_CONFIG.score_per_task)
	if not added then
		return nil, addErr
	end
	report.add = added

	local top, topErr = GetRankTop(activityId, DEFAULT_CONFIG.rank_size)
	if not top then
		return nil, topErr
	end
	report.rank_top = top

	local pending, pendErr = GetPersistInfo()
	report.persist = pending or { err = pendErr }
	return report
end
