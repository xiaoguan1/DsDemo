-- 九宫格 AOI：细格索引 + 每实体观众集（watchers）
-- 视图范围：以实体所在格为中心的 3x3 细格
-- 维护双向可见关系：实体 e 在 w 的视野内 <=> w 在 e 的视野内（格子邻接对称性保证）
local floor = math.floor

local GRID_SIZE = 50	-- 细格边长（单位）

Grids = {}			-- [key "gx,gy"] = {uid = true, ...}
EntityGrid = {}		-- [uid] = key 实体当前所在格
Watchers = {}		-- [uid] = {watcher_uid = true, ...} 实体当前视野内的其他实体

local EMPTY = {}	-- 空列表常量（未跨格时复用，避免频繁建表）

local function GridKey(x, y)
	return floor(x / GRID_SIZE) .. "," .. floor(y / GRID_SIZE)
end

-- 收集实体 3x3 视野内的实体 uid 集合（不含自身）
local function CollectNear(e, set)
	set = set or {}
	local gx = floor(e.x / GRID_SIZE)
	local gy = floor(e.y / GRID_SIZE)
	for dx = -1, 1 do
		for dy = -1, 1 do
			local grid = Grids[(gx + dx) .. "," .. (gy + dy)]
			if grid then
				for uid in pairs(grid) do
					if uid ~= e.uid then
						set[uid] = true
					end
				end
			end
		end
	end
	return set
end

-- 实体加入世界：入格、建立初始视野，返回视野内实体 uid 列表
function Add(e)
	local key = GridKey(e.x, e.y)
	local grid = Grids[key]
	if not grid then
		grid = {}
		Grids[key] = grid
	end
	grid[e.uid] = true
	EntityGrid[e.uid] = key

	local near = CollectNear(e)
	Watchers[e.uid] = {}
	local list = {}
	for w in pairs(near) do
		Watchers[e.uid][w] = true
		Watchers[w][e.uid] = true
		list[#list + 1] = w
	end
	return list
end

-- 实体离开世界：出格、解除所有可见关系，返回原观众 uid 列表
function Remove(e)
	local grid = Grids[EntityGrid[e.uid]]
	if grid then
		grid[e.uid] = nil
		if next(grid) == nil then
			Grids[EntityGrid[e.uid]] = nil
		end
	end
	EntityGrid[e.uid] = nil

	local watchers = Watchers[e.uid]
	Watchers[e.uid] = nil
	local list = {}
	for w in pairs(watchers) do
		list[#list + 1] = w
		if Watchers[w] then
			Watchers[w][e.uid] = nil
		end
	end
	return list
end

-- 实体移动后的视野重算：返回新进入视野的 uid 列表与离开视野的 uid 列表
function OnMove(e, oldx, oldy)
	local newKey = GridKey(e.x, e.y)
	local oldKey = GridKey(oldx, oldy)

	-- 未跨格：3x3 视野窗口不变，观众集不变
	if newKey == oldKey then
		return EMPTY, EMPTY
	end

	-- 维护格子索引
	local grid = Grids[oldKey]
	if grid then
		grid[e.uid] = nil
		if next(grid) == nil then
			Grids[oldKey] = nil
		end
	end
	local ngrid = Grids[newKey]
	if not ngrid then
		ngrid = {}
		Grids[newKey] = ngrid
	end
	ngrid[e.uid] = true
	EntityGrid[e.uid] = newKey

	local near = CollectNear(e)
	local myWatch = Watchers[e.uid]
	local enters, leaves = {}, {}

	-- 新进入视野的
	for w in pairs(near) do
		if not myWatch[w] then
			enters[#enters + 1] = w
			myWatch[w] = true
			Watchers[w][e.uid] = true
		end
	end

	-- 离开视野的
	for w in pairs(myWatch) do
		if not near[w] then
			leaves[#leaves + 1] = w
			myWatch[w] = nil
			Watchers[w][e.uid] = nil
		end
	end

	return enters, leaves
end

-- 实体当前观众集（活表，只读使用）
function GetWatchers(uid)
	return Watchers[uid]
end
