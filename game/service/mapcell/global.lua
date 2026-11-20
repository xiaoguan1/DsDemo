-- 地图分块服务核心逻辑（草图）
--
-- 设计要点：
-- 1. 数据分层：静态层（地形/可通行性，配置只读）+ 动态层（建筑/归属/驻军，可变需落库）
-- 2. 扁平存储：格子用一维数组下标存储，y 优先排列，避免 Lua 嵌套 table 开销
-- 3. chunk 分块：chunk 是负载均衡、AOI 订阅、广播、落库的最小单位
-- 4. chunk owner：chunk_key 哈希取模落到某个 cell，写操作统一路由到 owner（避免跨服务双写）
-- 5. AOI 九宫格：玩家进入/离开 chunk 时增删观察者，变更只广播给观察者（即玩家所在 agent）
-- 6. 增量同步：进视野发快照，之后发增量事件；跨 cell 的 chunk 由 owner cell 负责广播

local skynet = require "skynet"

PROXYSVR = Import("game/global/rpc/proxysvr.lua")
CHUNK_ROUTE = Import("game/global/chunk_route.lua")
assert(ACCEPT)
assert(RESPONSE)

-- ============ 配置（config 驱动，这里给默认值；5万格 = 250 x 200，32x32 一个 chunk） ============
local MAP_WIDTH = tonumber(skynet.getenv("map_width")) or 250
local MAP_HEIGHT = tonumber(skynet.getenv("map_height")) or 200
local CHUNK_SIZE = tonumber(skynet.getenv("map_chunk_size")) or 32
local CELL_NUM = tonumber(skynet.getenv("mapcell_default_num")) or 4

local CX_CNT = math.ceil(MAP_WIDTH / CHUNK_SIZE)	-- chunk 横向数量
local CY_CNT = math.ceil(MAP_HEIGHT / CHUNK_SIZE)	-- chunk 纵向数量

-- 本实例信息（mapcell.lua 启动时注入 MAPCELL_INDEX，已 tonumber）
local cell_index = MAPCELL_INDEX
local CellName = cell_index == 1 and ".MAPCELL" or (".MAPCELL" .. cell_index)
local CellCN = SELF_CLUSTERNAME

-- ============ 坐标工具 ============
-- 坐标约定：x,y 从 1 开始，越界视为非法
local function IsValidXY(x, y)
	return x and y and x >= 1 and y >= 1 and x <= MAP_WIDTH and y <= MAP_HEIGHT
end

-- (x,y) -> 一维数组下标（y 优先排列）
local function TileIdx(x, y)
	return (y - 1) * MAP_WIDTH + x
end

-- (x,y) -> chunk_key（"cx_cy"，0 起始）
local function ChunkKey(x, y)
	return math.floor((x - 1) / CHUNK_SIZE) .. "_" .. math.floor((y - 1) / CHUNK_SIZE)
end

-- chunk_key -> 该 chunk 左上角坐标
local function ChunkOrigin(ck)
	local cx, cy = string.match(ck, "^(%d+)_(%d+)$")
	return tonumber(cx) * CHUNK_SIZE + 1, tonumber(cy) * CHUNK_SIZE + 1
end

-- chunk owner 判定：哈希取模固定在某个 cell 实例（依赖 CELL_NUM 稳定，cell 上下线需同步调整）
local function HashChunkId(ck)
	local cx, cy = string.match(ck, "^(%d+)_(%d+)$")
	return tonumber(cx) * 7919 + tonumber(cy)
end

local function IsOwnerChunk(ck)
	return HashChunkId(ck) % CELL_NUM + 1 == cell_index
end

-- ============ 格子数据 ============
-- 静态层：只读配置（草图留空，实际由配置表加载地形/可通行性）
local Terrain = {}

-- 动态层：一维稀疏数组，元素 = { owner, building_id, troop_id, dura }，nil 表示无动态内容
local Dyn = {}

-- 脏格子集合，定时批量落库（避免每格变化落一次 DB）
local Dirty = {}

-- ============ AOI：chunk_key -> { [uid] = { agent_name, agent_cn } } ============
-- 观察者登记在 chunk 的 owner cell 上；广播只发生在 owner cell 本地
local Observers = {}

