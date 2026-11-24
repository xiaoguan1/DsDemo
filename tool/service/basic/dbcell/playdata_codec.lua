--------------------
-- playdata 编解码与键构造（客户端 / cell 共用）
-- 热层格式：<version>|<tool.serialise(data)>
-- 说明：放在 tool/service/basic/dbcell 下，避免 tool 反向依赖 game/global
--------------------

local tonumber = tonumber
local tostring = tostring
local type = type
local pcall = pcall
local sfind = string.find
local ssub = string.sub

-- 序列化任意 Lua 值
function PD_Pack(value)
	return tool.serialise(value)
end

-- 反序列化；失败返回 nil（load 只编译不执行，必须再调用 chunk）
function PD_Unpack(payload)
	if type(payload) ~= "string" or payload == "" then
		return nil
	end
	local loadOk, chunk = pcall(load, "return " .. payload)
	if not loadOk or not chunk then
		return nil
	end
	local isOk, value = pcall(chunk)
	if not isOk then
		return nil
	end
	return value
end

-- 编码：<version>|<serialised(data)>
function PD_Encode(version, data)
	assert(type(version) == "number")
	return tostring(version) .. "|" .. tool.serialise(data)
end

-- 解码：返回 version, data；脏数据返回 nil
function PD_Decode(payload)
	if type(payload) ~= "string" or payload == "" then
		return nil
	end
	local sep = sfind(payload, "|", 1, true)
	if not sep then
		return nil
	end
	local version = tonumber(ssub(payload, 1, sep - 1))
	local data = PD_Unpack(ssub(payload, sep + 1))
	if version == nil or data == nil then
		return nil
	end
	return version, data
end

---------------------- 业务键构造（设计 7.7） ----------------------

-- 全服活动数据：play:activity:{<game>}:<activity_id>
function MemKeyAct(game, activityId)
	assert(game and activityId)
	return "play:activity:{" .. game .. "}:" .. activityId
end

-- 玩家玩法档案：play:profile:{<game>}:<activity_id>:<uid>
function MemKeyActProfile(game, activityId, uid)
	assert(game and activityId and uid)
	return "play:profile:{" .. game .. "}:" .. activityId .. ":" .. uid
end

-- 排行榜：play:rank:{<game>}:<period>
function MemKeyRank(game, period)
	assert(game and period)
	return "play:rank:{" .. game .. "}:" .. period
end
