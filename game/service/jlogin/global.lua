-- 仲裁登录服务逻辑（全局唯一，寄生 user 节点或独立 jlogin 节点均可）
-- 1. 账号：查询/创角（accountdb 独立库，手机号唯一对应 uid）
-- 2. uid 发号：util_core.new_uid(cluster_no, skynet.self())，仅本服务可生产
-- 3. 决策：每次登录全量查询所有 user 节点（在线总人数 + 该uid是否在线），不缓存在线数据
--    - uid 在线 -> 复用其所在节点（顶号）
--    - uid 不在线 -> 选在线人数最少的存活节点
-- 4. token：一次性登录凭证（30秒过期），wgate 凭 token 换取 uid
-- 5. Logging[uid]：登录决策期间的占位标记，wgate 绑定完成 login_done 清除
-- 6. PendingKick[uid]：跨节点顶号时记录旧节点，login_done 后踢掉旧连接
-- 7. Gates：wgate 启动自注册（10秒心跳，30秒无心跳剔除），登录时挑选存活网关下发地址

local skynet = require "skynet"
local mysql = require "skynet.db.mysql"

JHANDLE = Import("game/service/jlogin/module/jhandle.lua")
local PROXYSVR = Import("game/global/rpc/proxysvr.lua")
assert(RESPONSE)
assert(ACCEPT)

local table = table
local pairs = pairs
local ipairs = ipairs
local smatch = string.match
local sformat = string.format
local sgsub = string.gsub
local assert = assert
local load = load

-- util_core uid 发号器（C 扩展，进程内静态状态；jlogin 为进程内唯一生产 uid 的服务）
local util_core = require "util.core"
local cluster_no = assert(tonumber(skynet.getenv("cluster_no")))

-- 账号库连接信息（独立账号库 accountdb）
local ACCOUNT_DB = assert(load("return " .. assert(skynet.getenv("accountdb_info"))))()
-- 账号库连接句柄（全局，热更后不重置）
AccountDb = false

