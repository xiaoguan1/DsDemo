-- 协议表封装（每个服务各加载一份：协议表 + 反向索引 + protobuf 编解码）
-- 数据来源：protocol/protomap.lua（由 protocol/gen_proto.lua 自动生成，禁止手改）
-- 热更：本模块被 Update 时会重新 dofile protomap.lua 并重建反向索引
local protobuf = require "protobuf"

-- 重新加载协议表（写入当前服务的全局环境），保证热更后拿到的是最新内容
dofile("protocol/protomap.lua")
local PROTOMAP = assert(_G.PROTOMAP, "protocol/protomap.lua PROTOMAP nil")

-- 协议编号 -> 协议名（上行按帧头 proto_id 分发用）
local ID2PROTO = {}
for name, body in pairs(PROTOMAP) do
	ID2PROTO[body.id] = name
end

-- 按协议编号查协议名（查不到返回 nil）
function NameById(proto_id)
	return ID2PROTO[proto_id]
end

-- 按协议名查协议定义 { desc, type, id, request, response }
function Body(name)
	return PROTOMAP[name]
end

-- 按协议名查协议编号
function Id(name)
	local body = PROTOMAP[name]
	return body and body.id
end

-- 解码上行 request（协议没有 request 或 payload 为空时返回空表）
function DecodeRequest(name, payload)
	local body = PROTOMAP[name]
	if not body or not body.request then
		return
	end
	if not payload or payload == "" then
		return {}
	end
	local data, err = protobuf.decode(body.request, payload)
	if not data then
		return nil, err
	end
	return data
end

-- 编码下行 response
function EncodeResponse(name, data)
	local body = PROTOMAP[name]
	if not body or not body.response then
		return
	end
	local isOk, out = pcall(protobuf.encode, body.response, data or {})
	if not isOk then
		return nil, out
	end
	return out
end
