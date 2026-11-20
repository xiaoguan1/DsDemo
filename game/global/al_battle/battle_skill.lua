--[[
battle_skill.lua —— 爱琳战斗·技能层（怒气槽 / 技能槽CD / 施放执行 / 目标选择）

分层定位（内核 <- 技能层 <- 内容层；与 battle/网格版同构，目标域换成槽位制）：
  - 只依赖 battle 对象暴露的原语（battle:event/emit/damage/...、battle.teams/order/units/skills、
    battle.slot/hz），不认识内核 tick 循环与槽位层的实现细节；
  - 不认识任何英雄/技能数值：技能定义（数值 + on_cast 效果脚本）在内容层 SKILLS，
    本层只回答"能不能放 / 对谁放 / 放出去收什么尾（扣怒气、上CD、落CAST事件、调效果脚本）"；
  - 经 cfg.skillsys 注入内核（与 cfg.slot 同款约定）：内核 tick 只回调 tick_cds/cast，
    内容层走内核薄路由（battle:pick/pick_many/pick_area/skill_ready/castable_skill）访问本层。

选敌规则（爱琳七类技能目标的技术谓词集）：
  nearest / lowest_hp / highest_atk / ally_lowest_hp   基础四则（同战斗版）
  random          随机 1 个（走 battle.rand，确定性）
  back_row        敌方后排(rank=2)攻击最高者（切脆皮）
  random_back     敌方后排随机 1 个（爱丽丝"后排随机1个+附近范围"的前半段）
  多目标 def.multi = { rule, n }（大葛叶"随机2个拉扯"、咒缚"对攻击最高2个上debuff"）：
     rule = "highest_atk" / "lowest_hp"（属性排序取前 n）/ "random"（无放回随机抽 n）
  区域 def.aoe = { shape, depth, center }（尼德霍格"前方范围"、光之化身"全体"）：
     shape = all / front(depth 排) / back / row（目标整排）/ splash（目标附近），
     几何枚举在槽位层邻域偏移表，本层只做 filter + 出场序排序

接口（全部显式传 battle 作第一参数）：
  SKILL.pick(battle, u, rule)                 单选：按规则返回 1 个目标（无目标返回 nil）
  SKILL.pick_many(battle, u, rule, n)         多选：属性排序前 n / 随机抽 n（无放回，确定性）
  SKILL.pick_area(battle, u, target, aoe_cfg) 区域选区：槽位层 scan_area + filter + 出场序排序
  SKILL.skill_ready(battle, u, sid)           怒气门槛 + 独立 CD 是否就绪
  SKILL.castable_skill(battle, u)             按 u.skills 顺序找第一个可放技能（顺序 = 优先级）
  SKILL.cast(battle, u, sid, target)          执行：扣怒气 / 上CD / CAST事件 / 调 on_cast（多目标分流）
  SKILL.tick_cds(battle, u)                   每 tick 递减该单位所有技能剩余 CD

新技能机制（新选敌谓词、新施放条件等）只改本文件；新技能数值与效果脚本仍只在内容层。
]]

local RAGE_MAX = 100                                 -- 怒气槽上限：技能消耗怒气，攒怒/上限语义由内容层解释

local other_side = { A = "B", B = "A" }

