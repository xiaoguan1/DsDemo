local queue = {}

function queue.new()
	return setmetatable({first = 1, last = 0}, {__index = queue})
end

function queue:push(v)
	self.last = self.last + 1
	self[self.last] = v
end

function queue:pop()
	if self.first > self.last then
		return
	end
	local v = self[self.first]
	self[self.first] = nil
	self.first = self.first + 1
	return v
end

return queue