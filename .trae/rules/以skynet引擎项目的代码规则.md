# skynet 引擎项目统一代码规则

> 适用范围：所有以 skynet（cloudwu/skynet）为服务器引擎的 Lua 项目。
> 各项目服务器架构不尽相同，本文按约束强度分三级标注：
>
> - 【统一规范】：所有 skynet 项目必须遵守（目录结构、起服方式、热更、协议、通用工具、命名）。
> - 【默认实现】：以 GameDemo 为参考模板的实现，其他项目可整体沿用、替换或裁剪（网关、集群通信、数据库、后台管理等）。
> - 【项目自定义】：完全由各项目自行设计，仅要求写进本项目文档（见第 13 节清单）。

---

## 1. 顶层目录结构【统一规范】

```
<项目根>/
├── skynet/            # 引擎本体（第三方，默认不改；如必须改动需注释说明，如 lauxlib.c 的 clearone 接口）
├── config/            # 节点起服配置（每种节点类型一份配置文件）
├── game/              # 游戏业务代码
│   ├── service/       # 玩法逻辑服务（每个服务一个子目录）
│   └── global/        # 全局公共模块（工具、日志、宏、类、算法等，全项目共享）
├── tool/              # 引擎级工具与基础设施（与具体玩法无关，可跨项目复用）
│   ├── service/startup/  # 起服入口服务（由 config 的 start 字段指定）
│   ├── service/basic/    # 基础设施服务（数据库、定时器、集群通信、日志收集等）
│   ├── luaplugins/       # 启动预加载与全局扩展（import.lua、table/string 扩展等）
│   ├── cplugins/         # C 插件源码
│   ├── cplugins-so/      # 编译后的 .so
│   └── 3rd/              # 第三方库源码
├── protocol/          # 协议定义与生成（与玩法解耦）
│   ├── protos/        # *.proto 协议源文件
│   ├── pbs/           # 编译产物 *.pb
│   └── ...            # 生成工具与自动生成的协议表
└── log/               # 运行时日志（按节点名分目录）
```

职责边界：
- `tool/` 只放与具体玩法无关的引擎级能力（基础设施服务、工具、插件）。
- `game/` 放业务：`game/service/` 是玩法服务，`game/global/` 是业务侧公共库。
- `protocol/` 独立于服务代码，协议表由工具生成，禁止手改生成产物。

## 2. 起服配置与启动脚本【统一规范】

- 每种节点类型一份配置文件，放 `config/` 下；配置是 Lua 源码格式（skynet config 语法）。节点类型的划分由项目架构决定。
- 配置文件必须包含且保持以下关键段，项目可增补：
  - 引擎：`thread`、`cpath`、`bootstrap`、`start`（指向 `tool/service/startup/` 下的入口服务）、`lualoader`。
  - `luaservice` 按固定顺序排列：`tool/service/startup/`（起服相关）→ `tool/service/basic/`（基础设施）→ `game/service/`（玩法服务）→ `skynet/service/`（内置）。
  - `lua_path`：`game/global/`、引擎 lualib、项目 lualib。
  - `lua_cpath`：`tool/cplugins-so/`、引擎 luaclib。
  - 预加载钩子：`apreload`、`preload` 指向 `tool/luaplugins/`（apreload 用于主入口完成必要操作后再向后续服务开放节点数据）。
  - 节点信息段：`node_name`、`cluster_no`、`server_id`、`is_testserver`（测试服标记，决定 debug 日志等行为）。字段名统一，取值随项目架构而定。
  - 运行参数：数据库、日志、监听端口、证书等（具体内容见对应【默认实现】章节）。
- 不使用 skynet 主从节点模式（`harbor = 0`）；跨节点通信方案由项目自选（默认实现见第 9 节，可整体替换）。

## 3. 服务分层与目录约定【统一规范】

