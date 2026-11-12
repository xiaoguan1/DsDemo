--[[
编译协议的主要流程
	流程1 使用protoc对proto文件进行编译生成pb文件
	
	流程2 生成协议信息
		1.game/global/rprotomap.lua 是业务开发定义的协议信息（协议名 -> {desc, request, response}），type 由脚本自动推导
		2.protocol/save-prot-id 是自动化生成的 协议名->编号 持久化文件，不允许手动修改！！！
		作用：保证旧协议编号保持不变，新协议在上一个编号基础上 +1 递增
		3.protocol/protomap.lua 是自动化生成的协议表文件，不允许手动修改！！！
		节点内实际加载的是该文件（协议名 -> {desc, type, id, request, response}）

	注意：目前protobuf仅支持版本2，未支持版本3
]]

local table = table
local string = string
local sformat = string.format
local io = io
local iopen = io.open
local ipopen = io.popen

local protocolPath = "./protocol/"
local fileProtoPath = protocolPath .. "protos"
local pbsPath = protocolPath .. "pbs"

-- --include_imports 参数，用于编译时包含导入的proto文件，否则会报错：import "xxx" not found in file "xxx.proto" at line 1
-- -o 等价于 --descriptor_set_out，输出 FileDescriptorSet 描述文件（.pb），供 pbc 运行时加载
local protoc = "protoc --proto_path=" .. fileProtoPath .. " --include_imports -o "
local protocTail = "/%s.pb %s"			-- 每条命令尾部：输出pb文件名 + 输入proto文件名
local protocHead = protoc .. pbsPath

local proFiles = {}			-- proto后缀的协议文件
local package2message = {}	-- proto后缀文件的message内容

local function _Error(fmt, ...)
	if (...) == nil then
		error(fmt)
	else
		error(sformat(fmt, ...))
	end
end

-- 字符串切割（注意：sep 是字符集合，等价于 gmatch 的 [^sep]+ 语义，不是普通分隔字符串）
function string.split(str, sep)
	if not sep or not str or str == "" then
		return
	end
	local result = {}
	for s in str:gmatch("([^" .. sep .. "]+)") do
		table.insert(result, s)
	end
	return result
end

-- 获取table的长度
function table.size(t)
	assert(t)
	local count = 0
	for _ in pairs(t) do
		count = count +1
	end
	return count
end

-- 检查 .proto 文件内容 
-- 校验项：1.syntax 必须为 proto2  2.package 名必须与文件名一致  3.同 package 下 message 不允许重名
local function _GetProtoFiles()
	local dirs = assert(ipopen("ls " .. fileProtoPath),
							sformat("%s popen fail!", fileProtoPath))

	for file in dirs:lines() do
		local fPath = fileProtoPath .. "/" .. file
		local f = assert(iopen(fileProtoPath .. "/" .. file),
					sformat("filePath:%s open fail!", fPath))

		local context, err = f:read("*a")
		f:close()
		if not context then
			_Error("%s err:%s", file, err)
		end

		local fileName = string.split(file, ".")
		fileName = assert(fileName and fileName[1],
						sformat("%s not find file name", file))

		-- 判断是否定义了 syntax = "proto2";
		local isSyntax = context:find("syntax%s*=%s*\"proto2\"%s*;")
		if not isSyntax then
			_Error("%s must set syntax = proto2;", file)
		end

		-- 判断是否定义了package
		local isPackage = context:find("package%s+" .. fileName .. "%s*;")
		if not isPackage then
			_Error("%s must set package %s;", file, fileName)
		end

		table.insert(proFiles, file)

		if package2message[fileName] then
			-- 重复定义了 package 相同的名字
			_Error("%s repeat package %s", file, fileName)
		else
			local messageList = {}
			package2message[fileName] = messageList
			for message in context:gmatch("%s*message%s+([%w_]+)") do
				if messageList[message] then
					_Error("%s repeat message %s", fileName, message)
				end
				messageList[message] = true
			end
		end
	end
	dirs:close()
end

