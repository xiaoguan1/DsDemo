local minheap = require "minheap"
local math = math

-- 0：障碍、1：可行走
local POS_TYPE0 = 0
local POS_TYPE1 = 1

local DIRS = {
	-- 上，下，左、右
	{0, 1}, {0, -1}, {-1, 0}, {1, 0},
	{1, 1}, {1, -1}, {-1, -1}, {-1, 1},
}

-- 节点移动代价
local MOVECOST = 1

-- 每一个节点的移动消耗时间(可根据格子种类自定义时间、秒单位)
local MOVETIME = 10

-- 局部函数 ---------------------------------
-- 启发式函数（切比雪夫距离）
local function _Heuristic(a, b)
	local dx = math.abs(a.x - b.x)
	local dy = math.abs(a.y - b.y)
	return math.max(dx, dy)
end

local function _GetKey(x, y)
	return x << 8 | y
end
local function _SplitKey(key)
	local x = key >> 8
	local y = key & 255
	return x, y
end

local function IsSamePos(t, x, y)
	for k, v in pairs(t) do
		if v.x == x and v.y == y then
			return k
		end
	end
end

DStarLite = {__ClassType = "DStarLite"}
-- DStarLite的构造函数
function DStarLite:New(map_data)
	local o = {
		map_data = map_data,	-- 地图配置
		map_modify = {},		-- 地图修改（判断坐标状态优先以它为准，其次以map_data为准）

		role_data = {},	-- 玩家寻路路径数据
	}
	setmetatable(o, {__index = self})
	return o
end

function DStarLite:GetRoleData(uid)
	return uid and self.role_data[uid]
end

function DStarLite:IsWalk(x, y)
	local key = x and y and _GetKey(x, y)
	if not key then return end
	local state = self.map_modify[key]
	if not state then
		state = self.map_data[y] and self.map_data[y][x]
	end
	return state == POS_TYPE1
end

function DStarLite:GetNode(uid, x, y)
	local key = _GetKey(x, y)
	local rData = self:GetRoleData(uid)
	local node = rData.openSet[key]
	if not node then
		node = {
			key = _GetKey(x, y),
			x = x,
			y = y,
			g = math.huge,	-- 移动成本
			h = 0,			-- 估值成本
			f = 0,			-- 实际成本
			parent = nil,
		}
		node.h = _Heuristic(node, rData.start)
		rData.openSet[key] = node
	end
	return node
end

function DStarLite:GetNbrList(uid, node)
	if not node then return end
	local nbrs = {}
	for _, v in pairs(DIRS) do
		local nbrx = node.x + v[1]
		local nbry = node.y + v[2]
		if self:IsWalk(nbrx, nbry) then
			table.insert(nbrs, {x = nbrx, y = nbry})
		end
	end
	return nbrs
end

-- 添加玩家的寻路事件
function DStarLite:AddRoleEvent(uid, start, goal)
	local rData = self:GetRoleData(uid)
	if rData then
		_ERROR_F("please not repeat add data, uid: start:%s goal:%s", uid, start, goal)
		return
	end

	rData = {
		uid = uid,
		start = table.copy(start),
		goal = table.copy(goal),
		moveTime = nil,					-- 开始移动时间
		current = nil,					-- 玩家当前位置

		-- minheap：优先队列(最小堆)
		-- openList：存放节点状态为OPEN的节点。且其按照节点的k值从小到大进行排序
		openList = minheap:New("key", {"f", "g", "h"}, true),
		openSet = {},
		closeList = {},
		pathList = {},	-- 计算后，生成的路径。
	}
	self.role_data[uid] = rData
	local gNode = self:GetNode(uid, goal.x, goal.y)
	gNode.g = 0
	gNode.f = gNode.g + gNode.h
	self:UpdateOpenList(uid, gNode)
	return rData
end

function DStarLite:UpdateOpenList(uid, node)
	local rData = self:GetRoleData(uid)
	if not rData then
		return
	end

	if rData.openList:HasUnique(node.key) then
		rData.openList:Modify(node)
	else
		rData.openList:Push(node)
	end
