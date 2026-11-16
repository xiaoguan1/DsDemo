-- 前后端协议编号定义（无缝世界 M1）
-- 帧格式：消息总长度(2B) | 协议编号(2B) | 协议内容 —— 大端，websocket binary

local proto = {}

-- 上行 C2S
proto.C2S_ENTER = 10001	-- C->S 进入世界（payload = uid 文本，可为空串由服务端分配）
proto.C2S_MOVE = 10002	-- C->S 移动上报

-- 下行 S2C
proto.S2C_ENTER_RESULT = 20001	-- S->C 进入世界结果（payload = "0:uid:x:y" 文本；错误码非 0 时 = "err:msg"）
proto.S2C_ENTITY_ENTER = 20002	-- S->C 实体进入视野（payload = >I4ff uid,x,y）
proto.S2C_ENTITY_LEAVE = 20003	-- S->C 实体离开视野（payload = >I4 uid）
proto.S2C_ENTITY_MOVE = 20004	-- S->C 实体移动（payload = >I4ffffI4 uid,x,y,vx,vy,t）

return proto
