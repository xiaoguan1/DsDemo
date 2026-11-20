--[[
content.lua —— 爱琳战斗·内容层（高频变更区，可 SafeImport 热更）

新增英雄 / 属性 / 技能 / 行为 全部在这一层改，内核 kernel.lua 不动：
  * 新属性：写进英雄 attrs 池 + 在 bundle 乘区/监听器里消费（参考 B2 破甲、A6 复仇）
  * 新技能：SKILLS 加一项（怒气/冷却/选敌规则/on_cast 原语组合），挂到英雄 skills 数组；
    AOE 技能额外配 aoe={shape,depth,center}，on_cast 用 battle:pick_area 枚举（参考 301/304/305）
  * 多目标技能配 multi={rule,n}，on_cast 收到的就是目标簇数组（参考 302/303）
  * 多技能：英雄 skills 数组有几个就拥有几个技能，顺序 = 释放优先级，每人独立 CD
  * 多行为：BEHAVIORS 加一个函数，英雄表 behavior 字段写 key（参考 guard/berserk）
  * 站位：222 配置（前2中2后2），出生位 = 槽位层固定坑位（battle_slot.lua 前排先填），
    换站位本质就是换 lineup 顺序；近战 range=1（普攻打列1）、远程 range=2（普攻打列2）
  * 技能机制（怒气槽/CD/施放/选敌）在 battle_skill.lua（技能层）：本层只配技能数值 + on_cast 脚本

技能目标覆盖爱琳七类（技能文本佐证的技术谓词集）：
  ①全体       301 审判之光（光之化身 250% 全体）
  ②单体+属性筛选 302 咒缚荆棘（对攻击最高 2 个上"降攻" debuff）
  ③随机N个    303 魂之拉扯（大葛叶：随机 2 个拉扯到战场中央）
  ④前方范围   304 毁灭冲击（尼德霍格：前方 2 排所有敌方）
  ⑤目标附近溅射 305 荆棘之种（爱丽丝：后排随机 1 个 + 其附近范围）
  ⑥位置型位移   306 震荡击（击退）/ 303（拉扯）/ 307 影落（落到敌方身后同排正对）
  ⑦怒气机制    A3 开局怒气 50 先手控制 + 全队普攻/受击攒怒（bundle 监听器）
]]

local SKILLMOD = Import("game/global/al_battle/battle_skill.lua")

-- ================= 1) 英雄数据 =================
-- 不配站位：出生位 = 槽位层固定坑位（lineup 顺序 1..6 → 槽位 1..6，前排先填 222 配置）；
-- range: 1=近战（普攻抽列1）、2=远程（普攻抽列2）；start_rage: 开局怒气（爱琳部分英雄先手大招）
HEROES = {
    -- A 侧（A1..A6 依次站槽位 1..6：前排 A1/A2、中排 A3/A4、后排 A5/A6）
    A1 = { name = "圣盾骑士", hp = 14200, atk = 520, atk_int = 1.10, crit = 10, range = 1,
           skills = { 306 } },                                   -- 坦克：震荡击（伤害+击退）
    A2 = { name = "剑圣",   hp = 11000, atk = 680, atk_int = 1.00, crit = 15, range = 1,
           skills = { 310 } },                                   -- 战士：星爆斩（单体收割）
    A3 = { name = "圣愈师", hp = 11500, atk = 480, atk_int = 1.15, crit = 10, range = 2,
           skills = { 308, 309 }, behavior = "guard", start_rage = 50 }, -- 辅助：开局怒气 50 先手控（怒气机制⑦）
    A4 = { name = "光天使", hp =  9600, atk = 780, atk_int = 1.20, crit = 25, range = 2,
           skills = { 301, 309 } },                              -- 法师：审判之光（全体250%）优先于冰封
    A5 = { name = "神射手", hp =  8800, atk = 660, atk_int = 0.90, crit = 25, range = 2,
           skills = {} },                                        -- 射手：纯普攻（远程抽列2）
    A6 = { name = "夜刃刺客", hp =  9000, atk = 700, atk_int = 0.85, crit = 30, range = 1,
           skills = { 307 } },                                   -- 刺客：影落（落到敌方身后收割残血）
    -- B 侧（同顺序镜像站槽位 1..6）
    B1 = { name = "魔将",   hp = 13800, atk = 540, atk_int = 1.05, crit = 10, range = 1,
           skills = { 309 } },                                   -- 坦克：冰封（控制攻击最高者）
    B2 = { name = "狂战士", hp = 11500, atk = 700, atk_int = 1.10, crit = 20, range = 1,
           skills = { 310 }, behavior = "berserk", attrs = { pierce = 40 } }, -- 战士：半血狂暴+破甲40
    B3 = { name = "咒术师", hp = 10400, atk = 560, atk_int = 1.15, crit = 15, range = 2,
           skills = { 302 } },                                   -- 术士：对攻击最高2个上降攻debuff
    B4 = { name = "尼德霍格", hp =  9800, atk = 750, atk_int = 1.25, crit = 10, range = 2,
           skills = { 304 } },                                   -- 法师：毁灭冲击（前方2排范围）
    B5 = { name = "爱丽丝", hp =  9000, atk = 620, atk_int = 1.00, crit = 20, range = 2,
           skills = { 305 } },                                   -- 射手：后排随机1个+其附近溅射
    B6 = { name = "大葛叶", hp = 10800, atk = 680, atk_int = 0.95, crit = 20, range = 1,
           skills = { 303 } },                                   -- 妖术：随机2个拉扯到战场中央
}

