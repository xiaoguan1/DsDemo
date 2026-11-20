# lua-zlib 说明

本目录是 Lua 的 zlib 绑定库，编译产物为 `zlib.so`（输出到 `../../cplugins-so/`），在 Lua 侧通过 `require "zlib"` 使用。

## 一、来源

- 本项目文件来自 **brimworks/lua-zlib**（作者 Brian Maher，版权 2009-2016），核心实现见 [lua_zlib.c](./lua_zlib.c)。
- 底层的实际压缩算法由 C 标准 zlib 库提供（`#include <zlib.h>`，链接 `-lz`）。
- 文件内嵌了一段 **lzlib**（作者 Tiago Dionizio，LuaDist 项目）的兼容代码，原始出处：
  `https://raw.githubusercontent.com/LuaDist/lzlib/93b88e931ffa7cd0a52a972b6b26d37628f479f3/lzlib.c`，由编译宏 `LZLIB_COMPAT` 控制是否启用。

lua-zlib 与 lzlib 是两个 API 风格不同的 zlib 绑定库，lua-zlib 通过 `LZLIB_COMPAT` 宏把 lzlib 的接口作为"兼容层"一并编译进来，让两套 API 同时可用。

## 二、非 LZLIB_COMPAT 模式（lua-zlib 原生 API）

编译时不加 `-DLZLIB_COMPAT` 即为本模式。特点是**流式接口**：不直接对数据压缩，而是先"创建一台机器"，返回一个 Lua 函数，再一段一段把数据喂给它。

### 模块函数一览

| 函数 | 作用 |
|---|---|
| `zlib.deflate([level], [window])` | 创建压缩机，返回压缩函数 |
| `zlib.inflate([window])` | 创建解压机，返回解压函数 |
| `zlib.crc32()` | 创建 CRC32 校验累加器，返回累加函数 |
| `zlib.adler32()` | 创建 Adler32 校验累加器，返回累加函数 |
| `zlib.version()` | 返回 zlib 库版本号（多个数字返回值） |

没有 `compress` / `decompress` 这类一次性函数。

### 压缩示例

```lua
local zlib = require "zlib"

local pack = zlib.deflate(6)      -- 压缩级别 6（1~9，越大越狠越慢）

local out = {}
out[#out+1] = pack("hello ")      -- 喂第一段数据
out[#out+1] = pack("world")       -- 喂第二段数据
out[#out+1] = pack()              -- 无参调用 = 收尾（Z_FINISH），吐出剩余数据
local zip = table.concat(out)
```

每次调用返回 4 个值：

| 返回值 | 含义 |
|---|---|
| 第 1 个 | 本次产出的压缩数据（字符串） |
| 第 2 个 | 流是否已结束（Z_STREAM_END） |
| 第 3 个 | 累计输入字节数 |
| 第 4 个 | 累计输出字节数 |

中途还可指定 flush 级别：`pack(data, "sync")` / `"full"`。

**必须无参调用一次收尾**：zlib 会把最后一块数据攒在内部缓冲里，不收尾则结尾数据丢失，解压会失败。

### 解压示例

```lua
local unpack = zlib.inflate()     -- 默认自动识别 zlib / gzip 格式

local plain = {}
plain[#plain+1] = unpack(zip_part1)
plain[#plain+1] = unpack(zip_part2)
plain[#plain+1] = unpack()        -- 收尾
local raw = table.concat(plain)
```

### 校验和示例

```lua
local crc = zlib.crc32()
crc("data1")
crc("data2")
local sum, total_bytes = crc()    -- 无参取出：累计 CRC、累计字节数

local adler = zlib.adler32()      -- 用法相同
adler("abc")
local a = adler()
```

### 适用场景

- 数据很大或按段产生（网络流、日志、大文件），边生产边压缩，省内存。
- 缺点：写法比一次性调用啰嗦，需要记得收尾。

## 三、LZLIB_COMPAT 模式（兼容 lzlib API）

