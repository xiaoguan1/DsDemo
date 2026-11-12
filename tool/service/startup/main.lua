-- user 节点启动入口：公共启动逻辑见 start_node.lua
dofile "tool/service/startup/start_node.lua"

StartNode(START_USER_SERVICE)
