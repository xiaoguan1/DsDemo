# Redis 知识点梳理（DsDemo playdata 实战）

> 目的：把本项目里用到的 Redis 知识系统串一遍，既能在代码里对上号，也能补齐面试/排障常用的底层概念。
>
> 阅读建议：先看第 1、2 章建立模型，再按“数据类型 → 原子脚本 → 缓存模式 → 锁/CAS → 队列 → 集群/运维”顺序看。每章末尾的“本项目对应”可以直接跳到代码。

---

## 0. 一张图看懂本项目怎么用 Redis

```text
example（play 节点上的无状态玩法服务）
   │  mem_add_score / mem_read / mem_cas
   ▼
dbserver（mem 协议，按业务 key 哈希）
   │
   ▼
dbcell（每个 play 节点 4 个）
   ├─ Redis：热层缓存、锁、排行榜、注册表、持久化队列
   └─ MySQL：database_info（同 cluster 的 play 共享），热层未命中时直接回源
          │
          ▼
   持久化消费者：RPOPLPUSH 队列 → MySQL upsert → LREM ack
```

四个角色：

| 角色 | 典型 Key | 代码位置 |
|---|---|---|
| 热层缓存 | `play:activity:{game}:<id>`、`play:profile:{game}:<id>:<uid>` | `game/global/playdata/server.lua` |
| 分布式锁 | `<业务key>:lock` | `server.lua` 的 `_AcquireLock/_ReleaseLock` |
| 持久化队列 | `play:persist:queue`、`:dead`、`:processing:*` | `server.lua` 的 `StartConsumer` |
| 实例注册表 | `play:reg:{game}:<instance>`、`:idx`、`:gen` | `tool/service/basic/dbcell/mem_registry.lua` |

---

## 1. Redis 基础执行模型

### 1.1 单线程执行命令

Redis 处理命令的主线程是单线程的（网络 I/O 可以是多线程，但命令执行是串行的）。这带来两个直接结论：

1. **单条命令天然原子**：`INCR`、`SET NX`、`RPUSH` 不会被打断。
2. **多条命令之间不保证原子**：`GET` 之后再 `SET`，中间可能插入别的客户端的命令。

所以本项目里所有“读-判断-写”的复合操作，都放进了 Lua 脚本或用了单条原子命令：

- 抢锁：`SET key token NX EX 5`（一条命令）
- CAS + 入队：`EVAL` 脚本
- 注册代次比较：`EVAL` 脚本

### 1.2 返回值：nil 不是错误

Redis 的 `GET` 在 key 不存在时返回 nil；网络/命令错误则是另一回事。本项目的 `dbcell_mem.Exec` 约定：

```lua
-- 成功：返回结果（可能是 nil，例如 GET 未命中）
-- 失败：返回 nil, err
local value, err = DBMEM.Exec("get", key)
```

这就是为什么 `playdata/server.lua` 里到处是 `if err then ... end`，而不是只看返回值是否为 nil。

### 1.3 连接与并发

本项目每个 dbcell 持有一个 Redis 连接，底层是 skynet 的 `socketchannel`：

- 一个连接可以被多个协程同时使用，请求按序发送、响应按序匹配；
- 某个协程在等 Redis 响应时会挂起，不会阻塞整个服务；
- 连接失败后进入 1 秒冷却，避免每个请求都卡在重连上；
- 60 秒一次 `PING` 保活。

对应代码：`tool/service/basic/dbcell/dbcell_mem.lua` 的 `_Connect` / `Exec` / `CheckMem`。

### 1.4 过期时间

Redis 的过期是“惰性删除 + 定期删除”，不是到点立刻物理删除：

- key 过期后，`GET` 看不到；
- 内存可能晚一点才释放；
- `TTL` 返回 `-2` 表示 key 不存在，`-1` 表示存在但没有过期时间。

本项目的所有缓存 key 都带 TTL，注册表 key 靠心跳续期。

---