-- 集群内 user 节点列表（有序；跨节点调用按此遍历）
local UserNodes = {}
for serverId, cfg in pairs(SERVER_CONFIG) do
	if cfg.nodename == USER_NODE then
		UserNodes[#UserNodes + 1] = serverId
	end
end
assert(#UserNodes > 0, "not find user node")
table.sort(UserNodes)

-- token 登录凭证表：token -> { uid, server_id, expire }
local TokenMap = {}
local TokenSeq = 0

-- uid 登录决策占位（决策开始置 true，wgate 绑定完成 login_done 清除，token 过期兜底清除）
local Logging = {}
-- uid 跨节点顶号记录：uid -> 旧节点 server_id（login_done 时踢旧连接）
local PendingKick = {}

-- wgate 地址注册表：Gates[server_id][gate_name] = { ip, port, clustername, time }
local Gates = {}
local GateRotate = {}

local TokenTimeout = 30	-- token 有效期（秒）
local GateTimeout = 30	-- 网关心跳超时（秒）

-- 惰性连接账号库（阻塞协程）
local function GetAccountDb()
	if AccountDb then
		return AccountDb
	end
	AccountDb = mysql.connect({
		host = ACCOUNT_DB.dbhost,
		port = ACCOUNT_DB.dbport,
		database = ACCOUNT_DB.dbname,
		user = ACCOUNT_DB.dbuser,
		password = ACCOUNT_DB.dbpasswd,
	})
	if not AccountDb then
		_ERROR_F("jlogin connect accountdb(%s:%s) fail", ACCOUNT_DB.dbhost, ACCOUNT_DB.dbport)
	end
	return AccountDb
end

-- 转义 sql 字符串（防注入，demo 级防护）
local function SqlEscape(s)
	return sgsub(s, "'", "''")
end

-- 手机号查 uid（不存在返回 nil）
local function GetUidByPhone(phone)
	local db = GetAccountDb()
	if not db then
		return
	end
	local res = db:query(sformat("select uid from account where phone = '%s';", SqlEscape(phone)))
	if not res or res.badresult or #res <= 0 then
		return
	end
	return res[1].uid
end

-- 创角：new_uid 发号并写账号库；并发冲突（phone 唯一键）时返回已有 uid
local function CreateAccount(phone, serverId)
	local uid = util_core.new_uid(cluster_no, skynet.self())
	local db = GetAccountDb()
	if db then
		db:query(sformat(
			"insert into account(uid, phone, server_id, create_time) values('%s', '%s', %d, %d);",
			SqlEscape(uid), SqlEscape(phone), serverId, os.time()))
	end
	-- 无论插入成败，以库中 phone 对应的 uid 为准（duplicate 时兜底拿到已有 uid）
	return GetUidByPhone(phone) or uid
end

-- 全量查询所有 user 节点：返回 该uid在线节点、最小负载节点（调用失败的节点跳过）
local function QueryAllNodes(uid)
	local online_node, min_node, min_count
	for _, serverId in ipairs(UserNodes) do
		local cn = SERVICE_CLUSTERNAME["agent"][serverId]
		if cn then
			local isOk, count, isOnline = TryCall(PROXYSVR.GetProxy(".AGENT", cn, "lua").call, "query", uid)
			if isOk then
				if isOnline then
					online_node = serverId
				end
				if min_count == nil or count < min_count then
					min_count, min_node = count, serverId
				end
			end
		end
	end
	return online_node, min_node
end

-- 从指定节点的存活网关中轮询挑选一个（无存活返回 nil）
local function PickGate(serverId)
	local gs = Gates[serverId]
	if not gs then
		return
	end
	local now = os.time()
	local alive = {}
	for _, g in pairs(gs) do
		if g.time >= now - GateTimeout then
			alive[#alive + 1] = g
		end
	end
	if #alive <= 0 then
		return
	end
	GateRotate[serverId] = (GateRotate[serverId] or 0) % #alive + 1
	return alive[GateRotate[serverId]]
end

-- 生成一次性登录 token；跨节点顶号时登记待踢旧节点
local function GenToken(uid, serverId, oldServerId)
	TokenSeq = TokenSeq + 1
	local token = sformat("%08x%08x%08x%08x", os.time(), TokenSeq,
		math.random(0, 0xffffffff), math.random(0, 0xffffffff))
	TokenMap[token] = { uid = uid, server_id = serverId, expire = os.time() + TokenTimeout }
	if oldServerId and oldServerId ~= serverId then
		PendingKick[uid] = oldServerId
	end
	return token
end

-- 登录决策主流程：查询在线/负载 -> 选定落点节点 -> 挑网关 -> 发 token -> 回包
local function DoLoginFlow(sid, uid)
	local online_node, min_node = QueryAllNodes(uid)
	if Logging[uid] and not online_node then
		-- 前一次登录尚在决策中且未实际绑定上线：拒绝并发登录
		_INFO_F("jlogin uid:%s logging in progress, reject", uid)
		JHANDLE.ReplyLoginResult(sid, 2)
		return
	end

	local pick_node = online_node or min_node
	if not pick_node then
		_ERROR_F("jlogin uid:%s all user node unavailable", uid)
		JHANDLE.ReplyLoginResult(sid, 3)
		return
	end

	local gate = PickGate(pick_node)
	if not gate then
		_ERROR_F("jlogin uid:%s node:%s no alive gate", uid, pick_node)
		JHANDLE.ReplyLoginResult(sid, 4)
		return
	end

	Logging[uid] = true
	local token = GenToken(uid, pick_node, online_node)
	_INFO_F("jlogin uid:%s -> node:%s gate:%s:%s%s", uid, pick_node, gate.ip, gate.port,
		online_node and " (relogin)" or "")
	JHANDLE.ReplyLoginResult(sid, 0, token, gate.ip, gate.port)
end

-- 客户端登录请求（首包 phone）：有账号走登录流程，无账号询问创角
local function OnClientLogin(sid, phone)
	if not phone or phone == "" then
		JHANDLE.ReplyLoginResult(sid, 5)
		return
	end
	local uid = GetUidByPhone(phone)
	if not uid then
		JHANDLE.MarkCreate(sid)
		JHANDLE.ReplyLoginResult(sid, 1)	-- code=1 需创角确认
		return
	end
	DoLoginFlow(sid, uid)
end

-- 客户端确认创角（phone）：二次查库防并发 -> 选负载最小节点 -> 发号写库 -> 登录流程
local function OnClientCreate(sid, phone)
	local uid = GetUidByPhone(phone)
	if not uid then
		-- 创角前先选节点（写账号库需要落点 server_id）
		_, min_node = QueryAllNodes(nil)
		if not min_node then
			JHANDLE.ReplyLoginResult(sid, 3)
			return
		end
		uid = CreateAccount(phone, min_node)
		if not uid then
			JHANDLE.ReplyLoginResult(sid, 6)
			return
		end
	end
	DoLoginFlow(sid, uid)
end

-- wgate 启动自注册/心跳（幂等刷新）：server_id 为 wgate 所在节点
function ACCEPT.register_gate(server_id, gate_name, clustername, ip, port)
	server_id = tonumber(server_id)
	if not server_id or not gate_name then
		return
	end
	Gates[server_id] = Gates[server_id] or {}
	Gates[server_id][gate_name] = {
		ip = ip,
		port = port,
		clustername = clustername,
		time = os.time(),
	}
end

-- wgate 校验 token（一次性，校验即删）：返回 uid, server_id
function RESPONSE.verify_token(token)
	local info = TokenMap[token]
	if not info then
		return
	end
	TokenMap[token] = nil
	if info.expire < os.time() then
		return
	end
	return info.uid, info.server_id
end

-- wgate 绑定完成后通知：清 Logging；跨节点顶号则踢旧节点连接
function ACCEPT.login_done(uid)
	Logging[uid] = nil
	local oldServerId = PendingKick[uid]
	if not oldServerId then
		return
	end
	PendingKick[uid] = nil
	local cn = SERVICE_CLUSTERNAME["agent"][oldServerId]
	if cn then
		TryCall(PROXYSVR.GetProxy(".AGENT", cn, "lua").send, "kick_uid", uid)
		_INFO_F("jlogin uid:%s relogin, kick old node:%s", uid, oldServerId)
	end
end

-- 当前 user 节点数量（监控/仲裁查询用）
function RESPONSE.user_node_count()
	return #UserNodes
end

function __init__()
	-- uid 发号器初始化（C 静态状态，仅首次有效；jlogin 不在进程内单独重启）
	local ok, err = pcall(util_core.set_checkuid_service, skynet.self())
	if not ok then
		_ERROR_F("jlogin set_checkuid_service fail:%s", tostring(err))
	end
	ok, err = pcall(util_core.set_max_uid_serial, os.time() % (2 ^ 23))
	if not ok then
		_ERROR_F("jlogin set_max_uid_serial fail:%s", tostring(err))
	end

	-- 客户端连接回调
	JHANDLE.SetLoginCb(OnClientLogin, OnClientCreate)

	-- 定时清理：过期 token（含 Logging/PendingKick 兜底）、失联网关
	skynet.fork(function ()
		while true do
			skynet.sleep(60 * 100)
			local now = os.time()
			for token, info in pairs(TokenMap) do
				if info.expire < now then
					TokenMap[token] = nil
					Logging[info.uid] = nil
					PendingKick[info.uid] = nil
				end
			end
			for serverId, gs in pairs(Gates) do
				for gate_name, g in pairs(gs) do
					if g.time < now - GateTimeout then
						gs[gate_name] = nil
						_WARN_F("jlogin gate:%s on node:%s timeout, remove", gate_name, serverId)
					end
				end
			end
		end
	end)
end
