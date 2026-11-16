-- perf 压测服务：驱动 cell 批量生成实体并逐帧移动，统计帧耗时
-- 验收标准（M1）：500 实体同格移动，帧均耗时 < 20ms
-- 启动方式：main 节点启动后由 main 拉起（config 配 perf_auto = true）
local skynet = require "skynet"
local SERVICE_NAME = SERVICE_NAME

-- 启动参数：cell 服务地址（loader 以字符串传给服务主 chunk，skynet.start 回调不接收参数）
local launch_cell_addr = ...

dofile "./game/global/log.lua"

skynet.start(function ()
	local cell = assert(tonumber(launch_cell_addr), "perf need cell addr")

	local n = tonumber(skynet.getenv("perf_n")) or 500
	local frames = tonumber(skynet.getenv("perf_frames")) or 100
	local step = tonumber(skynet.getenv("perf_step")) or 10

	-- 等 cell 完成初始化
	skynet.sleep(50)

	local isOk, result = TryCall(skynet.call, cell, "lua", "perf_run", n, frames, step)
	if not isOk or not result then
		_ERROR_F("perf_run fail err:%s", tostring(result))
		skynet.exit()
		return
	end

	local avg, mx, mn, p50 = result.avg_ms, result.max_ms, result.min_ms, result.p50_ms
	_INFO_F("=== perf report ===")
	_INFO_F("实体数:%s 帧数:%s 步幅:%s", result.n, result.frames, step)
	_INFO_F("帧耗时 avg=%.3fms max=%.3fms min=%.3fms p50=%.3fms", avg, mx, mn, p50)
	_INFO_F("广播总量:%s 实体移动吞吐:%s/s", result.broadcast, result.entities_per_sec)
	_INFO_F("验收(帧均<20ms): %s", result.pass and "PASS" or "FAIL")

	skynet.exit()
end)
