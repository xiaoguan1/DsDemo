local table = table

function table.empty(t)
	for k, v in pairs(t) do
		return false
	end
	return true
end

function table.size(t)
	local len = 0
	for _, _ in pairs(t) do
		len = len + 1
	end
	return len
end

-- 比较两个table的指针地址是否一样
function table.ptreq(t1, t2)
	return tostring(t1) == tostring(t2)
end

function table.has_value(t, v)
	for _k, _v in pairs(t) do
		if v == _v then
			return _k
		end
	end
end

function table.copy(t)
	local tt = {}
	for k, v in pairs(t) do
		tt[k] = v
	end
	return tt
end

function table.deepcopy(src)
	if type(src) ~= "table" then
		return src
	end
	local copied = {}
	local function clone_table(t, deep)
		deep = deep or 1
		if deep >= 100 then
			error("deepcopy deep >= 100, fail!")
		end
		if copied[t] then
			return copied[t]	-- 循环/共享引用直接复用
		end
		local r = {}
		copied[t] = r
		for k, v in pairs(t) do
			local vt = type(v)
			if vt == "userdata" then
				error("not support copy userdata")
			elseif vt == "table" then
				r[k] = clone_table(v, deep + 1)
			else
				r[k] = v
			end
		end
		return r
	end
	return clone_table(src)
end

function table.clear(tbl)
	for k in pairs(tbl) do
		tbl[k] = nil
	end
end

-- 返回一个只读表（若tbl里面还有tbl，想要限制只读，目前只能手打添加。。。。）
function table.onlyread(tbl)
	if type(tbl) ~= "table" then
		_ERROR("table.onlyread arg must table!")
		return
	end

	local rtbl = setmetatable({}, {
		__index = tbl,
		__newindex = function (t, k, v)
			error(string.format("%s only read. key:%s value:%s insert fail!", tbl,k, v))
		end,
		__pairs = function (_rtbl)
			-- 参数 _rtbl 和 rtbl 是一样的，故忽略即可。

			local function filter(t, k)
				local v
				k, v = next(t, k)
				return k, v
			end
			return filter, tbl, nil
		end
	})
	return rtbl
end

-- 比较两个table是否相等
function table.equal(ele1, ele2)
    local seen = {}
    local function eq(a, b)
        -- 基础类型
        if type(a) ~= "table" or type(b) ~= "table" then
            return a == b
        end
		-- table类型
        if a == b then return true end
        if seen[a] and seen[a][b] then return true end
        if not seen[a] then seen[a] = {} end
        seen[a][b] = true
        for k, v in pairs(a) do
            if not eq(v, b[k]) then return false end
        end
        for k, v in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end
    return eq(ele1, ele2)
end