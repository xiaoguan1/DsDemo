----- auto generate file, please do not modify -----
PROTOMAP = {
	["testresponse"] = { desc = "测试响应类型协议", type = "response", id = "1",
		request = "role.C2s_empty",
		response = "role.S2c_role",
	},
	["testpush"] = { desc = "测试推送类型协议", type = "push", id = "2",
		response = "role.S2c_role",
	},
	["testreceive"] = { desc = "测试接收类型协议", type = "notify", id = "3",
		request = "role.C2s_empty",
	},
}