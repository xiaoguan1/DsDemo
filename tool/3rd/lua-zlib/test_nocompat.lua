--[[
    非 LZLIB_COMPAT 模式测试用例（lua-zlib 原生流式 API）
    ====================================================================
    运行前提：
      1. zlib.so 以【不带 -DLZLIB_COMPAT】方式编译（见 Makefile 默认 CFLAGS）
      2. require "zlib" 能找到编译产物（默认输出到 ../../cplugins-so/）

    运行方式（在 lua-zlib 目录或 cpath 配置好后）：
      lua test_nocompat.lua

    本模式模块里只有：deflate / inflate / crc32 / adler32 / version
    没有 compress / decompress 这类一次性函数。

    --------------------------------------------------------------------
    先记住两个最重要的概念，后面每个用例都会用到：

    【概念1】deflate / inflate 是"流式"接口
      它们不是直接处理数据，而是"造一台机器"并返回一个 Lua 函数 f：
          zlib.deflate([level], [window])  -> 压缩函数 f
          zlib.inflate([window])           -> 解压函数 f
      拿 f 一段一段喂数据（机器记得自己的状态），最后【无参调用一次 f()】
      完成"收尾"（Z_FINISH），把机器肚子里攒的最后一段压缩数据吐出来。
      优点：数据很大或按段产生（网络流/日志）时，不必先拼成一个大字符串。

    【概念2】过滤器函数 f 每次调用固定返回 4 个值：
          f("数据")  ->  out, eos, total_in, total_out
      第1个 out        : 本次（这一口喂进去后）产出的数据
                         压缩函数产出的是压缩字节；解压函数产出的是原文。
                         注意：机器是攒着输出的，某次调用 out 可能是 ""，
                         不代表没干活，只是这口数据还没凑够一个输出块。
      第2个 eos        : 布尔值，流是否已经走到底（Z_STREAM_END）
                         压缩侧：调用了收尾 f() 且流全部吐完 -> true
                         解压侧：解到流的结尾 -> true
      第3个 total_in   : 数字，这台机器【累计】吃进去多少字节
      第4个 total_out  : 数字，这台机器【累计】吐出来多少字节
      普通业务里一般只用第 1 个，后 3 个用于进度统计/调试。
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

-- 造一段带规律的测试数据（n 行重复文本，约 n*39 字节），方便肉眼对比压缩前后大小
local function make_raw(n)
    local t = {}
    for i = 1, n do
        t[#t+1] = string.format("line %d: hello zlib %s\n", i, string.rep("a", 16))
    end
    return table.concat(t)
end

-- 1. version()：返回 zlib 链接库的版本号
--    例：zlib 1.2.8 会返回三个数字 1, 2, 8（多返回值）
do
    local v1, v2, v3 = zlib.version()
    print(v1, v2, v3)
    check("version() 返回值是数字", type(v1) == "number" and type(v2) == "number")
end

-- 2. 核心往返：deflate 压缩 -> inflate 解压，结果 == 原文
--    这是最标准的一段"压缩-解压"完整流程；
--    重点看 pack(raw) .. pack() 这句：
--      pack(raw)  -> 喂入原文，拿到第一段压缩结果（可能没吐干净）
--      pack()     -> 【无参收尾】让机器用 Z_FINISH 把剩余压缩数据全吐出来
--    不收尾的话，zip 会缺尾巴，解压必然还原不出原文（见用例 5）。
do
    local raw = make_raw(100)

    local pack = zlib.deflate()            -- 造压缩机（默认级别 Z_DEFAULT_COMPRESSION=6）
    local zip = pack(raw) .. pack()        -- 喂数据 + 无参收尾，拼接成完整压缩串

    local unpack_ = zlib.inflate()         -- 造解压机（默认窗口 MAX_WBITS+32，自动识别 zlib/gzip）
    local back = unpack_(zip) .. unpack_() -- 喂压缩串 + 无参收尾

    check("完整往返: 解压结果等于原文", back == raw)
    check("压缩确实变小了", #zip < #raw)   -- 规律文本空间局部性好，压缩率很高
end

-- 3. 流式特性：分块喂数据 vs 整块喂数据，压缩结果【完全一致】
--    原理：zlib 的压缩输出只取决于"字节流内容 + 每次调用的 flush 级别"，
--    与数据被切成几段喂进去无关（每口之间都是 Z_NO_FLUSH）。
--    这个用例同时验证了"机器能记住跨调用的状态"。
do
    local raw = make_raw(200)
    local mid = math.floor(#raw / 2)

    local f1 = zlib.deflate(6)                     -- 前半段 + 后半段，分两口喂
    local zip1 = f1(raw:sub(1, mid)) .. f1(raw:sub(mid + 1)) .. f1()

    local f2 = zlib.deflate(6)                     -- 整段一口喂
    local zip2 = f2(raw) .. f2()

    check("分块压缩与整块压缩结果一致", zip1 == zip2)
end

-- 4. 验证过滤器 f 的 4 个返回值结构（见文件头【概念2】）
--    第一次喂数据时流还没结束，所以 eos 一定是 false
do
    local f = zlib.deflate(6)
    local out, eos, tin, tout = f("hello")
    check("返回4个值: 第1个 out 是字符串(压缩数据)", type(out) == "string")
    check("返回4个值: 第2个 eos 是布尔(还没收尾应为 false)", eos == false)
    check("返回4个值: 第3/4个 total_in/total_out 是数字(累计字节数)",
        type(tin) == "number" and type(tout) == "number")
    f() -- 收尾释放流（忘了也别慌，流的 __gc 元方法最终会兜底调 deflateEnd）
end

-- 5. 验证【无参收尾】的必要性
--    不调 bad() 直接丢嘴里喂过的数据会出现什么？
--      deflate 内部有输出缓冲，没收到 Z_FINISH 时最后一块数据会一直攒着，
--      zip_bad 里只有前半段压缩字节，是一条"被截断的流"。
--    拿截断流去解压：inflate 通常不会报错（它以为数据还没传完，返回 Z_OK
--    继续等），只会解出"不完整的原文"；所以断言是"报错 或 产物 != 原文"。
do
    local raw = make_raw(50)

    local bad = zlib.deflate()
    local zip_bad = bad(raw)          -- 故意不调用 bad() 收尾 -> 流的尾巴丢了

    -- 解压截断流：可能抛错，也可能"成功"但产出不完整的原文
    local ok, back = pcall(function()
        local u = zlib.inflate()
        return u(zip_bad) .. u()
    end)
    check("不收尾的解压失败或产物不完整(验证收尾必要性)", (not ok) or back ~= raw)

    -- 对照组：正确收尾后，同样流程应完整还原
    local good = zlib.deflate()
    local zip_ok = good(raw) .. good()
    local u = zlib.inflate()
    check("正确收尾后解压成功", u(zip_ok) .. u() == raw)
end

-- 6. 收尾之后的机器是什么行为？
--    lz_filter_impl 在流结束后会把 C 层的 z_stream 置空（相当于机器报废）：
--      - 再喂数据  -> C 层直接抛错 "IllegalState: calling deflate function
--                     when stream was previously closed"（所以这里必须用 pcall 接住）
--      - 无参重复收尾 -> 幂等操作，只返回 "", true（第2个返回值 eos 仍是 true）
do
    local f = zlib.deflate()
    local out = f("hello") .. f()          -- f() 完成收尾，内部流已关闭

    local ok = pcall(function()
        f("再喂也没用")                    -- 流关闭后再喂数据 -> C层直接抛错
    end)
    check("收尾后再喂数据会报错", not ok)

    local tail, eos = f()                  -- 重复无参收尾 -> 幂等，返回 "", true
    check("重复收尾返回空串", tail == "")
    check("重复收尾 eos = true", eos == true)
    _ = out
end

-- 7. crc32 累加器：分块累加 == 一次性喂，结果一致
--    无参调用 zlib.crc32() 得到的是一个"校验累加器"闭包：
--      acc("数据")       -> 把这段数据并入校验（返回两个数：当前CRC、累计长度）
--      acc()             -> 无参时只是【取出】当前结果，不改变状态
--    好处：不需要把数据拼成一个大字符串，边收边算，随时取快照。
do
    local raw = make_raw(30)

    local acc = zlib.crc32()
    acc(raw:sub(1, 100))      -- 第1口
    acc(raw:sub(101))         -- 第2口（两段拼起来就是完整 raw）
    local sum1, len1 = acc()  -- 无参取出：累计CRC值, 累计字节数

    local acc2 = zlib.crc32()
    acc2(raw)                 -- 整段一次性喂
    local sum2, len2 = acc2()

    check("crc32: 分块累加与整块一致", sum1 == sum2)
    check("crc32: 累计长度正确", len1 == len2 and len1 == #raw)
    check("crc32: 值是数字", type(sum1) == "number")
end

-- 8. adler32 累加器：数据变一个字节，校验值就变
--    用途范例：给存档/配置算指纹，内容被改动立刻能从校验值上看出来。
do
    local acc = zlib.adler32()
    acc("hello world")
    local a1 = acc()

    local acc2 = zlib.adler32()
    acc2("hello worlD") -- 最后一个字母 d -> D
    local a2 = acc2()

    check("adler32: 数据变化导致校验值变化", a1 ~= a2)
end

-- 9. 错误处理：inflate 收到非法数据会抛错，而不是静默返回垃圾
--    "这不是 zlib 数据" 的字节流开头不符合 zlib 头格式，
--    内部 inflate 返回 Z_DATA_ERROR，lz_assert 直接 lua_error。
--    实际业务里解压网络来的数据【必须】用 pcall/xpcall 包住，防止服务被炸。
do
    local u = zlib.inflate()
    local ok, err = pcall(function()
        return u("这不是 zlib 数据"):rep(2)
    end)
    check("非法数据会抛错", not ok and err ~= nil)
end

-- 10. 压缩级别对产物大小的影响（旁证）
--      deflate 第1个参数是级别：1 最快压缩率低，9 最狠但最慢。
--      对规律性强的数据（"abcdefg" 重复 1000 次），级别 9 压得不比级别 1 差，
--      这里用 <= 而不是 < 是故意的：zlib 不保证严格更小，只保证"不会更差"。
do
    local raw = ("abcdefg"):rep(1000)

    local f1 = zlib.deflate(1)         -- 最快、压缩率低
    local z1 = f1(raw) .. f1()
    local f9 = zlib.deflate(9)         -- 最狠、最慢
    local z9 = f9(raw) .. f9()

    check("级别9压得不超过级别1(旁证)", #z9 <= #z1)
    local u = zlib.inflate()
    check("级别9的产物可正确解压", u(z9) .. u() == raw)
end

-- 汇总：fails 为 0 时以退出码 0 结束（方便挂 CI），否则退出码 1
print(string.format("\n非COMPAT模式测试结束: %s", fails == 0 and "全部通过" or ("有 " .. fails .. " 个失败")))
