-- 玩家上行协议处理表：模块字段名 = 协议名，值为 function(uid, req) -> response 数据
-- 新增协议处理：按协议名定义同名函数即可（与 protocol/protomap.lua 的协议名一致）
-- notify 类型协议无回包，处理函数返回 nil；response 类型返回的 table 会被编码回客户端
-- push 类型协议是服务端主动下发，不走这里（主动下发用全局 PushProto）

-- response 协议：客户端上行 role.C2s_empty，服务端回 role.S2c_role
function testresponse(uid, req)
	_INFO_F("agent handle testresponse, uid:%s", uid)

	-- 演示服务端主动推送（push 协议只定义 response）
	PushProto(uid, "testpush", { uid = uid, aaa = "push_from_server" })

	-- role.S2c_role 必填字段：uid、aaa
	return { uid = uid, sex = 0, account = "demo", aaa = "hello_client" }
end

-- notify 协议：只上行不回包
function testreceive(uid, req)
	_INFO_F("agent handle testreceive, uid:%s", uid)
end

function __update__()
	print("qqqqqqqqq  2333 222")
end