--[[
battle_move.lua —— 战报战斗·移动层（占格 / 走位 / 突进 / 击退）

解耦边界：
  - 依赖地图层（构造时注入 map，调它的 A*/距离/边界），不依赖内核；
  - 只改单位的 x,y 与占格表，不发任何事件（MOVE 事件由内核收到结果后统一落战报）；
  - 碰撞模型：一格最多一个单位（不可叠位）；突进/击退被挡停在最近空位。

接口：
  mover:put_unit(u) / mover:release_unit(u)        出生占格 / 离场（死亡）释放
  mover:occupied(x, y[, except])                   某格是否被占用（except 一般传自己）
  mover:slot_pos(side, idx)                        转地图层固定坑位，内核出生取位用
  mover:dist(a, b)                                 两单位曼哈顿距离
  mover:move_toward(u, target, max_steps, range)   走位：沿 A* 路径走，距目标 <= range 就停
  mover:dash(u, target)                            突进：跳到目标相邻空位（被占找最近空位）
  mover:knockback(u, target, k)                    击退：沿远离方向一格一格推，撞墙/撞人停
  mover:scan_shape(cx, cy, shape, size)            范围枚举：形状模板平移锚点后收集占格单位（AOE 用）
  位移三兄弟返回 { from={x,y}, to={x,y} }，没动返回 nil（内核据此决定发不发 MOVE 事件）
]]

MoverClass = Class.NewClass("<<battle mover class>>")

local function xykey(x, y)
    return x * 1000 + y
end

function MoverClass:new(map)
    local mover = {
        map = map,          -- 地图层对象：取尺寸/槽位/寻路，移动层除了单位不认识别的
        grid = {},          -- 占格表：格键 -> 单位（一格最多一个；死亡由内核 release 后清空）
        astar_cnt = 0,      -- 统计：寻路调用次数（入口打印，观察绕行频率）
        steps_cnt = 0,      -- 统计：累计位移格数（WALK/DASH/KNOCKBACK 都计入）
    }
    setmetatable(mover, { __index = MoverClass })
    return mover
end

-- 出生占格：内核建好单位、定好出生位后调用
function MoverClass:put_unit(u)
    self.grid[xykey(u.x, u.y)] = u
end

-- 离场释放：死亡时调用（幂等：只有还占着才清）
function MoverClass:release_unit(u)
    local key = xykey(u.x, u.y)
    if self.grid[key] == u then
        self.grid[key] = nil
    end
end

-- 某格是否被占用（except 传自己，用于排除自身占格）
function MoverClass:occupied(x, y, except)
    local u = self.grid[xykey(x, y)]
    if not u then
        return false
    end
    return u ~= except
end

function MoverClass:dist(a, b)
    return self.map:dist(a.x, a.y, b.x, b.y)
end

function MoverClass:slot_pos(side, idx)
    return self.map:slot_pos(side, idx)
end

-- 传送格子（内部统一入口：先释放原格再占新格）；from == to 视为没动返回 nil
function MoverClass:teleport(u, x, y)
    if u.x == x and u.y == y then
        return nil
    end
    local from = { x = u.x, y = u.y }
    local d = self.map:dist(from.x, from.y, x, y)
    self.grid[xykey(u.x, u.y)] = nil
    u.x, u.y = x, y
    self.grid[xykey(u.x, u.y)] = u
    self.steps_cnt = self.steps_cnt + d
    return { from = from, to = { x = u.x, y = u.y } }
end

-- 常态走位：A* 寻路到目标（队友挡路自动绕行），最多走 max_steps 格；
-- 走到距目标 <= range 就停（不贴脸、不多走，与射程判定自然衔接）。
function MoverClass:move_toward(u, target, max_steps, range)
    if max_steps <= 0 then
        return nil
    end
    self.astar_cnt = self.astar_cnt + 1
    local path = self.map:astar(u.x, u.y, target.x, target.y, function(x, y)
        return self:occupied(x, y)
    end)
    if not path or #path == 0 then
        return nil                                    -- 无路可走：原地待命
    end
    local steps = math.min(max_steps, #path - range)  -- 全路径长 - 射程 = 需要走的步数
    if steps <= 0 then
        return nil                                    -- 已够得着，不多走
    end
    local from = { x = u.x, y = u.y }
    for i = 1, steps do
        local cell = path[i]
        self.grid[xykey(u.x, u.y)] = nil
        u.x, u.y = cell.x, cell.y
        self.grid[xykey(u.x, u.y)] = u
    end
    self.steps_cnt = self.steps_cnt + steps
    return { from = from, to = { x = u.x, y = u.y } }
end

-- 突进：跳到目标相邻的格子（目标自己不动）。
-- 理想位 = 目标邻格里离 u 最近的那个（正面突脸）；被占则按(离 u 距离, y, x)顺序找最近空邻格；全占不动。
function MoverClass:dash(u, target)
    if not target.alive then
        return nil
    end
    local cands = self.map:neighbors(target.x, target.y)
    table.sort(cands, function(p, q)
        local dp = self.map:dist(u.x, u.y, p.x, p.y)
        local dq = self.map:dist(u.x, u.y, q.x, q.y)
        if dp ~= dq then
            return dp < dq
        end
        if p.y ~= q.y then
            return p.y < q.y
        end
        return p.x < q.x
    end)
    for _, c in ipairs(cands) do
        if self.map:in_bounds(c.x, c.y) and not self:occupied(c.x, c.y, u) then
            return self:teleport(u, c.x, c.y)         -- 落点可能是自己当前格（已贴脸）→ teleport 判没动
        end
    end
    return nil
end

-- 击退：把 target 沿"远离 u"方向推 k 格；一格一格试，撞墙/撞人停在最后可走格。
function MoverClass:knockback(u, target, k)
    if not target.alive or k <= 0 then
        return nil
    end
    local dx, dy
    if target.x > u.x then
        dx = 1
    elseif target.x < u.x then
        dx = -1
    else
        dx = 0
    end
    if target.y > u.y then
        dy = 1
    elseif target.y < u.y then
        dy = -1
    else
        dy = 0
    end
    local nx, ny, moved = target.x, target.y, false
    for _ = 1, k do
        local cx, cy = nx + dx, ny + dy
        if not self.map:in_bounds(cx, cy) or self:occupied(cx, cy, target) then
            break                                       -- 撞墙/撞人：停在上一格
        end
        nx, ny, moved = cx, cy, true
    end
    if not moved then
        return nil
    end
    return self:teleport(target, nx, ny)
end

-- ===== 范围枚举（AOE）：锚点 + 形状偏移表 -> 占格单位列表 =====
-- 逐偏移平移后查占格表，一格最多一个单位天然不重复；
-- 尸体在上层 damage() 结算时已 release 腾格，枚举结果自然不含死亡单位
function MoverClass:scan_offs(cx, cy, offs)
    local out = {}
    for _, o in ipairs(offs) do
        local x, y = cx + o.x, cy + o.y
        if self.map:in_bounds(x, y) then
            local u = self.grid[xykey(x, y)]
            if u then
                out[#out + 1] = u
            end
        end
    end
    return out
end

-- 形状模板查表在地图层（shape_cells 带缓存），移动层只做"偏移平移 + 占格收集"；
-- 内核只认这一个口，不认识任何形状公式
function MoverClass:scan_shape(cx, cy, shape, size)
    return self:scan_offs(cx, cy, self.map:shape_cells(shape, size))
end

MOVE = {
    MoverClass = MoverClass,
    new = function(map)
        return MoverClass:new(map)
    end,
}