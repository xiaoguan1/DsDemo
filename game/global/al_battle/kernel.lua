--[[
kernel.lua —— 爱琳战斗·内核层（稳定骨架，低频变更，改了要停机+版本迁移）

设计目标（与 battle/网格版同构：空间层从"50×30 自由网格"换成"3排×2列 槽位制"）：
  1) 内核只提供"通用设施"（tick/事件/结算原语/乘区池），不含任何英雄/技能/行为的数值与规则；
  2) 新增属性 / 行为 = 只改 content.lua 里的数据与脚本，内核不动；
     技能机制（怒气槽/技能CD/施放/选敌）= 只改 battle_skill.lua（技能层），技能数值与效果脚本仍只在内容层；
  3) 所有遍历基于显式数组（lineup / 有序监听器 / 排位枚举），保证同 seed 战报逐字节可复现。

类 / 对象结构（与项目 oop/class.lua 的 Class.NewClass 配套）：
  BattleClass = Class.NewClass("<<battle class>>")              -- 类模板：全部方法定义在类上
  battle = BattleClass:new_battle(seed, cfg)                    -- 工厂：生成战斗实例
  setmetatable(battle, { __index = BattleClass })               -- 实例经元表访问类方法

稳定接口速览（内容层/入口只允许用这些）：
  K.simulate(seed, cfg, bundle)            装配并跑完一场，直接产出战报
  BattleClass:new_battle(seed, cfg)        建战斗 -> 挂 bundle -> battle:run()
  battle:on(event, fn) / battle:emit(...)  事件订阅/广播（有序监听器，执行顺序确定）
  battle:register_mult(fn)                 伤害乘区贡献器（新伤害规则=注册一条，公式永不改）
  battle:pick / pick_many / pick_area      技能选敌/选区：薄路由，机制实现全在 battle_skill.lua
  battle:skill_ready / castable_skill      技能槽查询：薄路由，机制实现全在 battle_skill.lua
  battle:basic_target(u)                   普攻选敌：薄路由，排位规则（同排/列首/蔓延）全在 battle_slot.lua
  battle:event(extra)                      事件构造原语（tick/ms 自动填充并落队）
  battle:damage / heal                     唯一结算原语（内容脚本只能通过这些组合）
  battle:knockback / pull / land_behind    唯一位移原语（槽位制三件套：击退/拉扯/翻越）
  battle.default_behavior(battle, u)       出厂默认行动逻辑（内容层行为可 fallback 到它）

约定：
  - 战场是槽位制：每方 3 排(rank 0=前排 1=中排 2=后排) × 2 列(col 0=列1 1=列2) 共 6 槽，
    占位/排位普攻规则/区域枚举/位移原语在 battle_slot.lua（槽位层）；内核经 cfg.slot 注入调用，
    不认识槽位细节，换站位规则/换空间粒度内核零改动；
  - 技能机制在 battle_skill.lua（技能层），经 cfg.skillsys 注入（与 cfg.slot 同款约定）：
    内核 tick 循环只回调它的 tick_cds/cast，其余技能接口走薄路由转发；
  - 单位固定字段之外，扩展属性一律进 attrs 池（破甲 pierce），开局怒气走 start_rage 字段，内核无感知；
  - 英雄 N 个技能 = skills 数组（顺序即释放优先级），每个技能独立 CD；
  - MOVE 事件 from/to 为 { rank, col } 槽位坐标（网格版为 { x, y }），其余事件字段与网格版一致。
]]

TICKS_PER_SEC = 60                              -- 逻辑帧 60Hz
BATTLE_SECONDS = 90                             -- 单场上限 90s
TOTAL_TICKS   = TICKS_PER_SEC * BATTLE_SECONDS

VARIANCE  = 0.10                                -- 伤害浮动 ±10%
CRIT_MULT = 1.5                                 -- 暴击倍率

-- 确定性伪随机（LCG）：同 seed 同输出，战报可复现
local function rng_new(seed)
    local state = seed % 2147483648
    return function(n)
        state = (state * 1103515245 + 12345) % 2147483648
        return state % n + 1
    end
end

