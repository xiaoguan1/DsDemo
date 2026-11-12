-- agent 管理者（实例1，命名 .AGENT）：自身不承载玩家，职责如下
-- 1. worker 生命周期管理：启动注册、动态空实例缩容回收（底座 worker 常驻）
-- 2. 负载汇总：worker 绑定/解绑时返回玩家数，管理者维护负载表
-- 3. 玩家分配：登录服务调用 alloc，挑选最空闲 worker（全满自动扩容新实例）
-- 4. 玩家落点表：uid -> worker 实例，顶号/解绑按落点转发

local skynet = require "skynet"

-- 缩容协程：60 秒为一个执行单位，扫描任务入队串行执行
local queue = require "skynet_queue"
CS = queue()

PROXYSVR = Import("game/global/rpc/proxysvr.lua")
assert(ACCEPT)
assert(RESPONSE)

local agent_default_num = tonumber(skynet.getenv("agent_default_num")) or 8
local agent_max_player = tonumber(skynet.getenv("agent_max_player")) or 50

-- worker 命名规则（与 startup/main.lua 保持一致：实例N -> .AGENTN）
local function WorkerName(i)
	return ".AGENT" .. i
end

-- worker 负载表：index -> 玩家数（worker 调用返回，实时同步）
Workers = {}
-- 玩家落点表：uid -> worker index（顶号/解绑按此转发）
PlayerAgent = {}
-- 扩容游标：首个动态实例编号 = 底座数量 + 1
NextWorkerIndex = agent_default_num + 1

-- 挑选最空闲的未满 worker（同负载取编号小者，底座优先）
local function PickWorker()
	local pick, pick_count
	for index, count in pairs(Workers) do
		if count < agent_max_player and (not pick_count or count < pick_count
			or (count == pick_count and index < pick)) then
			pick, pick_count = index, count
		end
	end
	return pick
end

-- 动态扩容：新建 worker 实例并命名（注册由 worker 启动后上报）
local function ExtendWorker()
	local index = NextWorkerIndex
	local id = skynet.newservice("agent", index)
	if not id then
		_ERROR_F("manager extend worker index:%s fail", index)
		return
	end
	skynet.name(WorkerName(index), id)
	Workers[index] = 0
	NextWorkerIndex = index + 1
	_INFO_F("manager extend worker:%s", WorkerName(index))
	return index
end

-- worker 启动注册（幂等：重复注册仅补登记）
function ACCEPT.worker_register(index)
	index = tonumber(index)
	if not index then
		return
	end
	Workers[index] = Workers[index] or 0
	_INFO_F("manager worker:%s register", WorkerName(index))
end

-- worker 主动退出（空实例缩容），从负载表剔除
function ACCEPT.worker_exit(index)
	index = tonumber(index)
	if not Workers[index] then
		return
	end
	Workers[index] = nil
	_INFO_F("manager worker:%s exit, remove", WorkerName(index))
end

-- 分配玩家到最空闲 worker：全满自动扩容；成功返回 worker 名，失败返回 nil
function RESPONSE.alloc(uid, gate_name, gate_cn)
	local old_index = PlayerAgent[uid]

	local index = PickWorker()
	if not index then
		index = ExtendWorker()
	end
	if not index then
		_ERROR_F("manager alloc fail uid:%s, no worker", uid)
		return
	end

	-- 绑定并同步负载；失败（worker 已死）则剔除换一个重试
	local isOk, count = TryCall(PROXYSVR.GetProxy(WorkerName(index), SELF_CLUSTERNAME, "lua").call, "bind", uid, gate_name, gate_cn)
	if not isOk then
		_WARN_F("manager worker:%s bind fail, remove", WorkerName(index))
		Workers[index] = nil
		index = PickWorker() or ExtendWorker()
		if not index then
			return
		end
		isOk, count = TryCall(PROXYSVR.GetProxy(WorkerName(index), SELF_CLUSTERNAME, "lua").call, "bind", uid, gate_name, gate_cn)
		if not isOk then
			return
		end
	end
	Workers[index] = count

	PlayerAgent[uid] = index
	if old_index and old_index ~= index then
		-- 顶号：解绑旧 worker 上的归属
		local isOk2, old_count = TryCall(PROXYSVR.GetProxy(WorkerName(old_index), SELF_CLUSTERNAME, "lua").call, "unbind", uid)
		if isOk2 and Workers[old_index] then
			Workers[old_index] = old_count
		end
	end
	return WorkerName(index)
end

-- 解绑玩家：按落点表转发到对应 worker（玩家下线/被顶号调用）
function ACCEPT.unbind(uid)
	local index = PlayerAgent[uid]
	if not index then
		return
	end
	PlayerAgent[uid] = nil
	local isOk, count = TryCall(PROXYSVR.GetProxy(WorkerName(index), SELF_CLUSTERNAME, "lua").call, "unbind", uid)
	if isOk and Workers[index] then
		Workers[index] = count
	end
end

-- 总在线玩家数（监控/仲裁查询用）
function RESPONSE.player_count()
	local cnt = 0
	for _, count in pairs(Workers) do
		cnt = cnt + count
	end
	return cnt
end

-- 缩容扫描：逐个检测 worker 在线人数；仅回收编号 > 底座的空实例，底座 worker（2~N）常驻
local function SweepWorkers()
	for index in pairs(Workers) do
		local agentName = WorkerName(index)
		local isOk, count = TryCall(PROXYSVR.GetProxy(agentName, SELF_CLUSTERNAME, "lua").call, "player_count")
		if not isOk then
			-- worker 已死：剔除登记
			Workers[index] = nil
			_WARN_F("manager worker:%s dead, remove", agentName)
		elseif count == 0 then
			if index <= agent_default_num then
				-- 底座 worker 常驻，不回收
				Workers[index] = 0
			else
				-- 空动态实例：直接关闭（worker 侧校验当前确实无玩家才退出，防止与绑定并发冲突）
				TryCall(PROXYSVR.GetProxy(agentName, SELF_CLUSTERNAME, "lua").send, "shutdown")
				_INFO_F("manager sweep close empty worker:%s", agentName)
			end
		else
			Workers[index] = count
		end
	end
end

function __init__()
	skynet.fork(function ()
		while true do
			skynet.sleep(60 * 100)
			CS(SweepWorkers)
		end
	end)
end
