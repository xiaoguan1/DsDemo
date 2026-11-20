--[[
battle_map.lua —— 战报战斗·地图层（纯静态：尺寸 / 槽位 / 边界 / 距离 / A* 寻路）

解耦边界：
  - 不认识"单位"，没有占格概念，只回答"格子"问题；
  - 某格能不能走由调用方（移动层）注入 occupied 函数判定；
  - 换地图（尺寸/坑位/寻路算法）只改本文件，内核与内容层零改动。

地图：50 长(x) × 30 宽(y)，x∈1..50、y∈1..30。
站位：每方最多 5 个英雄，坑位固定（前排 3 + 后排 2）；
  A 在左（x 小），B 镜像在右（x = W + 1 - x，y 不变）；
  不足 5 人时按槽位 1..N 顺序取位：槽位 1..3 前排、4..5 后排（谁站哪由入口按 lineup 顺序分配）。
距离：曼哈顿距离 |dx| + |dy|（与 4 方向走路步数一致，range=1 即 4 邻接）。
寻路：A* 4 方向网格；f 相同按插入序领先（确定性）；目标格允许被占（目标自己站在那）。
形状模板：diamond(菱)/square(方)/cross(十字) 由 shape+size 查表生成并缓存（AOE 结算零公式）。
]]

MapClass = Class.NewClass("<<battle map class>>")

MAP_W = 50      -- 战场长（x 轴）
MAP_H = 30      -- 战场宽（y 轴）

-- 每方 5 个固定坑位（相对 A 侧坐标）：槽位 1..3 前排、4..5 后排
local SLOT_POS = {
    { x = 16, y = 9  },     -- 槽位 1 前排上
    { x = 16, y = 15 },     -- 槽位 2 前排中
    { x = 16, y = 21 },     -- 槽位 3 前排下
    { x = 11, y = 13 },     -- 槽位 4 后排上（错开一格，不堵同列）
    { x = 11, y = 17 },     -- 槽位 5 后排下
}

-- 4 方向邻居顺序固定（左/右/上/下）：A* 展开顺序确定，保障同 seed 战报复现
local DIRS = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }

function MapClass:new(w, h)
    local map = { w = w or MAP_W, h = h or MAP_H }
    setmetatable(map, { __index = MapClass })
    return map
end

-- 边界判定
function MapClass:in_bounds(x, y)
    return x >= 1 and x <= self.w and y >= 1 and y <= self.h
end

-- 越界钳制（预留：部分玩法允许贴边走）
function MapClass:clamp(x, y)
    return math.min(math.max(x, 1), self.w), math.min(math.max(y, 1), self.h)
end

-- 两格曼哈顿距离：走路步数下限，射程/选敌的 distance 全部走它
function MapClass:dist(ax, ay, bx, by)
    return math.abs(ax - bx) + math.abs(ay - by)
end

-- 固定坑位：每方 5 个；B 侧 x 镜像（y 不变）。slot_idx 越界返回 nil（供判重/守卫）
function MapClass:slot_pos(side, slot_idx)
    local p = SLOT_POS[slot_idx]
    if not p then
        return nil
    end
    if side == "B" then
        return { x = self.w + 1 - p.x, y = p.y }
    end
    return { x = p.x, y = p.y }
end

-- 4 方向邻居（不滤边界，由调用方自行判定）
function MapClass:neighbors(x, y)
    local out = {}
    for _, d in ipairs(DIRS) do
        out[#out + 1] = { x = x + d[1], y = y + d[2] }
    end
    return out
end

-- A* 4 方向网格寻路：
--   occupied = function(x, y) 返回 true 表示不可通行（目标格豁免，允许目标自己占着）
--   返回 { {x,y}, ... } 不含起点、含终点；不可达返回 nil
--   确定性：open 表每次取全局 f 最小；f 相同时取先插入者（严格 < 扫描，天然稳定）
function MapClass:astar(sx, sy, tx, ty, occupied)
    if not self:in_bounds(sx, sy) or not self:in_bounds(tx, ty) then
        return nil
    end
    local start_k, goal_k = sx * 1000 + sy, tx * 1000 + ty
    if start_k == goal_k then
        return {}   -- 已在目标格
    end
    local g_cost, came, closed = {}, {}, {}
    local open = { { x = sx, y = sy, k = start_k, f = self:dist(sx, sy, tx, ty) } }
    g_cost[start_k] = 0
    while #open > 0 do
        local bi = 1
        for i = 2, #open do
            if open[i].f < open[bi].f then
                bi = i
            end
        end
        local cur = table.remove(open, bi)
        if cur.k == goal_k then
            local rev = {}
            local ck = cur.k
            while ck ~= start_k do
                rev[#rev + 1] = { x = math.floor(ck / 1000), y = ck % 1000 }
                ck = came[ck]
            end
            local path = {}
            for i = #rev, 1, -1 do
                path[#path + 1] = rev[i]
            end
            return path
        end
        closed[cur.k] = true
        for _, nb in ipairs(self:neighbors(cur.x, cur.y)) do
            if self:in_bounds(nb.x, nb.y) then
                local nk = nb.x * 1000 + nb.y
                local blocked = occupied and occupied(nb.x, nb.y) and nk ~= goal_k
                if not closed[nk] and not blocked then
                    local ng = g_cost[cur.k] + 1
                    local old = g_cost[nk]
                    if not old or ng < old then
                        g_cost[nk] = ng
                        came[nk] = cur.k
                        local nf = ng + self:dist(nb.x, nb.y, tx, ty)
                        local found = false
                        for _, o in ipairs(open) do
                            if o.k == nk then
                                o.f = nf
                                found = true
                                break
                            end
                        end
                        if not found then
                            open[#open + 1] = { x = nb.x, y = nb.y, k = nk, f = nf }
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- ===== 形状模板（AOE 范围）：策划只配 shape+size 两字段，运行时纯查表、结算路径零公式 =====
--   diamond  菱形：曼哈顿距离 |dx|+|dy| <= size（含中心格 0,0）
--   square   正方形：以中心为锚的外接框，边长 2*size+1（含中心格）
--   cross    十字：中心整行 + 中心整列（含中心格）
-- 生成顺序固定：dx 外循环(小->大)、dy 内循环；偏移表首次生成后缓存常驻
local SHAPE_CACHE = {}                                  -- key = "shape_size" -> 偏移数组 {{x=dx,y=dy},...}

local function build_shape(shape, size)
    local cells = {}
    for dx = -size, size do
        for dy = -size, size do
            local keep = false
            if shape == "diamond" then
                keep = (math.abs(dx) + math.abs(dy) <= size)
            elseif shape == "square" then
                keep = true
            elseif shape == "cross" then
                keep = (dx == 0 or dy == 0)
            end
            if keep then
                cells[#cells + 1] = { x = dx, y = dy }
            end
        end
    end
    return cells
end

-- 查形状偏移表（带缓存）：同 shape+size 只有首次生成花一次双重循环，之后纯查表
function MapClass:shape_cells(shape, size)
    local key = shape .. "_" .. size
    local t = SHAPE_CACHE[key]
    if not t then
        t = build_shape(shape, size)
        SHAPE_CACHE[key] = t
    end
    return t
end

MAP = {
    W = MAP_W,
    H = MAP_H,
    MapClass = MapClass,
    new = function(w, h)
        return MapClass:new(w, h)
    end,
}