## 2. 本项目用到的命令清单

### 2.1 String

| 命令 | 用途 | 项目位置 |
|---|---|---|
| `GET` | 读缓存/读锁/读注册信息 | `server.lua`、`mem_registry.lua` |
| `SET key value` | 普通写 | `dbcell_mem.lua` |
| `SET key value EX ttl` | 带过期写 | `server.lua` 回填 |
| `SET key value NX EX ttl` | 抢锁、空值缓存、回填防覆盖 | `server.lua` |
| `SETEX key ttl value` | 带过期写（等价 `SET EX`） | `dbcell_mem.lua` |
| `DEL` | 删缓存/删队列/删锁 | `server.lua` |
| `EXISTS` | 判断 key 是否存在 | `dbcell_mem.lua` |
| `EXPIRE` | 给已存在的 key 补 TTL | `server.lua` 排行榜 |
| `TTL` | 查剩余过期时间 | `mem_registry.lua` 状态更新 |
| `INCR` / `INCRBY` | 注册表代次、计数器 | `mem_registry.lua`、`dbcell_mem.lua` |
| `MGET` | 批量读注册信息 | `mem_registry.lua` |

### 2.2 Hash

| 命令 | 用途 |
|---|---|
| `HSET/HGET/HDEL/HINCRBY` | 对象字段读写 |
| `HGETALL` | 取整个 Hash（返回扁平数组） |

项目主要在 ddbug 的 Redis 自检里用到 Hash；playdata 的对象缓存**没有**用 Hash，而是把整个 table 序列化成 String，原因见 3.1。

### 2.3 List

| 命令 | 用途 |
|---|---|
| `RPUSH` | 持久化任务入队 |
| `RPOPLPUSH` | 原子“出队 + 进 processing 列表” |
| `LREM` | 处理完成后从 processing 删除 |
| `LLEN` | 队列积压监控 |
| `LINDEX 0` | 取最老任务，计算积压年龄 |

### 2.4 Set

| 命令 | 用途 |
|---|---|
| `SADD` | 注册实例 id 写入索引 |
| `SMEMBERS` | 取全部实例 id |
| `SREM` | 注销/清理过期实例 |

### 2.5 ZSet

| 命令 | 用途 |
|---|---|
| `ZADD` | 写入排行榜成员 |
| `ZINCRBY` | 原子加分 |
| `ZSCORE` | 查成员分数 |
| `ZREM` | 删除成员 |
| `ZREVRANGE ... WITHSCORES` | 取 TopN |
| `ZREVRANK` | 查排名（`ranking.lua` 通过通用 exec） |

### 2.6 脚本

| 命令 | 用途 |
|---|---|
| `EVAL` | 执行 Lua 脚本：CAS、锁释放、注册表 |

---

## 3. 数据类型怎么选

### 3.1 String 存整个对象（本项目的选择）

热层值格式：

```text
<version>|<tool.serialise(data)>
例：3|{["total_score"]=120,["stage"]=1}
```

为什么不用 Hash 存字段？

- 本项目需要**整体 CAS**：版本一致才替换整个对象。String 一条 `SET` 就能完成；
- Hash 的字段级更新无法直接表达“整体版本”，要额外维护版本字段和字段级冲突；
- 序列化后一次读写，逻辑简单。

代价：

- 不能单独更新某个字段，必须读-改-写；
- 对象很大时是“大 key”，要注意拆分；
- 序列化格式变更要考虑兼容。

### 3.2 List 做队列（而不是 LPOP）

`LPOP` 出队后如果消费者崩溃，任务就丢了。本项目用：

```text
RPOPLPUSH play:persist:queue play:persist:processing:<server>_<cell>
```

一条命令完成“从主队列取出 + 放入 processing 列表”，任务至少有两条命：

- 成功处理 → `LREM processing 1 task` 确认；
- 崩溃/失败 → 重启时把 processing 里的任务 `RPOPLPUSH` 回主队列。

