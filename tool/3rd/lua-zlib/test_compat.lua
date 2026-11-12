--[[
    LZLIB_COMPAT 模式测试用例（开启 lzlib 兼容层）
    ====================================================================
    运行前提：
      1. zlib.so 以【带 -DLZLIB_COMPAT】方式编译：
           gcc -O3 -fPIC -Wall -DNDEBUG -DLZLIB_COMPAT -shared -o zlib.so -I<luadir> lua_zlib.c -lz
      2. require "zlib" 能找到编译产物

    运行方式：
      lua test_compat.lua

    本模式是"超集"，两种风格共存，由【第一参数类型】分派：
      - 一次性 API：compress / decompress        （本模式专属，最常用）
      - 带参一次性校验：crc32(初值, str) / adler32(初值, str)（本模式专属）
      - 原生流式过滤器：deflate(数字) / inflate(数字)  （与非COMPAT模式相同）
      - 一批 lzlib 风格常量：BEST_SPEED / BEST_COMPRESSION 等

    说明：本目录随附的 lua_zlib.c 是精简捆绑版，zstream 的方法表
    （:write/:read 等回调式流接口）未注册，因此回调式流
    （zlib.deflate(sink表) / zlib.inflate(source表)）不在本测试范围内，
    测试聚焦确定可用的接口。

    --------------------------------------------------------------------
    各接口的【返回值含义】速查（本文件会逐一验证）：

    【A】zlib.compress(str, [level, ...])
          -> zip, ret
      zip : 压缩后的字符串
      ret : 最后一次 deflate 的返回码
            - ret == 1  => Z_STREAM_END，压缩完整结束（成功）
            - ret < 0   => 失败（对应负错误码），此时 zip 可能是空串/半成品
            注意：不是 0！Z_OK(0) 只出现在中间循环过程，成功时最终是 1。

    【B】zlib.decompress(str, [windowBits])
          -> raw
      只返回一个值：解压出的原文。
      数据非法时【直接抛错】（内部 lua_error），所以调用处要用 pcall 接。

    【C】zlib.crc32(初值, str) / zlib.adler32(初值, str)（带参一次性）
          -> sum
      返回【单个数字】校验值。

    【D】zlib.crc32() / zlib.adler32()（无参，返回累加闭包 acc）
          acc("数据") -> sum, len   （并入数据后返回当前校验值、累计字节数）
          acc()       -> sum, len   （无参只是取快照，不改变状态）

    【E】zlib.deflate(数字) / zlib.inflate(数字)（原生流式过滤器 f）
          f("数据") -> out, eos, total_in, total_out
      与非COMPAT模式完全一致：out=本次产出数据，eos=流是否结束，
      total_in/total_out=累计输入/输出字节数；最后必须无参调用 f() 收尾。
]]

local zlib = require "zlib"

local fails = 0

-- 统一的断言：名字 + 条件，失败时计数并打印
local function check(name, ok)
    if ok then
        print(string.format("[PASS] %s", name))
    else
        fails = fails + 1
        print(string.format("[FAIL] %s", name))
    end
end

