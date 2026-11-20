local ostime = os.time

--[[
battle_kernel.lua —— 战报战斗·内核层（稳定骨架，低频变更，改了要停机+版本迁移）

设计目标：
  1) 内核只提供"通用设施"（tick/事件/结算原语/乘区池），不含任何英雄/技能/行为的具体数值与规则；
  2) 新增属性 / 行为 = 只改 battle_content.lua 里的数据与脚本，内核不动；
     技能机制（怒气槽/技能CD/施放/选敌）= 只改 battle_skill.lua（技能层），技能数值与效果脚本仍只在内容层；
  3) 所有遍历基于显式数组（lineup / 有序监听器），保证同 seed 战报逐字节可复现。

类 / 对象结构（与项目 oop/class.lua 的 Class.NewClass 配套）：
  BattleClass = Class.NewClass("<<battle class>>")            -- 类模板：全部战斗方法定义在类上
  battle = BattleClass:new_battle(seed, cfg)                  -- 工厂：生成一个战斗对象
  setmetatable(battle, { __index = BattleClass })             -- 实例经元表访问类方法
  -- 战斗状态(seed/units/events/tick/rand...)全部是实例字段，方法一律从 self 读取；
  -- 原闭包私有状态(rand/cur_event/do_move/exec...)收敛为"实例字段 + 模块局部函数(显式传 self)"。

稳定接口速览（内容层/入口只允许用这些）：
  K.simulate(seed, cfg, bundle)            装配并跑完一场，直接产出战报
  BattleClass:new_battle(seed, cfg)        建战斗 -> 挂 bundle -> battle:run()
  battle:on(event, fn) / battle:emit(...)  事件订阅/广播（有序监听器，执行顺序确定）
  battle:register_mult(fn)                 伤害乘区贡献器（新伤害规则=注册一条，公式永不改）
  battle:pick(u, rule) / pick_area(...)    选敌/选区：薄路由，技能机制实现全在 battle_skill.lua
  battle:skill_ready / castable_skill      技能槽查询：薄路由，技能机制实现全在 battle_skill.lua
  battle:event(extra)                      事件构造原语（tick/ms 自动填充并落队，技能层等依赖方用）
  battle:damage / heal / dash / knockback  唯一结算原语（内容脚本只能通过这些组合）
  battle.default_behavior(battle, u)       出厂默认行动逻辑（内容层行为可 fallback 到它）

约定：
  - 战场是 50×30 网格地图：站位/距离/寻路在 battle_map.lua（地图层），
    占格/走位/突进/击退在 battle_move.lua（移动层）；内核只注入 cfg.mover 调用，
    不认识格子细节，换地图/换寻路算法内核零改动；
  - 技能机制在 battle_skill.lua（技能层），经 cfg.skillsys 注入（与 mover 同款约定）：
    内核 tick 循环只回调它的 tick_cds/cast，其余技能接口走薄路由转发，
    内核不认识怒气/CD/选敌规则，新技能机制只改技能层；
  - 单位固定字段(hp/atk/x/y/range...)之外，扩展属性一律进 attrs 池，内核无感知；
  - 英雄 N 个技能 = skills 数组（顺序即释放优先级），每个技能独立 CD。
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
    for k, val in pairs(v) do                          -- 其余键值部分
        if not (type(k) == "number" and k >= 1 and k < n) then
            local kk = type(k) == "number" and string.format("[%d]", k) or k
            parts[#parts + 1] = "  " .. kk .. " = " .. ser(val)
        end
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n}"
end

--[[ 建战斗：完全数据驱动。
  cfg = {
    lineup    = { id, ... }                                行动顺序（显式数组，确定性关键）
    heroes    = { id -> { name, hp, atk, atk_int(秒), range, move_spd, skills, behavior, attrs } }
                （站位不再配在英雄上：出生位由 cfg.mover:slot_pos(阵营, 该方第几个) 决定）
    skills    = { sid -> { name, rage, cd_s, pick, on_cast(battle,u,target) } }
    behaviors = { key -> function(battle, u) return op }   多套行为逻辑，英雄表只记 key
    mover     = 移动层对象（占格/走位/突进/击退），由入口注入；nil 时退化为不移动、原地互打
  } ]]

BattleClass = Class.NewClass("<<battle class>>")

local other_side = { A = "B", B = "A" }

