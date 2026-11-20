-- 跳点式的A星寻路（简称jps）
local table = table
local utf8 = utf8

local MISC = Import("game/global/findpath/jps/misc.lua")

local DIRECTION_4 = MISC.DIRECTION_4

local POS_STATE0 = MISC.POS_STATE0
local POS_STATE1 = MISC.POS_STATE1

-- 类
Mapping = { __ClassType = "<<mapping class>>" }

-- 坐标是否有效
function Mapping:IsValid(x, y)
	return x and y and self.mapData[x] and self.mapData[x][y]
end

function Mapping:IsWalk(x, y)
	local state = x and y and self.mapData[x] and self.mapData[x][y]
	return state == POS_STATE1
end

function Mapping:IsObs(x, y)
	local state = x and y and self.mapData[x] and self.mapData[x][y]
	return state == POS_STATE0
end

-- 两个坐标点是否可达
function Mapping:IsCanGo(startX, startY, goalX, goalY)
	local startKey = MISC.Key(startX, startY)
	local goalKey = MISC.Key(goalX, goalY)
	return self.key2area[startKey] == self.key2area[goalKey]
end

-- 获取node节点邻居
function Mapping:GetNeighbors(node)
	node = node or {}
	if not self:IsWalk(node.x, node.y) then
		return
	end
	local neighbs = {}
	local x, y = node.x, node.y

	if not node.pkey then
		-- 父节点为空，起点或者目标点！
		for _, v in ipairs(DIRECTION_4) do
			local nextX, nextY = (x + v.x), (y + v.y)
			if self:IsWalk(nextX, nextY) then
				table.insert(neighbs, {x = nextX, y = nextY})
			end
		end
		return neighbs
	end

	local px, py = MISC.RKey(node.pkey)
	local xDir, yDir = MISC.CalcDir(px, x), MISC.CalcDir(py, y)
	local nextX, nextY = x + xDir, y + yDir
	local preX, preY = x - xDir, y - yDir
	if xDir ~= 0 and yDir ~= 0 then
		-- 简化问题：
		-- 		1.斜方向移动可以分解成两个移动方向向量！例如 "右上斜方向" 移动可，可以分解成右方、上方。
		--		  又因为斜方向包含 右上、左上、右下、左下 四个斜方向！而为了抽象出这一部分的逻辑，
		-- 		  故在变量命名上假设它是右上斜方向移动！特别注意：方向上的移动要严格的使用 xDir 和 yDir
		-- 		2：xDir 和 yDir 的取值是 -1 或者 1

		local upWalk = self:IsWalk(x, nextY)
		local rightWalk = self:IsWalk(nextX, y)
		local downWalk = self:IsWalk(x, preY)
		local leftWalk = self:IsWalk(preX, y)

		-- 正前方是否可行走
		if self:IsWalk(nextX, nextY) then
			table.insert(neighbs, {x = nextX, y = nextY})
		end

		-- 斜方向的两个方向分量
		if upWalk then
			table.insert(neighbs, {x = x, y = nextY})
		end
		if rightWalk then
			table.insert(neighbs, {x = nextX, y = y})
		end

		-- 两个强迫邻居
		if not leftWalk and self:IsWalk(preX, nextY) then
			table.insert(neighbs, {x = preX, y = nextY})
		end
		if not downWalk and self:IsWalk(nextX, preY) then
			table.insert(neighbs, {x = nextX, y = preY})
		end
	elseif xDir ~= 0 then
		-- 横向（因为yDir为0，故nextY和y的值一样）
		if self:IsWalk(nextX, y) then
			table.insert(neighbs, {x = nextX, y = y})
		end
		local upY, downY = y + 1, y - 1
		local upWalk = self:IsWalk(x, upY)
		local downWalk = self:IsWalk(x, downY)
		if not upWalk and self:IsWalk(nextX, upY) then
			table.insert(neighbs, {x = nextX, y = upY})
		end
		if not downWalk and self:IsWalk(nextX, downY) then
			table.insert(neighbs, {x = nextX, y = downY})
		end
	elseif yDir ~= 0 then
		-- 纵向（因为xDir为0，故nextX和x的值一样）
		local rightX, leftX = x + 1, x - 1
		local rightWalk = self:IsWalk(rightX, y)
		local leftWalk = self:IsWalk(leftX, y)
		if self:IsWalk(x, nextY) then
			table.insert(neighbs, {x = x, y = nextY})
		end
		if not leftWalk and self:IsWalk(leftX, nextY) then
			table.insert(neighbs, {x = leftX, y = nextY})
		end
		if not rightWalk and self:IsWalk(rightX, nextY) then
			table.insert(neighbs, {x = rightX, y = nextY})
		end
	else
		error("calc neighbors fail")
	end

	return neighbs
end

-- a星寻路（核心逻辑）
function Mapping:AStart(startX, startY, goalX, goalY)

end

