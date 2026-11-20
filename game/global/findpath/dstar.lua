-- 资料来源：
--	https://www.cnblogs.com/MyStringIsNotNull/p/16273574.html
-- 	https://blog.csdn.net/qq_44339029/article/details/127490956
--  https://blog.csdn.net/weixin_42875283/article/details/124341524?spm=1001.2014.3001.5501

-- D星寻路算法虽然解决了动态障碍的问题，但是依然存在一些问题（例如：死路缺陷、网格数和计算量同步递增）

local minheap = require "minheap"
local table = table

local POS_STATE0 = 0	-- 障碍
local POS_STATE1 = 1	-- 正常可行走

local MAX_COST = 99999

local DIRS = {
	-- 上，下，左、右
	{0, 1}, {0, -1}, {-1, 0}, {1, 0},

	{1, 1}, {1, -1}, {-1, -1}, {-1, 1},
}

-- 节点状态
local STATE = { NEW = 1, OPEN = 2, CLOSED = 3, }

local function _GetKey(x, y)
	return x << 8 | y
end
local function _SplitKey(key)
	local x = key >> 8
	local y = key & 255
	return x, y
end
local function _CreateNode(x, y)
	-- k：表示当前(x, y)最小的h值
	-- h：表示当前(x, y)坐标到达目标节点(即goal)的代价
	-- parent：表示当前(x, y)节点的父节点
	return {
		key = _GetKey(x, y),
		x = x,
		y = y,
		state = STATE.NEW,
		h = 0,
		k = MAX_COST,
		parent = nil,
	}
end

-- D星算法的类模板
DStar = { ClassType = "DStar" }
function DStar:New(map_data)
	local o = {
		map_data = map_data,
		role_data = {},	-- 玩家寻路路径数据
		pos_state = {},	-- 坐标最新状态(障碍、非障碍)

		-- 优先队列(最小堆)
		-- openList = minheap:New("key", {"k"}),
	}
	setmetatable(o, {__index = self})
	return o
end

function DStar:GetRoleData(uid)
	return self.role_data[uid]
end

-- 切比雪夫距离(Chebyshev Distance)，直行和对角线移动的成本均为1。
function DStar:CalcCost_CD(sx, sy, gx, gy)
	if not (self:IsWalk(sx, sy) and self:IsWalk(gx, gy)) then
		return MAX_COST
	end
	local dx = math.abs(gx - sx)
	local dy = math.abs(gy - sy)
	return math.max(dx, dy)  -- 切比雪夫距离
end

-- 欧几里得距离(Euclidean distance), 精确区分直行与斜向成本。
function DStar:CalcCost_ED(sx, sy, gx, gy)
	if not (self:IsWalk(sx, sy) and self:IsWalk(gx, gy)) then
		return MAX_COST
	end
	local dx = math.abs(gx - sx)
	local dy = math.abs(gy - sy)
	if dx > 0 and dy > 0 then
		return 1.414  -- 斜向移动成本
	else
		return 1      -- 直行移动成本
	end
end

-- 曼哈顿距离计算(Manhattan Distance)，不精确地区分直线与斜向成本。
function DStar:CalcCost_MD(sx, sy, gx, gy)
	if self:IsWalk(sx, sy) and self:IsWalk(gx, gy) then
		return math.abs(gx - sx) + math.abs(gy - sy)
	end
	return MAX_COST
end

-- 坐标是否有效
function DStar:IsValid(x, y)
	return self.map_data[y] and self.map_data[y][x]
end

-- true：(x,y)为障碍
function DStar:IsObs(x, y)
	if not self:IsValid(x, y) then
		error(string.format("addobs, x:%s y:%s no valid", x, y))
	end
	local key = _GetKey(x, y)
	local state = self.pos_state[key] or self.map_data[y][x]
	if state == POS_STATE0 then
		return true
	end
end

-- true: (x,y)可正常行走
function DStar:IsWalk(x, y)
	if not self:IsValid(x, y) then
		return
	end
	local key = _GetKey(x, y)
	if self.pos_state[key] then
		return
	end
	local mtype = self.map_data[y] and self.map_data[y][x]
	if mtype ~= POS_STATE1 then
		return
	end
	return true
end

-- 更新(x,y)坐标的属性状态
function DStar:UpdatePosState(x, y, nState)
	if not (nState == POS_STATE0 or nState == POS_STATE1) then
		error(string.format("update pos state, but state:%s error! x:%s y:%s", nState, x, y))
	end
	if not self:IsValid(x, y) then
		return
	end
	local key = _GetKey(x, y)
	local oState = self.map_data[y][x]
	if oState == nState then
		self.pos_state[key] = nil
	else
		self.pos_state[key] = nState
	end
	_INFO_F("update x:%s y:%s oldstate:%s newstate:%s", x, y, oState, nState)
end

-- 更新地图节点（并影响role_path）
function DStar:modifyMap(x, y, isObs)
	if not self:IsValid(x, y) then
		return
	end
	local nState = isObs and POS_STATE0 or POS_STATE1
	local key = _GetKey(x, y)
	local oState = self.pos_state[key] or self.map_data[y][x]
	if nState == oState then
		return
	end
	self:UpdatePosState(x, y, nState)
	for uid, rdata in pairs(self.role_data) do
		local node = rdata.openSet[_GetKey(x, y)]
		if node then
			local neighbors = self:CalcNeighbors(uid, x, y) or {}
			for _, nbr in pairs(neighbors) do
				if nbr.parent == node and nbr.state == STATE.CLOSED then
					local cost = self:CalcCost_CD(node.x, node.y, nbr.x, nbr.y)
					self:Insert(uid, nbr, cost)
				end
			end
		end
	end
