-- 单 Cell 世界模块：实体权威数据 + 移动裁决 + AOI 增量广播
-- 世界状态仅由 cell 服务（单协程串行）读写，天然免锁
local skynet = require "skynet"
local PROTO = require "proto"
local AOI = Import("game/service/cell/module/aoi.lua")

local pack = string.pack
local rnd = math.random
local floor = math.floor

local WORLD_WIDTH = 10000	-- 世界宽
local WORLD_HEIGHT = 10000	-- 世界高
local PERF_UID_BASE = 0x80000000	-- 压测实体 uid 起始（避开玩家 uid 段）

Entities = {}	-- [uid] = {uid, x, y, vx, vy, t, bind_id, is_perf}
NextUid = 1		-- 玩家发号器（uint32）
Broadcast = function () end	-- 下行广播回调：function(uid, proto_id, payload)，由 cell.lua 注入（默认空操作防竞态）

PerfActive = false	-- 压测进行中标记

-- 下行实体数据包
local function _PackEntityEnter(e)
	return pack(">I4ff", e.uid, e.x, e.y)
end
local function _PackEntityMove(e)
	return pack(">I4ffffI4", e.uid, e.x, e.y, e.vx, e.vy, e.t)
end
local function _PackEntityLeave(uid)
	return pack(">I4", uid)
end

-- 向指定接收者广播
local function _Broadcast(uid, proto_id, payload)
	Broadcast(uid, proto_id, payload)
end

-- 出生坐标（M1：世界内随机撒点）
local function _RandPos()
	return rnd(WORLD_WIDTH), rnd(WORLD_HEIGHT)
end