-- jsp寻路（核心逻辑）
function Mapping:Jsp(startX, startY, goalX, goalY)
	assert(self:IsValid(startX, startY) and self:IsValid(goalX, goalY))

	if not self:IsCanGo(startX, startY, goalX, goalY) then
		_ERROR_F("start:(%s, %s) can go goal:(%s, %s) !!!", startX, startY, goalX, goalY)
		return
	end

	local result = {
		openList = {},		-- 待检测节点列表
		openSet = {},		-- 辅助节点列表
		closeList = {},		-- 已检测节点列表
	}
	local openList, openSet, closeList = result.openList, result.openSet, result.closeList
	local startNode = MISC.CreateNode(startX, startY)
	table.insert(openList, startNode)
	openSet[startNode.key] = startNode

	local function _SeekJumpPoint(x, y, xDir, yDir)
		assert(x and y and xDir and yDir)
		if not (self:IsWalk(x, y) and
			(xDir >= -1 and xDir <= 1) and (yDir >= -1 and yDir <= 1) and
			(xDir ~= 0 or yDir ~= 0))
		then
			return
		end

		-- 条件1：位置节点是起始点或目标点
		if x == goalX and y == goalY then
			return {x = x, y = y}
		end

		-- 条件2：位置节点至少有一个强迫邻居
		local nextX, nextY = x + xDir, y + yDir
		local preX, preY = x - xDir, y - yDir
		if xDir ~= 0 and yDir ~= 0 then
			if (self:IsWalk(nextX, preY) and not self:IsWalk(x, preY)) or
				(self:IsWalk(preX, nextY) and not self:IsWalk(preX, y))
			then
				return {x = x, y = y}
			end
		elseif yDir ~= 0 then
			if (self:IsWalk(x - 1, nextY)) and not self:IsWalk(x - 1, y) or
				(self:IsWalk(x + 1, nextY) and not self:IsWalk(x + 1, y))
			then
				return {x = x, y = y}
			end
		else
			if (self:IsWalk(nextX, y + 1) and not self:IsWalk(x, y + 1)) or
				(self:IsWalk(nextX, y - 1) and not self:IsWalk(x, y - 1))
			then
				return {x = x, y = y}
			end
		end

		-- 条件3：如果位置节点x。父节点到位置节点x是对角移动(即xDir和yDir均不为0)，
		--			且x可以通过水平或者垂直方向的移动到达另一个跳点，则节点x也是跳点。
		if xDir ~= 0 and yDir ~= 0 then
			local isOk1 = _SeekJumpPoint(nextX, y, xDir, 0)
			local isOk2 = _SeekJumpPoint(x, nextY, 0, yDir)
			if isOk1 or isOk2 then
				return {x = x, y = y}
			end
		end

		-- 未寻找到跳点，继续沿着既定的方向前进
		if self:IsWalk(nextX, nextY) then
			return _SeekJumpPoint(nextX, nextY, xDir, yDir)
		end
	end

	while #openList > 0 do
		local current = table.remove(openList, 1)
		openSet[current.key] = nil
		closeList[current.key] = current
		if current.x == goalX and current.y == goalY then
			result.node = current
			return result
		end

		local jumpPoints = {}
		local neighbs = self:GetNeighbors(current) or {}
		for _, v in ipairs(neighbs) do
			local xDir, yDir = MISC.CalcDir(current.x, v.x), MISC.CalcDir(current.y, v.y)
			local point = _SeekJumpPoint(v.x, v.y, xDir, yDir)
			if point then
				table.insert(jumpPoints, point)
			end
		end

		local newG = current.g + 1
		for _, v in ipairs(jumpPoints) do
			local key = MISC.Key(v.x, v.y)
			if not closeList[key] then
				local existV = openSet[key]
				if existV then
					if existV.g > newG then
						existV.g = newG
						existV.f = existV.g + existV.h
						existV.pkey = current.key
					end
				else
					local node = MISC.CreateNode(v.x, v.y)
					node.g, node.h = newG, MISC.CalcH(v.x, goalX, v.y, goalY)
					node.f = node.g + node.h
					node.pkey = current.key
					table.insert(openList, node)
					openSet[node.key] = node
					table.sort(openList, MISC.CompareF)
				end
			end
		end
	end
end

-- 初始化地图
function Mapping:New(m)
	assert(m and table.size(m) == #m, "map arg error")

	local area2key, key2area
	local mapData = MISC.MapStrToTable(m)
	area2key, key2area = MISC.FloodFill(mapData)

	local o = {
		__IsObject = os.time(),
		mapData = mapData,	-- 地图数据 {[x] = {[y] = state, .. }}  注：0：障碍、1：可行走
		area2key = area2key,
		key2area = key2area,
	}
	setmetatable(o, {__index = self})
	return o
end

function Mapping:Test()
	-- start:(10, 16)  ->  goal:(40, 27)
	local m = {
		"############################################################",
		'#..........................................................#',
		'#.............................#............................#',
		'#.............................#............................#',
		'#.............................#............................#',
		'#.............................#............................#',
		'#.............................#............................#',
		'#.............................#............................#',
		'#.............................#............................#',
		'#.............................#............................#',
		'#.............................#............................#',
		'#.............................#............................#',
		'#.............................#............................#',
		'#######.#######################################............#',
		'#....#........#............................................#',
		'#....#........#............................................#',
		'#....##########............................................#',
		'#..........................................................#',
		'#..........................................................#',
		'#..........................................................#',
		'#..........................................................#',
		'#..........................................................#',
		'#...............................##############.............#',
		'#...............................#............#.............#',
		'#...............................#............#.............#',
		'#...............................#....####....#.............#',
		'#...............................#....#.....................#',
		'#...............................##############.............#',
		'#..........................................................#',
		'#..........................................................#',
		'############################################################',
	}

	local mapObj = self:New(m)
	local result = mapObj:Jsp(10, 16, 40, 27)

	local node = result.node
	local openList, openSet, closeList = result.openList, result.openSet, result.closeList
	local path = {}
	while node do
		path[node.x] = node.y
		node = node.pkey and closeList[node.pkey]
	end

	local newM = {}
	for y = 1, #m do
		local p = ""
		for x, byte in utf8.codes(m[y]) do
			local c = utf8.char(byte)
			if path[x] == y then
				p = p .. "L"
			else
				p = p .. c
			end
		end
		table.insert(newM, p)
	end
	for _, v in ipairs(newM) do
		print(v)
	end
end