-- (x,y) 为中心的九宫格 chunk_key 集合（set 形式，供 diff 用）
local function NineChunkKeys(x, y)
	local set = {}
	if not IsValidXY(x, y) then
		return set
	end
	local cx = math.floor((x - 1) / CHUNK_SIZE)
	local cy = math.floor((y - 1) / CHUNK_SIZE)
	for dy = -1, 1 do
		for dx = -1, 1 do
			local nx, ny = cx + dx, cy + dy
			if nx >= 0 and ny >= 0 and nx < CX_CNT and ny < CY_CNT then
				set[nx .. "_" .. ny] = true
			end
		end
	end
	return set
end

-- 解析非本 cell chunk 的 owner cell 地址（owner 判定以 IsOwnerChunk 本地哈希为准；
-- 路由表仅用于拿到转发目标，查不到则返回 nil，调用方据此告警丢弃而不是误当本 cell 处理）
local function GetOwnerCell(ck)
	if IsOwnerChunk(ck) then
		return false
	end
	local isOk, info = TryCall(CHUNK_ROUTE.Get, ck)
	if isOk and info and info.cell_name then
		return info.cell_name, info.cell_cn
	end
end

-- ============ 增量广播 ============
-- 把 chunk 上的变更打包发给所有观察者（观察者是玩家所在 agent，由 agent 按 uid 路由到连接）
local function BroadcastChunk(ck, event, diff)
	local list = Observers[ck]
	if not list then
		return
	end
	for uid, info in pairs(list) do
		-- 服务间消息走 lua 协议；agent 侧需实现 ACCEPT.map_sync 转发到 wgate push
		TryCall(PROXYSVR.GetProxy(info.agent_name, info.agent_cn, "lua").send,
			"map_sync", uid, ck, event, diff)
	end
end

local function MarkDirty(idx)
	Dirty[idx] = true
end

-- ============ AOI 进入/离开 ============
function ACCEPT.enter_aoi(uid, agent_name, agent_cn, ck)
	-- 内部接口：cell 之间转发用；必须由 owner cell 执行登记
	if not IsOwnerChunk(ck) then
		_WARN_F("mapcell enter_aoi err, chunk:%s not owner", ck)
		return
	end
	local list = Observers[ck]
	if not list then
		list = {}
		Observers[ck] = list
	end
	list[uid] = { agent_name = agent_name, agent_cn = agent_cn }
end

function ACCEPT.leave_aoi(uid, ck)
	if not IsOwnerChunk(ck) then
		return
	end
	local list = Observers[ck]
	if list then
		list[uid] = nil
		if next(list) == nil then
			Observers[ck] = nil
		end
	end
end

-- agent 调用：玩家登录/移动/下线时更新 AOI 订阅
-- old_x/old_y 为空表示首次进图；new_x/new_y 为空表示离线/瞬移离开
function ACCEPT.aoi_update(uid, agent_name, agent_cn, old_x, old_y, new_x, new_y)
	local old_set = NineChunkKeys(old_x, old_y)
	local new_set = NineChunkKeys(new_x, new_y)

	-- 离开旧视野
	for ck in pairs(old_set) do
		if not new_set[ck] then
			if IsOwnerChunk(ck) then
				ACCEPT.leave_aoi(uid, ck)
			else
				local name, cn = GetOwnerCell(ck)
				if name then
					TryCall(PROXYSVR.GetProxy(name, cn, "lua").send, "leave_aoi", uid, ck)
				end
			end
		end
	end

	-- 进入新视野
	for ck in pairs(new_set) do
		if not old_set[ck] then
			if IsOwnerChunk(ck) then
				ACCEPT.enter_aoi(uid, agent_name, agent_cn, ck)
			else
				local name, cn = GetOwnerCell(ck)
				if name then
					TryCall(PROXYSVR.GetProxy(name, cn, "lua").send, "enter_aoi", uid, agent_name, agent_cn, ck)
				end
			end
		end
	end
end

-- ============ 写操作：统一路由到 chunk owner ============
-- 建造/占领等写操作入口；跨 cell 时转发到 owner cell 执行，保证单写者
function ACCEPT.build(uid, x, y, building_id)
	if not IsValidXY(x, y) then
		_WARN_F("mapcell build err, invalid xy:%s,%s", tostring(x), tostring(y))
		return
	end
	local ck = ChunkKey(x, y)
	if not IsOwnerChunk(ck) then
		local name, cn = GetOwnerCell(ck)
		if not name then
			_WARN_F("mapcell build err, chunk:%s owner cell not found in route", ck)
			return
		end
		TryCall(PROXYSVR.GetProxy(name, cn, "lua").send, "build", uid, x, y, building_id)
		return
	end

	local idx = TileIdx(x, y)
	local tile = Dyn[idx]
	if not tile then
		tile = {}
		Dyn[idx] = tile
	end
	tile.owner = uid
	tile.building_id = building_id
	MarkDirty(idx)

	-- 只广播给该 chunk 的观察者（AOI 范围内的玩家，不用全图广播）
	BroadcastChunk(ck, "build", { x = x, y = y, owner = uid, building_id = building_id })
