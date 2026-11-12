local util = require "util.core"
local type = type
local string = string
local sformat = string.format

-- 反向解析util.new_uid函数，获得serverId
local BITCHARS = {
	'0','1','2','3','4','5','6','7','8','9',
	'a','b','c','d','e','f','g','h','i','j',
	'k','l','m','n','o','p','q','r','s','t',
	'u','v',
}
local CHAR_2_NUM = {}
for k, v in ipairs(BITCHARS) do
	CHAR_2_NUM[v] = k - 1
end
function GetServerId_ByUid(uid)
	local serverId = 0
	for i = 7, 12 do
		local no = CHAR_2_NUM[string.sub(uid, i, i)]
		if i == 7 then
			serverId = no & (0x7)
		elseif i == 12 then
			serverId = (serverId << 2) + (no >> 3)
		else
			serverId = (serverId << 5) + no
		end
	end
	return serverId
end

-- 校验邮件附件
function CheckResList(list)
	if type(list) ~= "table" then
		return false
	end
	for _, v in pairs(list) do
		local t = type(v)
		if t == "table" then
			if not CheckResList(v) then
				return false
			end
		elseif t ~= "number" or v <= 0 then
			return false
		end
	end
	return true
end

-- 校验Http地址
function CheckHttpAddr(address)
	if not address or address == "" then
		return false, "url"
	end
	local proto, host = address:match "^(%a+)://([^:]+):?%d*$"
	if not proto or not host then
		return false, "no proto or host"
	end
	proto = proto:lower()
	if proto ~= "http" and proto ~= "https" then
		return false, "invalid proto"
	end
	return true
end

function HashNo(uniqueKey, hashNum)
	if type(uniqueKey) == "number" then
		local no = uniqueKey % hashNum
		return no > 0 and no or hashNum
	elseif type(uniqueKey) == "string" then
		return util.strhash(uniqueKey, hashNum)
	else
		error(sformat("uniqueKey:%s hashNum:%s", uniqueKey, hashNum))
	end
end