end

function DStar:CalcNeighbors(uid, x, y)
	local rData = self:GetRoleData(uid)
	if not rData then
		return
	end
	local result = {}
	for _, v in pairs(DIRS) do
		local nbrx = x + v[1]
		local nbry = y + v[2]
		if self:IsWalk(nbrx, nbry) then
			local nbr = rData.openSet[_GetKey(nbrx, nbry)]
			if not nbr then
				nbr = _CreateNode(nbrx, nbry)
				rData.openSet[nbr.key] = nbr
			end
			table.insert(result, nbr)
		end
	end
	return result
end

function DStar:IsGoal(uid)
	local rData = self.role_data[uid]
	if not rData then
		return
	end
	local key = _GetKey(rData.start.x, rData.start.y)
	local node = rData.openSet[key]
	return node and node.state == STATE.CLOSED
end

function DStar:DoProcess(uid)
	while not self:IsGoal(uid) do
		local size = self:ProcessState(uid)
		if not size or size <= 0 then
			return
		end
	end
end

function DStar:ProcessState(uid)
	local rData = self:GetRoleData(uid)
	if not rData then
		return
	end
	local node = rData.openList:Pop()
	if not node then
		return
	end
	node.state = STATE.CLOSED

	-- 传播
	if node.k < node.h then
		-- raise状态：h值大于k值，表示当前该节点处于h值被修改为较大的状态。（例如该节点被设置成障碍）
		-- 为此查找邻居节点来得到减低自身的h值
		local neighbors = self:CalcNeighbors(uid, node.x, node.y) or {}
		for _, nbr in pairs(neighbors) do
			local cost = self:CalcCost_CD(node.x, node.y, nbr.x, nbr.y)
			local h = nbr.h + cost
			if node.k > nbr.h and node.h > h then
				node.parent = nbr
				node.h = h
			end
		end
	end

	-- 该过程类似于dijikstra，用来传播信息当前节点h值变化的信息和降低邻居节点的h值
	local neighbors = self:CalcNeighbors(uid, node.x, node.y) or {}
	if node.k == node.h then
		for _, nbr in pairs(neighbors) do
			local cost = self:CalcCost_CD(node.x, node.y, nbr.x, nbr.y)
			if nbr.state == STATE.NEW or
				(nbr.parent == node and nbr.h ~= (node.h + cost)) or
				(nbr.parent ~= node and nbr.h > (node.h + cost))
			then
				nbr.parent = node
				self:Insert(uid, nbr, node.h + cost)
			end
		end
	else
		-- k值和h值不相同，表示节点处于调整状态
		for _, nbr in pairs(neighbors) do
			local cost = self:CalcCost_CD(node.x, node.y, nbr.x, nbr.y)
			if nbr.state == STATE.NEW or
				(nbr.parent == node and nbr.h ~= node.h + cost)
			then
				nbr.parent = node
				self:Insert(uid, nbr, node.h + cost)
			else
				-- 邻居节点存在更短的路径
				-- 调整当前节点并重新传播当前节点的h值变化信息给周围节点
				if nbr.parent ~= node and (nbr.h > node.h + cost) then
					self:Insert(node, node.h)
				else
					-- 传播邻居节点的信息，使其可以影响当前节点进而修改当前节点的h值和路径信息
					-- 因为这里存在比当前节点的h值更低的值
					if (nbr.parent ~= node and node.h > (nbr.h + cost) and nbr.state == STATE.CLOSED and nbr.h > node.k) then
						self:Insert(uid, nbr, nbr.h)
					end
				end
			end
		end
	end

	return rData.openList:Size()
end

function DStar:Insert(uid, node, newH)
	local rData = self:GetRoleData(uid)
	if not rData then return end

	if node.state == STATE.NEW then
		node.h = newH
		node.k = newH
		node.state = STATE.OPEN
		rData.openList:Push(node)
	elseif node.state == STATE.OPEN then
		node.k = math.min(node.k, newH)
		rData.openList:ModifyByUnique(node)
	else
		node.k = math.min(node.h, newH)
		node.h = newH
		node.state = STATE.OPEN
		rData.openList:Push(node)
	end
end

-- 添加寻路数据
function DStar:CreateFindPath(uid, start, goal)
	local rData = self:GetRoleData(uid)
	assert(not rData, string.format("uid:%s already has data", uid))

	rData = {
		uid = uid,
		start = table.copy(start),
		goal = table.copy(goal),
		current = table.copy(start),

		-- minheap：优先队列(最小堆)
		-- openList：存放节点状态为OPEN的节点。且其按照节点的k值从小到大进行排序
		openList = minheap:New("key", {"k"}, true),
		openSet = {},
	}
	self.role_data[uid] = rData

	local goalNode = _CreateNode(goal.x, goal.y)
	goalNode.h, goalNode.k = 0, 0
	goalNode.state = STATE.OPEN
	rData.openSet[goalNode.key] = goalNode
	rData.openList:Push(goalNode)
	return rData
end

-- 调试接口：输出路径
function DStar:findPath(uid)
	local rData = self:GetRoleData(uid)
	if not rData then
		return
	end

	local mapData = table.deepcopy(self.map_data)
	local key = _GetKey(rData.start.x, rData.start.y)
	local node = rData.openSet[key]
	local n = node
	while n do
		mapData[n.y][n.x] = "E"
		n = n.parent
	end
	for key in pairs(self.pos_state) do
		local x, y = _SplitKey(key)
		mapData[y][x] = "O"
	end

	for y = 1, #mapData do
		local m = ""
		for x = 1, #mapData[1] do
			m = m .. mapData[y][x] .. " "
		end
		print(m)
	end

end
