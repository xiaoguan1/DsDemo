--[[
battle_main.lua —— 爱琳战斗·装配入口（编排层）

分层职责（四文件 + 装配；与 battle/（50×30 网格版）层数一致、空间层不同）：
  kernel.lua         内核：tick 主循环 / 事件 / 乘区池 / 结算与位移原语（低频变更，改了要停机+版本迁移）
  battle_skill.lua   技能：怒气槽 / 技能CD / 施放执行 / 选敌·选区域（七类目标谓词）
  content.lua        内容：12 英雄（222 阵容）/ 10 技能（数值+效果脚本）/ 行为库 / 装配清单（高频变更，可热更）
  battle_slot.lua    槽位：3排×2列 占位 / 排位普攻规则 / 邻域偏移表 / 击退·拉扯·翻越（不认识内核，只改 rank/col）
  battle_main.lua    入口：注入 slot + skillsys → simulate → 摘要 + 战报输出（只做编排）

与网格版（game/global/battle）的差异对照：
  网格版  battle_map(50×30)+battle_move(占格/寻路)，普攻要"够不着→寻路走位"（MOVE=WALK 常态事件）
  槽位版  地图+移动两层合一为 battle_slot(6槽)，普攻永不走位（站位即射程，MOVE 只剩技能位移）
  MOVE 事件 from/to：{x,y} 网格坐标 → {rank,col} 槽位坐标
  普攻选敌：nearest_enemy+寻路 → 排位规则（同排优先，近战打列1/远程打列2，排距蔓延）
  范围伤害：形状模板（菱形/十字，1500 格） → 谓词+邻域偏移表（6 槽）：同构退化，结算复杂度骤降

解耦关键：内核不认识槽位细节，只认 cfg.slot 接口（put_unit/slot_pos/dist/basic_target/
  knockback/pull/land_behind/scan_area）；也不认识技能机制，只认 cfg.skillsys（tick_cds/cast）。
  换站位规则改 battle_slot，换技能机制改 battle_skill，内核与内容层零改动。

扩展套路（新增玩法四步走，内核不动）：
  新属性：英雄表 attrs 加字段 + bundle 加消费该属性的乘区/监听器（参考 B2 破甲 40 / A6 复仇）
  新技能：SKILLS 加一项 + 挂到英雄 skills 数组（数值+on_cast 脚本只在此层）
  新AOE：技能配 aoe={shape,depth,center}，on_cast 用 battle:pick_area（301 全体 / 304 前2排 / 305 溅射）
  新多目标：技能配 multi={rule,n}，on_cast 迭代目标簇（302 攻击最高2 / 303 随机2拉扯）
  新位移：槽位层加原语 + 内核加薄路由（现有击退/拉扯/翻越三件套盖满爱琳位移类）
  新选敌谓词：只改 battle_skill.lua 的 pick/pick_many；新区域形状：只改槽位层 build_neighbor
]]
local KERNEL = Import("game/global/al_battle/kernel.lua")
local CONTENT = Import("game/global/al_battle/content.lua")
local SLOTMOD = Import("game/global/al_battle/battle_slot.lua")
local SKILLMOD = Import("game/global/al_battle/battle_skill.lua")

local K = KERNEL.K
local C = CONTENT.C
local SLOT = SLOTMOD.SLOT
local SKILL = SKILLMOD.SKILL

local SEED = 81003

-- 每场战斗单独装配一个槽位层对象：
-- slot 带占位状态（谁站哪槽），不能跨场复用，否则上一场的站位残留会污染本场确定性
local function fresh_cfg()
    local slot = SLOT.new()
    return {
        lineup = C.lineup,
        heroes = C.heroes,
        skills = C.skills,
        behaviors = C.behaviors,
        slot = slot,                        -- 内核注入槽位层：内核不认识排位/占位/区域细节
        skillsys = SKILL,                   -- 内核注入技能层：内核不认识怒气/CD/选敌/施放机制
    }, slot
end

local function count_event(events, evtype)
    local n = 0
    for i = 1, #events do
        if events[i].type == evtype then n = n + 1 end
    end
    return n
end

local function report_to(report, filename, tag)
    local body = K.ser(report)
    if io and io.open then
        local fp = io.open(filename, "w")
        fp:write("-- 爱琳战斗战报(事件流) 由 battle_main.lua 生成  槽位 ", report.rule.board.rows, "排x",
                 report.rule.board.cols, "列  每方 ", report.rule.board.per_side, " 槽  seed=", SEED, "\nreturn ", body, "\n")
        fp:close()
        print(string.format("战报已写出: %s (%d 字节)", filename, #body))
    else
        print("<<<" .. tag .. "_BEGIN>>>")
        print(body)
        print("<<<" .. tag .. "_END>>>")
    end
end

function Main()
    assert(K, "kernel.lua 未加载")
    assert(C, "content.lua 未加载")
    assert(SLOT, "battle_slot.lua 未加载")
    assert(SKILL, "battle_skill.lua 未加载")

    local cfg, slot = fresh_cfg()
    local report = K.simulate(SEED, cfg, C.bundle)

    print(string.format("== al_battle 装配入口  seed=%d  槽位制 %d排x%d列（每方%d槽）==", SEED,
                        report.rule.board.rows, report.rule.board.cols, report.rule.board.per_side))
    print(string.format("  用时 %.2fs (%d ticks)  事件 %d 条  MOVE:%d CAST:%d HEAL:%d KILL:%d BASIC:%d",
          report.duration_ms / 1000, report.duration_ticks, #report.events,
          count_event(report.events, "MOVE"),
          count_event(report.events, "CAST"),
          count_event(report.events, "HEAL"),
          count_event(report.events, "KILL"),
          count_event(report.events, "BASIC")))
    print(string.format("  槽位层: 位移 %d 次（击退/拉扯/翻越合计，槽位制无走位）", slot.move_cnt))
    print(string.format("  结果: 胜方=%s 原因=%s  存活 A:%d B:%d  剩余血量 A:%d B:%d",
          report.result.winner, report.result.reason,
          report.result.alive.A, report.result.alive.B,
          report.result.left_hp.A, report.result.left_hp.B))

    report_to(report, "battle_report_al.lua", "BR_AL")

    -- 确定性自证：同 seed 再跑一场（换新槽位层），序列化应逐字节一致（内容热更的安全网）
    local cfg2, _ = fresh_cfg()
    local again = K.simulate(SEED, cfg2, C.bundle)
    print("  确定性: " .. ((K.ser(again) == K.ser(report)) and "PASS(同seed战报逐字节一致)" or "FAIL"))
end

function __init__()
    Main()   -- 演示环境直接调用；生产环境改为服务框架入口（如 skynet.start(Main)）
end