-----------------------
--- 玩家类模板
---  热更新初步策略：
--- 			__ClassType 更新完后要将新类和旧类进行比对，在旧类的身上进行增删操作
--- 			__ObjectType 不进行热更新，因为这仅仅是一堆数据。仅需关注类模板（__ClassType）
-----------------------

local ostime = os.time

-- 在线玩家对象 ------
ROLE_OBJS = {}

function GetAllRoleObjs()
	return ROLE_OBJS
end

function GetRoleObjByUid(uid)
	return uid and ROLE_OBJS[uid]
end

-- 玩家类 ------
RoleClass = { __ClassType = "<<role class>>" }

-- 玩家类的构造方法
function RoleClass:New(o)
	o = o or { __Data = {}, }
	if type(o.uid) ~= "string" or ROLE_OBJS[o.uid] then
		_ERROR_F("RoleClass new fail! o:%s", tool.dumptree(o))
		return
	end

	o.__SuperClass = self		-- 标记RoleClass为父类
	o.__IsObject = ostime()		-- 标记为实例对象
	o.__Tmp = {}				-- 重置临时数据

	-- 直接将RoleClass放入o原表的__index里面。
	-- 	若o已设置A函数 且 RoleClass也设置A函数，o:A() 会调用o的而非RoleClass
	setmetatable(o, {__index = self})
	ROLE_OBJS[o.uid] = o

	return o
end

function RoleClass:GetUid()
	return self.uid
end

-- 将玩家数据保存至数据库中
function RoleClass:SaveDb()
	local data = self.__Data or {}
end

-- 存盘数据
function RoleClass:SetData(fieldName, data)
	self.__Data[fieldName] = data
end
function RoleClass:GetData(fieldName)
	return self.__Data[fieldName]
end

-- 临时数据（上线、下线就没有了）
function RoleClass:SetTempData(fieldName, data)
	self.__Tmp[fieldName] = data
end
function RoleClass:GetTempData(fieldName)
	return self.__Tmp[fieldName]
end

function RoleClass:Update(NewRoleClass)
	
end

--autogen-begin
function RoleClass:GetSex()
    return self.__Data.Sex
end
function RoleClass:SetSex(Sex)
    self.__Data.Sex = Sex
end

function RoleClass:GetLike1()
    return self.__Tmp.Like1
end
function RoleClass:SetLike1(Like1)
    self.__Tmp.Like1 = Like1
end

function RoleClass:GetLike2()
    return self.__Tmp.Like2
end
function RoleClass:SetLike2(Like2)
    self.__Tmp.Like2 = Like2
end


--autogen-end