-- 战报序列化：数组部分按 1..n 显式顺序，剩余键值按插入态输出（同运行历史插入序列一致）
local ESC = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ['"'] = '\\"', ["\\"] = "\\\\" }
local function quote(s)
    return '"' .. tostring(s):gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\%03d", c:byte()) end) .. '"'
end
local function ser(v)
    local t = type(v)
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "string" then return quote(v) end
    local parts, n = {}, 1
    while v[n] ~= nil do                               -- 数组部分：不带 key，按序
        parts[#parts + 1] = "  " .. ser(v[n])
        n = n + 1
    end
    for k, val in pairs(v) do                          -- 其余键值部分：按插入序
        if not (type(k) == "number" and k >= 1 and k < n) then
            local kk = type(k) == "number" and string.format("[%d]", k) or k
            parts[#parts + 1] = "  " .. kk .. " = " .. ser(val)
        end
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n}"
end

--[[ 建战斗：完全数据驱动。
  cfg = {
    lineup    = { id, ... }                                行动顺序（显式数组，确定性关键；
                                                           同时即站位顺序：第 N 个站槽位 N = 前三排后/前排先填）
    heroes    = { id -> { name, hp, atk, atk_int(秒), crit, range(1近战/2远程), skills,
                          behavior, attrs, start_rage } }
    skills    = { sid -> { name, rage, cd_s, pick, on_cast, [aoe] , [multi] } }
    behaviors = { key -> function(battle, u) return op }   多套行为逻辑，英雄表只记 key
    slot      = 槽位层对象（占位/排位/区域/位移），由入口注入；nil 时退化：无位移、按序号站位
  } ]]

BattleClass = Class.NewClass("<<battle class>>")

local other_side = { A = "B", B = "A" }

-- ===== 模块私有辅助（显式接收 battle 作 self） =====
local function cur_event(self, extra)
    local ev = {
        tick = self.tick,
        ms = math.floor(self.tick * 1000 / TICKS_PER_SEC)
    }
    for k, v in pairs(extra) do
        ev[k] = v
   end
    return ev
end

-- 统一落 MOVE 事件：换排/换列/碰撞全在槽位层算完，内核只负责记录（from/to 是 {rank,col} 槽位坐标）
local function do_move(self, u, from, to, reason, victim_id)
    u.move_cnt = u.move_cnt + 1
    self.events[#self.events + 1] = cur_event(self,{
                                type = "MOVE",
                                caster = u.id,
                                victim = victim_id,
                                reason = reason,
                                from = from,
                                to = to
                            })
end

local function battle_alive(self)
    local a, b = 0, 0
    for _, u in ipairs(self.teams.A) do
        if u.alive then
            a = a + 1
        end
    end
    for _, u in ipairs(self.teams.B) do
        if u.alive then
            b = b + 1
        end
    end
    return a > 0 and b > 0
end

-- ===== 操作执行：内核只认 op.kind，规则全在行为函数与内容脚本里 =====
local function exec(self, u, op)
    local kind = op.kind
    if kind == "CAST" then
        if self.skillsys then
            self.skillsys.cast(self, u, op.sid, op.target)  -- 技能层执行：扣怒气/上CD/落CAST事件/调效果脚本
        end
    elseif kind == "BASIC" then
        u.basic_cnt = u.basic_cnt + 1
        u.atk_cd = u.atk_cd_max
        self:emit("ON_ATTACK", { caster = u, target = op.target })
        self:damage(u, op.target, op.mult or 1.0, "BASIC")
    end
end

-- ===== 类方法区：全部定义在 BattleClass 上，实例经 __index 元表访问 =====

