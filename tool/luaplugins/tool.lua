----------------------------
-- 创建者：Ghost
-- 模块作用：sys拓展函数

----------------------------

local json = require "cjson"
local pcall = pcall
local pairs = pairs
local ipairs = ipairs
local type = type
local string = string
local tostring = tostring
local table = table
if not tool then
	tool = {}
	_G.tool = tool
end

local function _normalize(value)
	local retval = ''
	if type(value) == 'function' then
		retval = '<' .. tostring(value) .. '>'
	elseif type(value) == 'table' then
		retval = '<' .. tostring(value) .. '>'
	elseif type(value) == 'string' then
		retval = string.format('%q', value)
	else
		retval = tostring(value)
	end
	return retval
end

local function is_array(tbl)
	local len, maxK = 0, 0
	for k, b in pairs(tbl) do
		if type(k) ~= "number" then
			return false
		end
		len = len + 1
		if maxK < k then
			maxK = k
		end
	end
	if maxK ~= len then
		return false
	end
	return true, maxK
end

function tool.repr(value)
	local retval = ''
	if type(value) == 'table' then
		local visited = {}
		retval = retval .. '{'
		for i, v in ipairs(value) do
			retval = retval .. _normalize(v) .. ','
			visited[i] = 1
		end
		for k, v in pairs(value) do
			if not visited[k] then
				retval = retval .. '[' .. _normalize(k) .. '] = ' .. _normalize(v) .. ', '
			end
		end
		retval = retval .. '}'
		return retval
	else
		retval = _normalize(value)
	end
	return retval
end

function tool.FindErrorType(value, dummy)
	if not value then
		return
	end
	local Types = {number = 1, string = 1, table = 1, boolean = 1,}
	if not Types[type(value)] then
		print(value, dummy)
		error("FindErrorType error value:".. value)
	else
		if type(value) == "table" then
			print("table ", tool.repr(value), dummy)
			for k, v in pairs(value) do
				tool.FindErrorType(k, v)
				tool.FindErrorType(v, k)
			end
		end
	end
end

local function dodump(value, c, visited)
	local retval = ''
	if type(value) == 'table' then
		c = (c or 0) + 1
		if c >= 100 then
			error("dump to deep: " .. c)
		end

		visited = visited or {}
		if visited[value] then
			return '<circular>'
		end
		visited[value] = true

		retval = retval .. '{'
		for k, v in pairs(value) do
			retval = retval .. '[' .. dodump(k, c, visited) .. '] = ' .. dodump(v, c, visited) .. ', '
		end
		visited[value] = nil
		retval = retval .. '}'
		return retval
	else
		retval = _normalize(value)
	end
	return retval
end

-- 循环引用会以 <circular> 占位，不会死循环；超深(100层)仍会报错。
function tool.dump(value)
	return dodump(value)
end

local function _Foreach(t, f)
	for k, v in pairs(t) do
		if f(k, v) then
			break
		end			-- 拓展可中断
	end
end

local function _WordsIndentBy(xn)
	local result = ""
	for i = 1, xn do
		result = result .. "  "
	end
	return result
end

local function _ToTreeString(t, deep, visited)
	if deep >= 100 then
		error("tool.dumptree deep error!")
	end
	if type(t) ~= "table" then
		return tostring(t)
	end

	visited = visited or {}
	if visited[t] then
		-- 遇到循环引用 打印占位符（暂不报错）
		return tostring(t) .. '---<circular>'
	end
	visited[t] = true

	local indent = _WordsIndentBy(deep)
	local result = indent .. "{\n"

	_Foreach(t, function(k, v)
		result = result .. _WordsIndentBy(deep + 1)
		if type(k) == "string" then
			result = result .. "[" .. string.format('%q', k) .. "]="
		else
			result = result .. "[" .. tostring(k) .. "]="
		end
		if type(v) == "table" then
			local subT = _ToTreeString(v, deep + 2, visited)
			result = result .. "\n" .. subT .. "," .. "\n"
		else
			if type(v) == "string" then
				result = result .. string.format('%q', v) .. "," .. "\n"
			else
				result = result .. tostring(v) .. "," .. "\n"
			end
		end
	end)

	visited[t] = nil
	return result .. indent .. "}"