end

-- 计算路径
function DStarLite:ComputePath(uid)
	local rData = self:GetRoleData(uid)
	if not rData then return end

	local startX = rData.start.x
	local startY = rData.start.y
	local max_steps = 99999
	while rData.openList:Size() > 0 do
		if max_steps <= 0 then
			print("ComputeShortestPath error: max steps exceeded.")
			break
		end
		max_steps = max_steps - 1
		local pNode = rData.openList:Pop()
		rData.closeList[pNode.key] = true
		if pNode.x == startX and pNode.y == startY then
			-- 到达终点,记录路径
			self:OutPutPath(uid)
			break
		end
		for _, v in pairs(self:GetNbrList(uid, pNode) or {}) do
			if not rData.closeList[_GetKey(v.x, v.y)] then
				local nbrNode = self:GetNode(uid, v.x, v.y)
				if nbrNode.g > pNode.g then
					nbrNode.g = pNode.g + MOVECOST
					nbrNode.f = nbrNode.g + nbrNode.h
					nbrNode.parent = pNode.key
					self:UpdateOpenList(uid, nbrNode)
				end
			end
		end
	end
	-- if rData.is then
		print("max_steps run count:", 99999 - max_steps)
	-- end
end

function DStarLite:AgainComputePath(uid, index)
	local rData = self:GetRoleData(uid)
	if not rData then return end

	local pos = index and rData.pathList[index]
	local node = pos and rData.openSet[_GetKey(pos.x, pos.y)]
	if not node then return end
	-- 这里还可以再细化，因为玩家是移动的，根据rData.current做最新的起点(start)

	-- 清除 1 ~ index-1 的无效路径结果
	for i = 1, index - 1 do
		local p = i and rData.pathList[i]
		if p then
			local key = _GetKey(p.x, p.y)
			rData.openSet[key] = nil
			rData.closeList[key] = nil
		end
	end

	-- 收集当前障碍的前驱节点和该前驱节点的邻居，选举一个最合适的节点出发。
	local sortList = {}
	table.insert(sortList, node)
	for _, v in pairs(self:GetNbrList(uid, node) or {}) do
		if node.parent ~= _GetKey(v.x, v.y) then
			table.insert(sortList, self:GetNode(uid, v.x, v.y))
		end
	end

	self:UpdateOpenList(uid, node)
	for _, v in pairs(self:GetNbrList(uid, node) or {}) do
		if node.parent ~= _GetKey(v.x, v.y) then
			self:UpdateOpenList(uid, self:GetNode(uid, v.x, v.y))
		end
	end

	self:ComputePath(uid)
end

function DStarLite:OutPutPath(uid)
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

-- 修改地图（设置障碍 or 清除障碍）
function DStarLite:modifyMap(x, y, isObs)
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

	if nPosType ~= POS_TYPE0 then
		-- 非障碍则结束
		return
	end
	for uid, rData in pairs(self.role_data) do
		local index = rData.pathList and IsSamePos(rData.pathList, x, y)
		if index then
			if index == #rData.pathList then
				-- goal坐标变为障碍
				rData.pathList[index] = nil
			else
				-- 路径中途有障碍生成
				-- 结合当前玩家的坐标做判断，退回父节点再次计算
				self:AgainComputePath(uid, index + 1)
			end
		end
	end
end

function DStarLite:StartMove(uid)
	local rData = self:GetRoleData(uid)
	if not rData or rData.moveTime then
		return
	end

	rData.moveTime = os.time()

end

-- 打印玩家路径
function DStarLite:Print(uid)
	local rData = self:GetRoleData(uid)
	if not rData then return end
	local mapData = table.deepcopy(self.map_data)
	for key, v in pairs(self.map_modify) do
		if v == POS_TYPE0 then
			local x, y = _SplitKey(key)
			mapData[y][x] = "O"
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