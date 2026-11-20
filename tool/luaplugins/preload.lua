local skynet = require "skynet"
local skynet_getenv = skynet.getenv
require "skynet.manager"
local traceback = debug.traceback
scoroutine = require "skynet.coroutine"
Class = require "oop.class"


-- 重置随机种子
math.randomseed()

-- 容错执行函数
local function _RetFunc(isOk, ...)
	if not isOk then
		skynet.error(...)	-- 缺了日志输出，暂用skynet.error代替
	end
	return isOk, ...
end

function TryCall(func, ...)
	return _RetFunc(xpcall(func, traceback, ...))
end

-- lua原生接口函数的拓展（优先加载）
_G.TOOL_FILES = {
	"tool/luaplugins/table.lua",
	"tool/luaplugins/string.lua",
	"tool/luaplugins/tool.lua",
	"tool/luaplugins/posix.lua",
}
for _, pathFile in pairs(TOOL_FILES) do
	if not TryCall(dofile, pathFile) then
		skynet.abort()
	end
end

-- 宏定义
_G.MACRO_FILES = {
	"game/global/macro/common.lua",
	"game/global/macro/namedsvr.lua",
	"game/global/macro/fenv.lua",
	"game/global/macro/color.lua",
}
for _, pathFile in pairs(MACRO_FILES) do
	if not TryCall(dofile, pathFile) then
		skynet.abort()
	end
end

if not _G.Import then
	local func, err = loadfile("tool/luaplugins/import.lua", "bt", _G)
	if not func then
		skynet.error(err)
		skynet.abort()
	end
	if not TryCall(func) then
		skynet.abort()
	end
end

-- 注册的公共协议
skynet.register_protocol({
	name = "callout",
	id = skynet.PTYPE_CALLOUT,
	unpack = skynet.unpack,
	pack = skynet.pack,
})

local gamePreload = skynet.getenv("game_preload")
if gamePreload then
	dofile(gamePreload)
end
