--------------------
-- playdata 客户端（薄封装）
-- 一次操作只发一条 mem 消息，由 play 节点的 cell 完成缓存/回源/CAS/持久化
-- 返回结构：{ code = "ok"|"not_found"|"conflict"|"source_error"|"redis_error", ... }
--------------------

local skynet = require "skynet"
local PROXYSVR = Import("game/global/rpc/proxysvr.lua")

-- 复用 mem_common 的协议注册，并取得 mem 协议代理
Import("game/global/mem_common.lua")
local DBSERVER = assert(PROXYSVR.GetProxyByServiceName("dbserver", "mem"), "dbserver service invalid")

-- 统一调用：服务/命令异常转为结构化错误，避免把调用方协程打挂
local function _Call(cmd, ...)
	local isOk, res = TryCall(DBSERVER.call[cmd], ...)
	if not isOk or res == nil then
		return { code = "call_error", err = tostring(res) }
	end
	return res
end

-- 读：热层 → 回源 → 回填；default 不为 nil 时未命中会自动初始化
function Read(key, ttl, default)
	return _Call("mem_read", key, ttl, default)
end

-- CAS 更新：成功返回新版本；冲突返回 conflict
function Cas(key, version, data, ttl)
	return _Call("mem_cas", key, version, data, ttl)
end

function RankAdd(key, member, score)
	return _Call("mem_rank_add", key, member, score)
end

function RankTop(key, n)
	return _Call("mem_rank_top", key, n)
end

-- 复合业务：活动积分 + 玩家档案 + 排行榜，cell 内一次完成
function AddScore(uid, game, activityId, score)
	return _Call("mem_add_score", uid, game, activityId, score)
end

function QueueInfo()
	return _Call("mem_queue_info", "mem")
end

function QueueClear()
	return _Call("mem_queue_clear", "mem")
end
