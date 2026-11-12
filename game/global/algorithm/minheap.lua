-- 最小堆

local table = table
local tsize = table.size
local tremove = table.remove
local tinsert = table.insert
local tdeepcopy = table.deepcopy
local tempty = table.empty
local tsort = table.sort
local string = string
local sformat = string.format
local ostime = os.time
local tdump = tool.dump

-- 最小堆类
MinHeap = Class.NewClass("<<minheap class>>")

-- isQuote:true 引用(不对ele进行复制)
function MinHeap:New(uniqueKey, sortKeys, extData)
	assert(type(uniqueKey) == "string" and uniqueKey:len() > 0)
	assert(type(sortKeys) == "table" and #sortKeys > 0 and #sortKeys == tsize(sortKeys))
	for _, key in pairs(sortKeys) do
		if type(key) ~= "string" then
			error("sortKey type not string key " .. key)
		end
	end
	extData = extData or {}
	local isInfinite = true
	if extData.len then
		isInfinite = false
		assert(type(extData.len) == "number" and extData.len > 0)
	end

	local o = {
		sortKeys = tdeepcopy(sortKeys),
		uniqueKey = uniqueKey,
		heap = {},
		stub = {},
		isQuote = extData.isquote,	-- true:表示引用元素、false:深复制插入的元素
		isInfinite = isInfinite,	-- true:无穷容量、false:有限容量

		__IsObject = ostime(),		-- 标记为实例对象
	}
	if not o.isInfinite then
		o.len = extData.len

		-- true:堆满时。插入新元素时与堆顶元素比较，若比堆顶元素小则直接舍弃！（保存前N个大的元素）
		-- false：堆满时。与同一层的叶子节点比较，若都大于同一层的叶子节点则直接舍弃！（保存前N个小的元素）
		o.scheme = extData.scheme
	end
	setmetatable(o, {__index = self})
	return o
end

function MinHeap:IsEmpty()
	return self:Size() <= 0
end

function MinHeap:Size()
	return #self.heap
end

function MinHeap:IsFull()
	if self.isInfinite then
		return false
	end
	return #self.heap >= self.len
end

function MinHeap:Remove(unique)
	if self:IsEmpty() then
		return
	end
	local index = unique and self.stub[unique]
	local node = index and self.heap[index]
	if not node then
		return
	end

	local uniqueKey = self.uniqueKey
	local size = self:Size()
	if index == size then
		tremove(self.heap)
		self.stub[unique] = nil
	else
		local node1 = self.heap[index]
		local node2 = tremove(self.heap)
		self.stub[node1[uniqueKey]] = nil
		self.stub[node2[uniqueKey]] = index
		self.heap[index] = node2
		self:SideDown(index)
	end
	return node
end

function MinHeap:GetTopUnique()
	if self:IsEmpty() then
		return
	end
	return self.heap[1][self.uniqueKey]
end

function MinHeap:GetTop()
	if self:IsEmpty() then
		return
	end
	return self.heap[1]
end

function MinHeap:Clear()
	self.heap = {}
	self.stub = {}
end

-- 最小堆出栈
function MinHeap:Pop()
	if self:IsEmpty() then
		return
	end
	local top = self:GetTop()
	local size = self:Size()
	if size == 1 then
		self:Clear()
	elseif size > 1 then
		self.heap[1] = nil
		self.stub[top[self.uniqueKey]] = nil
		self:Swap(1, size)
		self:SideDown()
	end
	return top
end

function MinHeap:GetDataByUnique(unique)
	local index = unique and self.stub[unique]
	if not index then return end
	local ele = self.heap[index]
	if not ele then return end
	ele = tdeepcopy(ele)
	setmetatable(ele, {__newindex = function (...) error("not modify") end})
	return ele
end

function MinHeap:GetDataByIndex(index)
	local ele = index and self.heap[index]
	if not ele then return end
	ele = tdeepcopy(ele)
	setmetatable(ele, {__newindex = function (...) error("not modify") end})
	return ele
end

function MinHeap:Modify(modifyEle)
	if not modifyEle then return end
	local unique = modifyEle[self.uniqueKey]
	if not unique then
		error(sformat("not uniqueKey:%s modifyEle:%s", self.uniqueKey, tdump(modifyEle)))
	end
	for _, key in ipairs(self.sortKeys) do
		if not modifyEle[key] then
			error(sformat("not sortKey:%s modifyEle:%s", key, tdump(modifyEle)))
		end
	end

	local index = unique and self.stub[unique]
	local oldEle = index and self.heap[index]
	if not oldEle then
		error(sformat("not find unique:%s data", unique))
	end

	local isGt = self:CompareFunc(modifyEle, oldEle)
	if self.isQuote then
		self.heap[index] = modifyEle
	else
		self.heap[index] = tdeepcopy(modifyEle)
	end
	if isGt then
		-- oldEle小于modifyEle，自下到上排序
		self:SideUp(index)
	else
		-- oldEle大于modifyEle, 自上到下排序。
		self:SideDown(index)
	end
end

-- 排序(自上到下排序)
function MinHeap:SideDown(index)
	local size = self:Size()
	if size <= 1 then
		return
	end

	local loop = 0
	index = index or 1
	while true do
		loop = loop + 1
		if loop > size then
			error("side down error! loop:" .. loop)
		end

		local l = index * 2
		local r = (index * 2) + 1
		local smallest = index
		if l <= size then
			local parent = self.heap[smallest]
			local lSon = self.heap[l]
			if self:CompareFunc(lSon, parent) then
				smallest = l
			end
		end
		if r <= size then
			local parent = self.heap[smallest]
			local rSon = self.heap[r]
			if self:CompareFunc(rSon, parent) then
				smallest = r
			end
		end
		if index == smallest then
			break
		end
		self:Swap(index, smallest)
		index = smallest
	end
end

function MinHeap:HasUnique(unique)
	return unique and self.stub[unique]
end

function MinHeap:GetLeafNodes()
	local result = {}
	for i = self:Size(), 1, -1 do
		if self.heap[2*i] or self.heap[(2*i)+1] then
			break
		end
		tinsert(result, self.heap[i])
	end
	return result
end

-- 插入新元素
function MinHeap:Push(ele)
	local uniqueKey = self.uniqueKey
	local unique = ele[uniqueKey]
	if not unique then
		error("not uniqueKey field " .. uniqueKey)
	end

	if self:HasUnique(unique) then
		error(sformat("repeat same unique:%s", unique))
	end

	for _, key in ipairs(self.sortKeys) do
		if not ele[key] then
			error("not sortKey field " .. key)
		end
	end

	if self:IsFull() then
		if self.scheme then
			-- true:堆满时。插入新元素时与堆顶元素比较，若比堆顶元素小则直接舍弃！（保存前N个大的元素）
			local topEle = self:GetTop()
			if self:CompareFunc(ele, topEle) then
				return
			end

			self.heap[1] = self.isQuote and ele or tdeepcopy(ele)
			self.stub[topEle[uniqueKey]] = nil
			self.stub[ele[uniqueKey]] = 1
			self:SideDown()
		else
			-- false：堆满时。与所有叶子节点比较，若都大于所有叶子节点则直接舍弃！（保存前N个小的元素）
			local leafNodes = self:GetLeafNodes()
			if not leafNodes or tempty(leafNodes) then
				_ERROR_F("minheap push new ele:%s, but leaf nodes is empty!", tdump(ele))
				return
			end
			tsort(leafNodes, function (n1, n2)
				if not self:CompareFunc(n1, n2) then
					return true
				end
			end)
			if self:CompareFunc(leafNodes[1], ele) then
				return
			end
			local exunique = leafNodes[1][uniqueKey]
			local index = self.stub[exunique]
			self.stub[exunique] = nil
			self.stub[unique] = index
			self.heap[index] = self.isQuote and ele or tdeepcopy(ele)
			-- 更新最小堆
			self:SideUp(index)
		end
	else
		local index = self:Size() + 1
		self.heap[index] = self.isQuote and ele or tdeepcopy(ele)
		self.stub[unique] = index
		-- 更新最小堆
		self:SideUp(index)
	end
end

function MinHeap:Swap(aIndex, bIndex)
	local uniqueKey = self.uniqueKey
	local heap = self.heap
	local aNode = heap[aIndex]
	local bNode = heap[bIndex]
	heap[aIndex] = bNode
	heap[bIndex] = aNode
	if aNode then
		self.stub[aNode[uniqueKey]] = bIndex
	end
	if bNode then
		self.stub[bNode[uniqueKey]] = aIndex
	end
end

-- 比较函数
-- true：parent父节点 大于 son子节点
-- false：parent父节点 小于 son子节点
function MinHeap:CompareFunc(son, parent)
	for i = 1, #self.sortKeys do
		local key = self.sortKeys[i]
		if parent[key] > son[key] then
			return true
		elseif parent[key] < son[key] then
			return false
		end
	end
end

-- 排序(自下到上排序)
function MinHeap:SideUp(index)
	local size = self:Size()
	if size <= 1 then
		return
	end
	index = index or size
	if not (index > 0 and index <= size) then
		return
	end

	local heap = self.heap
	local loop = 0
	while true do
		loop = loop + 1
		if loop > size then
			error("minheap side up error! loop:" .. loop)
		end

		local smallest = index // 2
		if smallest <= 0 then break end

		local parent = heap[smallest]
		local son = heap[index]

		if not self:CompareFunc(son, parent) then
			break
		end

		self:Swap(index, smallest)
		index = smallest
	end
end
