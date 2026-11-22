-- 服务内逻辑装载：只做模块 Import 与挂载，业务逻辑写在 module/ 下

-- 注册 rpc 分发（跨节点调用的入口，misc.lua 会注册 "rpc" 协议）
Import("game/global/rpc/proxysvr.lua")

-- 模块表即服务内共享逻辑；跨节点调用：rpc.mod_call.example[serverId].EXAMPLE.Ping(...)
EXAMPLE = Import("game/service/example/module/example.lua")

-- 服务启动即装载静态配置（第一类数据：只读缓存 + 版本管理）
EXAMPLE.InitConfig(1)

-- 本节点内的 lua 协议入口（skynet.call 走 RESPONSE）
function RESPONSE.ping(tag)
	return EXAMPLE.Ping(tag)
end

-- 静态配置：返回 config, version
function RESPONSE.cfg()
	return EXAMPLE.GetConfig()
end

-- 全服活动数据
function RESPONSE.actget(activityId)
	return EXAMPLE.GetActivity(activityId)
end

-- 完成任务加分：活动积分 + 玩家档案 + 排行榜（普通玩法数据）
function RESPONSE.addscore(uid, activityId, score)
	return EXAMPLE.AddScore(uid, activityId, score)
end

-- 玩家玩法档案
function RESPONSE.profile(uid, activityId)
	return EXAMPLE.GetProfile(uid, activityId)
end

-- 排行榜前 N
function RESPONSE.rank(activityId, n)
	return EXAMPLE.GetRankTop(activityId, n)
end

-- 持久化积压监控
function RESPONSE.persistinfo()
	return EXAMPLE.GetPersistInfo()
end

-- 清空持久化队列（仅调试用）
function RESPONSE.persistclear()
	return EXAMPLE.ClearPersist()
end

-- 一键演示：配置 → 活动 → 加分 → 排行榜 → 持久化队列
function RESPONSE.demo(uid, activityId)
	return EXAMPLE.Demo(uid, activityId)
end