-- 工厂：生成战斗对象。状态全部落在实例字段，方法在类表，实例元表指回类。
function BattleClass:new_battle(seed, cfg)
    local battle = {
        seed = seed,                        -- 随机种子：同 seed 全场随机序列一致，战报可复现
        rand = rng_new(seed),               -- 本场专用 LCG 随机函数（唯一随机入口，结算必须走它）
        heroes = cfg.heroes,                -- 英雄配置表 id->{name,hp,atk,...}：引用内容层数据，内核只读
        skills = cfg.skills or {},          -- 技能配置表 sid->{name,rage,cd_s,pick,on_cast[,aoe][,multi]}
        behaviors = cfg.behaviors or {},    -- 行为函数表 key->fn：多套行为逻辑按 key 挂载
        slot = cfg.slot,                    -- 槽位层对象（入口注入；内核不认识排位/占位细节，只调它）
        skillsys = cfg.skillsys,            -- 技能层对象（入口注入；内核不认识怒气/CD/选敌，只回调它 tick_cds/cast）
        hz = TICKS_PER_SEC,                 -- 本场频率(Hz)：供技能层把 CD 从秒换算成格
        units = {},                         -- 单位索引 id->unit（内容脚本按 battle.units["A3"] 取人）
        teams = { A = {}, B = {} },         -- 分边队伍表 A/B->单位数组（遍历/存活统计走它）
        order = {},                         -- 全场行动顺序数组：按 cfg.lineup 显式排列（确定性关键）
        mults = {},                         -- 伤害乘区贡献器数组：register_mult 注册，damage 依次消费
        listeners = {},                     -- 事件监听表 event->有序函数数组：battle:on 订阅
        events = {},                        -- 战报事件流数组：每格动作落事件，最终序列化产出
        tick = 0,                           -- 当前逻辑帧：run 每格 +1（60Hz）
        duration = 0,                       -- 实际进行帧数：战斗结束时的时长（1 帧 = 1/60 秒）
    }
    setmetatable(battle, { __index = BattleClass })         -- 对象 -> 类方法

    local side_idx = { A = 0, B = 0 }                       -- 各阵营已出生人数：第 N 个站槽位 N
    for _, id in ipairs(cfg.lineup) do
        local t, side = cfg.heroes[id], id:sub(1, 1)
        side_idx[side] = side_idx[side] + 1
        -- 出生位：槽位层固定坑位（前排先填 222 配置）；无槽位层时退化为序号排开
        local pos = (battle.slot and battle.slot:slot_pos(side, side_idx[side]))
                    or { rank = side_idx[side] - 1, col = 0 }
        local u = {
            id = id,                                     -- 单位唯一 id（如 "A1"/"B6"，首字符即阵营）
            side = side,                                 -- 阵营 "A"/"B"
            name = t.name,                               -- 英雄名（战报展示用）
            hp_max = t.hp,                               -- 血量上限（出生满血，治疗封顶用）
            hp = t.hp,                                   -- 当前血量：归零触发死亡/击杀
            atk = t.atk,                                 -- 基础攻击：伤害结算基数（debuff 直接改它）
            crit = t.crit or 0,                          -- 暴击率 0-100：damage 内 rand(100) <= crit 判定
            atk_cd_max = math.floor(t.atk_int * TICKS_PER_SEC + 0.5),  -- 普攻间隔：秒 -> 格
            atk_cd = 0,                                  -- 普攻剩余 CD 格数：0 才可出手，每 tick -1
            rage = t.start_rage or 0,                    -- 怒气 0..100：开局怒气（爱琳部分英雄带初始怒气先手）
            skills = t.skills or {},                     -- 拥有技能 id 数组（顺序 = 释放优先级）
            skill_cds = {},                              -- 各技能独立剩余 CD：sid -> 格数（互不共享）
            rank = pos.rank,                             -- 排位 0=前排 1=中排 2=后排（占位由槽位层维护）
            col = pos.col,                               -- 列位 0=列1 1=列2（近战抽列1/远程抽列2）
            range = t.range or 1,                        -- 1=近战（普攻列1偏好） 2=远程（普攻列2偏好），无走位概念
            behavior = t.behavior or "default",          -- 行为策略 key：查 behaviors 表，未命中 fallback 默认行为
            attrs = t.attrs,                             -- 扩展属性池：新属性只进这里，内核无感知
            alive = true,                                -- 存活标记：false 后不再出手、排除出选敌/治疗
            dealt = 0,                                   -- 统计：累计造成伤害
            healed = 0,                                  -- 统计：累计治疗量
            basic_cnt = 0,                               -- 统计：普攻次数
            cast_cnt = 0,                                -- 统计：技能释放次数
            move_cnt = 0,                                -- 统计：位移次数（击退/拉扯/翻越都计入）
            kills = 0,                                   -- 统计：击杀数
        }
        battle.units[id] = u                             -- 全局索引：按 id 唯一取单位
        battle.teams[side][#battle.teams[side] + 1] = u  -- 分边归档：按阵营存入队伍数组
        battle.order[#battle.order + 1] = u              -- 行动顺序：严格按 cfg.lineup 排列（确定性关键）
        if battle.slot then
            battle.slot:put_unit(u)                      -- 出生占槽（一槽最多一个，碰撞自此生效）
        end
    end

    return battle
end

-- ===== 事件订阅（战斗级作用域）：有序数组，监听器执行顺序确定 =====
function BattleClass:on(event, fn)
    local list = self.listeners[event]
    if not list then
        list = {}
        self.listeners[event] = list
    end
    list[#list + 1] = fn
end
function BattleClass:emit(event, payload)
    for _, fn in ipairs(self.listeners[event] or {}) do
        fn(payload, self)
    end
end
-- 事件构造原语：技能层等依赖方落自定义事件用（tick/ms 自动填充并直接入队，返回事件对象）
function BattleClass:event(extra)
    local ev = cur_event(self, extra)
    self.events[#self.events + 1] = ev
    return ev
end

-- ===== 乘区注册：新伤害加成 = 注册贡献器，伤害公式永不再改 =====
function BattleClass:register_mult(fn)
    self.mults[#self.mults + 1] = fn
end

-- ===== 目标查询（薄路由：普攻排位规则在槽位层，技能选敌在技能层） =====
function BattleClass:dist(a, b)
    if self.slot then
        return self.slot:dist(a, b)                        -- 槽位层排距 |Δrank|（同排=0 贴脸）
    end
    return math.abs(a.rank - b.rank)                       -- 无槽位层退化：直接排距
end
function BattleClass:nearest_enemy(u)
    local best, bd = nil, math.huge
    for _, e in ipairs(self.teams[other_side[u.side]]) do
        if e.alive then
            local d = self:dist(u, e)
            if d < bd then
                best, bd = e, d
           end
        end
    end
    return best
end
-- 普攻选敌薄路由：同排优先（近战列1/远程列2，排距蔓延）全部在槽位层排位规则里
function BattleClass:basic_target(u)
    if self.slot then
        return self.slot:basic_target(self, u)
    end
    return self:nearest_enemy(u)
end
-- ===== 技能层薄路由：机制实现全在 battle_skill.lua（cfg.skillsys 注入），内核只转发 =====
function BattleClass:pick(u, rule)
    if self.skillsys then
        return self.skillsys.pick(self, u, rule)
    end
end
function BattleClass:pick_many(u, rule, n)
    if self.skillsys then
        return self.skillsys.pick_many(self, u, rule, n)
    end
end
function BattleClass:pick_area(u, target, aoe_cfg)
    if self.skillsys then
        return self.skillsys.pick_area(self, u, target, aoe_cfg)
    end
end
function BattleClass:skill_ready(u, sid)
    if self.skillsys then
        return self.skillsys.skill_ready(self, u, sid)
    end
end
function BattleClass:castable_skill(u)
    if self.skillsys then
        return self.skillsys.castable_skill(self, u)
    end
end

-- ===== 结算原语（内核唯一的数值/状态入口，内容脚本只能通过这些组合） =====
-- 基础伤害：基础 × 乘区池（浮动/暴击/内容贡献器），广播 ON_HIT/ON_DEATH
function BattleClass:damage(u, tgt, mult, ev_type)
    local is_crit = self.rand(100) <= u.crit
    local swing = 1 + (self.rand(21) - 11) * (VARIANCE / 10)
    local pool = { mult, swing, is_crit and CRIT_MULT or 1 }
    for _, f in ipairs(self.mults) do
        local m = f(self, u, tgt)                             -- 内容层乘区贡献器
        if m then
            pool[#pool + 1] = m
        end
    end
    local dmg = u.atk
    for _, m in ipairs(pool) do
        dmg = dmg * m
    end
    dmg = math.floor(dmg + 0.5)
    tgt.hp = math.max(0, tgt.hp - dmg)
    u.dealt = u.dealt + dmg
    self.events[#self.events + 1] = cur_event(self, {
                                        type = ev_type,
                                        caster = u.id,
                                        target = tgt.id,
                                        dmg = dmg,
                                        crit = is_crit,
                                        target_hp = tgt.hp
                                    })
    self:emit("ON_HIT", { caster = u, target = tgt, dmg = dmg, crit = is_crit })
    if tgt.hp <= 0 and tgt.alive then
        tgt.alive = false
        u.kills = u.kills + 1
        if self.slot then
            self.slot:release_unit(tgt)                   -- 尸体腾槽：不再参与排位选敌与位移碰撞
        end
        self.events[#self.events + 1] = cur_event(self, {
                                        type =     "KILL",
                                        caster = u.id,
                                        victim = tgt.id
                                    })
        self:emit("ON_DEATH", { caster = u, victim = tgt })
    end
end
function BattleClass:heal(u, tgt, amount)
    if not tgt.alive then return end
    amount = math.floor(amount + 0.5)
    local real = math.min(amount, tgt.hp_max - tgt.hp)
    if real <= 0 then
        return  -- 满血不占事件流
    end
    tgt.hp = tgt.hp + real
    u.healed = u.healed + real
    self.events[#self.events + 1] = cur_event(self, {
                                        type = "HEAL",
                                        caster = u.id,
                                        target = tgt.id,
                                        heal = real,
                                        target_hp = tgt.hp
                                    })
    self:emit("ON_HEAL", { caster = u, target = tgt, heal = real })
end

-- ===== 位移原语（槽位语义三件套：规则/碰撞全在槽位层 battle.slot，内核只判"动不动"并落 MOVE 事件） =====
-- 击退：把 target 向远离施法者方向退 k 排（被占推挤互换，退到后排边界为止）
function BattleClass:knockback(u, target, k)
    if not self.slot then
        return
    end
    local moved = self.slot:knockback(self, u, target, k)
    if moved then
        do_move(self, target, moved.from, moved.to, "KNOCKBACK", target.id)
    end
end
-- 拉扯：把 target 拽到战场中央（中排 rank=1，被占推挤互换）
function BattleClass:pull(u, target)
    if not self.slot then
        return
    end
    local moved = self.slot:pull(self, u, target)
    if moved then
        do_move(self, target, moved.from, moved.to, "PULL", target.id)
    end
end
-- 翻越：施法者落到 target 同排正对位（爱琳"落到敌方身后"的槽位表达，落点被己方占则不动）
function BattleClass:land_behind(u, target)
    if not self.slot then
        return
    end
    local moved = self.slot:land_behind(self, u, target)
    if moved then
        do_move(self, u, moved.from, moved.to, "LAND", u.id)
    end
end

-- 战斗内查询：最近一次自身相关事件（倒序扫描），供内容层做防连发/序列判定
function BattleClass:last_event(caster_id, evtype)
    for i = #self.events, 1, -1 do
        local e = self.events[i]
        if e.caster == caster_id and (not evtype or e.type == evtype) then
            return e
        end
    end
end

-- 出厂默认行为：有技能放技能（按槽位优先级），否则按排位规则普攻。
-- 槽位制没有"走位"（站位即射程），普攻目标由排位规则动态给出，单位永不主动挪位。
function BattleClass:default_behavior(u)
    local cast = self:castable_skill(u)
    if cast then
        return { kind = "CAST", sid = cast.sid, target = cast.target }
    end
    local tgt = self:basic_target(u)
    if tgt and u.atk_cd == 0 then
        return { kind = "BASIC", target = tgt, mult = 1.0 }
    end
end

-- ===== tick 主循环：每格推进时钟 + CD 递减 + 问行为。这就是"不可变骨架"。 =====
function BattleClass:run()
    for i = 1, TOTAL_TICKS do
        if not battle_alive(self) then break end
        self.tick = i
        self.duration = i
        for _, u in ipairs(self.order) do
            if u.alive then
                u.atk_cd = math.max(0, u.atk_cd - 1)
                if self.skillsys then
                    self.skillsys.tick_cds(self, u)          -- 技能层：每 tick 递减技能剩余 CD
                end
                if not battle_alive(self) then
                    break
                end
                local behavior = self.behaviors[u.behavior] or self.default_behavior
                local op = behavior(self, u)                -- 内核只问：现在出手吗？出什么？
                if op then
                    exec(self, u, op)
                end
            end
        end
    end
end

-- 模拟：build -> 绑定内容 bundle -> run -> 结果判定 -> 组装战报
local function simulate(seed, cfg, bundle, id_fmt)
    local battle = BattleClass:new_battle(seed, cfg)
    if bundle then
        for _, f in ipairs(bundle.mults or {}) do battle:register_mult(f) end
        for _, e in ipairs(bundle.listeners or {}) do battle:on(e[1], e[2]) end
    end
    battle:run()

    local function alive_and_hp(side)
        local n, hp = 0, 0
        for _, u in ipairs(battle.teams[side]) do
            if u.alive then
                n, hp = n + 1, hp + u.hp
            end
        end
        return n, hp
    end
    local na, ha = alive_and_hp("A")
    local nb, hb = alive_and_hp("B")
    local reason = (na == 0 or nb == 0) and "WIPE" or "TIMEOUT"
    local winner
    if na > 0 and nb == 0 then
        winner = "A"
    elseif nb > 0 and na == 0 then
        winner = "B"
    elseif na ~= nb then
        winner = (na > nb) and "A" or "B"
    else
        winner = (ha == hb) and "DRAW" or ((ha > hb) and "A" or "B")
    end

    -- 快照：初始面板（含出生槽位 rank/col），供回放/展示
    local snap = { A = {}, B = {} }
    local snap_idx = { A = 0, B = 0 }
    for _, id in ipairs(cfg.lineup) do
        local t = cfg.heroes[id]
        local side = id:sub(1, 1)
        snap_idx[side] = snap_idx[side] + 1
        -- 出生位与开局放人规则一致：槽位层固定坑位，不足 6 人按槽位顺序
        local p = (battle.slot and battle.slot:slot_pos(side, snap_idx[side]))
                  or { rank = snap_idx[side] - 1, col = 0 }
        snap[side][#snap[side] + 1] = {
            id = id, name = t.name,
            hp = t.hp,
            atk = t.atk,
            rank = p.rank, col = p.col,
            range = t.range or 1,
        }
    end

    local stats = {}
    for _, u in ipairs(battle.order) do
        stats[#stats + 1] = {
            id = u.id, name = u.name,
            side = u.side,
            dealt = u.dealt,
            healed = u.healed,
            basic = u.basic_cnt,
            cast = u.cast_cnt,
            moves = u.move_cnt,
            kills = u.kills,
        }
    end
    table.sort(stats, function(x, y) return x.dealt > y.dealt end)

    local rows = battle.slot and battle.slot.rows or 3
    local cols = battle.slot and battle.slot.cols or 2
    return {
        battle_id = id_fmt and string.format(id_fmt, seed) or string.format("BR-AL-%08d", seed),
        rule = {
            seconds = BATTLE_SECONDS,
            hz = TICKS_PER_SEC,
            total_ticks = TOTAL_TICKS,
            board = {
                rows = rows, cols = cols,
                per_side = rows * cols,
                note = "槽位制: rank 0=前排 1=中排 2=后排, col 0=列1 1=列2",
            },
        },
        snapshot = snap,
        duration_ticks = battle.duration,
        duration_ms = math.floor(battle.duration * 1000 / TICKS_PER_SEC),
        events = battle.events,
        stats = stats,
        result = {
            winner = winner, reason = reason,
            alive = { A = na, B = nb },
            left_hp = { A = ha, B = hb },
        },
    }
end

K = {
    TICKS_PER_SEC = TICKS_PER_SEC,
    BATTLE_SECONDS = BATTLE_SECONDS,
    TOTAL_TICKS = TOTAL_TICKS,
    BattleClass = BattleClass,
    new_battle = function(seed, cfg) return BattleClass:new_battle(seed, cfg) end,
    simulate = simulate,
    ser = ser,
    rng_new = rng_new,
}