local table = table

-- 四边形的方向配置
DIRECTION_4 = {
	{x = 0, y = 1}, {x = 0, y = -1}, -- 上、下
	{x = -1, y = 0}, {x = 1, y = 0}, -- 左、右
	{x = 1, y = 1}, {x = 1, y = -1}, -- 右上、右下
	{x = -1, y = 1}, {x = -1, y = -1}, -- 左上、左下
}
assert(#DIRECTION_4 == table.size(DIRECTION_4))

-- 坐标位置的特性
POS_STATE0 = 0	-- 障碍
POS_STATE1 = 1	-- 正常可行走
local COLORS = { POS_STATE0, POS_STATE1, }

local BYTE_SIZE = 8
function Key(x, y)
	return x << BYTE_SIZE | y
end
function RKey(key)
	local x = key >> BYTE_SIZE
	local y = key ~ (x << BYTE_SIZE)
	return x, y
end

function CreateNode(x, y)
	assert(x and y)
	return {
		x = x,
		y = y,
		key = Key(x, y),
		pkey = nil, -- 父节点的key值
		h = 0,
		g = 0,
		f = 0,
	}
end

-- 判断父坐标p 和 子坐标s 的移动方向
function CalcDir(p, s)
	assert(p and s)
	local diff = s - p
	if diff > 0 then
		-- 前进
		return 1
	elseif diff < 0 then
		-- 后退
		return -1
	end
	return 0
end

-- 预估值（曼哈顿距离）
function CalcH(x, y, goalX, goalY)
	return math.abs(goalX - x) + math.abs(goalY - y)
end

function CompareF(p1, p2)
	if p1.f < p2.f then
		return true
	elseif p1.f == p2.f and p1.g < p2.g then
		return true
	end
end

-- 洪水填充算法(目的：划分地图区域，处理死路问题！)
function FloodFill(mapData)
	local area2key, key2area = {}, {}
	if table.empty(mapData or {}) then
		return area2key, key2area
	end

	mapData = table.deepcopy(mapData)
	local maxX = #mapData
	local maxY = #mapData[maxX]
	local maxDeep = maxX * maxY	-- 最大深度

	-- 深度探索递归方法（注意：如果地图极大，有可能栈溢出）
	local function dfs(areaNo, areaList, x, y, ocolor, ncolor, deep)
		if not (1 <= x and x <= maxX and 1 <= y and y <= maxY) then
			return
		end
		if not mapData[x][y] or mapData[x][y] ~= ocolor then
			return
		end
		if deep > maxDeep then
			error("loop count too deep!")
		end

		deep = deep + 1
		mapData[x][y] = ncolor

		local key = Key(x, y)
		areaList[key] = ocolor
		key2area[key] = areaNo
		for _, v in ipairs(DIRECTION_4) do
			dfs(areaNo, areaList, x + v.x, y + v.y, ocolor, ncolor, deep)
		end
	end

	local areaNo = 1
	for _, color in pairs(COLORS) do
		for x, yList in ipairs(mapData) do
			for y, state in ipairs(yList) do
				if state == color then
					area2key[areaNo] = area2key[areaNo] or {}
					dfs(areaNo, area2key[areaNo], x,  y, color, tostring(color), 1)
					areaNo = areaNo + 1
				end
			end
		end
	end

	return area2key, key2area
end

function MapStrToTable(mapData)
	local data = {}
	for y = 1, #mapData do
		for x, byte in utf8.codes(mapData[y]) do
			local c = utf8.char(byte)
			local state = POS_STATE1
			if c == "#" then
				state = POS_STATE0
			end
			data[x] = data[x] or {}
			data[x][y] = state
		end
	end
	return data
end

-- 输出路径
function PrintPath(closeList, node)
	local path = ""
	while node do
		path = path .. string.format("(%s, %s) <-", node.x, node.y)
		node = node.pkey and closeList[node.pkey]
	end
	print(path)
end