-- 对侧存活单位（选敌原语内部用；普攻目标在内核 basic_target 走槽位层排位规则）
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
    if rule == "ally_lowest_hp" then                        -- 治疗系：选友方最低血量（全员满血则无目标）
        local best = nil
        for _, e in ipairs(battle.teams[u.side]) do
            if e.alive and e.hp < e.hp_max and (not best or e.hp < best.hp) then
                best = e
            end
        end
        return best
    end
    if rule == "random" then                                -- 随机 1 个（确定性：走 battle.rand）
        local es = enemies(battle, u.side)
        if #es == 0 then return nil end
        return es[battle.rand(#es)]
    end
    if rule == "random_back" then                           -- 敌方后排随机 1 个（爱丽丝式切后排）
        local es = {}
        for _, e in ipairs(enemies(battle, u.side)) do
            if e.rank == 2 then
                es[#es + 1] = e
            end
        end
        if #es == 0 then return end
        return es[battle.rand(#es)]
    end
    if rule == "back_row" then                              -- 敌方后排攻击最高者
        local best = nil
        for _, e in ipairs(enemies(battle, u.side)) do
            if e.rank == 2 and (not best or e.atk > best.atk) then
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
                better = battle:dist(u, e) < battle:dist(u, best)   -- 排距（同排=0 最近）
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

-- 多目标选择（def.multi 用）：highest_atk/lowest_hp = 全队列属性排序取前 n；
-- random = 无放回随机抽 n（池子拷贝 + battle.rand 抽签 + 移除，确定性）。
local function pick_many(battle, u, rule, n)
    local es = enemies(battle, u.side)
    if rule == "random" then
        local pool, out = {}, {}
        for i = 1, #es do
            pool[i] = es[i]
        end
        for i = 1, math.min(n, #es) do
            local idx = battle.rand(#pool)
            out[#out + 1] = pool[idx]
            table.remove(pool, idx)
        end
        return out
    end
    local sorted = {}
    for i = 1, #es do
        sorted[i] = es[i]
    end
    table.sort(sorted, function(x, y)
        if rule == "highest_atk" then
            return x.atk > y.atk
        elseif rule == "lowest_hp" then
            return x.hp < y.hp
        end
        return false
    end)
    local out = {}
    for i = 1, math.min(n, #sorted) do
        out[i] = sorted[i]
    end
    return out
end

-- 区域选区（AOE 结算通用）：aoe_cfg = { shape, depth, center, filter }
--   shape  : "all"(敌方全体) | "front"(敌方前 depth 排) | "back"(敌方后排)
--          | "row"(锚点整排) | "splash"(锚点附近溅射)——几何枚举在槽位层邻域偏移表
--   depth  : 仅 shape="front" 有效（如尼德霍格毁灭冲击 = front+2 前两排）
--   center : "self"（以释放者为中心）| "target"（以选中目标为中心），默认 "self"
--   filter : "enemy"（对侧存活）| "ally"（己方存活）| "all"，默认 "enemy"
--   枚举走 battle.slot 的 scan_area（不碰占位细节），结果按出场顺序（battle.order）排序保证确定性
local function pick_area(battle, u, target, aoe_cfg)
    aoe_cfg = aoe_cfg or {}
    local anchor = (aoe_cfg.center == "target" and target) or u
    local filter = aoe_cfg.filter or "enemy"
    local scanned = {}
    if battle.slot then
        scanned = battle.slot:scan_area(battle, u, anchor, aoe_cfg)
    end
    local out = {}
    for _, t in ipairs(battle.order) do
        if t.alive then
            for _, s in ipairs(scanned) do
                if s == t then
                    if filter == "all"
                       or (filter == "enemy" and t.side ~= u.side)
                       or (filter == "ally" and t.side == u.side) then
                        out[#out + 1] = t
                    end
                    break
                end
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
-- 多目标技能（def.multi）只验"有敌可打"（代表目标 nearest），实际目标簇在 cast 里定
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
-- 多目标技能（def.multi）：先按规则定目标簇再结算，CAST 事件只记代表目标与簇大小
local function cast(battle, u, sid, target)
    local def = battle.skills[sid]
    u.cast_cnt = u.cast_cnt + 1
    u.rage = u.rage - def.rage
    u.skill_cds[sid] = def.cd_s * battle.hz                   -- 每技能独立 CD（秒 -> 格）
    if def.multi then
        local targets = pick_many(battle, u, def.multi.rule, def.multi.n)
        battle:event({
            type = "CAST",
            caster = u.id,
            skill = sid,
            skname = def.name,
            target = (targets[1] and targets[1].id) or "none",
            rage_cost = def.rage,
            multi = #targets,
        })
        def.on_cast(battle, u, targets)                       -- 内容脚本（对内多目标簇）
        return
    end
    battle:event({
        type = "CAST",
        caster = u.id,
        skill = sid,
        skname = def.name,
        target = target.id,
        rage_cost = def.rage,
    })
    def.on_cast(battle, u, target)                            -- 内容脚本（对单选目标）
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
    pick_many = pick_many,
    pick_area = pick_area,
    skill_ready = skill_ready,
    castable_skill = castable_skill,
    cast = cast,
    tick_cds = tick_cds,
}