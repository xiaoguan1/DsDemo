-- 节点的宏文件

-- 所有服务的统一定义表（合并原 BASIC_SERVICE_MAP 与 ALL_SERVICE_MAP）
-- named：服务在本节点注册的名字
-- unique：该服务在整个集群中是唯一的（如 jlogin，全集群只有一份）
-- basic：节点基础设施服务，每个节点都必须启动，且不允许跨节点调用
SERVICE_MAP = {
	-- 基础服务设施
	["manage"] = { named = ".MANAGE", basic = true },	-- 节点管理服务
	["protosvr"] = { named = ".PROTOSVR", basic = true },	-- 协议服务，加载协议和更新协议
	["gamelog"] = { named = ".GAMELOG", basic = true },
	["stimer"] = { named = ".STIMER", basic = true },
	["dbserver"] = { named = ".DBSERVER", basic = true },
	["gcluster"] = { named = ".GCLUSTER", basic = true },

	-- example玩法
	["example"] = { named = ".EXAMPLE" },

	["display"] = { named = ".DISPLAY" },

	-- 无状态网关服务（num_env 指定从环境变量读取实例数量，可多实例部署）
	["wgate"] = { named = ".WGATE", num_env = "gateway_num" },

	-- 仲裁登录服务（仲裁玩家登录哪个 user 节点，集群内全局唯一）
	["jlogin"] = { named = ".JLOGIN", unique = true },

	-- 中心服服务
	-- ["..."] = { named = "...." },

	-- 玩家服的服务
	-- ["mail"] = { named = ".MAIL"},
	-- ["ugate"] = { named = ".UGATE"},	-- 登录服务(会代理起到agent服务)
	["agent"] = { named = ".AGENT", num_env = "agent_default_num"},	-- 玩家逻辑服(无状态，多实例，可动态扩缩容)
}

-- 基础服务设施启动顺序，每个节点都必须启动！！！
BASIC_SERVICE_LIST = {
	"manage", 		-- 第一个启动，避免启动失败导致外部无法操作。
	"protosvr",
	"gamelog",
	"stimer",
	"dbserver",
	"gcluster"
}

USER_NODE = "user"		-- 玩家服节点
CROSS_NODE = "cross"	-- 跨服节点
JLOGIN_NODE = "jlogin"	-- 仲裁登录节点（集群内全局唯一的登录服务所在节点）

CLUSTER_NAME_MATCH = "^(%a+)@(%d+)_(%d+)$"	-- 解析集群节点名称
CLUSTER_NAME_FMT = "%s@%s_%s"				-- 集群名称格式

--[[ 启动内容完全依靠以下三张启动顺序表：
	basic ：节点基础设施服务，按 BASIC_SERVICE_LIST 顺序启动
	normal：一般服务，无状态多实例（数量来自 skynet 环境变量，见 start_node.lua）
	adhoc ：相对自由的服务，可根据中心库 server_config 的 is_start_xxx 决定是否启动 ]]

--[[ user节点的启动服务顺序表 ]]
START_USER_SERVICE = {
	nodename = USER_NODE,

	-- 基础服务设施
	basic = BASIC_SERVICE_LIST,

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
	nodename = CROSS_NODE,

	-- 基础服务设施
	basic = BASIC_SERVICE_LIST,

	-- 相对自由的服务，可根据数据库配置决定是否启动
	adhoc = {
		"display",
		"example",
	},

}

--[[ jlogin节点的启动服务顺序表 ]]
START_JLOGIN_SERVICE = {
	nodename = JLOGIN_NODE,

	-- 基础服务设施
	basic = BASIC_SERVICE_LIST,

	-- 相对自由的服务，可根据数据库配置决定是否启动
	adhoc = {
		"jlogin",
	}
}

-- 节点启动顺序表登记：新增节点类型只需定义一张带 nodename 的 START 表并在此登记
START_SERVICE_LIST = {
	START_USER_SERVICE,
	START_CROSS_SERVICE,
	START_JLOGIN_SERVICE,
}

-- 节点列表（由 START_SERVICE_LIST 派生）
NODE_LIST = {}
for _, st in ipairs(START_SERVICE_LIST) do
	NODE_LIST[#NODE_LIST + 1] = st.nodename
end

-- 记录各个节点的自由服务信息（由 START_SERVICE_LIST 派生，仅供查询，禁止写运行时字段）
ADHOC_SERVICE_MAP = {}

-- 记录各个节点的一般服务信息（由 START_SERVICE_LIST 派生，仅供查询，禁止写运行时字段）
NORMAL_SERVICE_MAP = {}

-- 按节点生成服务映射表规则
local function genSvrMapRule(mtbl, nodename, serviceList)
	assert(not mtbl[nodename])
	mtbl[nodename] = {}
	for _, svrname in pairs(serviceList or {}) do
		assert(not mtbl[nodename][svrname])
		mtbl[nodename][svrname] = assert(SERVICE_MAP[svrname])
	end
end
for _, st in ipairs(START_SERVICE_LIST) do
	genSvrMapRule(ADHOC_SERVICE_MAP, st.nodename, st.adhoc)
	genSvrMapRule(NORMAL_SERVICE_MAP, st.nodename, st.normal)
end

---- 定义自检：加载本文件时即执行，配置错误直接暴露 ----

-- 自检1：BASIC_SERVICE_LIST 与 SERVICE_MAP 中 basic 标记的集合完全一致
local basicCount = 0
for _, svrname in ipairs(BASIC_SERVICE_LIST) do
	assert(SERVICE_MAP[svrname] and SERVICE_MAP[svrname].basic,
		string.format("basic service[%s] not mark basic in SERVICE_MAP", svrname))
end
for _, svrData in pairs(SERVICE_MAP) do
	if svrData.basic then
		basicCount = basicCount + 1
	end
end
assert(basicCount == #BASIC_SERVICE_LIST,
	"SERVICE_MAP basic service count != BASIC_SERVICE_LIST length")

-- 自检2：named 非空且全局唯一
local namedSet = {}
for svrname, svrData in pairs(SERVICE_MAP) do
	assert(type(svrData.named) == "string" and svrData.named ~= "",
		string.format("service[%s] named invalid", svrname))
	assert(not namedSet[svrData.named],
		string.format("service named[%s] duplicate! please check SERVICE_MAP", svrData.named))
	namedSet[svrData.named] = true
end

-- 自检3：启动清单（normal/adhoc）引用的服务必须已在 SERVICE_MAP 定义，且 nodename 有效
for _, st in ipairs(START_SERVICE_LIST) do
	assert(st.nodename, "START service table nodename invalid")
	for _, listname in ipairs({"normal", "adhoc"}) do
		for _, svrname in ipairs(st[listname] or {}) do
			assert(SERVICE_MAP[svrname],
				string.format("start list service[%s] not define in SERVICE_MAP", svrname))
		end
	end
end
