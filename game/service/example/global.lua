-- 服务内逻辑装载：只做模块 Import 与挂载，业务逻辑写在 module/ 下

-- 注册 rpc 分发（跨节点调用的入口，misc.lua 会注册 "rpc" 协议）
Import("game/global/rpc/proxysvr.lua")

-- 模块表即服务内共享逻辑；跨节点调用：rpc.mod_call.example[serverId].EXAMPLE.Ping(...)
EXAMPLE = Import("game/service/example/module/example.lua")

-- 本节点内的 lua 协议入口（skynet.call 走 RESPONSE）
function RESPONSE.ping(tag)
	return EXAMPLE.Ping(tag)
end
