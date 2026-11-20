-- 前后端的协议制定
RPROTOMAP = {
	["testresponse"] = { desc = "测试响应类型协议",
		request = "role.C2s_empty",
		response = "role.S2c_role",
	},
	["testreceive"] = { desc = "测试接收类型协议",
		request = "role.C2s_empty",
	},
	["testpush"] = { desc = "测试推送类型协议",
		response = "role.S2c_role",
	},
}