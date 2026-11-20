--[[
battle_content.lua —— 战报战斗·内容层（高频变更区，可 SafeImport 热更）

新增英雄 / 属性 / 技能 / 行为 全部在这一层改，内核 battle_kernel.lua 不动：
  * 新属性：写进英雄 attrs 池 + 在 bundle 乘区/监听器里消费（参考 B3 破甲、A3 复仇）
  * 新技能：SKILLS 加一项（怒气/冷却/选敌规则/on_cast 原语组合），挂到英雄 skills 数组；
    AOE 技能额外配 aoe={shape,size,center,filter}，on_cast 用 battle:pick_area 枚举（参考 202 地震波/203 十字斩）
  * 多技能：英雄 skills 数组有几个就拥有几个技能，顺序 = 释放优先级，每人独立 CD
  * 多行为：BEHAVIORS 加一个函数，英雄表 behavior 字段写 key；未覆盖的细节自动 fallback 内核默认行为
  * 站位/移动：出生位由地图层固定坑位决定（见 battle_map.lua）；近战 range=1 够不着自动绕行走位，远程 range=99 原地输出
  * 技能机制（怒气槽/CD/施放/选敌）在 battle_skill.lua（技能层）：本层只配技能数值 + on_cast 效果脚本 + 攒怒常量
]]
local SKILLMOD = Import("game/global/battle/battle_skill.lua")

-- ================= 1) 英雄数据 =================
-- 不配站位：出生位 = 地图层固定坑位（battle_map.lua 每方 5 坑：前排3+后排2，A 左 B 镜像右）；
-- 每方不足 5 人时按 lineup 顺序取槽位 1..N（前排优先）
-- range: 1=近战（会走位），99=远程（原地输出）；move_spd: 每 tick 最大步数
HEROES = {
    -- A 侧（坑位由地图层分配：A1..A5 依次站槽位 1..5）
    A1 = { name = "圣骑士", hp = 14200, atk = 520, atk_int = 1.10, crit = 10, range = 1, move_spd = 1,
           skills = { 104, 103 }, behavior = "guard" },        -- 双技能：圣光(治疗)+震荡击(控制)；守卫行为
    A2 = { name = "剑圣",   hp = 11000, atk = 680, atk_int = 1.00, crit = 15, range = 1, move_spd = 1,
           skills = { 103 } },                                  -- 单技能
    A3 = { name = "影刺客", hp =  9000, atk = 600, atk_int = 0.70, crit = 30, range = 1, move_spd = 1,
           skills = { 102, 101 } },                             -- 双技能：影袭(突进)优先于星爆斩
    A4 = { name = "星法师", hp =  9600, atk = 780, atk_int = 1.20, crit = 25, range = 99, move_spd = 0,
           skills = { 202, 101 } },                             -- AOE(地震波菱形)优先于单体星爆斩
    A5 = { name = "神射手", hp =  8800, atk = 660, atk_int = 0.90, crit = 25, range = 99, move_spd = 0,
           skills = {} },                                       -- 无技能纯普攻
    -- B 侧（同顺序镜像站槽位 1..5）
    B1 = { name = "魔将",   hp = 13800, atk = 540, atk_int = 1.05, crit = 10, range = 1, move_spd = 1,
           skills = { 102 }, behavior = "berserk" },            -- 半血狂暴行为
    B2 = { name = "狂战士", hp = 11500, atk = 700, atk_int = 1.10, crit = 20, range = 1, move_spd = 1,
           skills = { 203, 103 } },                             -- AOE(十字斩)优先于震荡击
    B3 = { name = "暗刺客", hp =  8600, atk = 590, atk_int = 0.68, crit = 30, range = 1, move_spd = 1,
           skills = { 101, 102 }, attrs = { pierce = 40 } },    -- 扩展属性：破甲 40（内核零感知）
    B4 = { name = "冰法师", hp =  9200, atk = 750, atk_int = 1.25, crit = 10, range = 99, move_spd = 0,
           skills = { 105 } },
    B5 = { name = "暗弓",   hp =  9100, atk = 680, atk_int = 0.95, crit = 20, range = 99, move_spd = 0,
           skills = { 105 } },
}

-- 行动顺序：显式数组（确定性关键，替代 Lua pairs 无序遍历）
LINEUP = { "A1", "A2", "A3", "A4", "A5", "B1", "B2", "B3", "B4", "B5" }

