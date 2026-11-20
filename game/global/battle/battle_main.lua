--[[
battle_main.lua —— 战斗入口（装配层）

分层职责（对应项目 import.lua 按序加载的六文件）：
  battle_kernel.lua   内核：tick 主循环 / 事件 / 乘区池 / 结算与移动原语（低频变更，改了要停机+版本迁移）
  battle_skill.lua    技能：怒气槽 / 技能CD / 施放执行 / 选敌选范围（机制层，新选敌规则等只改这里）
  battle_content.lua  内容：英雄 / 技能库(数值+效果脚本) / 行为库 / 被动监听 / 装配清单（高频变更，可 SafeImport 热更）
  battle_map.lua      地图：尺寸 / 每方 5 固定坑位 / 边界 / 距离 / A* 寻路（不认识单位，occupied 由调用方注入）
  battle_move.lua     移动：占格表 / 走位 / 突进 / 击退（不认识内核，只改 x,y 与占格，不发事件）
  battle_main.lua     入口：装配 map + mover + skillsys 注入 cfg → simulate → 摘要 + 战报输出（只做编排）

解耦关键：内核不认识地图/寻路，只认 cfg.mover 三个位移接口（move_toward/dash/knockback）；
也不认识技能机制，只认 cfg.skillsys 回调（tick_cds/cast），选敌/选区走 battle 薄路由。
换地图/换碰撞规则改 map/move，换技能机制改 battle_skill，内核与内容层零改动。

扩展套路（新增玩法四步走，内核不动）：
  新属性：英雄表 attrs 加字段 + bundle 加消费该属性的乘区/监听器（参考 B3 破甲 40 / A3 复仇被动）
  新技能：SKILLS 加一项 + 挂到英雄 skills 数组（参考 102 影袭=突进、103 震荡击=击退、104 圣光=治疗）
  新AOE：技能配 aoe={shape,size,center,filter}，on_cast 用 battle:pick_area（202 地震波=菱形、203 十字斩=十字）
  新行为：BEHAVIORS 加函数 + 英雄表 behavior 字段指过去，未覆盖处 fallback 内核默认行为
  新技能机制：只改 battle_skill.lua（如新选敌规则给 pick 加分支、新施放条件改 skill_ready）
  新地图/新站位：只改 battle_map.lua；新碰撞/新位移：只改 battle_move.lua，战报保持 MOVE(from/to) 事件
]]
local KERNEL = Import("game/global/battle/kernel.lua")
local CONTENT = Import("game/global/battle/content.lua")
local MAPMOD = Import("game/global/battle/battle_map.lua")
local MOVEMOD = Import("game/global/battle/battle_move.lua")
local SKILLMOD = Import("game/global/battle/battle_skill.lua")

local K = KERNEL.K
local C = CONTENT.C
local MAP = MAPMOD.MAP
local MOVE = MOVEMOD.MOVE
local SKILL = SKILLMOD.SKILL

local SEED = 81002

-- 每场战斗单独装配一张地图 + 一个移动器：
-- mover 带占格状态（谁站哪格），不能跨场复用，否则上一场的站位残留会污染本场确定性
local function fresh_cfg()
    local map = MAP.new(MAP.W, MAP.H)
    local mover = MOVE.new(map)
    return {
        lineup = C.lineup,
        heroes = C.heroes,
        skills = C.skills,
        behaviors = C.behaviors,
        mover = mover,                      -- 内核注入移动层：内核不认识地图/寻路细节
        skillsys = SKILL,                   -- 内核注入技能层：内核不认识怒气/CD/选敌/施放机制
    }, mover
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
        fp:write("-- 战报(事件流) 由 battle_main.lua 生成  地图 ", report.rule.map.w, "x", report.rule.map.h, "  seed=", SEED, "\nreturn ", body, "\n")
        fp:close()
        print(string.format("战报已写出: %s (%d 字节)", filename, #body))
    else
        print("<<<" .. tag .. "_BEGIN>>>")
        print(body)
        print("<<<" .. tag .. "_END>>>")
    end
end

function Main()
    assert(K, "battle_kernel.lua 未加载")
    assert(C, "battle_content.lua 未加载")
    assert(MAP, "battle_map.lua 未加载")
    assert(MOVE, "battle_move.lua 未加载")

    local cfg, mover = fresh_cfg()
    print("C.bundle ", tool.dumptree(C.bundle))
    local report = K.simulate(SEED, cfg, C.bundle)

    print(string.format("== bmain 装配入口  seed=%d  地图 %dx%d ==", SEED, report.rule.map.w, report.rule.map.h))
    print(string.format("  用时 %.2fs (%d ticks)  事件 %d 条  MOVE:%d CAST:%d HEAL:%d KILL:%d",
          report.duration_ms / 1000, report.duration_ticks, #report.events,
          count_event(report.events, "MOVE"),
          count_event(report.events, "CAST"),
          count_event(report.events, "HEAL"),
          count_event(report.events, "KILL")))
    print(string.format("  移动层: 寻路 %d 次  总位移 %d 格（走位/突进/击退合计）", mover.astar_cnt, mover.steps_cnt))
    print(string.format("  结果: 胜方=%s 原因=%s  存活 A:%d B:%d  剩余血量 A:%d B:%d",
          report.result.winner, report.result.reason,
          report.result.alive.A, report.result.alive.B,
          report.result.left_hp.A, report.result.left_hp.B))

    report_to(report, "battle_report_v5_aoe.lua", "BRV5_AOE")

    -- 确定性自证：同 seed 再跑一场（换新地图+新移动器），序列化应逐字节一致（内容热更的安全网）
    local cfg2, _ = fresh_cfg()
    local again = K.simulate(SEED, cfg2, C.bundle)
    print("  确定性: " .. ((K.ser(again) == K.ser(report)) and "PASS(同seed战报逐字节一致)" or "FAIL"))
end

function __init__()
    Main()   -- 演示环境直接调用；生产环境改为服务框架入口（如 skynet.start(Main)）
end