end

-- 行军/战斗等事件入口同样遵循"先判断 owner，跨 cell 转发"模式，在此扩展

-- ============ 读操作（快照 + 查询） ============
-- 注意：读接口被 call（session != 0）进来，必须定义在 RESPONSE 并 return，由 dispatch 统一 retpack
-- 快照：返回 (x,y) 九宫格内全部动态格子（登录/进图时给客户端，跨 cell 部分转发拉取并合并）
function RESPONSE.snapshot(uid, x, y)
	local out = {}
	if not IsValidXY(x, y) then
		return out
	end
	for ck in pairs(NineChunkKeys(x, y)) do
		if IsOwnerChunk(ck) then
			local ox, oy = ChunkOrigin(ck)
			for ty = oy, oy + CHUNK_SIZE - 1 do
				for tx = ox, ox + CHUNK_SIZE - 1 do
					if tx <= MAP_WIDTH and ty <= MAP_HEIGHT then
						local d = Dyn[TileIdx(tx, ty)]
						if d then
							out[#out + 1] = { x = tx, y = ty, owner = d.owner, building_id = d.building_id }
						end
					end
				end
			end
		else
			local name, cn = GetOwnerCell(ck)
			if name then
				local ok2, part = TryCall(PROXYSVR.GetProxy(name, cn, "lua").call, "chunk_dump", ck)
				if ok2 and part then
					for _, v in ipairs(part) do
						out[#out + 1] = v
					end
				end
			end
		end
	end
	return out
end

-- 仅本 cell 内 chunk 的动态格子 dump（供跨 cell 快照合并用）
function RESPONSE.chunk_dump(ck)
	local out = {}
	local ox, oy = ChunkOrigin(ck)
	for ty = oy, oy + CHUNK_SIZE - 1 do
		for tx = ox, ox + CHUNK_SIZE - 1 do
			if tx <= MAP_WIDTH and ty <= MAP_HEIGHT then
				local d = Dyn[TileIdx(tx, ty)]
				if d then
					out[#out + 1] = { x = tx, y = ty, owner = d.owner, building_id = d.building_id }
				end
			end
		end
	end
	return out
end

-- 单格查询：跨 cell 时转发到 owner cell 查询并回传结果
function RESPONSE.tile_query(uid, x, y)
	if not IsValidXY(x, y) then
		return
	end
	local ck = ChunkKey(x, y)
	if not IsOwnerChunk(ck) then
		local name, cn = GetOwnerCell(ck)
		if not name then
			return
		end
		local ok2, data = TryCall(PROXYSVR.GetProxy(name, cn, "lua").call, "tile_query", uid, x, y)
		if ok2 then
			return data
		end
		return
	end
	local d = Dyn[TileIdx(x, y)]
	return d and { x = x, y = y, owner = d.owner, building_id = d.building_id } or nil
end

-- ============ 落库：脏格子批量回写 ============
-- 只落动态层；实际按动态层序列化成 json 写 dbserver，这里占位
local function FlushDirty()
	if next(Dirty) == nil then
		return
	end
	local n = 0
	for _ in pairs(Dirty) do
		n = n + 1
	end
	_DEBUG("mapcell:%s flush %d dirty tiles", CellName, n)
	Dirty = {}
end

-- 定时批量落库（草图用 fork 定时；生产建议接 stimer 统一调度）
skynet.fork(function ()
	while true do
		skynet.sleep(500)	-- 5 秒一批
		FlushDirty()
	end
end)

-- ============ 启动：登记本 cell 负责的 chunk 到全局路由表 ============
local own_count = 0
for cy = 0, CY_CNT - 1 do
	for cx = 0, CX_CNT - 1 do
		local ck = cx .. "_" .. cy
		if IsOwnerChunk(ck) then
			local isOk, isReg = TryCall(CHUNK_ROUTE.Reg, ck, CellName, CellCN)
			if isOk and isReg then
				own_count = own_count + 1
			end
		end
	end
end
_INFO_F("mapcell:%s register ok, owns %d chunks of grid %d x %d", CellName, own_count, MAP_WIDTH, MAP_HEIGHT)