这就是“至少一次”语义；重复消费靠 MySQL 里的版本号检查做幂等。

### 3.3 Set 做索引（详情和索引分离）

注册表：

```text
play:reg:{game}:<instance_id>   → 实例详情（String + TTL）
play:reg:{game}:idx             → 实例 id 集合（Set）
play:reg:{game}:gen             → 代次计数器（String + INCR）
```

为什么不用一个 Hash 存所有实例？

- Hash 不能给单个 field 设置 TTL；
- 实例详情需要独立过期，用 String + TTL 更自然；
- Set 负责枚举，MGET 批量取详情，过期后清理索引成员。

`{game}` 是 Redis Cluster 的 **hash tag**：保证同一游戏的注册表 key 落在同一个 slot，脚本可以同时操作详情 key 和索引 key。

### 3.4 ZSet 做排行榜

- `ZINCRBY` 原子加分；
- `ZREVRANGE 0 n-1 WITHSCORES` 取 TopN；
- `ZREVRANK` 取 0 基排名；
- 榜单是“可重建的展示投影”，发奖前必须回 MySQL 校验权威成绩。

---

## 4. 过期与 TTL 设计

### 4.1 本项目 TTL 表

| Key | TTL | 原因 |
|---|---|---|
| 活动/档案热层 | 300 秒 | 热数据，过期可回源 |
| 空值缓存 | 30 秒 | 防穿透，但不能太久 |
| 单飞锁 | 5 秒 | 防死锁；回源通常很快 |
| 排行榜 | 7 天 | 兜底清理，周期结束也会主动清 |
| 注册信息 | 30 秒 | 心跳 10 秒续期，崩溃后自动消失 |

### 4.2 雪崩与 TTL 打散

如果大量 key 在同一秒过期，请求会同时回源，压垮 MySQL。常见做法：

- TTL 加随机抖动：`300 + math.random(0, 60)`；
- 多级缓存：本地缓存 + Redis；
- 回源限流/熔断。

本项目当前是固定 TTL，属于可改进点；因为 play 节点数量有限、回源有单飞锁，短期可接受。

### 4.3 过期 key 与索引残留

Set 里的成员不会跟着 String 的 TTL 一起消失。所以 `RegList` 在 `MGET` 后发现某个 id 对应详情为 nil，就 `SREM` 清理索引。这是“详情 TTL + 索引清理”的标准配合。

---

## 5. Lua 脚本与原子性

### 5.1 基本规则

- `EVAL script numkeys key1 key2 ... arg1 arg2 ...`
- 脚本里的 `KEYS[1..n]` 是 key，`ARGV[1..n]` 是参数；
- 脚本执行期间，Redis 不会插入其他客户端的命令；
- 脚本**不是事务**：如果脚本中途报错，前面已经执行的写**不会回滚**；
- 脚本要短小，避免长循环阻塞 Redis；
- Cluster 下脚本涉及的所有 key 必须在同一个 slot（用 hash tag）。

### 5.2 脚本一：CAS + 持久化入队

`server.lua` 的 `CAS_PUSH_SCRIPT`：

```lua
local cur = redis.call('GET', KEYS[1])
local expected = tonumber(ARGV[1])
if cur then
    local ver = tonumber(string.match(cur, '^(%d+)|'))
    if not ver or ver ~= expected then
        return 0
    end
elseif expected ~= 0 then
    return 0
end
redis.call('SET', KEYS[1], ARGV[2], 'EX', ARGV[3])
redis.call('RPUSH', KEYS[2], ARGV[4])
return 1
```

逐行理解：

1. 读当前值；
2. 解析 `version|data` 的版本前缀；
3. 版本不一致返回 0（冲突）；
4. key 不存在时，只有期望版本为 0 才允许写（初始化）；
5. 版本一致：写新值 + 设置 TTL；
6. 同一条脚本里把持久化任务 `RPUSH` 进队列；
7. 返回 1。

