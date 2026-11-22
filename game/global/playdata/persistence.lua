--------------------
-- 普通玩法数据异步持久化（设计 7.8 写链路 / 7.9 persistence.lua）
--
-- 队列用 Redis List：rpush 入队 / lpop 出队（FIFO），Redis 为队列载体，
-- 实例崩溃不丢任务（禁止只放实例内存队列——设计 7.8 机制 1）
-- 消费方：user 节点持久化消费服务（设计方案十二章第 9 项），复用 dbserver 落库；
-- 本文件提供投递（play 节点用）与消费循环（user 节点持久化服务启动），
-- 双方按同一任务格式：{ key = ..., version = ..., data = ..., ts = ..., retry = ... }
--
-- 可重放/重试：消费失败 retry+1 回投队尾，超限进死信队列；落库用 dbserver upsert
--   （modsave），同 key 最后一次写胜。TODO(持久化服务)：落库前比较 DB version，
--   拒绝旧版本覆盖（"按版本顺序持久化"的完整实现随十二章第 9 项落地）
--
-- 使用：local PERSIST = Import("game/global/playdata/persistence.lua") 后经 PERSIST.xxx 调用
--------------------

local skynet = require "skynet"

local tostring = tostring
local type = type

local BASE = Import("game/global/playdata/base.lua")
local MEMCOMMON = Import("game/global/mem_common.lua")

local MAX_RETRY = 3			-- 超过则进死信队列
local DEFAULT_TICK = 10		-- 消费轮询间隔（skynet.sleep 单位 1/100 秒，即 100ms）

function MemKeyPersistQueue(game)
	return "play:persist:{" .. game .. "}:queue"
end

function MemKeyPersistDead(game)
	return "play:persist:{" .. game .. "}:dead"
end

-- 投递持久化任务（play 节点热层更新成功后调用；返回 true / nil, err）
function Send_PersistPush(game, key, version, data)
	local task = {
		key = key,
		version = version,
		data = data,
		ts = os.time(),
		retry = 0,
	}
	return MEMCOMMON.Call_MemExec("rpush", MemKeyPersistQueue(game), BASE.PD_Pack(task))
end

-- 非阻塞取一个任务：无任务返回 nil；Redis 故障返回 nil, err
function Call_PersistPop(game)
	return MEMCOMMON.Call_MemExec("lpop", MemKeyPersistQueue(game))
end

-- 清空主队列（仅调试/测试用；生产环境应等消费完成自然清空）
function Call_PersistClear(game)
	return MEMCOMMON.Call_MemDel(MemKeyPersistQueue(game))
end

-- 积压监控（RPO 必须用任务数量/最老任务年龄验证，而不是只配定时器——设计 7.8）
-- 返回 { queue = 主队列长度, dead = 死信长度, oldest_age = 最老任务年龄(秒) }
function Call_PersistPending(game)
	local queueLen, err1 = MEMCOMMON.Call_MemExec("llen", MemKeyPersistQueue(game))
	if not queueLen then
		return nil, err1
	end
	local deadLen, err2 = MEMCOMMON.Call_MemExec("llen", MemKeyPersistDead(game))
	if not deadLen then
		return nil, err2
	end

	local oldestAge
	local oldest = MEMCOMMON.Call_MemExec("lindex", MemKeyPersistQueue(game), 0)	-- 队头即最老
	if oldest then
		local task = BASE.PD_Unpack(oldest)
		if task and task.ts then
			oldestAge = os.time() - task.ts
		end
	end
	return { queue = queueLen, dead = deadLen, oldest_age = oldestAge }
end

-- 处理单个任务：落库成功返回 "done"；失败按次数回投或进死信
local function _Process(game, payload)
	local task = BASE.PD_Unpack(payload)
	if type(task) ~= "table" or type(task.key) ~= "string" or task.data == nil then
		_WARN_F("persist drop invalid task:%s", tostring(payload))
		return "drop"
	end

	local isOk, err = BASE.Save(task.key, BASE.PD_Encode(task.version or 0, task.data))
	if isOk then
		return "done"
	end
	_WARN_F("persist save fail key:%s err:%s", tostring(task.key), tostring(err))

	task.retry = (task.retry or 0) + 1
	if task.retry > MAX_RETRY then
		MEMCOMMON.Call_MemExec("rpush", MemKeyPersistDead(game), BASE.PD_Pack(task))
		return "dead"
	end
	MEMCOMMON.Call_MemExec("rpush", MemKeyPersistQueue(game), BASE.PD_Pack(task))
	return "retry"
end

-- 消费循环：应由 user 节点持久化消费服务启动（play 节点无 dbserver，直接拒绝）
-- 循环内部全容错：单任务异常不中断消费；Redis 暂不可用时按间隔休眠继续
function PersistStartLoop(game, tick)
	if not IsUser() then
		_WARN_F("persist loop only start on user node")
		return false
	end

	skynet.fork(function ()
		while true do
			local isOk, payload, err = pcall(Call_PersistPop, game)
			if not isOk then
				_WARN_F("persist pop fail:%s", tostring(payload))
			elseif err then
				_WARN_F("persist queue unavailable:%s", tostring(err))
			elseif payload then
				local isProcOk, procErr = pcall(_Process, game, payload)
				if not isProcOk then
					_ERROR_F("persist process fail:%s", tostring(procErr))
				end
			end
			skynet.sleep(tick or DEFAULT_TICK)
		end
	end)
	_INFO_F("persist loop start, game:%s", tostring(game))
	return true
end
