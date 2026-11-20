-- https://blog.csdn.net/mkr67n/article/details/106031055

DStarLite = {}

-- D* Lite算法Lua实现
local DStarLite = {}
DStarLite.__index = DStarLite

--== 优先队列实现（最小堆）==--
local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

function PriorityQueue.new()
    return setmetatable({
        heap = {},
        indices = {}  -- 快速查找表
    }, PriorityQueue)
end

function PriorityQueue:insert(node, key1, key2)
    if self.indices[node] then self:remove(node) end
    local entry = { node = node, key = { key1, key2 } }
    table.insert(self.heap, entry)
    self.indices[node] = #self.heap
    self:_siftUp(#self.heap)
end

function PriorityQueue:pop()
    if #self.heap == 0 then return nil end
    local min = self.heap[1]
    self:_swap(1, #self.heap)
    self.heap[#self.heap] = nil
    self.indices[min.node] = nil
    self:_siftDown(1)
    return min.node, min.key[1], min.key[2]
end

function PriorityQueue:_siftUp(index)
    while index > 1 do
        local parent = math.floor(index / 2)
        if self:_compare(index, parent) then
            self:_swap(index, parent)
            index = parent
        else
            break
        end
    end
end

function PriorityQueue:_siftDown(index)
    local size = #self.heap
    while true do
        local left = 2 * index
        local right = 2 * index + 1
        local smallest = index
        
        if left <= size and self:_compare(left, smallest) then
            smallest = left
        end
        if right <= size and self:_compare(right, smallest) then
            smallest = right
        end
        if smallest == index then break end
        self:_swap(index, smallest)
        index = smallest
    end
end

function PriorityQueue:_compare(a, b)
    local keyA = self.heap[a].key
    local keyB = self.heap[b].key
    return keyA[1] < keyB[1] or (keyA[1] == keyB[1] and keyA[2] < keyB[2])
end

function PriorityQueue:_swap(i, j)
    self.heap[i], self.heap[j] = self.heap[j], self.heap[i]
    self.indices[self.heap[i].node] = i
    self.indices[self.heap[j].node] = j
end

--== D* Lite核心实现 ==--
function DStarLite.new(map, start, goal)
    local self = setmetatable({
        map = map,        -- 二维网格地图（0=可行走, 1=障碍）
        U = PriorityQueue.new(),
        km = 0,           -- 路径修正偏移量
        nodes = {},       -- 节点缓存
        start = { x = start.x, y = start.y },
        goal = { x = goal.x, y = goal.y },
        last = nil        -- 最后访问节点
    }, DStarLite)

    -- 初始化目标节点
    local goalNode = self:_getNode(goal.x, goal.y)
    goalNode.rhs = 0
    self.U:insert(goalNode, self:_calculateKey(goalNode))

    return self
end

function DStarLite:_getNode(x, y)
    if not self.nodes[y] then self.nodes[y] = {} end
    if not self.nodes[y][x] then
        self.nodes[y][x] = {
            x = x, y = y,
            g = math.huge,
            rhs = math.huge
        }
    end
    return self.nodes[y][x]
end

function DStarLite:_calculateKey(node)
    local minVal = math.min(node.g, node.rhs)
    return {
        minVal + self:_heuristic(self.start, node) + self.km,
        minVal
    }
end

function DStarLite:_heuristic(a, b)
    -- 曼哈顿距离（适合4方向移动）
    return math.abs(a.x - b.x) + math.abs(a.y - b.y)
end

function DStarLite:_getNeighbors(node)
    local neighbors = {}
    for dx = -1, 1 do
        for dy = -1, 1 do
            if not (dx == 0 and dy == 0) then
                local x = node.x + dx
                local y = node.y + dy
                if self:_isValidPosition(x, y) then
                    table.insert(neighbors, self:_getNode(x, y))
                end
            end
        end
    end
    return neighbors
end

function DStarLite:_isValidPosition(x, y)
    return y >= 1 and y <= #self.map 
        and x >= 1 and x <= #self.map[y] 
        and self.map[y][x] == 0
end

function DStarLite:computeShortestPath()
    while true do
        local u, k1, k2 = self.U:pop()
        if not u then break end

        local startNode = self:_getNode(self.start.x, self.start.y)
        local startKey = self:_calculateKey(startNode)

        -- 终止条件：队列顶部的键不小于起点键
        if (k1 > startKey[1]) or (k1 == startKey[1] and k2 > startKey[2]) then
            self.U:insert(u, k1, k2)
            break
        end

        if u.g > u.rhs then
            u.g = u.rhs
            for _, s in ipairs(self:_getNeighbors(u)) do
                if s ~= u then
                    if s.rhs > u.g + self:_cost(s, u) then
                        s.rhs = u.g + self:_cost(s, u)
                        self.U:insert(s, self:_calculateKey(s))
                    end
                end
            end
        else
            u.g = math.huge
            for _, s in ipairs(self:_getNeighbors(u)) do
                if s.rhs == u.g + self:_cost(s, u) then
                    if s ~= self:_getNode(self.goal.x, self.goal.y) then
                        s.rhs = math.huge
                    end
                    self.U:insert(s, self:_calculateKey(s))
                end
            end
            self.U:insert(u, self:_calculateKey(u))
        end
    end
end

function DStarLite:_cost(a, b)
    -- 计算移动成本（对角线距离为√2≈1.414）
    local dx = math.abs(a.x - b.x)
    local dy = math.abs(a.y - b.y)
    if dx + dy == 1 then return 1 end  -- 相邻
    if dx == 1 and dy == 1 then return 1.414 end  -- 对角
    return math.huge
end

--== 路径追踪 ==--
function DStarLite:getPath()
    local path = {}
    local current = self:_getNode(self.start.x, self.start.y)
    
    while current.x ~= self.goal.x or current.y ~= self.goal.y do
        table.insert(path, { x = current.x, y = current.y })
        
        local minCost = math.huge
        local best = nil
        for _, neighbor in ipairs(self:_getNeighbors(current)) do
            local total = neighbor.g + self:_cost(current, neighbor)
            if total < minCost then
                minCost = total
                best = neighbor
            end
        end
        
        if not best then return nil end  -- 无可用路径
        current = best
    end
    table.insert(path, { x = self.goal.x, y = self.goal.y })
    return path
end

--== 使用示例 ==--
local map = {
    {0,0,0,0,0},
    {0,1,1,1,0},
    {0,0,0,0,0},
}

local dstar = DStarLite.new(
    map,
    {x = 1, y = 1},  -- 起点
    {x = 5, y = 3}   -- 终点
)

-- 首次计算路径
dstar:computeShortestPath()
local path = dstar:getPath()
print("初始路径:")
for _, p in ipairs(path) do
    print("("..p.x..","..p.y..")")
end

-- 动态更新障碍物
print("\n更新障碍物后:")
map[2][3] = 1  -- 添加新障碍物
dstar.km = dstar.km + dstar:_heuristic(dstar.start, dstar.goal)
dstar:computeShortestPath()
path = dstar:getPath()
for _, p in ipairs(path) do
    print("("..p.x..","..p.y..")")
end



----------------------------------------------------




-- D* Lite算法Lua实现
local DStarLite = {}

-- 优先队列实现（最小堆）
local function PriorityQueue()
    local heap = {}
    return {
        insert = function(self, node, key)
            table.insert(heap, {node=node, key=key})
            local i = #heap
            while i > 1 do
                local parent = math.floor(i/2)
                if heap[parent].key < heap[i].key then break end
                heap[parent], heap[i] = heap[i], heap[parent]
                i = parent
            end
        end,
        pop = function(self)
            if #heap == 0 then return nil end
            local min = heap[1]
            heap[1] = heap[#heap]
            heap[#heap] = nil
            local i = 1
            while true do
                local left = 2*i
                local right = 2*i+1
                local smallest = i
                if left <= #heap and heap[left].key < heap[smallest].key then
                    smallest = left
                end
                if right <= #heap and heap[right].key < heap[smallest].key then
                    smallest = right
                end
                if smallest == i then break end
                heap[i], heap[smallest] = heap[smallest], heap[i]
                i = smallest
            end
            return min.node, min.key
        end,
        isEmpty = function(self)
            return #heap == 0
        end
    }
end

-- 节点构造函数
local function Node(x, y)
    return {
        x = x, y = y,
        g = math.huge,    -- 到目标的实际代价
        rhs = math.huge,   -- 基于邻居的最小代价
    }
end

-- 初始化D* Lite
function DStarLite:new(map, start, goal)
    local obj = {
        map = map,        -- 二维网格地图（0=可行走, 1=障碍）
        U = PriorityQueue(),
        km = 0,           -- 路径修正偏移量
        nodes = {},       -- 节点缓存
        start = start,    -- 起点{x,y}
        goal = goal,      -- 终点{x,y}
    }
    
    -- 初始化目标节点
    local goalNode = Node(goal.x, goal.y)
    goalNode.rhs = 0
    obj.nodes[goal.y] = obj.nodes[goal.y] or {}
    obj.nodes[goal.y][goal.x] = goalNode
    obj.U:insert(goalNode, self:calculateKey(goalNode))
    
    return setmetatable(obj, {__index = DStarLite})
end

-- 计算节点的优先级键值
function DStarLite:calculateKey(node)
    local k1 = math.min(node.g, node.rhs) + self:heuristic(self.start, node) + self.km
    local k2 = math.min(node.g, node.rhs)
    return {k1, k2}
end

-- 启发式函数（曼哈顿距离）
function DStarLite:heuristic(a, b)
    return math.abs(a.x - b.x) + math.abs(a.y - b.y)
end

-- 获取相邻节点
function DStarLite:getNeighbors(node)
    local neighbors = {}
    for dx=-1,1 do
        for dy=-1,1 do
            if not (dx == 0 and dy == 0) then
                local x = node.x + dx
                local y = node.y + dy
                if self.map[y] and self.map[y][x] == 0 then
                    table.insert(neighbors, {x=x, y=y})
                end
            end
        end
    end
    return neighbors
end

-- 更新节点并加入队列
function DStarLite:updateNode(u)
    if u.g ~= u.rhs then
        self.U:insert(u, self:calculateKey(u))
    else
        -- 从队列中移除（此处简化处理）
    end
end

-- 主计算循环
function DStarLite:computeShortestPath()
    while true do
        local u = self.U:pop()
        if not u then break end
        
        local key = self:calculateKey(u)
        local currentKey = self:calculateKey(self.nodes[self.start.y][self.start.x])
        
        if key[1] > currentKey[1] or (key[1] == currentKey[1] and key[2] > currentKey[2]) then
            self.U:insert(u, key)
            break
        end
        
        if u.g > u.rhs then
            u.g = u.rhs
            for _, s in ipairs(self:getNeighbors(u)) do
                local sNode = self:getNode(s.x, s.y)
                if sNode.rhs > u.g + 1 then
                    sNode.rhs = u.g + 1
                    self:updateNode(sNode)
                end
            end
        else
            u.g = math.huge
            for _, s in ipairs(self:getNeighbors(u)) do
                local sNode = self:getNode(s.x, s.y)
                if sNode.rhs == u.g + 1 then
                    sNode.rhs = math.huge
                    self:updateNode(sNode)
                end
            end
            self:updateNode(u)
        end
    end
end

-- 示例用法
local map = {
    {0, 0, 0, 0, 0},
    {0, 1, 1, 1, 0},
    {0, 0, 0, 0, 0},
}

local dstar = DStarLite:new(
    map,
    {x=1, y=1},  -- 起点
    {x=5, y=3}   -- 终点
)

dstar:computeShortestPath()

-- 打印路径
local current = dstar.start
while current.x ~= dstar.goal.x or current.y ~= dstar.goal.y do
    local neighbors = dstar:getNeighbors(dstar:getNode(current.x, current.y))
    local nextNode = nil
    local minCost = math.huge
    for _, n in ipairs(neighbors) do
        local node = dstar:getNode(n.x, n.y)
        if node.g < minCost then
            minCost = node.g
            nextNode = n
        end
    end
    if not nextNode then
        print("No path found!")
        break
    end
    print(string.format("Move to (%d, %d)", nextNode.x, nextNode.y))
    current = nextNode
end







------------------------
-- D* Lite算法是一种增量启发式搜索算法，用于实时更新图中的最短路径
-- 参考论文：Koenig and Likhachev - http://idm-lab.org/bib/abstracts/papers/aaai02b.pdf

local math_min = math.min
local math_huge = math.huge
local table_insert = table.insert
local table_remove = table.remove

local function approx(f1, f2)
    return f1 == f2
    -- return math.abs(f1 - f2) < 1e-5
end

-- 节点类
local Node = {}
Node.__index = Node

function Node.new(data, cost_func, heuristic_func)
    local self = setmetatable({}, Node)
    self.Data = data
    self.Cost = cost_func
    self.Heuristic = heuristic_func
    self.Neighbors = {}
    self.G = math_huge
    self.RHS = math_huge
    return self
end

function Node:GEqualRHS()
    return approx(self.G, self.RHS)
end

-- 优先队列实现（最小堆）
local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

function PriorityQueue.new(compare_func)
    local self = setmetatable({}, PriorityQueue)
    self.heap = {}
    self.compare = compare_func
    return self
end

function PriorityQueue:push(item)
    table_insert(self.heap, item)
    local i = #self.heap
    while i > 1 do
        local parent = math.floor(i/2)
        if self.compare(self.heap[i], self.heap[parent]) then
            self.heap[i], self.heap[parent] = self.heap[parent], self.heap[i]
            i = parent
        else
            break
        end
    end
end

function PriorityQueue:pop()
    if #self.heap == 0 then return nil end
    local item = self.heap[1]
    self.heap[1] = self.heap[#self.heap]
    table_remove(self.heap)
    local i = 1
    while true do
        local left = 2*i
        local right = 2*i+1
        local smallest = i
        if left <= #self.heap and self.compare(self.heap[left], self.heap[smallest]) then
            smallest = left
        end
        if right <= #self.heap and self.compare(self.heap[right], self.heap[smallest]) then
            smallest = right
        end
        if smallest ~= i then
            self.heap[i], self.heap[smallest] = self.heap[smallest], self.heap[i]
            i = smallest
        else
            break
        end
    end
    return item
end

function PriorityQueue:peek()
    return self.heap[1]
end

function PriorityQueue:size()
    return #self.heap
end

-- D* Lite 主类
local DStarLite = {}
DStarLite.__index = DStarLite

function DStarLite.new(start_node, goal_node, all_nodes)
    local self = setmetatable({}, DStarLite)
    self.start = start_node
    self.goal = goal_node
    self.all_nodes = all_nodes
    self.km = 0
    self.open_set = PriorityQueue.new(function(a, b)
        if approx(a.k1, b.k1) then
            return a.k2 < b.k2
        end
        return a.k1 < b.k1
    end)
    self.lookups = {}
    return self
end

function DStarLite:calculate_key(node)
    local min_val = math_min(node.G, node.RHS)
    return {
        k1 = min_val + node.Heuristic(node, self.start) + self.km,
        k2 = min_val,
        node = node
    }
end

function DStarLite:update_vertex(node)
    local key = self:calculate_key(node)
    local in_queue = self.lookups[node]

    if not node:GEqualRHS() and not in_queue then
        self.open_set:push(key)
        self.lookups[node] = key
    elseif in_queue then
        if key.k1 < in_queue.k1 or (approx(key.k1, in_queue.k1) and key.k2 < in_queue.k2) then
            self.lookups[node] = nil
            self.open_set:push(key)
            self.lookups[node] = key
        end
        if node:GEqualRHS() then
            self.lookups[node] = nil
        end
    end
end

function DStarLite:predecessors(node)
    return node.Neighbors -- 根据实际需求可能需要更复杂的实现
end

function DStarLite:successors(node)
    return node.Neighbors -- 根据实际需求可能需要更复杂的实现
end

function DStarLite:compute_shortest_path()
    local max_steps = 1000
    while self.open_set:size() > 0 do
        if max_steps <= 0 then
            print("ComputeShortestPath error: max steps exceeded.")
            break
        end
        max_steps = max_steps - 1

        local current = self.open_set:pop()
        self.lookups[current.node] = nil

        local key = self:calculate_key(current.node)
        if key.k1 < current.k1 or (approx(key.k1, current.k1) and key.k2 < current.k2) then
            self.open_set:push(key)
            self.lookups[current.node] = key
        elseif current.node.G > current.node.RHS then
            current.node.G = current.node.RHS
            for _, s in ipairs(self:predecessors(current.node)) do
                if s ~= self.goal then
                    s.RHS = math_min(s.RHS, s.Cost(s, current.node) + current.node.G)
                end
                self:update_vertex(s)
            end
        else
            local g_old = current.node.G
            current.node.G = math_huge
            local nodes = self:predecessors(current.node)
            table_insert(nodes, current.node)
            for _, s in ipairs(nodes) do
                if approx(s.RHS, s.Cost(s, current.node) + g_old) then
                    if s ~= self.goal then
                        s.RHS = math_huge
                    end
                    for _, s_prime in ipairs(self:successors(s)) do
                        s.RHS = math_min(s.RHS, s.Cost(s, s_prime) + s_prime.G)
                    end
                end
                self:update_vertex(s)
            end
        end
    end
    self.start.G = self.start.RHS
end

function DStarLite:initialize()
    self.open_set = PriorityQueue.new(function(a, b)
        if approx(a.k1, b.k1) then
            return a.k2 < b.k2
        end
        return a.k1 < b.k1
    end)
    self.lookups = {}
    self.km = 0

    for _, node in ipairs(self.all_nodes) do
        node.G = math_huge
        node.RHS = math_huge
    end

    self.goal.RHS = 0
    local key = self:calculate_key(self.goal)
    self.open_set:push(key)
    self.lookups[self.goal] = key
end

function DStarLite:recalculate_node(node)
    self.km = self.km + self.start.Heuristic(self.start, node)
    local connected = {}
    for _, s in ipairs(self:successors(node)) do table_insert(connected, s) end
    for _, s in ipairs(self:predecessors(node)) do table_insert(connected, s) end

    for _, s in ipairs(connected) do
        if s ~= self.start then
            s.RHS = math_min(s.RHS, s.Cost(s, node) + node.G)
        end
        self:update_vertex(s)
    end
    self:update_vertex(node)
    self:compute_shortest_path()
end

function DStarLite:get_path()
    local path = {self.start}
    -- 根据实际需求实现路径重建逻辑
    return path
end

return {
    Node = Node,
    DStarLite = DStarLite
}