**为什么入队要放在脚本里**：如果先 `SET` 再在 Lua 外面 `RPUSH`，中间进程崩溃就会出现“热层更新了、任务没入队”，数据永远不落 MySQL。

### 5.3 脚本二：比较并删除锁

`RELEASE_SCRIPT`：

```lua
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
end
return 0
```

只有锁的值等于自己的 token 才删除，避免误删别人的锁。

### 5.4 脚本三：注册代次比较

`mem_registry.lua` 的 `REG_SCRIPT`：

```lua
local old = redis.call('GET', KEYS[1])
if old then
    local oldGen = tonumber(string.match(old, '^(%d+)|'))
    if oldGen and oldGen > tonumber(ARGV[1]) then
        return 0
    end
end
redis.call('SET', KEYS[1], ARGV[2], 'EX', ARGV[3])
redis.call('SADD', KEYS[2], ARGV[4])
return 1
```

作用：

- 旧实例的延迟注册不能覆盖新实例（代次更大的赢）；
- 写详情 + 写索引在同一脚本里完成。

### 5.5 心跳/状态/注销脚本

- `HEARTBEAT_SCRIPT`：检查注册是否还在（不在返回 -1）、代次是否过期（过期返回 0），否则更新负载字段并续 TTL；
- `STATUS_SCRIPT`：改状态字段，**保留原 TTL**（先 `TTL` 再 `SET EX`）；
- `UNREGISTER_SCRIPT`：代次校验后 `DEL` 详情 + `SREM` 索引。

这些脚本的共同点：**读-判断-写**必须原子，否则并发下会互相覆盖。

### 5.6 先消除一个误解：`[[ ... ]]` 是字符串，不是注释

`server.lua` 里的：

```lua
local RELEASE_SCRIPT = [[
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
end
return 0
]]
```

不是“注释掉的代码”，而是 Lua 的**长字符串字面量**：

- `--` 才是单行注释；
- `--[[ ... ]]` 才是长注释；
- `[[ ... ]]` 是字符串，等价于带换行的 `"..."`。

这个字符串最终作为 `EVAL` 的 `script` 参数发给 Redis，由 Redis 内置的 Lua 解释器执行。所以它既不是“死代码”，也不是“注释”，而是**真正会运行的脚本**。`server.lua#L45-67` 这两段都是这种用法。

### 5.7 两段脚本的完整参数映射

#### 5.7.1 释放锁：`RELEASE_SCRIPT`

调用点（`_ReleaseLock`）：

```lua
DBMEM.Exec("eval", RELEASE_SCRIPT, 1, lockKey, token)
```

映射：

| EVAL 参数 | 值 | 脚本里 |
|---|---|---|
| numkeys | 1 | — |
| KEYS[1] | `lockKey` | `GET` / `DEL` 的 key |
| ARGV[1] | `token` | 期望的锁持有者 |

脚本逻辑：

```lua
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
end
return 0
```

三种情况：

| 场景 | `GET` 结果 | 返回值 | 效果 |
|---|---|---|---|
| 锁还在，且是自己的 token | token | 1 | 删除锁 |
| 锁已过期/已释放 | false | 0 | 什么都不做 |
| 锁已被别人抢到 | 别人的 token | 0 | 不删别人的锁 |

为什么不能直接 `DEL`：自己的锁过期后，别人可能已经拿到锁；直接 `DEL` 会删掉别人的锁。

#### 5.7.2 CAS + 持久化入队：`CAS_PUSH_SCRIPT`

调用点（`Cas`）：

```lua
DBMEM.Exec("eval", CAS_PUSH_SCRIPT, 2, key, QUEUE_KEY,
    version, payload, ttl, task)
```

映射：

