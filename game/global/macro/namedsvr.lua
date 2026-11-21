-- 节点的宏文件

-- 全局服务登记表
-- unique = true：基础服务，按节点名在代码内固定（见各节点启动表的 unique 段），不走数据库驱动
-- 其余为一般服务：某节点是否启动由中心库 server_config 的 is_start_<服务名> 列决定，
-- 实例数取 default_cnt（缺省 1）
ALL_SERVICE_MAP = {
	["protosvr"] = {named = ".PROTOSVR", unique = true},		-- 协议服务，加载协议和更新协议
	["gamelog"] = {named = ".GAMELOG", unique = true},
	["stimer"] = {named = ".STIMER", unique = true},
	["dbserver"] = {named = ".DBSERVER", unique = true},
	["gcluster"] = {named = ".GCLUSTER", unique = true},
	["manage"] = {named = ".MANAGE", unique = true},
	["memserver"] = {named = ".MEMSERVER", unique = true},		-- Redis 接入（玩法状态、实例注册表、排行榜等）
	["wgate"] = {named = ".WGATE", default_cnt = 8},			-- 网关多实例：1 为登录网关，登录后按连接数分流
	["agent"] = {named = ".AGENT", default_cnt = 8},
	["example"] = {named = ".EXAMPLE"},							-- 玩法服务骨架（模板），可删除
}

-- 节点名即是节点类型，取值固定；多个 play 进程共用节点名 play，
-- 进程由 cluster_no + node_name + server_id 共同区分
USER_NODE = "user"		-- 玩家服节点
PLAY_NODE = "play"		-- 玩法节点（无状态玩法实例池，N节点×1实例弹性扩容）

NODE_LIST = { USER_NODE, PLAY_NODE, }

CLUSTER_NAME_MATCH = "^(%w+)@(%d+)_(%d+)$"	-- 解析集群节点名称
CLUSTER_NAME_FMT = "%s@%s_%s"				-- 集群名称格式

--[[ user节点的启动服务顺序表 ]]
-- 基础服务（unique段）按节点名在代码内固定；normal 为一般服务白名单，
-- 一般服务：按节点启动表 normal 段在代码内固定，实例数取 ALL_SERVICE_MAP.default_cnt
START_USER_SERVICE = {
	-- 基础服务设施
	unique = {
		"manage", 		-- 第一个启动，避免启动失败导致外部无法操作。
		"protosvr",
		"gamelog",
		"stimer",
		"dbserver",
		"memserver",
		"gcluster"
	},

	-- 一般服务白名单（是否启动由 is_start_<服务名> 列决定，实例数取 default_cnt）
	normal = {
		"wgate",
		"agent",
	},
}

--[[ play节点的启动服务顺序表 ]]
-- 与user的差异：无dbserver（玩法不直接读写MySQL，玩家数据经agent、玩法数据走memserver）；新增memserver
START_PLAY_SERVICE = {
	-- 基础服务设施
	unique = {
		"manage", 		-- 第一个启动，避免启动失败导致外部无法操作。
		"protosvr",
		"gamelog",
		"stimer",
		"gcluster",
		"memserver",		-- 玩法状态与实例注册表的存储，必须先于玩法实例就绪
	},

	-- 一般服务白名单（是否启动由 is_start_<服务名> 列决定，实例数取 default_cnt）
	-- 接入新玩法时在此登记服务名
	normal = {
	},

	-- 相对自由的服务，可根据数据库配置决定是否启动（is_start_<服务名> 列开关）
	adhoc = {
		"example",
	},
}

-- 节点名（即节点类型） -> 启动服务顺序表
NODE_START_SERVICE = {
	[USER_NODE] = START_USER_SERVICE,
	[PLAY_NODE] = START_PLAY_SERVICE,
}

-- 记录各个节点的自由服务信息
ADHOC_SERVICE_MAP = {}

-- 按节点名生成服务映射表规则
local function genSvrMapRule(mtbl, nodeName, serviceList)
	assert(not mtbl[nodeName])
	mtbl[nodeName] = {}
	for _, svrname in pairs(serviceList or {}) do
		assert(not mtbl[nodeName][svrname])
		mtbl[nodeName][svrname] = assert(ALL_SERVICE_MAP[svrname])
	end
end
genSvrMapRule(ADHOC_SERVICE_MAP, USER_NODE, START_USER_SERVICE.adhoc)
genSvrMapRule(ADHOC_SERVICE_MAP, PLAY_NODE, START_PLAY_SERVICE.adhoc)

-- print("ADHOC_SERVICE_MAP ", tool.dumptree(ADHOC_SERVICE_MAP))