- 基础设施服务：放在 `tool/service/basic/<服务名>/`。所有节点都需要的基础能力（数据库、定时器、集群通信、日志收集等）必须注册为基础设施服务，与玩法解耦。
- 玩法服务：放在 `game/service/<服务名>/`，每个服务一个子目录，目录内分工（以 GameDemo 的 `game/service/wgate/` 为例）：
  - `wgate.lua` —— 服务启动文件（skynet.start 入口：先 `dofile ./game/global/log.lua` 初始化日志，注册协议后 `dofile` 加载本服务 `global.lua`，最后打印启动成功日志）。
  - `global.lua` —— 服务内逻辑装载文件：只负责把 `module/`（及 `handle/`）下的逻辑模块 Import 进来挂到服务环境、供服务内共享（如 `WHANDLE = Import("game/service/wgate/module/whandle.lua")`）。**不提倡**在 global.lua 中直接编写业务逻辑（如直接实现 ACCEPT/RESPONSE 函数体）。
  - `module/` —— 具体业务逻辑模块（ACCEPT/RESPONSE 等处理函数都实现在这里，global.lua 仅做装载与转发）。
  - `handle/` —— 该服务对外暴露的管理指令（含热更指令）。
- 服务命名、`SERVICE_NAME` 宏、namedsvr 注册名保持一致（见 `game/global/macro/namedsvr.lua`）。

## 4. 热更机制【统一规范】

- 模块加载一律使用 `Import("game/xxx.lua")`（由 `tool/luaplugins/import.lua` 提供），**不用** `require` 加载业务模块；`require` 仅用于引擎库/第三方库。
- 热更基于 `loadfile`/`dofile` + skynet.codecache；引擎侧需提供清单个文件缓存的接口（lauxlib.c 的 clearone）。
- Import 的热更语义：
  - 模块的 function env 不变（大量逻辑依赖 fenv，如 callout）。
  - 模块内 table 引用继续有效，通过「新内容 inject 到旧 table」完成替换。
  - 禁止 `local func = xxx.foo` 这类把模块函数提为 local 再引用的写法（热更后不会更新）。
- Import 模块生命周期回调（统一约定）：
  - `__init__` —— 模块首次加载时执行（构造逻辑）。
  - `__destroy__` —— 模块热更前执行（旧模块清理，如释放句柄、摘除 metatable 钩子）。
  - `__protocol__` —— 热更时在模块新代码执行后、表还原前立即执行（协议相关处理优先，防止 global 对象被改）。
  - `__update__` —— 热更表还原后执行（重新设置运行时内容，如 rpc 注册等）；回调内禁止阻塞操作（会引起多协程运行错误）。
- 热更失败自动回滚：新代码执行失败时恢复旧模块内容（含旧 `__update__`）并报错。
- 模块可热更的前提：包含 local 动态数据的模块不能 Update（更新会导致数据丢失），此类模块改动后需重启节点。
- pool 服务中 `__init__`/`__update__`/`__protocol__` 内禁止注册新的 callout（import.lua 会检查告警）。
- class.lua 与类模板的热更（区分两类对象）：
  - `oop/class.lua` 本身**不支持热更**：它在 preload 阶段通过 `require "oop.class"` 加载为全局 `Class`，不经过 Import 热更通道，也没有对应的 Update 路径。修改 class.lua（`NewClass` 实现、`AllClasses` 类注册表逻辑等）后必须重启节点才能生效。
  - 通过 `Class.NewClass(className)` 生成的类模板 table **支持热更**，机制如下：
    - 类模板热更时会重新执行文件、再跑一次 `NewClass`，返回一个新类 table；但 `AllClasses` 注册表只登记首次创建时的类，新返回的类 table 随后被丢弃（策略：无视它）。
    - import.lua 在热更还原阶段发现旧值是带 `__ClassType` 字段的 table 时，调用 `ReplaceTbl` 把新类内容**全量 inject 进旧类 table**：逐键递归替换、删除新类中已移除的成员、合并新增成员、并把 metatable 更新为新类的 metatable。外界持有的旧类引用因此继续有效，且能看到新内容。
    - `__ClassType`（类名标识）与 `__CreateClass`（创建时间）两个字段在 inject 时被忽略（ClassIgnoreFields），永远不会被热更覆盖。
    - 对比：模块中**普通数据 table** 热更时默认不更新（保留旧数据），只有带 `__ClassType` 的类模板 table 才做全量 ReplaceTbl。
  - 由此产生的约束：
    - 类模板字段不得与 `__ClassType`、`__CreateClass` 冲突。
    - 项目类体系**无继承**（ReplaceTbl 假设类之间没有继承关系），不要在类模板中引入继承机制。
    - 业务代码只通过全局 `Class` 接口使用类，不得直接依赖 class.lua 的内部实现（如 `AllClasses`、`GetAllClasses`）。
    - 热更后类模板不再调用 `NewClass`（类被删除/改名）时，旧类 table 找不到 inject 目标，将保持旧内容不变——删除类需要重启节点才能生效。
