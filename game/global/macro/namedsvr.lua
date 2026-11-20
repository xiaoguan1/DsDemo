-- 节点的宏文件

-- 每个节点的基础服务
BASIC_SERVICE_MAP = {
	["protosvr"] = {named = ".PROTOSVR"},		-- 协议服务，加载协议和更新协议
	["gamelog"] = {named = ".GAMELOG"},
	["stimer"] = {named = ".STIMER"},
	["dbserver"] = {named = ".DBSERVER"},
	["gcluster"] = {named = ".GCLUSTER"},
	["manage"] = {named = ".MANAGE"},
}

USER_NODE = "user"		-- 玩家服节点
CROSS_NODE = "cross"	-- 跨服节点

NODE_LIST = { USER_NODE, CROSS_NODE, }

-- 相对自由，可以在cross服启动，也可以在user节点启动。只要是中心服数据库设置了。
-- host_node：宿主节点限制。以example服务为例，允许启动该服务的节点只能是 cross
-- unique为true，则表示该服务在整个集群中是唯一的
-- node 其目的是为了在rpc.lua可以方便地根据服务名称获取网络地址
ALL_SERVICE_MAP = {
	-- example玩法
	["example"] = { named = ".EXAMPLE" },


	["display"] = { named = ".DISPLAY" },

	-- 无状态网关服务（可按 gateway_num 多实例部署）
	["wgate"] = { named = ".WGATE" },

	-- 仲裁登录服务（仲裁玩家登录那个user节点）
	["jlogin"] = { named = ".JLOGIN" },

	-- 中心服服务
	-- ["..."] = { named = "...." },

	-- 玩家服的服务
	-- ["mail"] = { named = ".MAIL"},
	-- ["ugate"] = { named = ".UGATE"},	-- 登录服务(会代理起到agent服务)
	["agent"] = { named = ".AGENT"},	-- 玩家逻辑服(无状态，多实例，可动态扩缩容)
}

CLUSTER_NAME_MATCH = "^(%a+)@(%d+)_(%d+)$"	-- 解析集群节点名称
CLUSTER_NAME_FMT = "%s@%s_%s"				-- 集群名称格式

--[[ user节点的启动服务顺序表 ]]
START_USER_SERVICE = {
	-- 基础服务设施
	unique = {
		"manage", 		-- 第一个启动，避免启动失败导致外部无法操作。
		"protosvr",
		"gamelog",
		"stimer",
		"dbserver",
		"gcluster"
	},

	-- 一般服务
	normal = {
		"display",
		"wgate",
		"agent",
	},

	-- 相对自由的服务，可根据数据库配置决定是否启动
	adhoc = {
		"jlogin",
	}
}

--[[ cross节点的启动服务顺序表 ]]
START_CROSS_SERVICE = {
	-- 基础服务设施
	unique = {
		"manage", 		-- 第一个启动，避免启动失败导致外部无法操作。
		"protosvr",
		"gamelog",
		"stimer",
		"dbserver",
		"gcluster"
	},

	-- -- 一般服务
	-- normal = {
	-- 	"....",
	-- },

	-- 相对自由的服务，可根据数据库配置决定是否启动
	adhoc = {
		"display",
		"example",
	},

}

-- 记录各个节点的自由服务信息
ADHOC_SERVICE_MAP = {}

-- 记录各个节点的一般服务信息
NORMAL_SERVICE_MAP = {}

-- 按节点生成服务映射表规则
local function genSvrMapRule(mtbl, nodename, serviceList)
	assert(not mtbl[nodename])
	mtbl[nodename] = {}
	for _, svrname in pairs(serviceList or {}) do
		assert(not mtbl[nodename][svrname])
		mtbl[nodename][svrname] = assert(ALL_SERVICE_MAP[svrname])
	end
end
genSvrMapRule(ADHOC_SERVICE_MAP, USER_NODE, START_USER_SERVICE.adhoc)
genSvrMapRule(ADHOC_SERVICE_MAP, CROSS_NODE, START_CROSS_SERVICE.adhoc)

genSvrMapRule(NORMAL_SERVICE_MAP, USER_NODE, START_USER_SERVICE.normal)
genSvrMapRule(NORMAL_SERVICE_MAP, CROSS_NODE, START_CROSS_SERVICE.normal)

-- print("ADHOC_SERVICE_MAP ", tool.dumptree(ADHOC_SERVICE_MAP))
-- print("ADHOC_SERVICE_MAP ", tool.dumptree(NORMAL_SERVICE_MAP))