| EVAL 参数 | 值 | 脚本里 |
|---|---|---|
| numkeys | 2 | — |
| KEYS[1] | 业务 key | 读/写热层 |
| KEYS[2] | `play:persist:queue` | `RPUSH` 持久化任务 |
| ARGV[1] | 期望版本号 | `expected` |
| ARGV[2] | 新 payload（`version+1|data`） | `SET` 的值 |
| ARGV[3] | TTL | `EX` 的秒数 |
| ARGV[4] | 持久化任务字符串 | `RPUSH` 的元素 |

脚本逐行：

```lua
local cur = redis.call('GET', KEYS[1])          -- 1. 读当前热层值
local expected = tonumber(ARGV[1])              -- 2. EVAL 参数都是字符串，转数字
if cur then                                     -- 3. key 存在
    local ver = tonumber(string.match(cur, '^(%d+)|'))  -- 4. 取 version| 前缀
    if not ver or ver ~= expected then          -- 5. 版本不一致 → 冲突
        return 0
    end
elseif expected ~= 0 then                       -- 6. key 不存在，只有期望 0 才允许初始化
    return 0
end
redis.call('SET', KEYS[1], ARGV[2], 'EX', ARGV[3])  -- 7. 写新值 + TTL
redis.call('RPUSH', KEYS[2], ARGV[4])               -- 8. 同脚本入队
return 1                                            -- 9. 成功
```

四种分支：

| 场景 | `cur` | `expected` | 结果 |
|---|---|---|---|
| 首次初始化 | 不存在 | 0 | 写新值 + 入队，返回 1 |
| 正常更新 | `3\|...` | 3 | 写 `4\|...` + 入队，返回 1 |
| 并发冲突 | `4\|...` | 3 | 返回 0 |
| 误用初始化 | `3\|...` | 0 | 返回 0 |

`Cas` 对返回值的映射：

```lua
if ret == 0 then
    return _Result("conflict")          -- 调用方重新 Read 再试
end
return _Result("ok", { version = version + 1 })
```

### 5.8 这两段脚本的工程意义

1. **原子性**：Redis 执行脚本期间不会插入其他命令；`GET → 判断 → SET → RPUSH` 是一个整体。
2. **不是事务**：如果 `SET` 之后 `RPUSH` 报错（例如类型错误），`SET` **不会回滚**；所以脚本里的参数类型要保证正确。
3. **EVAL 每次发送完整脚本**：脚本较长会占带宽；可以用 `SCRIPT LOAD` + `EVALSHA` 优化（当前项目用 `EVAL`，简单直接）。
4. **Cluster 跨槽**：`CAS_PUSH_SCRIPT` 的 `KEYS[1]` 带 `{game}`，`KEYS[2]` 是全局队列，Cluster 下可能跨槽；单机 Redis 没问题。
5. **脚本要短**：不要在脚本里做长循环、`KEYS *`、大范围 `SMEMBERS`，否则会阻塞整个 Redis。

### 5.9 `redis.call` 与 `redis.pcall`

- `redis.call`：命令出错会中断脚本，错误返回给客户端；
- `redis.pcall`：捕获错误并以 table 返回，脚本继续执行。

本项目两段脚本都很短、参数由代码保证，用 `call` 更直接；如果脚本里有“可能失败但可忽略”的命令，再考虑 `pcall`。

---

## 6. 缓存三大问题

### 6.1 缓存穿透：查不存在的数据

问题：请求一直查一个不存在的 key，每次都打到 MySQL。

本项目：

```text
源确认无记录 → SET key "0|false" NX EX 30
```

下次读命中空值缓存，直接返回 `not_found`，不再回源。

注意：空值缓存也要用 `NX`，避免并发写入时被“空值”覆盖。

### 6.2 缓存击穿：热点 key 过期瞬间

问题：热点 key 刚过期，大量请求同时回源。

本项目：

```text
未命中 → SET key:lock token NX EX 5
  ├─ 抢到 → 查 MySQL → 回填
  └─ 没抢到 → 睡 200ms 重读，最多 3 次 → 兜底自己回源
```

这就是“单飞（single-flight）”：同一时刻只有一个请求回源。锁是全局的（Redis），所以跨 cell、跨 play 节点也生效。