end

-- 支持递归打印嵌套 table；循环引用会以 <circular> 占位。
-- 不建议用 table 作为 key（table 是指向内存的指针，打印出来只是地址）
function tool.dumptree(t)
	return _ToTreeString(t, 0)
end

-- 提供堆栈信息（包括之前层级的local和upvalue都打印出来）
-- @param msg string|nil @额外信息
function tool.traceback(msg)
	-- 打印局部变量，方便查看问题
	local localData = {}
	for level = 2, 10 do
		local info = debug.getinfo(level, "f")
		if not info then break end

		local tbl = {}
		for idx = 1, 50 do
			local key, val = debug.getlocal(level, idx)
			if not key then break end
			if key:byte() ~= 40 then -- '('
				table.insert(tbl, string.format("%s:%s", tostring(key), tostring(val)))
			end
		end
		if #tbl > 0 then
			table.insert(localData, ("(local) " .. level .. " " .. (table.concat(tbl, ",") or "")))
		end
	end
	local localMsg = table.concat(localData, "\n")

	local upvalueMsg = nil
	local tbl = {}
	local info = debug.getinfo(2, "f")
	if info and info.func then
		local func = info.func
		for idx = 1, 50 do
			local key, val = debug.getupvalue(func, idx)
			if not key then break end
			table.insert(tbl, string.format("%s:%s", tostring(key), tostring(val)))
		end
		if #tbl > 0 then
			upvalueMsg = "(upvalue) " .. (table.concat(tbl, ",") or "")
		end
	end

	return string.format("tool.traceback: \n%s\n%s\n%s\n%s", msg, localMsg, upvalueMsg, debug.traceback("", 2))
end

local function serialise_table(value, depth, visited)
	depth = depth + 1
	if depth > 50 then
		error("tool.serialise: too many nested tables")
	end

	-- 循环引用检测：当前 table 已在祖先链中，检测到循环引用则报错
	if visited[value] then
		error("tool.serialise: circular reference detected")
	end
	visited[value] = true

	local isArr, len = is_array(value)
	local fragment = { "{" }
	local comma
	if isArr then
		-- array
		for i = 1, len, 1 do
			if comma then
				table.insert(fragment, ",")
			end
			table.insert(fragment, tool.serialise(value[i], depth, visited))
			comma = true
		end
	else
		-- map
		local indexs = {}
		for k in ipairs(value) do
			indexs[k] = k
		end
		for k, v in pairs(value) do
			if comma then
				table.insert(fragment, ",")
			end
			local ser
			if indexs[k] then
				ser = ("%s"):format(tool.serialise(v, depth, visited))
			else
				ser = ("[%s]=%s"):format(tool.serialise(k, depth, visited), tool.serialise(v, depth, visited))
			end
			table.insert(fragment, ser)
			comma = true
		end
	end

	visited[value] = nil

	table.insert(fragment, "}")
	return table.concat(fragment)
end

function tool.serialise(value, depth, visited)
	if depth == nil then depth = 0 end
	visited = visited or {}

	local typ = type(value)
	if value == json.null then
		error("tool.serialise: json.null is not supported")
	elseif typ == "string" then
		return ("%q"):format(value)
	elseif typ == "nil" or
			typ == "boolean"
	then
		return tostring(value)
	elseif typ == "number" then
		if value ~= value then
			error("tool.serialise: NaN is not supported")
		elseif value == math.huge or value == -math.huge then
			error("tool.serialise: inf is not supported")
		end
		return tostring(value)
	elseif typ == "table" then
		return serialise_table(value, depth, visited)
	else
		error("tool.serialise: unsupported type " .. typ)
	end
end
