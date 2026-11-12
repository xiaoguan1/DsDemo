local skynet = require "skynet"
require "skynet.manager"

-- wget -q -O - "http://127.0.0.1:40001/closesvc"
function Handle_Request(data)
	_INFO_F("close service succeed!")
	skynet.abort()
end