### 6.3 缓存雪崩：大量 key 同时过期

见 4.2。当前可改进点是 TTL 加随机抖动、回源限流。

### 6.4 缓存一致性

本项目对“普通玩法数据”的选择是：

```text
读：Redis → 未命中 → MySQL → 回填（Cache-Aside）
写：Redis CAS（热层先更新）→ 异步队列 → MySQL 最终一致
```

这是 write-behind，不是标准的“先写 MySQL 再删缓存”。原因：

- 普通玩法数据允许丢最近几秒；
- 用 Redis 承担高频写，MySQL 异步落库；
- 资产数据**绝不走这条链**，必须走 agent 的 MySQL 事务 + 结算幂等。

代价与边界：

- Redis 丢数据且尚未落库 → 最近几秒的普通数据丢失（设计允许）；
- 队列积压 → RPO 变大，需要监控；
- 不能把资产字段混进普通 playdata。

---

## 7. 分布式锁

### 7.1 正确姿势

```text
SET lockKey token NX EX 5
```

- `NX`：不存在才写，保证只有一个客户端抢到；
- `EX`：自动过期，防止持有者崩溃后死锁；
- 一条命令完成，不能拆成 `SETNX` + `EXPIRE`（中间崩溃会留下无 TTL 的锁）。

### 7.2 释放锁

```text
if GET(lockKey) == token then DEL(lockKey)
```

必须校验 token，否则可能删掉别人的锁（自己的锁过期后，别人已经抢到）。

### 7.3 本项目的边界

- 锁只保护“回源”这一段，不保护整个业务事务；
- 回源超过 5 秒时锁会过期，可能出现重复回源（概率低，可接受）；
- 没有看门狗续期；如果回源可能很慢，需要延长 TTL 或加续期；
- 锁竞争失败后轮询 3 次、每次 200ms，仍失败就兜底自己回源，避免请求永久失败。

---

## 8. 乐观锁与 CAS

### 8.1 版本号

热层值带版本：`<version>|data`。

- 读：拿到 `data` 和 `version`；
- 改：基于 `version` 算出新值；
- 写：`CAS(key, version, newData)`，版本不一致返回 `conflict`；
- 冲突：重新读、重新算、重试。

### 8.2 为什么需要 CAS

多个 play 节点/多个 cell 可能同时改同一个活动：

```text
A 读到 total_score=100, version=3
B 读到 total_score=100, version=3
A 写 105, version=4
B 写 108, version=4   ← 如果没有 CAS，A 的更新丢了
```

有 CAS 后，B 的写入会失败，重新读 105 再加 8，得到 113。

### 8.3 本项目的 CAS 循环

`AddScore` 里对活动和档案各有一个最多 3 次的重试循环：

```text
Read → 修改 → Cas
  ├─ ok → 结束
  ├─ conflict → Read 最新值 → 再试
  └─ 其他错误 → 返回
```

注意：CAS 只保证**单个 key** 的版本一致；`AddScore` 跨三个 key，不是事务，部分失败可能产生中间状态。

---

## 9. 队列与至少一次

### 9.1 链路

```text
Cas 成功
  └─ EVAL：SET 热层 + RPUSH play:persist:queue
消费者
  ├─ RPOPLPUSH queue → processing:<server>_<cell>
  ├─ 读 MySQL 当前 version
  ├─ 版本较旧 → 跳过
  ├─ 较新 → SaveModData
  └─ LREM processing 1 task
```

### 9.2 语义

- **至少一次**：任务可能重复（崩溃恢复、重试），不会丢；
- **幂等**：MySQL 写入前比较版本，旧任务不会覆盖新数据；
- **死信**：重试超过 3 次进 `play:persist:dead`，需要告警/人工处理；
- **RPO**：正常情况约等于消费者轮询间隔 + MySQL 写入时间；积压时变大。

### 9.3 与 Redis Stream 的对比

