--[[
battle_slot.lua —— 爱琳战斗·槽位层（3排×2列 槽位制空间：排位规则 / 邻域偏移表 / 位移原语）

爱琳诗篇的战斗空间是"槽位制"而非"自由网格"：
  - 每方最多 6 个英雄，编队固定 3 排(rank 0=前排 / 1=中排 / 2=后排) × 2 列(col 0=列1 / 1=列2)，
    通行配置"222"（前2中2后2），站位决定技能对象，玩家只能调站位与出手顺序；
  - 范围伤害的表达力取决于空间粒度：网格版(battle_map.lua)用形状模板（菱形/十字…），
    槽位制用"谓词 + 邻域偏移表"——本质是同一套 SHAPE_CACHE 思路在 6 槽粗粒度空间上的同构退化。
    （面试卖点：aoe 结算复杂度降为 6 槽常数级查表；新增范围只加一行谓词，不碰公式）

解耦边界（与网格版 battle_move.lua 同款约定）：
  - 不认识内核，只改单位的 rank/col 与槽位占位表，不发任何事件（MOVE 事件由内核落战报）；
  - 碰撞模型：一槽最多一个单位；击退/拉扯撞人时与占位者互换（"推挤"：人墙被顶开一格），
    翻越（落到敌方身后）遇占位则原地不动。

接口（全部显式传参，风格与移动层一致，返回位移则给 {from,to}）：
  slot:put_unit(u) / release_unit(u)        出生占槽 / 离场（死亡）释放
  slot:slot_pos(side, idx)                  第 idx 个出生坑位 -> {rank,col}（1..6，前排先填）
  slot:dist(a, b)                           两单位排距 |Δrank|（同排=0，列不影响射程判定）
  slot:basic_target(battle, u)              普攻目标：同排优先（近战打列1、远程打列2），排距蔓延前排优先
  slot:knockback(battle, u, target, k)      击退：目标向后退 k 排（被占则推挤互换，clamp 0..2）
  slot:pull(battle, u, target)              拉扯：目标被拽到中排 rank=1（爱琳"拉扯到战场中央"，列不变）
  slot:land_behind(battle, u, target)       翻越：施法者落到目标同排正对位（爱琳"落到敌方身后"的槽位表达）
  slot:scan_area(battle, u, anchor, aoe_cfg)区域枚举：谓词 + 邻域偏移表（AOE 结算，顺序确定）
]]

SlotClass = Class.NewClass("<<battle slot class>>")

ROWS = 3      -- 每方 3 排：rank 0=前排(接敌线) 1=中排 2=后排（双方编队镜像面对面）
COLS = 2      -- 每排 2 列：col 0=列1 col 1=列2

-- 固定坑位：槽位 1..6 按"前排先填、同排列1先于列2"顺序铺满（爱琳通行 222 配置：前2中2后2）
local SLOT_POS = {
    { rank = 0, col = 0 },   -- 槽位 1 前排·列1
    { rank = 0, col = 1 },   -- 槽位 2 前排·列2
    { rank = 1, col = 0 },   -- 槽位 3 中排·列1
    { rank = 1, col = 1 },   -- 槽位 4 中排·列2
    { rank = 2, col = 0 },   -- 槽位 5 后排·列1
    { rank = 2, col = 1 },   -- 槽位 6 后排·列2
}

local OTHER = { A = "B", B = "A" }

local function occ_key(rank, col)
    return rank * 10 + col
end

function SlotClass:new()
    local slot = {
        rows = ROWS,
        cols = COLS,
        occ = { A = {}, B = {} },   -- 占位表：side -> 槽键 -> 单位（一槽最多一个；死亡经 release 清空）
        move_cnt = 0,               -- 统计：位移次数（击退/拉扯/翻越合计，入口打印观察）
    }
    setmetatable(slot, { __index = SlotClass })
    return slot
end

-- 出生占槽：内核建好单位、按槽位定好 rank/col 后调用
function SlotClass:put_unit(u)
    self.occ[u.side][occ_key(u.rank, u.col)] = u
end

-- 离场释放：死亡时调用（幂等：只有还占着才清）
function SlotClass:release_unit(u)
    local key = occ_key(u.rank, u.col)
    if self.occ[u.side][key] == u then
        self.occ[u.side][key] = nil
    end
end