- 协议热更：协议表由生成工具重建，服务热更时重新 dofile `protocol/protomap.lua` 并重建反向索引。
- 热更指令统一由管理服务分发（经各服务 `handle/` 下的热更指令），不散落各服务。

## 5. 协议机制【统一规范】

- 协议使用 protobuf2（pbc），服务端共享 pb 并支持热更（协议增删改）。
- 流程：业务侧在 `game/global/rprotomap.lua` 维护协议信息（协议名 -> {desc, request, response}，type 自动推导），`protocol/protos/*.proto` 为手写源 → 运行生成工具 `protocol/gen_proto.lua` → 产出 `protocol/pbs/*.pb`、`protocol/save-prot-id`（协议名->编号持久化，保证旧协议编号不变、新协议编号递增）与 `protocol/protomap.lua`（自动生成，均禁止手改）。
- 每个服务各加载一份协议表（`game/global/proto.lua` 提供封装：编号↔名称反向索引、request 解码、response 编码）。
- 消息头约定：
  - 帧头：协议编号（服务协议类型 3 字节；rpc 协议类型 1 字节）。
  - 请求/响应分发：session==0 为上行请求（ACCEPT/CLIENT_ACCEPT 表），非 0 为响应（RESPONSE/CLIENT_RESPONSE 表），响应需 `skynet.retpack`。
- 面向客户端的服务注册 client 协议：`skynet.register_protocol { name = "client", id = skynet.PTYPE_CLIENT, ... }`，按 session 分发到 ACCEPT/RESPONSE。

## 6. 通用工具接口【统一规范】

- 类与对象：`game/global/oop/`（class.lua：`Class.NewClass(className)` 生成支持热更的类模板）。项目中类无继承体系，用组合。
- 日志：`game/global/log.lua`（服务内 dofile 后直接使用）：
  - 分级接口：`_INFO / _DEBUG / _WARN / _ERROR / _MEM_ALARM / _LOG_EVENT`，均有 `_F(fmt, ...)` 格式化版本。
  - 日志按级别落到 `./log/<node_name>/<level>/`，按天分文件；写文件统一走 gamelog 基础设施服务，服务内不自行写文件。
  - `_DEBUG` 仅在 `is_testserver == true` 时输出。
- 宏定义：`game/global/macro/`（common.lua、namedsvr.lua 服务名注册、fenv.lua、color.lua 日志颜色），由 preload 统一加载。
- 全局扩展（preload 时加载）：`tool/luaplugins/` 下 table.lua、string.lua、tool.lua、posix.lua。
- 其他公共库放 `game/global/`（util、queue、algorithm/、findpath/、rpc/ 等），全部通过 `Import` 加载。
- 服务容错调用使用 `TryCall(func, ...)`（xpcall 包装，返回 isOk, ...）。

## 7. 命名规范【统一规范】

| 类别 | 规范 | 示例 |
|---|---|---|
| 全局方法 | 大驼峰 PascalCase | `NewClass` |
| 局部方法 | 小驼峰 camelCase | `loadPlayerData` |
| 全局变量 | 全小写 + 下划线 | `aa_bb_cc` |
| 常量/宏/枚举 | 全大写 + 下划线 | `AA_BB_CC` |
| 局部变量 | 小驼峰 camelCase | `playerId` |

- 只允许字母和数字，不使用拼音缩写以外的随意缩写。

## 8. 代码书写约束【统一规范】