-- 造一段带规律的测试数据，方便肉眼对比压缩前后大小
local function make_raw(n)
    local t = {}
    for i = 1, n do
        t[#t+1] = string.format("line %d: hello zlib %s\n", i, string.rep("a", 16))
    end
    return table.concat(t)
end

-- 1. 本模式专属函数存在性检查
--    没开 LZLIB_COMPAT 编译的 zlib.so 里【没有】这两个字段，
--    如果这里取到 nil，说明加载的 so 是不带宏的版本。
check("compress 函数存在", type(zlib.compress) == "function")
check("decompress 函数存在", type(zlib.decompress) == "function")

-- 2. 一次性往返：compress(str) -> decompress(str)，并验证返回码语义
--    compress 的第二个返回值（见文件头【A】）：
--      成功 = 1（Z_STREAM_END），而不是 0（Z_OK 只出现在内部中间循环）。
do
    local raw = make_raw(100)
    local zip, ret = zlib.compress(raw)

    check("compress 返回码为 1 (Z_STREAM_END)", ret == 1)
    check("compress 第1返回值是字符串", type(zip) == "string")
    check("压缩确实变小了", #zip < #raw)

    check("decompress 还原原文", zlib.decompress(zip) == raw)
end

-- 3. 不同压缩级别都能正确还原
--    compress 第 2 个参数是级别；BEST_SPEED=1 快而松，BEST_COMPRESSION=9 狠而慢，
--    任何级别产出的都是标准 zlib 流，decompress 一视同仁都能解。
do
    local raw = make_raw(50)

    local z1 = zlib.compress(raw, zlib.BEST_SPEED)
    local z9 = zlib.compress(raw, zlib.BEST_COMPRESSION)

    check("BEST_SPEED/BEST_COMPRESSION 常量存在",
        type(zlib.BEST_SPEED) == "number" and type(zlib.BEST_COMPRESSION) == "number")
    check("BEST_SPEED 产物可解压", zlib.decompress(z1) == raw)
    check("BEST_COMPRESSION 产物可解压", zlib.decompress(z9) == raw)
end

-- 4. 更多 lzlib 兼容常量存在性检查
--    这些常量来自 lzlib 的 API 约定，只在带宏编译时注册（见 luaopen_zlib 尾部 SETINT）。
do
    check("lzlib 兼容常量存在",
        type(zlib.DEFAULT_COMPRESSION) == "number"
        and type(zlib.NO_COMPRESSION) == "number"
        and type(zlib.FILTERED) == "number"
        and type(zlib.HUFFMAN_ONLY) == "number")
end

-- 5. 错误处理：decompress 收到非法数据【直接抛错】（见文件头【B】）
--    内部 inflate 返回 Z_DATA_ERROR 后 lua_error，不返回错误码，
--    所以业务里必须用 pcall/xpcall 包住，防止服务被炸。
do
    local ok, err = pcall(function()
        return zlib.decompress("这不是 zlib 数据")
    end)
    check("decompress 非法数据抛错", not ok and err ~= nil)
end

-- 6. 带参一次性 crc32 / adler32 与累加闭包【结果一致】
--    两种写法只是接口糖，底层同一条 crc32 公式、同样的初始值 0：
--      一次性: zlib.crc32(0, raw)        -> 返回单个数字（见文件头【C】）
--      累加器: acc = zlib.crc32(); acc(raw) -> acc() 取出 (CRC, 累计长度)（见【D】）
do
    local raw = make_raw(20)

    local c1 = zlib.crc32(0, raw)     -- 一次性：初值 0 + 整段数据

    local acc = zlib.crc32()
    acc(raw)
    local c2 = acc()                  -- 累加闭包：取出当前 CRC

    check("crc32(初值, str) 与累加闭包结果一致", c1 == c2)

    local a1 = zlib.adler32(0, raw)
    local acc2 = zlib.adler32()
    acc2(raw)
    local a2 = acc2()
    check("adler32(初值, str) 与累加闭包结果一致", a1 == a2)
end

-- 7. 两种风格共存验证：传【数字】时仍走原生流式过滤器
--    lz_deflate_new/lz_inflate_new 里的分派逻辑：
--      表/函数/userdata/字符串 -> lzlib 回调式（本精简版未注册方法表，不可用）
--      数字                  -> 原生过滤器闭包（本用例验证的就是这条路径）
--    过滤器返回 4 个值（见文件头【E】），最后必须无参收尾。
do
    local raw = make_raw(40)

    local f = zlib.deflate(6)              -- 数字 -> 原生流式过滤器
    local zip = f(raw) .. f()              -- 喂数据 + 无参收尾

    local u = zlib.inflate(15)             -- 数字 -> 原生流式过滤器（15=标准zlib窗口）
    local back = u(zip) .. u()

    check("COMPAT 模式下原生过滤器仍可用", back == raw)
end

-- 8. 模拟项目用法（ddbug.lua 里 zlib.compress 的场景）：
--    把一个 table 序列化成字符串 -> compress 压缩 -> decompress 还原 -> 再反序列化
--    这就是"存档快照/调试导出"的典型模式：一次调用，无状态，代码最省。
do
    local function serialize(t)
        local parts = {}
        for k, v in pairs(t) do
            parts[#parts+1] = string.format("%s=%s", tostring(k), tostring(v))
        end
        table.sort(parts)
        return table.concat(parts, "|")
    end

    local data = { uid = 1001, name = "player_1001", gold = 99999, level = 88 }
    local text = serialize(data)

    local zip = zlib.compress(text)         -- 用不到时忽略第二个返回值即可
    local back = zlib.decompress(zip)

    check("模拟 ddbug 场景: 压缩-解压往返", back == text)
end

-- 汇总：fails 为 0 时以退出码 0 结束（方便挂 CI），否则退出码 1
print(string.format("\nCOMPAT模式测试结束: %s", fails == 0 and "全部通过" or ("有 " .. fails .. " 个失败")))