-- ================= 2) 技能库 =================
-- on_cast 是内容脚本：用内核原语（battle:damage/heal/dash/knockback）自由组合，
-- 新技能 = 加一条数据 + 一段脚本，内核零改动。
-- pick 规则：nearest / lowest_hp / highest_atk / ally_lowest_hp（后三者需内核新增分支时低频扩展）
SKILLS = {
    [101] = { name = "星爆斩", rage = 50, cd_s = 8,  pick = "lowest_hp",     -- 斩残血
              on_cast = function(battle, u, target)
                  battle:damage(u, target, 2.2, "SKILL")
              end },
    [102] = { name = "影袭",   rage = 40, cd_s = 10, pick = "highest_atk",   -- 位移技能：先突进再收割
              on_cast = function(battle, u, target)
                  battle:dash(u, target)
                  battle:damage(u, target, 2.6, "SKILL")
              end },
    [103] = { name = "震荡击", rage = 30, cd_s = 6,  pick = "nearest",       -- 控制技能：伤害+击退
              on_cast = function(battle, u, target)
                  battle:damage(u, target, 1.6, "SKILL")
                  battle:knockback(u, target, 2)
              end },
    [104] = { name = "圣光",   rage = 35, cd_s = 7,  pick = "ally_lowest_hp", -- 治疗技能：奶最低血量队友
              on_cast = function(battle, u, target)
                  battle:heal(u, target, u.atk * 0.8)
              end },
    [105] = { name = "冰锥",   rage = 45, cd_s = 9,  pick = "nearest",       -- 风筝技能：伤害+微击退
              on_cast = function(battle, u, target)
                  battle:damage(u, target, 1.9, "SKILL")
                  battle:knockback(u, target, 1)
              end },
    [202] = { name = "地震波", rage = 55, cd_s = 10, pick = "nearest",       -- AOE 形状模板：菱形(曼哈顿半径2)
              aoe = { shape = "diamond", size = 2, center = "self" },        -- 策划只配 shape+size：结算路径纯查表
              on_cast = function(battle, u, target)
                  for _, t in ipairs(battle:pick_area(u, target, SKILLS[202].aoe)) do
                      battle:damage(u, t, 1.5, "SKILL")                      -- 范围内人人挨 1.5 倍
                  end
              end },
    [203] = { name = "十字斩", rage = 40, cd_s = 8,  pick = "nearest",       -- AOE 形状模板：十字(臂长2)
              aoe = { shape = "cross", size = 2, center = "self" },
              on_cast = function(battle, u, target)
                  for _, t in ipairs(battle:pick_area(u, target, SKILLS[203].aoe)) do
                      battle:damage(u, t, 2.0, "SKILL")
                  end
              end },
}

-- ================= 3) 行为库（一个英雄可有多套行为逻辑，按 key 挂载） =================
local HEAL_SID = 104
BEHAVIORS = {
    -- 半血狂暴：血量低于 50% 时普攻 ×1.5，其余全部沿用默认行为
    berserk = function(battle, u)
        local op = battle.default_behavior(battle, u)
        if op and op.kind == "BASIC" and u.hp < u.hp_max * 0.5 then
            op.mult = 1.5
        end
        return op
    end,
    -- 守卫：队友血量低于 60% 且圣光就绪时，优先治疗而非输出；其余 fallback 默认
    guard = function(battle, u)
        local tgt = battle:pick(u, "ally_lowest_hp")
        if tgt and tgt.hp < tgt.hp_max * 0.6 and battle:skill_ready(u, HEAL_SID) then
            return { kind = "CAST", sid = HEAL_SID, target = tgt }
        end
        return battle.default_behavior(battle, u)
    end,
}

-- ================= 4) 装配清单 bundle =================
-- 一场战斗要挂的"内容交付物"：乘区贡献器 + 事件监听器。热更新 = 换这张单子。
local ATK_RAGE, HIT_RAGE = 18, 8

local function on_attack_rage(p)          -- 普攻攒怒（数值进内容层）
    p.caster.rage = math.min(SKILLMOD.SKILL.RAGE_MAX, p.caster.rage + ATK_RAGE)
end
local function on_hit_rage(p)             -- 被击攒怒
    p.target.rage = math.min(SKILLMOD.SKILL.RAGE_MAX, p.target.rage + HIT_RAGE)
end
local function pierce_mult(battle, src, tgt)   -- 破甲属性消费样例：B3 破甲 40 → 对目标伤害 ×1.4
    if src.attrs and src.attrs.pierce then
        return 1 + src.attrs.pierce / 100
    end
end
local function vengeance(p, battle)       -- 被动"复仇"：A3 队友阵亡 → A3 攻击 +60 并重置普攻 CD
    local owner, victim = battle.units["A3"], p.victim
    if owner and owner.alive and victim.side == "A" and victim.id ~= "A3" then
        owner.atk = owner.atk + 60
        owner.atk_cd = 0
    end
end

BUNDLE = {
    mults = { pierce_mult },                    -- 伤害乘区贡献器：simulate 逐个 battle:register_mult
                                                --   注册，伤害结算时依次消费（新伤害规则加这里）
    listeners = {                               -- 事件监听器：simulate 逐个 battle:on 订阅
                                                --   （有序数组，同帧多监听器执行顺序确定）
        { "ON_ATTACK", on_attack_rage },        -- 普攻出手：攻击方攒怒 18
        { "ON_HIT", on_hit_rage },              -- 受到伤害：受伤方攒怒 8
        { "ON_DEATH", vengeance },              -- 单位阵亡：A3 复仇被动（攻击 +60 并重置普攻 CD）
    },
}

C = {
    heroes = HEROES,
    lineup = LINEUP,
    skills = SKILLS,
    behaviors = BEHAVIORS,
    bundle = BUNDLE
}