- 任何方法内不得创建全局变量；全局变量只能在文件顶部事先声明（Import 模块运行期新增全局变量会触发 BindCheckLeak 告警，需及时处理）。
- 服务内不得阻塞调用（skynet.call 等）嵌套过深；热更回调内禁止阻塞。
- 业务模块一律 `Import` 加载；禁止 `local func = Import(...)` 后跨热更持有函数引用（见第 4 节）。
- 公共协议/表生成产物（`protocol/protomap.lua`、`protocol/save-prot-id`、`pbs/*.pb`）禁止手改，只能通过生成工具再生成。
- 修改 `skynet/` 引擎本体必须注释说明原因与影响面。
- 日志使用统一 log.lua 接口，禁止在服务内直接 `print`/`skynet.error` 输出业务日志。

## 9. 跨节点通信与集群【默认实现】

> 其他项目若采用不同架构（单节点、skynet cluster、其他 RPC 方案等），本节可整体替换；但热更、协议、目录规范不受影响。

- 集群通信由基础设施服务 gcluster（`tool/service/basic/gcluster/`）承载，走自研协议而非 skynet 主从模式。
- 消息约定：
  - 分异步（无需等待响应）与同步（需等待响应）两类。
  - 消息数据必须携带发送方节点信息（ip:port）与服务地址。
  - 同步消息必须携带 session；超时 3 秒。
  - 心跳：5 秒间隔（期间有消息发送则跳过）；对端 9×5 秒无任何消息则判死关闭 socket（不依赖 socket keepalive 做保活）。
- 跨节点调用约定：统一走 rpc 模块（`game/global/rpc/`），调用格式 `rpc.mod_call.服务名称[网络地址].模块名称.函数名称(参数...)`；每个服务都需加载 rpc 模块并提前设置，热更时在 `__update__` 中重新设置（不得有阻塞操作）。
- 节点类型：user（玩家服）、cross（跨服）、adhoc（临时/热门玩法节点）；区分「机器节点」（物理进程，经数据库 server_config 获取）与「lua 服务节点」（逻辑服务，经 namedsvr 获取），两者可相同（本地服务）也可不同（寄生服务）。

## 10. 网络接入【默认实现】

> 其他项目可替换网关方案（TCP/socket、单实例网关等），网关与业务分离的原则不变。

- 客户端连接统一走 websocket 网关（wgate），网关无状态支持多实例（监听端口按实例序号错开，命名 `.WGATE`/`.WGATE2`...）。
- 网关只负责连接管理与协议帧转发，玩家业务逻辑由 agent 服务承载；agent 实例容量与开服数量由配置控制（`agent_max_player`、`agent_default_num`）。

## 11. 后台管理【默认实现】

- 每个节点启动管理服务（manage/mconsole），监听 `mcs_port` 提供管理指令（热更、关闭服务等，经各服务 `handle/` 分发），访问有 IP 白名单限制。

## 12. 数据库设计【默认实现】

> 允许各项目按实际情况差异化设计；此处的「两层库」思路可作为参考。

- 数据库按「两层」设计（当前采用 MySQL）：
  - `centerdatadb_info` —— 全服共享库 `centerdata`：目前仅有一张表 `server_config`，但作用重大——定义每个服务的关键启动逻辑（节点注册信息、服务与网络地址映射等），是服务器分布式部署的核心支撑。机器节点信息依赖此表获取（lua 服务节点信息则通过 namedsvr 获取）。
  - `database_info` —— 区服逻辑库：以区服编号命名（如 `server1`、`server55001`），存放该服务器具体的业务逻辑数据，随节点属性而异（每个节点配置指向自己的区服库）。

## 13. 项目自定义清单【项目自定义】

各项目自行设计以下内容，但必须写进本项目文档（README/设计文档）：

- 节点类型划分与集群拓扑（单节点/多节点、user/cross/adhoc 的取舍）。
- 跨节点通信方案（沿用 gcluster 或替换）。
- 网关方案（websocket/TCP、单实例/多实例）。
- 玩法服务的具体划分（game/service 下具体有哪些服务）。
- 数据库表结构、选型与分库策略、区服/合服策略。
- 各服务内部模块结构。