List 方案的优点：简单、够用。
Stream 的优点：

- 消费组（consumer group）原生支持多消费者和 ack；
- `XPENDING` / `XCLAIM` 处理超时未确认；
- 更适合任务量大、消费者多的场景。

当前项目用 List + processing 列表，是“手写版”的可靠队列。

---

## 10. 键设计与容量

### 10.1 命名

```text
play:activity:{game}:<activity_id>
play:profile:{game}:<activity_id>:<uid>
play:rank:{game}:<period>
play:persist:queue
play:reg:{game}:<instance_id>
```

- 业务域前缀 `play:`，方便按前缀排查；
- `{game}` 是 hash tag，Cluster 下同槽；
- 注册表保留名 `idx`、`gen` 不允许作为实例 id。

### 10.2 大 key / 热 key

- 活动数据如果很大，序列化后就是一个大 String，读写都会变慢；
- 某个全服活动 key 可能成为热 key，所有 cell 都读它；
- 缓解：拆分字段、加本地缓存、按活动分片、读多写少的数据单独缓存。

### 10.3 必须设 TTL

除了注册表/队列这种有明确生命周期的，缓存 key 都要 TTL；否则 Redis 内存只增不减。

---

## 11. 集群、高可用与持久化（延伸）

### 11.1 部署形态

| 形态 | 特点 |
|---|---|
| 单机 | 简单，故障即不可用 |
| 主从 + 哨兵 | 自动故障切换，单 master 写 |
| Cluster | 16384 个 slot，多 master 分片，支持水平扩展 |

### 11.2 Cluster 的跨槽限制

Lua 脚本涉及的所有 key 必须在同一个 slot。本项目：

- 注册表脚本：详情 key 和索引 key 都带 `{game}` → 同槽，安全；
- CAS + 入队脚本：数据 key 带 `{game}`，队列是全局 `play:persist:queue` → **跨槽，Cluster 下会失败**。

单机 Redis 没问题；上 Cluster 时需要把队列改成按游戏分片（`play:persist:{game}:queue`），或改用 Stream。

### 11.3 持久化

- RDB：周期性快照，恢复快，可能丢最后一次快照后的数据；
- AOF：追加写，`appendfsync everysec` 最多丢约 1 秒；
- 混合持久化：RDB + AOF。

本项目把 Redis 当**热层**，普通数据丢了可以从 MySQL 回源；但注册表和持久化队列如果丢了会影响发现/落库，生产上要开启合适的持久化并做高可用。

### 11.4 内存淘汰

`maxmemory` + `maxmemory-policy`：

- `noeviction`：写满后报错；
- `allkeys-lru`：所有 key 按 LRU 淘汰（纯缓存常用）；
- `volatile-lru`：只淘汰有 TTL 的 key。

如果 Redis 里同时放“可丢的缓存”和“不可丢的队列/注册表”，淘汰策略要谨慎，最好拆实例。

---

## 12. 连接与故障处理

### 12.1 本项目的约定

```lua
-- 成功：结果（可能 nil）
-- 失败：nil, err
local value, err = Exec("get", key)
```

- 所有命令 `pcall` 包裹，不把异常抛给业务协程；
- 连接失败进入冷却，避免雪崩式重连；
- 错误日志 1 秒最多一条，防刷屏；
- `PING` 保活，60 秒一次。

### 12.2 超时与重试

- Redis 客户端有 socket 超时；
- 业务层重试必须幂等：读可以重试，写要带版本/CAS 或幂等 ID；
- 队列任务重试靠版本检查保证不重复覆盖。

---

## 13. 监控与排障

### 13.1 常用命令

```bash
redis-cli INFO stats        # 命中率、命令数
redis-cli INFO memory       # 内存使用
redis-cli INFO keyspace     # 各 db key 数量
redis-cli SLOWLOG GET 10    # 慢命令
redis-cli MEMORY USAGE key  # 单个 key 内存
redis-cli --bigkeys         # 大 key 扫描
redis-cli --hotkeys         # 热 key（需要 LFU 策略）
redis-cli LATENCY DOCTOR    # 延迟诊断
```

