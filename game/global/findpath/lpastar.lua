-- https://github.com/xwnb/motion_planning/blob/master/doc/LPA_STAR.md
-- https://blog.csdn.net/qq_44339029/article/details/126789410

local minheap = require "minheap"
local math = math

local DIRS = {
	-- 上，下，左、右
	{0, 1}, {0, -1}, {-1, 0}, {1, 0},
	{1, 1}, {1, -1}, {-1, -1}, {-1, 1},
}

-- 节点移动代价
local MOVECOST = 1

-- 0：障碍、1：可行走
local POS_TYPE0 = 0
local POS_TYPE1 = 1

local COLORS = {
	POS_TYPE0,
	POS_TYPE1,
}

-- 局部函数 ---------------------------------
local function _GetKey(x, y)
	return x << 8 | y
end
local function _SplitKey(key)
	local x = key >> 8
	local y = key & 255
	return x, y
end

-- 启发式函数（切比雪夫距离）
local function _Heuristic(a, b)
	local dx = math.abs(a.x - b.x)
	local dy = math.abs(a.y - b.y)
	return math.max(dx, dy)
end

local function IsSamePos(t, x, y)
	for k, v in pairs(t) do
		if v.x == x and v.y == y then
			return k
		end
	end
end

-- 洪水填充算法(目的：划分地图区域，处理死路问题！)
local function _FloodFill(mapData)
	if not mapData then
		-- 不能容忍参数为nil\false的情况
		error("arg mapData is nil!")
		return
	end
	local area2key, key2area = {}, {}
	if table.empty(mapData) then
		return area2key, key2area
	end

	mapData = table.deepcopy(mapData)
	local maxY = #mapData
	local maxX = #mapData[maxY]
	local maxDeep = maxX * maxY	-- 最大深度

	-- 深度探索递归方法（注意：如果地图极大，有可能栈溢出）
	local function dfs(areaNo, areaList, x, y, ocolor, ncolor, deep)
		if not (1 <= x and x <= maxX and 1 <= y and y <= maxY) then
			return
		end
		if not mapData[y][x] or mapData[y][x] ~= ocolor then
			return
		end
		if deep > maxDeep then
			error("loop count too deep!")
		end
		deep = deep + 1
		mapData[y][x] = ncolor
		local key = _GetKey(x, y)
		areaList[key] = ocolor
		key2area[key] = areaNo
		for _, v in pairs(DIRS) do
			dfs(areaNo, areaList, x + v[1], y + v[2], ocolor, ncolor, deep)
		end
	end

	local areaNo = 1
	for _, color in pairs(COLORS) do
		for x = 1, maxX do
			for y = 1, maxY do
				if mapData[y][x] == color then
					area2key[areaNo] = area2key[areaNo] or {}
					dfs(areaNo, area2key[areaNo], x,  y, color, tostring(color), 1)
					areaNo = areaNo + 1
				end
			end
		end
	end

	return area2key, key2area
end


-- LPA Star 类 ---------------------------------
LpaStar = {}
function LpaStar:New(map_data)
	local area2key, key2area = _FloodFill(map_data)
	local o = {
		map_data = map_data,	-- 地图配置
		area2key = area2key,
		key2area = key2area,
		map_modify = {},		-- 地图修改（判断坐标状态优先以它为准，其次以map_data为准）
		role_data = {},			-- 玩家寻路路径数据
	}
	setmetatable(o, {__index = self})
	return o
end

-- 洪水填充：根据坐标获取对应的区域编号
function LpaStar:GetArea(x, y)
	if x and y then
		local key = _GetKey(x, y)
		return self.key2area[key]
	elseif x and not y then
		return self.key2area[x]
	end
end

-- 洪水填充：根据区域编号获取该区域的坐标列表信息
function LpaStar:GetFFKeys(areaNo)
	return areaNo and self.area2key[areaNo]
end

-- 洪水填充：因地图的信息有变化，所以再次洪水填充！
function LpaStar:AgainFloodFill()
	local area2key, key2area = _FloodFill(self.map_data)
	self.area2key = area2key
	self.key2area = key2area