-- 实体进入世界（uid 为空则分配；同 uid 重进视为顶号重绑，旧实体先离场）
function Enter(uid, bind_id)
	if uid then
		uid = tonumber(uid)
	end
	if not uid then
		uid = NextUid
		NextUid = NextUid + 1
	end

	local old = Entities[uid]
	if old then
		Leave(uid, old.bind_id)
	end

	local x, y = _RandPos()
	local e = {
		uid = uid,
		x = x,
		y = y,
		vx = 0,
		vy = 0,
		t = 0,
		bind_id = bind_id,
	}
	Entities[uid] = e

	-- 入 AOI，收集视野内实体
	local watchers = AOI.Add(e)
	local snapshot = {}
	for _, w in ipairs(watchers) do
		local we = Entities[w]
		if we then
			snapshot[#snapshot + 1] = {uid = we.uid, x = we.x, y = we.y}
		end
	end

	-- 通知视野内实体：新实体进入
	for _, w in ipairs(watchers) do
		_Broadcast(w, PROTO.S2C_ENTITY_ENTER, _PackEntityEnter(e))
	end

	return {uid = uid, x = x, y = y, snapshot = snapshot}
end

-- 实体离开世界（bind_id 校验：旧连接下线不误删被顶号重绑的新实体）
function Leave(uid, bind_id)
	local e = Entities[uid]
	if not e then
		return
	end
	if bind_id and e.bind_id ~= bind_id then
		return
	end

	Entities[uid] = nil
	local watchers = AOI.Remove(e)
	local payload = _PackEntityLeave(uid)
	for _, w in ipairs(watchers) do
		_Broadcast(w, PROTO.S2C_ENTITY_LEAVE, payload)
	end
end

-- 移动后的 AOI 扩散处理：enters/leaves 互发 enter/leave，其余观众发 move
local function _AfterMove(e, oldx, oldy)
	local enters, leaves = AOI.OnMove(e, oldx, oldy)

	if #enters > 0 then
		local enterSet = {}
		local selfEnter = _PackEntityEnter(e)
		for _, w in ipairs(enters) do
			enterSet[w] = true
			_Broadcast(w, PROTO.S2C_ENTITY_ENTER, selfEnter)
			local we = Entities[w]
			if we then
				_Broadcast(e.uid, PROTO.S2C_ENTITY_ENTER, _PackEntityEnter(we))
			end
		end

		-- 其余观众（既未进入也未离开视野的）收 move
		local movePayload = _PackEntityMove(e)
		for w in pairs(AOI.GetWatchers(e.uid)) do
			if not enterSet[w] then
				_Broadcast(w, PROTO.S2C_ENTITY_MOVE, movePayload)
			end
		end
	else
		local movePayload = _PackEntityMove(e)
		for w in pairs(AOI.GetWatchers(e.uid)) do
			_Broadcast(w, PROTO.S2C_ENTITY_MOVE, movePayload)
		end
	end

	if #leaves > 0 then
		local selfLeave = _PackEntityLeave(e.uid)
		for _, w in ipairs(leaves) do
			_Broadcast(w, PROTO.S2C_ENTITY_LEAVE, selfLeave)
			_Broadcast(e.uid, PROTO.S2C_ENTITY_LEAVE, _PackEntityLeave(w))
		end
	end
end

-- 客户端移动上报：位置 + 可选速度/时间戳（缺省由服务端按位移推导）
function Move(uid, x, y, vx, vy, t)
	local e = Entities[uid]
	if not e then
		return false
	end

	-- 世界边界钳制
	if x < 0 then
		x = 0
	elseif x > WORLD_WIDTH then
		x = WORLD_WIDTH
	end
	if y < 0 then
		y = 0
	elseif y > WORLD_HEIGHT then
		y = WORLD_HEIGHT
	end

	local oldx, oldy = e.x, e.y
	if not vx then
		-- 未上报速度：按位移推导（单位 = 位移/移动上报周期）
		vx = x - oldx
		vy = y - oldy
	end

	e.x, e.y, e.vx, e.vy, e.t = x, y, vx, vy, t or 0
	_AfterMove(e, oldx, oldy)
	return true
end

---------------------- 压测接口（perf 服务调用） ----------------------

local perf_uids = {}

-- 批量生成压测实体（聚集在世界中心 100x100 区域内，模拟"同格"场景）
function PerfSpawn(n)
	PerfCleanup()
	local cx, cy = WORLD_WIDTH / 2, WORLD_HEIGHT / 2
	for i = 1, n do
		local e = {
			uid = PERF_UID_BASE + i,
			x = cx + rnd(100) - 50,
			y = cy + rnd(100) - 50,
			vx = 0,
			vy = 0,
			t = 0,
			bind_id = false,
			is_perf = true,
		}
		Entities[e.uid] = e
		AOI.Add(e)
		perf_uids[#perf_uids + 1] = e.uid
	end
	PerfActive = true
	return #perf_uids
end

-- 压测单步：全部实体随机小步移动一次
function PerfStep(step_size)
	local r = step_size or 10
	for i = 1, #perf_uids do
		local e = Entities[perf_uids[i]]
		if e then
			local oldx, oldy = e.x, e.y
			local nx, ny = e.x + rnd(-r, r), e.y + rnd(-r, r)
			if nx < 0 then nx = 0 elseif nx > WORLD_WIDTH then nx = WORLD_WIDTH end
			if ny < 0 then ny = 0 elseif ny > WORLD_HEIGHT then ny = WORLD_HEIGHT end
			e.x, e.y = nx, ny
			e.vx, e.vy = nx - oldx, ny - oldy
			e.t = e.t + 1
			_AfterMove(e, oldx, oldy)
		end
	end
end

-- 清理压测实体
function PerfCleanup()
	for i = 1, #perf_uids do
		local e = Entities[perf_uids[i]]
		if e then
			Entities[perf_uids[i]] = nil
			AOI.Remove(e)
		end
	end
	perf_uids = {}
	PerfActive = false
end

-- 压测入口：生成 n 实体 -> 跑 frames 帧 -> 统计帧耗时 -> 清理
-- 压测期间广播走本地计数（不经过 skynet 消息队列与网关），测量纯世界逻辑开销
function PerfRun(n, frames, step_size)
	if PerfActive then
		PerfCleanup()
	end
	PerfSpawn(n)

	local broadcast_count = 0
	local realBroadcast = Broadcast
	Broadcast = function ()
		broadcast_count = broadcast_count + 1
	end

	local times = {}
	local total = 0
	local maxT = 0
	local minT = 0x7fffffff
	for _ = 1, frames do
		local t0 = skynet.now()
		PerfStep(step_size)
		local dt = skynet.now() - t0
		times[#times + 1] = dt
		total = total + dt
		if dt > maxT then
			maxT = dt
		end
		if dt < minT then
			minT = dt
		end
	end

	Broadcast = realBroadcast
	PerfCleanup()

	table.sort(times)
	-- skynet.now() 单位 1/100 秒，换算毫秒
	local avg_ms = total * 10 / frames
	local max_ms = maxT * 10
	local min_ms = minT * 10
	local p50_ms = times[floor(frames / 2) + 1] * 10
	local entities_per_sec = floor(n * frames * 100 / total)

	return {
		n = n,
		frames = frames,
		avg_ms = avg_ms,
		max_ms = max_ms,
		min_ms = min_ms,
		p50_ms = p50_ms,
		broadcast = broadcast_count,
		entities_per_sec = entities_per_sec,
		pass = avg_ms < 20,	-- 验收：帧均耗时 < 20ms
	}
end