### 13.2 本项目关注指标

- 缓存命中率（`keyspace_hits / (hits + misses)`）；
- 回源次数、单飞锁等待次数；
- `play:persist:queue` 长度、最老任务年龄（`QueueInfo`）；
- 死信队列长度；
- Redis 连接状态/重连次数；
- 注册表实例数、READY 比例、心跳失败数。

---

## 14. 常见坑清单

1. 把 `SETNX` + `EXPIRE` 拆开用 → 中间崩溃留下死锁。
2. 释放锁不校验 token → 误删别人的锁。
3. 锁 TTL 太短 → 业务没跑完锁就过期。
4. 锁 TTL 太长 → 持有者崩溃后长时间不可用。
5. 用 `KEYS *` 扫线上 → 阻塞 Redis。
6. 大 key（几十 MB 的 String/Hash/ZSet）→ 读写慢、删除卡顿。
7. 热 key → 单 slot/单节点被打满。
8. 缓存 key 不设 TTL → 内存只增不减。
9. 空值缓存 TTL 太长 → 数据恢复后长时间读不到。
10. 回填不用 `NX` → 旧快照覆盖新值。
11. 先删缓存再写库 → 并发下缓存容易脏。
12. 把 Redis 当唯一数据库 → 丢数据无法恢复。
13. Lua 脚本里做长循环/大范围扫描 → 阻塞整个 Redis。
14. Cluster 下 Lua 跨 slot → `CROSSSLOT` 错误。
15. `HGETALL`/`MGET` 一次取太多 → 网络和内存压力。
16. 队列没有 processing/ack → 消费者崩溃丢任务。
17. 队列没有死信/告警 → 任务静默丢失。
18. 任务重试没有幂等 → 重复写/重复发奖。
19. `maxmemory` 配了 `noeviction` 又当纯缓存用 → 写满报错。
20. `bind 0.0.0.0` + 无密码 → 安全风险。

---

## 15. 代码对照表

| 想学什么 | 看哪里 |
|---|---|
| 连接、重连、命令封装 | `tool/service/basic/dbcell/dbcell_mem.lua` |
| 读缓存、单飞锁、空值缓存、回填 | `game/global/playdata/server.lua` 的 `Read` |
| CAS + 入队原子脚本 | `server.lua` 的 `Cas` / `CAS_PUSH_SCRIPT` |
| 复合业务与 CAS 重试 | `server.lua` 的 `AddScore` |
| 持久化消费者/至少一次 | `server.lua` 的 `StartConsumer` / `_ProcessTask` |
| 注册表、心跳、代次 CAS | `tool/service/basic/dbcell/mem_registry.lua` |
| 排行榜 | `server.lua` 的 `RankAdd/RankTop`、`game/global/playdata/ranking.lua` |
| 键规范、TTL、hash tag | `tool/service/basic/dbcell/playdata_codec.lua` |
| 协议路由（mem → cell） | `tool/service/basic/dbserver/dbserver.lua` |
| 真实命令自检 | `game/service/manage/handle/ddbug.lua` 的 `_TestMemCommon` |

---

## 16. 建议的练习

1. 给 `playdata` 的 TTL 加随机抖动，观察缓存雪崩的差异。
2. 把 `AddScore` 改成带 `request_id` 的幂等操作（Redis Set 去重 + 结果缓存）。
3. 把持久化队列从 List 改成 Redis Stream 消费组，比较 ack/重试/积压监控的差异。
4. 给 CAS 循环加指标：冲突次数、重试次数、失败率。
5. 用 `redis-cli --bigkeys`/`--hotkeys` 观察 demo 产生的 key。
6. 模拟 Redis 挂掉/MySQL 挂掉，验证 `redis_error` / `source_error` 的降级路径。