-- ===== 模块私有辅助（原 new_battle 闭包函数，现显式接收 battle 作 self） =====
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

-- 统一落 MOVE 事件：坐标/路径/碰撞全在移动层算完，内核只负责记录（from/to 是 {x,y} 格坐标）
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
    elseif kind == "MOVE" then
        self:move_step(u, op.target)
    end
end

-- ===== 类方法区：全部定义在 BattleClass 上，实例经 __index 元表访问 =====

-- 工厂：生成战斗对象。状态全部落在实例字段，方法在类表，实例元表指回类。
function BattleClass:new_battle(seed, cfg)
    local battle = {
        seed = seed,                        -- 随机种子：同 seed 全场随机序列一致，战报可复现
        rand = rng_new(seed),               -- 本场专用 LCG 随机函数（唯一随机入口，结算必须走它）
        heroes = cfg.heroes,                -- 英雄配置表 id->{name,hp,atk,...}：引用内容层数据，内核只读
        skills = cfg.skills or {},          -- 技能配置表 sid->{name,rage,cd_s,pick,on_cast}
        behaviors = cfg.behaviors or {},    -- 行为函数表 key->fn：多套行为逻辑按 key 挂载
        mover = cfg.mover,                  -- 移动层对象（入口注入；内核不认识地图/寻路，只调它位移/判距/腾格）
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
        -- 出生位：地图层固定坑位（A 左 B 镜像右，不足 5 人按槽位顺序取）；无移动层时退化为序号
        local slot = (battle.mover and battle.mover:slot_pos(side, side_idx[side]))
                     or { x = side_idx[side], y = 0 }
        local u = {
            id = id,                                     -- 单位唯一 id（如 "A1"/"B2"，首字符即阵营）
            side = side,                                 -- 阵营 "A"/"B"
            name = t.name,                               -- 英雄名（战报展示用）
            hp_max = t.hp,                               -- 血量上限（出生满血，复活/治疗封顶用）
            hp = t.hp,                                   -- 当前血量：归零触发死亡/击杀
            atk = t.atk,                                 -- 基础攻击：伤害结算基数（被动加成直接改它）
            crit = t.crit or 0,                          -- 暴击率 0-100：damage 内 rand(100) <= crit 判定
            atk_cd_max = math.floor(t.atk_int * TICKS_PER_SEC + 0.5),  -- 普攻间隔：秒 -> 格
            atk_cd = 0,                                  -- 普攻剩余 CD 格数：0 才可出手，每 tick -1，走位不重置
            rage = 0,                                    -- 怒气/能量槽 0..100：出手/受击攒(内容层)，放技能扣(技能层)
            skills = t.skills or {},                    -- 拥有技能 id 数组（顺序 = 释放优先级）
            skill_cds = {},                             -- 各技能独立剩余 CD：sid -> 格数（互不共享）
            x = slot.x,                                  -- 当前横坐标：出生位 = 地图层固定坑位
            y = slot.y,                                  -- 当前纵坐标：B 侧坐标镜像对称，占格由移动层维护
            range = t.range or 1,                        -- 射程：1=近战（够不着自动走位），99=远程（原地输出）
            move_spd = t.move_spd or 1,                  -- 每 tick 最大移动格数（WALK 步长上限，0=不可移动）
            behavior = t.behavior or "default",          -- 行为策略 key：查 behaviors 表，未命中 fallback 默认行为
            attrs = t.attrs,                            -- 扩展属性池：新属性只进这里，内核无感知
            alive = true,                                -- 存活标记：false 后不再出手、排除出选敌/治疗
            dealt = 0,                                   -- 统计：累计造成伤害
            healed = 0,                                  -- 统计：累计治疗量
            basic_cnt = 0,                               -- 统计：普攻次数
            cast_cnt = 0,                                -- 统计：技能释放次数
            move_cnt = 0,                                -- 统计：移动次数（WALK/DASH/KNOCKBACK 都计入）
            kills = 0,                                   -- 统计：击杀数
        }
        battle.units[id] = u                             -- 全局索引：按 id 唯一取单位
        battle.teams[side][#battle.teams[side] + 1] = u  -- 分边归档：按阵营存入队伍数组
        battle.order[#battle.order + 1] = u              -- 行动顺序：严格按 cfg.lineup 排列（确定性关键）
        if battle.mover then
            battle.mover:put_unit(u)                     -- 出生占格（一格最多一个，碰撞自此生效）
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

-- ===== 目标查询（行走/普攻用；技能选敌在技能层） =====
function BattleClass:dist(a, b)
    if self.mover then
        return self.mover:dist(a, b)                        -- 地图层曼哈顿距离（走路步数口径）
    end
    return math.abs(a.x - b.x) + math.abs(a.y - b.y)        -- 无移动层退化：坐标曼哈顿
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
-- ===== 技能层薄路由：机制实现全在 battle_skill.lua（cfg.skillsys 注入），内核只转发 =====
-- 内容层脚本维持 battle:xxx 调用习惯；未注入技能层时返回 nil（退化：无技能可放）
function BattleClass:pick(u, rule)
    if self.skillsys then
        return self.skillsys.pick(self, u, rule)
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
        if self.mover then
            self.mover:release_unit(tgt)                 -- 尸体腾格：不再阻挡寻路/落位（战报无此事件）
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

-- ===== 移动原语（坐标/路径/碰撞全在移动层 battle.mover，内核只判"动不动"并落 MOVE 事件） =====
-- 常态走位：向目标走近（队友挡路自动绕行），走到恰好进入射程为止。
-- 不重置普攻 CD → 下个 tick 继续走/够得着就出手，走位与输出自然衔接。
function BattleClass:move_step(u, target)
    if not self.mover then
        return
    end
    if self:dist(u, target) <= u.range then
        return
    end
    local moved = self.mover:move_toward(u, target, u.move_spd, u.range)
    if moved then
        do_move(self, u, moved.from, moved.to, "WALK", u.id)
    end
end
-- 位移技能：突进到目标相邻格（目标原地不动；邻格被占由移动层就近另寻空位）
function BattleClass:dash(u, target)
    if not self.mover or not target.alive then
        return
    end
    local moved = self.mover:dash(u, target)
    if moved then
        do_move(self, u, moved.from, moved.to, "DASH", u.id)
    end
end
-- 控制技能：把目标沿远离方向推 k 格（撞墙/撞人停在最后可走格，由移动层一格一格试）
function BattleClass:knockback(u, target, k)
    if not self.mover or not target.alive or k <= 0 then
        return
    end
    local moved = self.mover:knockback(u, target, k)
    if moved then
        do_move(self, target, moved.from, moved.to, "KNOCKBACK", target.id)
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

-- 出厂默认行为：有技能放技能（按槽位优先级），否则走位/普攻。
-- 内容层做"多套行为逻辑"时只写新函数并 fallback 到这里，内核无需知道每套逻辑的细节。
function BattleClass:default_behavior(u)
    local cast = self:castable_skill(u)
    if cast then
        return { kind = "CAST", sid = cast.sid, target = cast.target }
    end
    local tgt = self:nearest_enemy(u)
    if tgt then
        if self:dist(u, tgt) > u.range then
            return { kind = "MOVE", target = tgt }          -- 走位不占普攻 CD
        elseif u.atk_cd == 0 then
            return { kind = "BASIC", target = tgt, mult = 1.0 }
        end
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

    -- 快照：初始面板（含出生站位），供回放/展示
    local snap = { A = {}, B = {} }
    local slot_idx = { A = 0, B = 0 }
    for _, id in ipairs(cfg.lineup) do
        local t = cfg.heroes[id]
        local side = id:sub(1, 1)
        slot_idx[side] = slot_idx[side] + 1
        -- 出生位与开局放人规则一致：地图层坑位，不足 5 人按槽位顺序
        local p = (battle.mover and battle.mover:slot_pos(side, slot_idx[side]))
                  or { x = slot_idx[side], y = 0 }
        snap[side][#snap[side] + 1] = {
            id = id, name = t.name,
            hp = t.hp,
            atk = t.atk,
            x = p.x, y = p.y,
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

    local mi = (battle.mover and battle.mover.map) or {}
    return {
        battle_id = id_fmt and string.format(id_fmt, seed) or string.format("BR-%08d", seed),
        rule = {
            seconds = BATTLE_SECONDS,
            hz = TICKS_PER_SEC,
            total_ticks = TOTAL_TICKS,
            map = { w = mi.w or 0, h = mi.h or 0 }
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