-- protoc 编译 .proto 文件，生成 protocol/pbs/*.pb
-- 编译失败（os.execute 返回非 true）时直接报错中断，避免用不完整的 pb 继续生成协议表
local function _MakePbs()
	_GetProtoFiles()
	if #proFiles <= 0 then
		return
	end

	-- 删除pb文件夹下的所有文件
	os.execute("rm -rf " .. pbsPath .. "/*")

	for _, file in pairs(proFiles) do
		local fileName = string.split(file, ".")
		fileName = assert(fileName and fileName[1],
						sformat("%s not find file name", file))

		local tail = sformat(protocTail, fileName, file)
		local isOk = os.execute(protocHead .. tail)
		if isOk then
			print("protoc make " .. file)
		else
			_Error("protoc make %s fail", file)
		end
	end
end

local TipMsg = "----- auto generate file, please do not modify -----"
local Spi_Is_Cover = true	-- save-prot-id文件 覆盖写标记：首次生成或文件异常时为true（覆盖写），正常文件（首行为TipMsg）为false（追加写）。
local MAXPROTID = 65536		-- 最大允许的协议编号（协议编号只占2字节，范围1~65536）
local addProtocol = 0		-- 本次运行新增的协议数量（rprotomap中未分配过编号的协议）
local nowProtId				-- 当前协议编号（save-prot-id中记录的最后一个编号）
local protName2Id, id2ProtoName = {}, {}	-- 协议名<->编号 的双向映射
local saveprotid_path = "protocol/save-prot-id"

-- 加载 save-prot-id，建立 协议名<->编号 映射，并校验编号必须从1开始且严格+1递增
local function _LoadSaveProtId()
	local f = iopen(saveprotid_path, "r")
	if not f then
		-- 文件不存在，则创建并初始化
		print("create " .. saveprotid_path)
		os.execute(sformat("rm -f %s ; touch %s", saveprotid_path, saveprotid_path))
		nowProtId = 0
		return
	end

	local lineNo = 1
	for c in f:lines() do
		if lineNo == 1 then
			if c == TipMsg then
				-- save-prot-id文件正常，尾部追加方式写入
				Spi_Is_Cover = false
			end
		else
			local protName, protId = string.match(c, "^%s*([^,]+)%s*,%s*(%d+)%s*$")
			protId = protId and tonumber(protId)
			if protName and protId then
				if protId > MAXPROTID then
					-- 因为协议编号仅占用2个字节，故范围在1到65536的协议编号
					-- 若超出该范围则需要考虑业务那边是否需要拓展
					_Error("protocol id > %s!!!", MAXPROTID)
				end

				-- 协议编号的自增检查（必须是以1为增值）
				local isOk
				if (not nowProtId and protId == 1) or
					(nowProtId and (protId - nowProtId) == 1)
				then
					isOk = true
				end
				if not isOk then
					_Error("protocol id error, nowProtId:[%s] -> protId:[%s]", nowProtId or 0, protId)
				end

				protName2Id[protName] = protId
				id2ProtoName[protId] = protName
				nowProtId = protId
			else
				-- 存在某一行的内容格式不正确,直接报错处理.
				-- 即使不报错,接下来的协议编号检查也依然会抛出错误中断
				_Error("save-prot-id context error, [%s]", c)
			end
		end
		lineNo = lineNo + 1
	end
	f:close()

	-- 若文件为空（或首行不是TipMsg），则当前编号默认0，新增协议将从1开始分配
	nowProtId = nowProtId or 0
end

local PROT_TYPE_PUSH = "push"			-- 服务器推送协议（S->C）：只定义response
local PROT_TYPE_NOTIFY = "notify"		-- 客户端推送协议（C->S）：只定义request
local PROT_TYPE_RESPONSE = "response"	-- 前后端正常响应协议（C->S、S->C）：request和response都定义
local rprotomap_path = "game/global/rprotomap.lua"

-- 加载业务协议定义 rprotomap.lua，校验 request/response 指向的 message 必须存在于 proto 文件中
-- 协议 type 由脚本根据 request/response 自动推导；已存在协议复用 save-prot-id 中的编号，新协议从末尾+1递增
local function _LoadRprotomap()
	dofile(rprotomap_path)
	assert(RPROTOMAP and type(RPROTOMAP) == "table", "rprotomap.lua RPROTOMAP error")
	for protName, protBody in pairs(RPROTOMAP) do
		if not protBody.desc or #protBody.desc <= 0 or #protBody.desc >= 1024 then
			-- 没有定义desc 或者 desc太长
			_Error("rprotomap.lua %s desc error!", protName)
		end

		if protBody.type then
			-- 不能定义type，由该脚本自动判断类型
			_Error("rprotomap.lua %s must not definition type", protName)
		end

		if protBody.request and protBody.response then
			protBody.type = PROT_TYPE_RESPONSE
		elseif protBody.request then
			protBody.type = PROT_TYPE_NOTIFY
		elseif protBody.response then
			protBody.type = PROT_TYPE_PUSH
		else
			_Error("rprotomap.lua %s not definition request or response", protName)
		end

		-- 检查 request 和 response 的合法性
		for k, v in pairs({request = protBody.request, response = protBody.response}) do
			local isOk
			local info = string.split(v, ".") or {}
			if #info == 2 then
				local package = info[1]
				local message = info[2]
				if package2message[package] and package2message[package][message] then
					isOk = true
				end
			end
			if not isOk then
				_Error("rprotomap.lua %s, %s message not exist", protName, k)
			end
		end

		-- 赋值协议编号
		protBody.id = protName2Id[protName]
		if not protBody.id then
			-- 新增协议
			addProtocol = addProtocol + 1
			protBody.id = nowProtId + addProtocol
			protName2Id[protName] = protBody.id
			id2ProtoName[protBody.id] = protName
		end
	end
end

-- 写回 save-prot-id：覆盖写（首次生成）或追加写（仅写本次新增的协议）
-- 通过 id2ProtoName 反查编号对应的协议名，保证与 protomap.lua 使用同一份编号
local function _WriteSaveSpi()
	local startId, endId, mode
	if Spi_Is_Cover then
		-- 覆盖写
		mode = "w+"
		startId = 1
		endId = nowProtId + addProtocol
	else
		-- 追加写
		if addProtocol <= 0 then
			-- 没有新增协议，则无写入处理
			return
		end
		mode = "a+"
		startId = nowProtId + 1
		endId = nowProtId + addProtocol
	end

	local f = iopen(saveprotid_path, mode)
	if not f then
		_Error("%s io open fail", saveprotid_path)
	end

	if Spi_Is_Cover then
		-- 覆盖写
		f:write(TipMsg .. "\n")
	end

	for id = startId, endId do
		f:write(sformat("%s,%s\n", id2ProtoName[id], id))
	end

	f:flush()
	f:close()
end

local protomap_path = "protocol/protomap.lua"

-- 生成 protocol/protomap.lua（节点实际加载的协议表）
-- 按编号顺序遍历输出；rprotomap 中已删除的协议仅保留在 save-prot-id 中占位，防止旧编号被新协议复用
local function _WriteProtomap()
	local f = iopen(protomap_path, "w+")
	if not f then
		_Error("%s io open fail", protomap_path)
	end
	f:write(TipMsg .. "\n")
	f:write("PROTOMAP = {\n")

	local bodyFmt1 = [[
	["%s"] = { desc = "%s", type = "%s", id = "%s",
		response = "%s",
	},
]]
	local bodyFmt2 = [[
	["%s"] = { desc = "%s", type = "%s", id = "%s",
		request = "%s",
	},
]]
	local bodyFmt3 = [[
	["%s"] = { desc = "%s", type = "%s", id = "%s",
		request = "%s",
		response = "%s",
	},
]]

	local writeCount = 0
	for id = 1, nowProtId + addProtocol do
		local protName = assert(id2ProtoName[id])
		local protBody = RPROTOMAP[protName]
		if protBody then
			local bodyContext
			if protBody.type == PROT_TYPE_PUSH then
				bodyContext = sformat(bodyFmt1, protName, protBody.desc, PROT_TYPE_PUSH, id, protBody.response)
			elseif protBody.type == PROT_TYPE_NOTIFY then
				bodyContext = sformat(bodyFmt2, protName, protBody.desc, PROT_TYPE_NOTIFY, id, protBody.request)
			else
				bodyContext = sformat(bodyFmt3, protName, protBody.desc, PROT_TYPE_RESPONSE, id, protBody.request, protBody.response)
			end
			f:write(bodyContext)
			writeCount = writeCount + 1
		end
	end
	f:write("}")
	f:flush()
	f:close()

	dofile(protomap_path)
	local protomap_len = table.size(PROTOMAP)
	if protomap_len ~= writeCount then
		_Error("auto-generate %s, unknown error!", protomap_path)
	end
end

---------------- 主流程 ----------------
_MakePbs()          -- 1. protoc 编译 .proto -> protocol/pbs/*.pb
_LoadSaveProtId()   -- 2. 加载 save-prot-id，恢复 协议名<->编号 映射
_LoadRprotomap()    -- 3. 加载业务协议定义，校验并分配编号（旧协议复用，新协议递增）
_WriteSaveSpi()     -- 4. 写回 save-prot-id（覆盖或追加新增编号）
_WriteProtomap()    -- 5. 生成 protocol/protomap.lua 协议表
print("---------- make protocol all finish ----------")