-- 固定坑位：双方编队镜像面对面，同一 (rank,col) 索引即可互指，无需坐标换算；越界返回 nil
function SlotClass:slot_pos(side, idx)
    local p = SLOT_POS[idx]
    if not p then
        return nil
    end
    return { rank = p.rank, col = p.col }
end

-- 两单位排距：只比排不比列（同排=0 即"贴脸"；爱琳的选敌/射程全部走它）
function SlotClass:dist(a, b)
    return math.abs(a.rank - b.rank)
end

-- ===== 排位普攻规则（爱琳槽位制的核心选敌逻辑） =====
--   1) 同排优先：先抽"列首"——近战(range<=1)打列1(col0)、远程(range>1)打列2(col1)；
--   2) 列首空缺（阵亡/无人）→ 同排另一列；
--   3) 整排打空 → 按排距向外蔓延：同一排距内先更前排(rank-Δ)后更后排(rank+Δ)，前排优先；
--   全程确定性循环（teams 数组=创建序=行动序），无随机。
local function row_candidates(foes, rank, pref_col)
    local out = {}
    for _, c in ipairs(foes) do
        if c.alive and c.rank == rank and c.col == pref_col then
            out[#out + 1] = c
        end
    end
    for _, c in ipairs(foes) do
        if c.alive and c.rank == rank and c.col ~= pref_col then
            out[#out + 1] = c
        end
    end
    return out
end

function SlotClass:basic_target(battle, u)
    local foes = battle.teams[OTHER[u.side]]
    local pref = (u.range or 1) <= 1 and 0 or 1        -- 近战抽列1(col0)、远程抽列2(col1)
    for d = 0, ROWS - 1 do                              -- 排距 0（同排）→ 1 → 2 依次蔓延
        if d == 0 then
            local c = row_candidates(foes, u.rank, pref)
            if c[1] then
                return c[1]
            end
        else
            for _, r in ipairs({ u.rank - d, u.rank + d }) do   -- 同排距内：先更前排、后更后排
                if r >= 0 and r < ROWS then
                    local c = row_candidates(foes, r, pref)
                    if c[1] then
                        return c[1]
                    end
                end
            end
        end
    end
end

-- ===== 位移原语（槽位制：位移即换排/换列，占位表同步维护） =====

-- 槽位移统一入口：改 rank/col + 换占位；落点即现位视为没动返回 nil
local function set_slot(self, u, rank, col)
    if u.rank == rank and u.col == col then
        return
    end
    local from = { rank = u.rank, col = u.col }
    self.occ[u.side][occ_key(u.rank, u.col)] = nil
    u.rank, u.col = rank, col
    self.occ[u.side][occ_key(rank, col)] = u
    self.move_cnt = self.move_cnt + 1
    return { from = from, to = { rank = u.rank, col = u.col } }
end

-- 击退：target 沿"远离施法者"方向退 k 排（双方编队面对面对峙，退向己方后排 = 双方都是 rank+1）。
-- 落点被占则与占位者互换（推挤：人墙被顶开一格）；已在最后一排 / 原地则不动。
function SlotClass:knockback(battle, u, target, k)
    if not target.alive or not k or k <= 0 then
        return
    end
    local nr = math.min(ROWS - 1, target.rank + k)
    if nr == target.rank then
        return                                 -- 撞到自己后排边界：退无可退
    end
    local occupant = self.occ[target.side][occ_key(nr, target.col)]
    if not occupant then
        return set_slot(self, target, nr, target.col)
    end
    -- 推挤：后一格被占 → 与占位者互换（击退效果 = 两单位对调，人墙整体后移一格）
    set_slot(self, occupant, target.rank, target.col)
    return set_slot(self, target, nr, target.col)
end

-- 拉扯：target 被拽到战场中央 = 中排 rank=1（爱琳技能文本"拉扯到战场中央"），列不变；被占则互换；已在中排不动。
function SlotClass:pull(battle, u, target)
    if not target.alive or target.rank == 1 then
        return nil
    end
    local occupant = self.occ[target.side][occ_key(1, target.col)]
    if not occupant then
        return set_slot(self, target, 1, target.col)
    end
    set_slot(self, occupant, target.rank, target.col)
    return set_slot(self, target, 1, target.col)
end

-- 翻越（爱琳"落到敌方身后"）：施法者越过前排、落位与 target 同排正对（rank/col 均对齐 target）。
-- 槽位制下"跨入敌阵"不可表达（单位恒在己方编队内），等价表达 = 与目标同排正对贴脸：
--   落位后施法者的排位 = 目标排位，后续普攻按排位规则直指该排（切后排防线的落位收益）。
-- 落点被己方占则原地不动。
function SlotClass:land_behind(battle, u, target)
    if not target.alive then
        return nil
    end
    if u.rank == target.rank and u.col == target.col then
        return nil                                  -- 已正对贴脸：无需位移
    end
    if self.occ[u.side][occ_key(target.rank, target.col)] then
        return nil                                  -- 落点被己方占：原地不动
    end
    return set_slot(self, u, target.rank, target.col)
end

-- ===== 区域枚举（AOE）：谓词 + 邻域偏移表（网格版 SHAPE_CACHE 的槽位同构退化） =====
--   shape "all"     敌方全体（6 槽逐格枚举；爱琳"全体 250%"）
--   shape "front"   敌方前 depth 排（depth 默认 1 = 敌前排；爱琳"前方范围"= 压线伤害）
--   shape "back"    敌方后排（rank=2；刺客/射手切脆皮的射程）
--   shape "row"     锚点所在整排（目标同排两列）
--   shape "splash"  锚点附近溅射：同排两列 + 上下排同列（偏移表缓存；爱丽丝式"目标附近范围"）
--   枚举按 rank/col 显式顺序，天然确定（技能层还会按 battle.order 重排保证出场序）。
--   区域落点阵营：all/front/back 打在敌方编队上，row/splash 沿锚点所在编队展开。
local NEIGHBOR_CACHE = {}        -- key = shape -> 偏移数组 {{dr=.., dc=..}, ...}（首次生成后缓存常驻）

local function build_neighbor(shape)
    if shape == "splash" then
        return { { dr = 0, dc = 0 }, { dr = 0, dc = 1 }, { dr = -1, dc = 0 }, { dr = 1, dc = 0 } }
    end
    return {}
end

function SlotClass:neighbor_cells(shape)
    local t = NEIGHBOR_CACHE[shape]
    if not t then
        t = build_neighbor(shape)
        NEIGHBOR_CACHE[shape] = t
    end
    return t
end

function SlotClass:scan_area(battle, u, anchor, aoe_cfg)
    aoe_cfg = aoe_cfg or {}
    anchor = anchor or u
    local shape = aoe_cfg.shape or "row"
    local host = (shape == "all" or shape == "front" or shape == "back") and OTHER[u.side] or anchor.side
    local out = {}
    if shape == "all" then                                   -- 敌方全体
        for r = 0, ROWS - 1 do
            for c = 0, COLS - 1 do
                local t = self.occ[host][occ_key(r, c)]
                if t then
                    out[#out + 1] = t
                end
            end
        end
    elseif shape == "front" then                             -- 敌方前 depth 排
        local depth = aoe_cfg.depth or 1
        for r = 0, math.min(ROWS - 1, depth - 1) do
            for c = 0, COLS - 1 do
                local t = self.occ[host][occ_key(r, c)]
                if t then
                    out[#out + 1] = t
                end
            end
        end
    elseif shape == "back" then                              -- 敌方后排
        for c = 0, COLS - 1 do
            local t = self.occ[host][occ_key(ROWS - 1, c)]
            if t then
                out[#out + 1] = t
            end
        end
    elseif shape == "row" then                               -- 锚点整排
        for c = 0, COLS - 1 do
            local t = self.occ[host][occ_key(anchor.rank, c)]
            if t then
                out[#out + 1] = t
            end
        end
    elseif shape == "splash" then                            -- 锚点附近：偏移表查表（含自身）
        for _, o in ipairs(self:neighbor_cells("splash")) do
            local r = math.min(math.max(anchor.rank + o.dr, 0), ROWS - 1)
            local c = math.min(math.max(anchor.col + o.dc, 0), COLS - 1)
            local t = self.occ[host][occ_key(r, c)]
            if t then
                out[#out + 1] = t
            end
        end
    end
    return out
end

SLOT = {
    ROWS = ROWS,
    COLS = COLS,
    SlotClass = SlotClass,
    new = function()
        return SlotClass:new()
    end,
}