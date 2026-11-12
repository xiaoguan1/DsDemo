-- jlogin 节点启动入口：公共启动逻辑见 start_node.lua
-- 注意：脚本名必须是 jlogin_node（而非 jlogin），避免与 game/service/jlogin/jlogin.lua 服务名冲突
dofile "tool/service/startup/start_node.lua"

StartNode(START_JLOGIN_SERVICE)