-- 行动顺序：显式数组（确定性关键，替代 Lua pairs 无序遍历）；
-- 顺序 = 站位顺序 = 槽位 1..6 分配序（前排先填），末端单位同 tick 内后行动
LINEUP = { "A1", "A2", "A3", "A4", "A5", "A6", "B1", "B2", "B3", "B4", "B5", "B6" }

-- ================= 2) 技能库 =================
-- on_cast 是内容脚本：用内核原语（battle:damage/heal/knockback/pull/land_behind）自由组合，
-- 新技能 = 加一条数据 + 一段脚本，内核零改动。
-- pick 规则：nearest / lowest_hp / highest_atk / ally_lowest_hp / random / back_row / random_back
-- aoe 区域：all / front(depth) / back / row / splash（槽位层邻域偏移表）
-- multi 多目标：{ rule=highest_atk|lowest_hp|random, n=数量 }（on_cast 收到目标簇数组）
SKILLS = {
    [301] = { name = "审判之光", rage = 100, cd_s = 12, pick = "nearest",     -- ①全体：光之化身 250%
              aoe = { shape = "all" },
              on_cast = function(battle, u, target)
                  for _, t in ipairs(battle:pick_area(u, target, SKILLS[301].aoe)) do
                      battle:damage(u, t, 2.5, "SKILL")                       -- 敌方全员挨 2.5 倍
                  end
              end },
    [302] = { name = "咒缚荆棘", rage = 60, cd_s = 10, pick = "nearest",      -- ②属性筛选：攻击最高2个上降攻
              multi = { rule = "highest_atk", n = 2 },
              on_cast = function(battle, u, targets)
                  for _, t in ipairs(targets) do
                      battle:damage(u, t, 1.3, "SKILL")                       -- 伤害 + debuff
                      t.atk = math.floor(t.atk * 0.8)                         -- 永久降攻 20%（叠加衰减）
                  end
              end },
    [303] = { name = "魂之拉扯", rage = 80, cd_s = 12, pick = "nearest",      -- ③随机N拉扯：大葛叶随机2个
              multi = { rule = "random", n = 2 },
              on_cast = function(battle, u, targets)
                  for _, t in ipairs(targets) do
                      battle:damage(u, t, 1.4, "SKILL")                       -- 先伤害再拉扯
                      battle:pull(u, t)                                       -- 拉到战场中央（中排）
                  end
              end },
    [304] = { name = "毁灭冲击", rage = 70, cd_s = 10, pick = "nearest",      -- ④前方范围：尼德霍格前2排
              aoe = { shape = "front", depth = 2 },
              on_cast = function(battle, u, target)
                  for _, t in ipairs(battle:pick_area(u, target, SKILLS[304].aoe)) do
                      battle:damage(u, t, 1.8, "SKILL")                       -- 前两排人人 1.8 倍
                  end
              end },
    [305] = { name = "荆棘之种", rage = 60, cd_s = 9, pick = "random_back",   -- ⑤后排随机1+附近溅射：爱丽丝
              aoe = { shape = "splash", center = "target" },
              on_cast = function(battle, u, target)
                  for _, t in ipairs(battle:pick_area(u, target, SKILLS[305].aoe)) do
                      battle:damage(u, t, 1.7, "SKILL")                       -- 目标及附近（同排/上下排）1.7 倍
                  end
              end },
    [306] = { name = "震荡击", rage = 40, cd_s = 6,  pick = "nearest",        -- ⑥位移·击退：伤害+退一排
              on_cast = function(battle, u, target)
                  battle:damage(u, target, 1.6, "SKILL")
                  battle:knockback(u, target, 1)                              -- 被占推挤互换（人墙顶开）
              end },
    [307] = { name = "影落",   rage = 50, cd_s = 8,  pick = "lowest_hp",      -- ⑥位移·落到敌方身后：收割残血
              on_cast = function(battle, u, target)
                  battle:land_behind(u, target)                               -- 翻越到 target 同排正对
                  battle:damage(u, target, 2.6, "SKILL")
              end },
    [308] = { name = "圣愈",   rage = 45, cd_s = 7,  pick = "ally_lowest_hp", -- 治疗：奶最低血量队友
              on_cast = function(battle, u, target)
                  battle:heal(u, target, u.atk * 0.8)
              end },
    [309] = { name = "冰封",   rage = 40, cd_s = 8,  pick = "highest_atk",    -- 控制：伤害+冻结攻击最高者
              on_cast = function(battle, u, target)
                  battle:damage(u, target, 1.2, "SKILL")
                  target.atk_cd = target.atk_cd + 2 * 60                      -- 行动延后 2 秒（60Hz）
              end },
    [310] = { name = "星爆斩", rage = 50, cd_s = 8,  pick = "lowest_hp",      -- 单体：斩残血
              on_cast = function(battle, u, target)
                  battle:damage(u, target, 2.2, "SKILL")
              end },
}

