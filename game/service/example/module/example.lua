-- 玩法服务骨架模块
-- 无状态：函数只依赖入参与只读配置，不读写本模块的跨请求数据
-- 跨节点调用：rpc.mod_call.example[serverId].EXAMPLE.Ping("tag")

local skynet = require "skynet"
local sformat = string.format

-- 返回本实例身份，用于验证"任意实例可处理同一请求"（无状态寻址）
function Ping(tag)
	return sformat("[EXAMPLE] recv:%s self=%s@%s cluster:%s",
		tostring(tag), HOST_ENV.nodename, skynet.getenv("server_id"), SELF_CLUSTERNAME)
end
