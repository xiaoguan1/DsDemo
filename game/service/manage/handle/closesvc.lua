local skynet = require "skynet"
require "skynet.manager"

-- 关服前通知所有 agent 同步落库（动态实例编号无上限，按扫描窗口查找在线实例）
local AGENT_SCAN_MAX = 64
local function _SaveAllAgents()
	local svrData = ALL_SERVICE_MAP.agent
	if not svrData then
		return
	end
	local baseName = svrData.named	-- .AGENT
	for i = 1, AGENT_SCAN_MAX do
		local svrName = (i == 1) and baseName or (baseName .. i)
		local addr = skynet.localname(svrName)
		if addr then
			local isOk, err = pcall(skynet.call, addr, "lua", "shutdown_save")
			if not isOk then
				_ERROR_F("shutdown_save agent:%s fail:%s", svrName, tostring(err))
			end
		end
	end
end

-- wget -q -O - "http://127.0.0.1:40001/closesvc"
function Handle_Request(data)
	_SaveAllAgents()
	_INFO_F("close service succeed!")
	skynet.abort()
end
