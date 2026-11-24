--------------------
-- 持久化积压查询（客户端薄封装）
-- 任务投递已并入 cell 的 CAS 原子脚本，消费者也在 cell 内，这里只查询/清理
--------------------

local CLIENT = Import("game/global/playdata/client.lua")

-- 返回 { code="ok", queue, dead, oldest_age } / redis_error
function Call_PersistPending()
	return CLIENT.QueueInfo()
end

-- 清空主队列/死信/本 cell 处理中列表（仅调试用）
function Call_PersistClear()
	return CLIENT.QueueClear()
end