end

-- 洪水填充：判断是否相同区域
function LpaStar:IsSameAreaByNode(aNode, bNode)
	local aAreaNo = self:GetArea(aNode.key)
	local bAreaNo = self:GetArea(bNode.key)
	return aAreaNo == bAreaNo
end
function LpaStar:IsSameArea(sx, sy, gx, gy)
	return self:GetArea(sx, sy) == self:GetArea(gx, gy)	
end

-- 获取玩家寻路事件数据
function LpaStar:GetRoleData(uid)
	return uid and self.role_data[uid]
end

-- 添加玩家的寻路事件
function LpaStar:AddRoleEvent(uid, start, goal)
	local rData = self:GetRoleData(uid)
	if not uid or rData then
		_ERROR_F("please not repeat add data, uid: start:%s goal:%s", uid, start, goal)
		return
	end

	-- 判断起点和终点是否可达！
	if not self:IsSameArea(start.x, start.y, goal.x, goal.y) then
		_ERROR_F("start:%s goal:%s not in the same area", tool.dumptree(start), tool.dumptree(goal))
		return
	end

	rData = {
		uid = uid,
		start = table.copy(start),
		goal = table.copy(goal),
		moveTime = nil,					-- 开始移动时间
		current = nil,					-- 玩家当前位置

		-- minheap：优先队列(最小堆)
		openList = minheap:New("key", {"k1", "k2"}, true),
		openSet = {},
		-- closeList = {},
		pathList = {},	-- 计算后，生成的路径。
	}
	self.role_data[uid] = rData
	local gNode = self:GetNode(uid, goal.x, goal.y)
	gNode.rhs = 0
	rData.openList:Push(gNode)
	return rData
end

function LpaStar:GetNode(uid, x, y)
	local key = _GetKey(x, y)
	local rData = self:GetRoleData(uid)
	local node = rData.openSet[key]
	if not node then
		node = {
			key = key,
			x = x,
			y = y,
			g = math.huge,
			rhs = 0,
			k1 = 0,
			k2 = 0,
			parent = nil,
		}
		rData.openSet[key] = node
	end
	return node
end

function LpaStar:IsWalk(x, y)
	local key = x and y and _GetKey(x, y)
	if not key then return end
	local state = self.map_modify[key]
	if not state then
		state = self.map_data[y] and self.map_data[y][x]
	end
	return state == POS_TYPE1
end


function LpaStar:GetNbrList(uid, node)
	local rData = uid and self:GetRoleData(uid)
	if not rData or not node then
		return
	end
	local nbrs = {}
	for _, v in pairs(DIRS) do
		local nbrx = node.x + v[1]
		local nbry = node.y + v[2]
		if self:IsWalk(nbrx, nbry) then
			table.insert(nbrs, self:GetNode(uid, nbrx, nbry))
		end
	end
	return nbrs
end

function LpaStar:UpdateKey(uid, node)
	local rData = uid and self:GetRoleData(uid)
	if not rData or not node then
		return
	end
	node.k1 = math.min(node.g, node.rhs) + _Heuristic(node, rData.start)
	node.k2 = math.min(node.g, node.rhs)
	return node.k1, node.k2
end

function LpaStar:UpdateVertex(uid, node)
	local rData = uid and self:GetRoleData(uid)
	if not rData or not node then
		return
	end

	if not (node.x == rData.goal.x and node.y == rData.goal.y) then
		local newRhs = math.huge
		local newParent
		for _, nbr in pairs(self:GetNbrList(uid, node) or {}) do
			local tmpRhs = nbr.g + MOVECOST
			if tmpRhs < newRhs then
				newRhs = tmpRhs
				newParent = nbr.key
			end
		end
		node.rhs = newRhs
		node.parent = newParent
	end

	if rData.openList:HasUnique(node.key) then
		rData.openList:Remove(node.key)
	end
	if node.g ~= node.rhs then
		self:UpdateKey(uid, node)
		rData.openList:Push(node)
	end
