--------------------
-- 资产结算请求封装（第六章幂等结算 / 7.8 资产写链路 / 7.9 settlement.lua）
--
-- 纪律（重试幂等，设计 6.4）：
--   1. settle_id 在一次逻辑结算的重试过程中保持不变：RPC 超时 = 结果未知，
--      必须用同一 settle_id 重试/查询，禁止生成新编号
--   2. 数据库事务成功才算结算成功（幂等记录+余额+流水同一事务）
--   3. 玩法实例不得绕过 agent 资产入口直接修改玩家核心资产
--
-- 链路：play 实例 → 结算请求 → agent → MySQL 事务 → 提交成功 → 回包
-- 注意：agent 侧结算入口属第 3 阶段（设计方案十二章第 7 项），本模块只封装
--   请求构造与发送，agent 未实现时发送会失败，调用方按纪律用同 settle_id 重试
--------------------

local tostring = tostring

local PROXYSVR = Import("game/global/rpc/proxysvr.lua")

-- 生成结算 ID：requestId 由玩法保证一次逻辑结算内唯一（含时间戳+序号），重试复用
function GenSettleId(game, uid, requestId)
	assert(game and uid and requestId)
	return game .. "_" .. uid .. "_" .. requestId
end

-- 构造结算请求：
--   changes = { { type = "currency", id = 1, amount = 100, reason = "pve" }, ... }
--   extra 预留扩展（业务信息、补偿标识等）
function MakeSettle(game, uid, requestId, changes, extra)
	assert(type(changes) == "table" and #changes > 0)
	return {
		settle_id = GenSettleId(game, uid, requestId),
		uid = uid,
		game = game,
		changes = changes,
		extra = extra,
	}
end

-- 发送结算请求到玩家所在 agent（client 协议 "settle"，agent 第 3 阶段实现）
-- 成功返回 true；发送失败返回 nil, err（调用方用同一 settle 重试）
function Call_SettleRequest(agentName, agentCn, settle)
	assert(agentName and agentCn and settle and settle.settle_id)
	local isOk, err = TryCall(PROXYSVR.GetProxy(agentName, agentCn, "client").send.settle, settle)
	if not isOk then
		_WARN_F("settle send fail, settle_id:%s err:%s", tostring(settle.settle_id), tostring(err))
		return nil, err
	end
	return true
end
