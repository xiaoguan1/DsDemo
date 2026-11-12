
DbField = {
	"Sex",
}

TempField = {
	"Like1",
	"Like2",
}


-- 字段检查
function FieldCheck(ft1, ft2)
	assert(ft1 and ft2)

	local function _ReverseMap(ft, tf)
		for k, fieldName in pairs(ft) do
			if tf[fieldName] then
				error("repeat field " .. fieldName)
			end
			tf[fieldName] = k
		end
	end
	local function _DoCheck(tf1, tf2)
		for fieldName in pairs(tf1) do
			-- 存盘需要简单的命名方式，方便阅读与修改
			if not string.match(fieldName, "^[%a_][%w_]*$") then
				error(string.format("%s is not valid var name", fieldName))
			end

			if tf2[fieldName] then
				error(string.format("TempField has DbField.%s error!", fieldName))
			end
		end
	end

	local tf1, tf2 = {}, {}
	_ReverseMap(ft1, tf1)
	_ReverseMap(ft2, tf2)
	_DoCheck(tf1, tf2)
	_DoCheck(tf2, tf1)
end
FieldCheck(DbField, TempField)


local VAR_PATTERN_FORMAT = [[
function RoleClass:Get%s()
    return self.%s.%s
end
function RoleClass:Set%s(%s)
    self.%s.%s = %s
end

]]

local strList = ""
function DoAutoCreate(fieldList, saveStr)
	for _, field in pairs(fieldList) do
		local str = string.format(VAR_PATTERN_FORMAT,
						field, saveStr, field,
						field, field, saveStr, field, field
					)
		strList = strList .. str
	end
end
DoAutoCreate(DbField, "__Data")
DoAutoCreate(TempField, "__Tmp")
strList = "\n" .. strList .. "\n"

function GenFile(data)
	local filePath = "./game/global/oop/roleclass.lua"
	local content
	local rf = io.open(filePath, "r")
	if rf then 
		content = rf:read("*a")
		rf:close()
    end

	if content then
		local sub
		data, sub = string.gsub(content, "(%-%-autogen%-begin).-(%-%-autogen%-end)", "%1" .. data .. "%2")
        assert(sub == 1, string.format("must insert into file: %s once", filePath))
    else
        error("not file: " .. filePath)
    end

	local fd = assert(io.open(filePath, "w"))
	fd:write(data)
	fd:flush()
	fd:close()
end
GenFile(strList)
