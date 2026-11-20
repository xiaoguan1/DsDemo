--[[
battle_skill.lua —— 战报战斗·技能层（技能机制：怒气槽 / 技能槽CD / 施放执行 / 目标选择）

分层定位（内核 <- 技能层 <- 内容层）：
  - 只依赖 battle 对象暴露的原语（battle:event/emit/damage/...、battle.teams/order/units/skills、
    battle.mover/hz），不认识内核 tick 循环与地图/移动层的实现细节；
  - 不认识任何英雄/技能数值：技能定义（数值 + on_cast 效果脚本）在内容层 SKILLS，
    本层只回答"能不能放 / 对谁放 / 放出去收什么尾（扣怒气、上CD、落CAST事件、调效果脚本）"；
  - 经 cfg.skillsys 注入内核（与 cfg.mover 同款约定）：内核 tick 只回调 tick_cds/cast，
    内容层走内核薄路由（battle:pick/pick_area/skill_ready/castable_skill）访问本层。

接口（全部显式传 battle 作第一参数，风格与内核模块局部函数一致）：
  SKILL.pick(battle, u, rule)                 选敌原语：nearest/lowest_hp/highest_atk/ally_lowest_hp
  SKILL.pick_area(battle, u, target, aoe_cfg) 范围选区（AOE）：形状模板 + filter + 出场序排序
  SKILL.skill_ready(battle, u, sid)           怒气门槛 + 独立 CD 是否就绪
  SKILL.castable_skill(battle, u)             按 u.skills 顺序找第一个可放技能（顺序 = 优先级）
  SKILL.cast(battle, u, sid, target)          执行施放：扣怒气 / 上 CD / 落 CAST 事件 / 调 on_cast
  SKILL.tick_cds(battle, u)                   每 tick 递减该单位所有技能剩余 CD（内核 tick 循环回调）

新技能机制（新选敌规则、新施放条件等）只改本文件；新技能数值与效果脚本仍只在内容层。
]]

local RAGE_MAX = 100                                 -- 怒气槽上限：技能消耗怒气，攒怒/上限语义由内容层解释

local other_side = { A = "B", B = "A" }

-- 对侧存活单位（选敌原语内部用；走位/普攻的选目标在内核 nearest_enemy，属行为层设施）
local function enemies(battle, side)
    local out = {}
    for _, u in ipairs(battle.teams[other_side[side]]) do
        if u.alive then
            out[#out + 1] = u
        end
    end
    return out
end

-- 选敌原语：新技能要新选敌规则时，给本文件加一个分支即可（技能层低频扩展，全局共享）
local function pick(battle, u, rule)
    if rule == "ally_lowest_hp" then                            -- 治疗系：选友方最低血量
        local best = nil
        for _, e in ipairs(battle.teams[u.side]) do
            if e.alive and (not best or e.hp < best.hp) then
                best = e
            end
        end
        return best
    end
    local best = nil
    for _, e in ipairs(enemies(battle, u.side)) do
        local better = (best == nil)
        if not better then
            if rule == "nearest" then
                better = battle:dist(u, e) < battle:dist(u, best)
            elseif rule == "lowest_hp" then
                better = e.hp < best.hp
            elseif rule == "highest_atk" then
                better = e.atk > best.atk
            end
        end
        if better then
            best = e
        end
    end
    return best
end

-- 范围选区原语（AOE 结算通用）：aoe_cfg = { shape, size, center, filter }
--   shape  : "diamond" | "square" | "cross"（形状模板在移动层查表，本层不认识生成公式）
--   size   : 尺寸（菱形=曼哈顿半径 / 正方形=半边长 / 十字=臂长）
--   center : "self"（以释放者为中心）| "target"（以选中目标为中心），默认 "self"
--   filter : "enemy"（对侧存活）| "ally"（己方存活）| "all"，默认 "enemy"
--   枚举走 battle.mover 的 scan_shape（不碰占格表），结果按出场顺序（battle.order）排序保证确定性
local function pick_area(battle, u, target, aoe_cfg)
    aoe_cfg = aoe_cfg or {}
    local anchor = (aoe_cfg.center == "target" and target) or u
    local shape, size = aoe_cfg.shape or "diamond", aoe_cfg.size or 1
    local filter = aoe_cfg.filter or "enemy"
    local in_set = {}
    if battle.mover then
        for _, c in ipairs(battle.mover:scan_shape(anchor.x, anchor.y, shape, size)) do
            in_set[c] = true
        end
    end
    local out = {}
    for _, t in ipairs(battle.order) do
        if in_set[t] and t.alive then
            if filter == "all"
               or (filter == "enemy" and t.side ~= u.side)
               or (filter == "ally" and t.side == u.side) then
                out[#out + 1] = t
            end
        end
    end
    return out
end

-- 技能槽查询：怒气门槛 + CD 是否就绪（数值全部来自内容层技能定义，本层不写死任何技能规则）
local function skill_ready(battle, u, sid)
    local def = battle.skills[sid]
    return def and u.rage >= def.rage and (u.skill_cds[sid] or 0) == 0
end

-- 按 u.skills 顺序找第一个可放技能（顺序 = 释放优先级），返回 { sid, target }
local function castable_skill(battle, u)
    for _, sid in ipairs(u.skills) do
        local def = battle.skills[sid]
        if def and skill_ready(battle, u, sid) then
            local tgt = pick(battle, u, def.pick)
            if tgt then
                return { sid = sid, target = tgt }
            end
        end
    end
end

-- 执行施放（内核 exec 的 CAST 分支整体收编）：扣怒气 -> 上独立 CD -> 落 CAST 事件 -> 调效果脚本
local function cast(battle, u, sid, target)
    local def = battle.skills[sid]
    u.cast_cnt = u.cast_cnt + 1
    u.rage = u.rage - def.rage
    u.skill_cds[sid] = def.cd_s * battle.hz                   -- 每技能独立 CD（秒 -> 格）
    battle:event({
        type = "CAST",
        caster = u.id,
        skill = sid,
        skname = def.name,
        target = target.id,
        rage_cost = def.rage,
    })
    def.on_cast(battle, u, target)                            -- 内容脚本（原语组合）
end

-- 每 tick 递减该单位所有技能剩余 CD（内核 tick 循环回调；只改数值不产出事件，天然确定）
local function tick_cds(battle, u)
    for sid, cd in pairs(u.skill_cds) do
        if cd > 0 then
            u.skill_cds[sid] = cd - 1
        end
    end
end

SKILL = {
    RAGE_MAX = RAGE_MAX,
    pick = pick,
    pick_area = pick_area,
    skill_ready = skill_ready,
    castable_skill = castable_skill,
    cast = cast,
    tick_cds = tick_cds,
}