-- ================= 3) 行为库（一个英雄可有多套行为逻辑，按 key 挂载） =================
local HEAL_SID = 308
BEHAVIORS = {
    -- 半血狂暴：血量低于 50% 时普攻 ×1.5，其余全部沿用默认行为（技能优先→普攻）
    berserk = function(battle, u)
        local op = battle.default_behavior(battle, u)
        if op and op.kind == "BASIC" and u.hp < u.hp_max * 0.5 then
            op.mult = 1.5
        end
        return op
    end,
    -- 守卫：队友血量低于 60% 且圣愈就绪时，优先治疗而非输出；其余 fallback 默认
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
local ATK_RAGE, HIT_RAGE = 18, 8          -- 攒怒数值：出手+18 / 受击+8（爱琳怒气机制⑦）

local function on_attack_rage(p)          -- 普攻攒怒（数值进内容层）
    p.caster.rage = math.min(SKILLMOD.SKILL.RAGE_MAX, p.caster.rage + ATK_RAGE)
end
local function on_hit_rage(p)             -- 被击攒怒
    p.target.rage = math.min(SKILLMOD.SKILL.RAGE_MAX, p.target.rage + HIT_RAGE)
end
local function pierce_mult(battle, src, tgt)   -- 破甲属性消费样例：B2 破甲 40 → 对目标伤害 ×1.4
    if src.attrs and src.attrs.pierce then
        return 1 + src.attrs.pierce / 100
    end
end
local function vengeance(p, battle)       -- 被动"复仇"：A6 队友阵亡 → A6 攻击 +60 并重置普攻 CD
    local owner, victim = battle.units["A6"], p.victim
    if owner and owner.alive and victim.side == "A" and victim.id ~= "A6" then
        owner.atk = owner.atk + 60
        owner.atk_cd = 0
    end
end

BUNDLE = {
    mults = { pierce_mult },                    -- 伤害乘区贡献器：simulate 逐个 battle:register_mult
    listeners = {                               -- 事件监听器：simulate 逐个 battle:on 订阅（有序数组）
        { "ON_ATTACK", on_attack_rage },        -- 普攻出手：攻击方攒怒 18
        { "ON_HIT", on_hit_rage },              -- 受到伤害：受伤方攒怒 8
        { "ON_DEATH", vengeance },              -- 单位阵亡：A6 复仇被动（攻击 +60 并重置普攻 CD）
    },
}

C = {
    heroes = HEROES,
    lineup = LINEUP,
    skills = SKILLS,
    behaviors = BEHAVIORS,
    bundle = BUNDLE
}