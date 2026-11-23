--[[
LuaLS 运行时插件（仅编辑器侧，不改动任何业务代码）
用途：让业务代码里的 `local X = Import("game/xxx.lua")` 具备类型解析与跳转定义能力。
原理（本版本 LuaLS 插件 API：直接定义全局函数 OnSetText 返回 diff 列表）：
  1. 对 /service/ 与 /global/ 路径下的文件，把 Import("...") 调用虚拟替换为 require("...")，
     复用 require 的模块解析拿到返回类型；
  2. 对"以全局符号导出"风格的模块（mem_common.lua、battle_skill.lua 等），在文件末尾
     虚拟追加 `return { Call_MemPing = Call_MemPing, SKILL = SKILL, ... }`，
     使 require 的返回类型 = 指向真实定义的引用表（全局函数 + 非 local 变量）。
效果：MEM.Call_MemPing()、SKILLMOD.SKILL.pick() 均可 F12 跳到真实定义行。
说明：只改写语言服务器内存中的索引用文本，磁盘文件不变；
     仅对 game/ tool/ skynet/ 前缀路径生效；
     改写范围限业务目录（service/global），避免引擎与第三方库被推断后产生额外告警。
]]

-- 插件返回给语言服务器的文本替换描述：
--   start  - 替换区间起始字节偏移（1-based，含）
--   finish - 替换区间结束字节偏移（1-based，含）；start > finish 表示在 start 处插入
--   text   - 用于替换/插入的新文本
---@class LuaLSDiff
---@field start integer 替换区间起始字节偏移（1-based，含）
---@field finish integer 替换区间结束字节偏移（1-based，含）；小于 start 时表示在 start 处插入
---@field text string 用于替换或插入的新文本

--- 去掉长括号字符串（[[...]] / [==[...]==]）与块注释（--[[...]]、--[==[...]==]），
--- 避免把字符串/注释里的内容误当成真实代码（如 Redis 脚本里的顶格 "return 1"）
---@param text string 文件全文
---@return string 仅保留真实代码的文本（仅用于静态符号匹配，不参与 diff 字节偏移计算）
local function stripLongBrackets(text)
	local out = text:gsub("%-%-%[(=*)%[.-%]%1%]", "")
	out = out:gsub("%[(=*)%[.-%]%1%]", "")
	return out
end

--- 收集文件中导出的全局符号（非 local，去重保序）：全局函数 + 全局变量
---   - 全局函数：行首顶格的 `function Name(...)`
---   - 全局变量：行首顶格的 `Name = ...`（排除 local、字段赋值、==/>=/~= 比较）
---@param text string 文件全文
---@return string[] 全局符号名列表
local function collectGlobals(text)
	local list, seen = {}, {}
	local function add(name)
		if not seen[name] then
			seen[name] = true
			list[#list + 1] = name
		end
	end
	-- 归一化换行 + 剔除长字符串/块注释，仅用于符号名匹配（不影响 diff 的字节偏移计算）
	local src = "\n" .. stripLongBrackets(text:gsub("\r\n", "\n"))
	for name in src:gmatch("\nfunction[ \t]+([%a_][%w_]*)") do
		add(name)
	end
	for name in src:gmatch("\n([%a_][%w_]*)%s*=[^=]") do
		add(name)
	end
	return list
end

--- 判断文件是否已存在顶层 return（有则不应再追加 return 表）
--- 需先剔除长字符串/块注释，否则脚本字符串里的 "return" 会造成误判
---@param text string 文件全文
---@return boolean 是否已含顶层 return
local function hasTopLevelReturn(text)
	return ("\n" .. stripLongBrackets(text)):find("\nreturn%s") ~= nil
end

--- 由符号名列表生成 `return { a = a, b = b, ... }` 表体文本
---@param list string[] 全局符号名列表
---@return string 表体文本（不含 return {} 包裹）
local function buildReturnTable(list)
	local t = {}
	for _, name in ipairs(list) do
		t[#t + 1] = "\t" .. name .. " = " .. name .. ","
	end
	return table.concat(t, "\n")
end

--- LuaLS 插件入口：对每个被索引的文件生成虚拟文本修改（diff），磁盘文件不变
---@param uri string 文件 URI（如 file:///e%3A/MyWork/...）
---@param text string 文件原始全文
---@return LuaLSDiff[]|nil 文本替换列表；无修改时返回 nil
function OnSetText(uri, text)
	local diffs = {}
	if uri:find("/service/") or uri:find("/global/") then
		local src = "\n" .. text
		for _, iPos, _, _, _, path, _, endPos in src:gmatch("([^%w_.])()Import(%s*)%((%s*)([\"'])([^\"']-)[\"'](%s*)%)()") do
			if path:find("^game/") or path:find("^tool/") or path:find("^skynet/") then
				-- 整个 Import("path") 调用替换为 require("path")；
				-- 去掉 .lua 扩展名，否则 LuaLS 默认 ?.lua 模式解析不到该文件
				diffs[#diffs + 1] = {
					start = iPos - 1, -- 原文本 1-based 字节偏移
					finish = endPos - 2,
					text = 'require("' .. path:gsub("%.lua$", "") .. '")',
				}
			end
		end
	end
	if not hasTopLevelReturn(text) then
		local list = collectGlobals(text)
		if #list > 0 then
			local nl = (text == "" or text:sub(-1) == "\n") and "" or "\n"
			diffs[#diffs + 1] = {
				start = #text + 1,
				finish = #text,
				text = nl .. "return {\n" .. buildReturnTable(list) .. "\n}\n",
			}
		end
	end
	if #diffs == 0 then
		return nil
	end
	return diffs
end
