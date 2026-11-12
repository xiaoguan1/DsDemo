local skynet = require "skynet"
local log_color_mode = skynet.getenv("log_color_mode") == "false"

-- 颜色相关的宏定义

local string = string
local sformat = string.format

if not log_color_mode then		-- 24-bit真彩模式


--[[
解释：RGB的16进制颜色码 转换 成可以在 日志里使用的 ANSI 转义序列
	颜色码格式 #RRGGBB (RR表示红色、GG表示绿色、BB表示蓝色。且范围均是 00-FF)

	第一步：把十六进制拆成 RGB 十进制值（例如：#fe6cb7）
		fe 的十进制为 254、6c 的十进制为 108、b7 的十进制为 183

	第二步：拼成 ANSI 真彩色序列
		ANSI 真彩色序列格式
			前景色（文字颜色）：[38;2;R;G;Bm
			背景色（底色）：[48;2;R;G;Bm

	#fe6cb7 转换成 前景色 [38;2;254;108;183m
	#fe6cb7 转换成 背景色 [48;2;254;108;183m
]]

-- ANSI真彩色序列的颜色码
local ANSI_COLORS = {
	white	= "#ffffff",
	blue	= "#2438CB",
	pink	= "#e603e6",
	red		= "#e50000",
	green 	= "#008011",
	yellow	= "#ebb039",
	yellow2 = "#fff44f",

	purple	= "#8a2be2",
}

-- 日志相关颜色
LOG_COLORS = {}
local RGB_REG = "^#(%w%w)(%w%w)(%w%w)"
LOG_COLOR_FMT = "[38;2;%s;48;2;%sm"		-- 字色、背景色格式

for name, rgb in pairs(ANSI_COLORS) do
	local rr, gg, bb = rgb:match(RGB_REG)
	if not rr or not gg or not bb then
		error(string.format("ANSI_COLORS name:[%s] value[%s] error!", name, rgb))
	end
	LOG_COLORS[name] = sformat("%s;%s;%s", tonumber(rr, 16), tonumber(gg, 16), tonumber(bb, 16))
end

-- 日志颜色组装（fcolor:字色  bcolor:底色）
local function _Log_Assembly(fcolor, bcolor)
	assert(fcolor and bcolor)
	return sformat(LOG_COLOR_FMT, fcolor, bcolor)
end

LOG_NORMAL = _Log_Assembly(LOG_COLORS.white, LOG_COLORS.green)		-- 一般日志
LOG_WARNING = _Log_Assembly(LOG_COLORS.white, LOG_COLORS.yellow)	-- 警告日志
LOG_ERROR = _Log_Assembly(LOG_COLORS.white, LOG_COLORS.red)			-- 错误日志
LOG_EVENT = _Log_Assembly(LOG_COLORS.white, LOG_COLORS.blue)		-- 事件日志
LOG_MEM = _Log_Assembly(LOG_COLORS.red, LOG_COLORS.white)			-- 内存报警日志
LOG_DEBUG = _Log_Assembly(LOG_COLORS.yellow2, LOG_COLORS.purple)	-- 调试日志



else		-- 4bit色彩模式

-- 字体颜色
local FONT_COLOR = {
	Black	=	"[30",		-- 黑色
	Red		= 	"[31",		-- 红色
	Green	=	"[32",		-- 绿色
	Yellow	=	"[33",		-- 黄色
	Blue	=	"[34",		-- 蓝色
	Purple	=	"[35",		-- 紫色
	Cyan	=	"[36",		-- 青色
	White	=	"[37",		-- 白色
}

-- 背景颜色
local BACKGROUND_COLOR = {
	Black	=	";40m",		-- 黑色
	Red		=	";41m",		-- 红色
	Green	=	";42m",		-- 绿色
	Yellow	=	";43m",		-- 黄色
	Blue	=	";44m",		-- 蓝色
	Purple	=	";45m",		-- 紫色
	Cyan	=	";46m",		-- 青色
	White	=	";47m",		-- 白色
}

LOG_NORMAL = FONT_COLOR.White .. BACKGROUND_COLOR.Green		-- 一般日志(白字绿底)
LOG_WARNING = FONT_COLOR.Black .. BACKGROUND_COLOR.Yellow	-- 警告日志(黑字黄底)
LOG_ERROR = FONT_COLOR.Black .. BACKGROUND_COLOR.Red		-- 错误日志(黑字红底)
LOG_MEM = FONT_COLOR.Black .. BACKGROUND_COLOR.Purple		-- 内存报警日志(黑字紫底)
LOG_EVENT = FONT_COLOR.Green .. BACKGROUND_COLOR.Yellow		-- 事件日志(绿字黄底)
LOG_DEBUG = FONT_COLOR.Green .. BACKGROUND_COLOR.Purple		-- 事件日志(绿字紫底)

end