end

function LpaStar:ComputeShortestPath(uid)
	local rData = uid and self:GetRoleData(uid)
	if not rData then return end

	local openList = rData.openList
	local maxStep = 99999

	while openList:Size() > 0 do
		maxStep = maxStep - 1
		local top = openList:Pop()
		-- local startNode = self:GetNode(uid, rData.start.x, rData.start.y)
		-- local condi1 = startNode.k1 > top.k1 or (startNode.k1 == top.k1 and startNode.k2 > top.k2)
		-- local condi2 = startNode.rhs ~= startNode.g and startNode.g ~= math.huge
		-- if not (condi1 or condi2) then
		-- 	if top.x == 1 and top.y == 1 then
		-- 		print(top.x, top.y, maxStep)
		-- 	end
		-- end
		if top.x == rData.start.x and top.y == rData.start.y then
			-- 到达终点，设置局部一致。
			top.g = top.rhs
			break
		end
		if top.g > top.rhs then
			top.g = top.rhs
			for _, nbr in pairs(self:GetNbrList(uid, top) or {}) do
				self:UpdateVertex(uid, nbr)
			end
		elseif top.g < top.rhs then
			top.g = math.huge
			self:UpdateVertex(uid, top)
			for _, nbr in pairs(self:GetNbrList(uid, top) or {}) do
				self:UpdateVertex(uid, nbr)
			end
		end
	end
	_INFO_F("loop:%s", maxStep)
end

-- 动态更新地图
function LpaStar:UpdateMap(x, y, isObs)
	if not (x and y and self.map_data[y] and self.map_data[y][x]) then
		return
	end
	local key = _GetKey(x, y)
	local nPosType = isObs and POS_TYPE0 or POS_TYPE1
	local oPosType = self.map_modify[key] or self.map_data[y][x]
	if oPosType == nPosType then
		return
	end
	if self.map_modify[key] then
		self.map_modify[key] = nil
	else
		self.map_modify[key] = nPosType
	end
	for uid, rData in pairs(self.role_data) do
		local index = rData.pathList and IsSamePos(rData.pathList, x, y)
		if index then
			local startNode = self:GetNode(uid, rData.start.x, rData.start.y)
			local goalNode = self:GetNode(uid, rData.goal.x, rData.goal.y)
			if self:IsSameAreaByNode(startNode, goalNode) then
				local node = self:GetNode(uid, x, y)
				rData.openSet[node.key] = nil
				for _, nbr in pairs(self:GetNbrList(uid, node) or {}) do
					if nbr.parent == node.key then
						nbr.rhs = math.huge
						self:UpdateVertex(uid, nbr)
					end
				end
				self:ComputeShortestPath(uid)
			else
				-- 起点和终点已经不是同一片区域了，不可到达！

			end
		end
	end
end

function LpaStar:OutPutPath(uid)
	local rData = self:GetRoleData(uid)
	if not rData then return end

	-- 生成新的路径
	local pathList = {}
	local node = self:GetNode(uid, rData.start.x, rData.start.y)
	while node do
		table.insert(pathList, {x = node.x, y = node.y})
		if not node.parent then
			break
		end
		node = self:GetNode(uid, _SplitKey(node.parent))
	end
	rData.pathList = pathList
	rData.openList:Clear()
end

-- 打印玩家路径
function LpaStar:Print(uid)
	local rData = self:GetRoleData(uid)
	if not rData then return end
	local mapData = table.deepcopy(self.map_data)
	for key, v in pairs(self.map_modify) do
		if v == POS_TYPE0 then
			local x, y = _SplitKey(key)
			mapData[y][x] = "0"
		elseif v == POS_TYPE1 then
			local x, y = _SplitKey(key)
			mapData[y][x] = "1"
		end
	end

	for _, v in pairs(rData.pathList) do
		mapData[v.y][v.x] = "E"
	end

	for y = 1, #mapData do
		local m = ""
		for x = 1, #mapData[1] do
			m = m .. mapData[y][x] .. " "
		end
		print(m)
	end
	print()
end