编译时加 `-DLZLIB_COMPAT` 启用，文件内 `#ifdef LZLIB_COMPAT` 包裹的 lzlib 代码才会参与编译（约在 [lua_zlib.c](./lua_zlib.c) 23~839 行与 1248~1292 行）。

### 额外获得的能力

| 能力 | 说明 |
|---|---|
| `zlib.compress(str, [level...])` | **一次性压缩**，返回 `压缩串, 返回码`（返回码为 1 即 Z_STREAM_END 成功；负数表示失败。注意不是 0，Z_OK(0) 只出现在内部中间循环） |
| `zlib.decompress(str, [windowBits])` | **一次性解压**，返回原文；数据非法时直接抛 Lua 错误 |
| `zlib.deflate(fn/table/userdata, ...)` | 第一参数传回调对象时走 lzlib **回调式流**：通过 sink 的 `:write(data)` 送出压缩结果 |
| `zlib.inflate(str/fn/table, ...)` | 第一参数传字符串或带 `:read(n)` 的对象时，走 lzlib source 回调模式 |
| `zlib.crc32(初始值, str)` / `zlib.adler32(初始值, str)` | 带参调用直接一次性计算校验和 |
| 常量 | `NO_COMPRESSION`、`DEFAULT_COMPRESSION`、`FILTERED`、`HUFFMAN_ONLY`、`RLE`、`FIXED`、`DEFAULT_STRATEGY`、`GZIP_WINDOWBITS` 等 |

### 一次性用法示例

```lua
local zlib = require "zlib"

local zip, ret = zlib.compress(big_string, zlib.BEST_COMPRESSION)
assert(ret == 1, "compress failed: " .. ret)  -- 1 = Z_STREAM_END

local raw = zlib.decompress(zip)
```

### 回调式流示例

```lua
-- 压缩：结果通过 sink:write 推出来
local sink = { write = function(_, chunk) io.write(chunk) end }
local ds = zlib.deflate(sink, 6)   -- 内部机制负责喂数据、调 write

-- 解压：数据从 source:read 拉出来
local src = { read = function(_, n) return file:read(n) end }
local is = zlib.inflate(src)
```

### 模式内共存

开宏后两种风格并存，靠**第一参数类型**分派：

- `zlib.deflate(6)` 传数字 → 走原生流式过滤器，用法同第二节；
- `zlib.deflate(sink表)` 传表/函数/userdata → 走 lzlib 回调式。

### 适用场景与建议

- 中小数据块想一行搞定（协议包、存档快照、调试导出）时，一次性 `compress/decompress` 最简单直观。
- 本项目中 [game/service/manage/handle/ddbug.lua](../../../game/service/manage/handle/ddbug.lua) 使用了 `zlib.compress`，因此**部署的 `zlib.so` 必须带 `LZLIB_COMPAT` 编译**，否则运行时会报 `attempt to index a nil value (field 'compress')`。
- 本目录 [Makefile](./Makefile) 的 `CFLAGS` 目前未加该宏，与线上产物不一致，建议补为：
  `CFLAGS = -O3 -fPIC -Wall -DNDEBUG -DLZLIB_COMPAT`。
- 代价仅是 so 体积略大、接口面更宽；原生闭包写法不受影响，属"超集"编译，项目内推荐开启。

## 四、两种模式对比速查

| 对比项 | 非 LZLIB_COMPAT | LZLIB_COMPAT |
|---|---|---|
| `compress` / `decompress` | 无 | 有（一次性） |
| `deflate` / `inflate` 参数 | 只接受数字 | 数字 → 原生过滤器；对象 → lzlib 回调 |
| `crc32` / `adler32` | 仅累加闭包 | 累加闭包 + 带参一次性 |
| 常量 | 仅 `BEST_SPEED` / `BEST_COMPRESSION` | 另有一批压缩策略/窗口常量 |
| 代码体积 | 较小 | 多约 800 行兼容代码 |
| 适用 | 纯流式、最小体积场景 | 需要一次性 API 的场景（本项目） |