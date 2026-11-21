--------------------
-- 网关登录模块
-- 职责（仅登录网关 .WGATE 处理未绑定连接的首包）：
--   1. 出生校验：按手机号查中心库账号表，校验账号状态与出生服务器
--   2. 创角确认：账号不存在时通知客户端确认，同意则生成 uid 并落库，拒绝则断开
--   3. 重登限流：同一手机号 60 秒内累计 20 次登录请求直接封号
--   4. 顶号：节点在线表 uid -> 会话，新登录踢掉旧连接（epoch 防止旧连接误清在线表）
--   5. socket 移交：登录通过后把连接移交给本节点最空闲的 .WGATE/.WGATE2... 实例，
--      由目标网关选最闲 agent、绑定、回登录成功包
-- 说明：ONLINE/LOGIN_ATTEMPTS 为模块 local 状态，热更会丢失，改动后需重启节点
--------------------

local skynet = require "skynet"
local util = require "util.core"
local PROXYSVR = Import("game/global/rpc/proxysvr.lua")
local PROTO = Import("game/global/proto.lua")

-- 中心库账号表由所有 dbcell 共同承载，经 dbserver 的 db 协议按 uid/phone 哈希路由
local DBSERVER = PROXYSVR.GetProxyByServiceName("dbserver", "db")

local sformat = string.format
local tonumber = tonumber
local type = type
local ostime = os.time
local SERVER_ID = assert(tonumber(skynet.getenv("server_id")))
local GATE_COUNT = ALL_SERVICE_MAP.wgate.default_cnt or 1
local AGENT_COUNT = ALL_SERVICE_MAP.agent.default_cnt or 1
local AGENT_MAX_PLAYER = assert(tonumber(skynet.getenv("agent_max_player")))

-- 账号状态（与中心库 account.status 对应）
local STATUS_BANNED = 1

-- 登录返回码（与 protocol/protos/account.proto 注释一致）
local CODE = {
	OK = 0,
	NEED_CREATE = 1,
	BANNED = 2,
	WRONG_NODE = 3,
	TOO_FREQUENT = 4,
	SERVER_FULL = 5,
	CANCELED = 6,
	SYSTEM_ERROR = 7,
	INVALID_PARAM = 8,
}

-- 重登限流：同一手机号 60 秒内累计 20 次登录请求即封号
local LOGIN_LIMIT_COUNT = 20
local LOGIN_LIMIT_WINDOW = 60

-- 节点在线表：uid -> {uid, phone, epoch, gate_name, agent_name, agent_cn, login_time, status}
local ONLINE = {}
-- 登录请求计数：phone -> {count, start}
local LOGIN_ATTEMPTS = {}
-- 登录所有权纪元：每次登录自增，用于淘汰旧会话/在途会话
local EPOCH = 0

local function _NewEpoch()
	EPOCH = EPOCH + 1
	return EPOCH
end

local function _GateName(index)
	return index == 1 and ".WGATE" or (".WGATE" .. index)
end

local function _AgentName(index)
	return index == 1 and ".AGENT" or (".AGENT" .. index)
end

-- 手机号：可带一个前导 +，5~20 位数字
local function _ValidPhone(phone)
	return type(phone) == "string" and #phone >= 5 and #phone <= 20 and phone:match("^%+?%d+$") ~= nil
end

local function _Reply(id, protoName, data)
	local isOk, err = WHANDLE.PushFrame(id, protoName, data)
	if not isOk then
		_WARN_F("login reply fail, sid:%s proto:%s err:%s", tostring(id), protoName, tostring(err))
	end
end

-- 账号库操作统一走 dbserver：命令名后的第一个参数是哈希路由 key
local function _DbCall(cmd, ...)
	return TryCall(DBSERVER.call[cmd], ...)
end

-- 踢掉旧会话：已绑定的连接踢下线；在途移交的会话靠 epoch 校验淘汰
local function _KickOldSession(uid)
	local old = ONLINE[uid]
	if not old then
		return
	end
	if old.gate_name == WHANDLE.GateName then
		WHANDLE.Kick(uid)
	elseif old.gate_name then
		local isOk, err = pcall(skynet.send, old.gate_name, "lua", "kick", uid)
		if not isOk then
			_WARN_F("kick old session fail, uid:%s gate:%s err:%s",
				tostring(uid), tostring(old.gate_name), tostring(err))
		end
	end
end

-- 封号：更新中心库账号状态并踢掉可能仍在线的会话
local function _BanAccount(phone)
	local isOk, account = _DbCall("getaccount", phone)
	if not isOk or not account then
		return false
	end
	local banOk, result = _DbCall("setaccountstatus", phone, STATUS_BANNED)
	if not banOk or not result then
		_ERROR_F("ban account fail, phone:%s", phone)
		return false
	end
	_INFO_F("account banned, phone:%s uid:%s", phone, tostring(account.uid))
	_KickOldSession(account.uid)
	return true
end

-- 重登计数：窗口内累计达到阈值返回 false
local function _CheckLoginRate(phone)
	local now = ostime()
	local rec = LOGIN_ATTEMPTS[phone]
	if not rec or (now - rec.start) >= LOGIN_LIMIT_WINDOW then
		rec = { count = 0, start = now }
		LOGIN_ATTEMPTS[phone] = rec
	end
	rec.count = rec.count + 1
	if rec.count >= LOGIN_LIMIT_COUNT then
		LOGIN_ATTEMPTS[phone] = nil
		return false
	end
	return true
end

-- 选本节点连接数最少的网关实例（查询失败则忽略该实例，全部失败时退回登录网关自身）
local function _PickLeastGate()
	local bestName, bestCount = WHANDLE.GateName, nil
	for i = 1, GATE_COUNT do
		local gateName = _GateName(i)
		local isOk, count = pcall(skynet.call, gateName, "lua", "gate_count")
		if isOk and type(count) == "number" then
			if not bestCount or count < bestCount then
				bestName, bestCount = gateName, count
			end
		end
	end
	return bestName
end

-- 选本节点最闲且未满的 agent 实例
local function _PickLeastAgent()
	local bestName, bestCount = nil, nil
	for i = 1, AGENT_COUNT do
		local agentName = _AgentName(i)
		local proxy = PROXYSVR.GetProxy(agentName, SELF_CLUSTERNAME, "lua")
		local isOk, count = pcall(proxy.call.player_count)
		if isOk and type(count) == "number" and count < AGENT_MAX_PLAYER then
			if not bestCount or count < bestCount then
				bestName, bestCount = agentName, count
			end
		end
	end
	if not bestName then
		return
	end
	return bestName, SELF_CLUSTERNAME
end

-- 登录网关内部指令：claim/offline 需要访问节点在线表，统一在 .WGATE 执行
local LOGIN_COMMAND = {}

function LOGIN_COMMAND.claim(uid, epoch, gateName, agentName, agentCn)
	local info = ONLINE[uid]
	if not info or info.epoch ~= epoch then
		return false
	end
	info.gate_name = gateName
	info.agent_name = agentName
	info.agent_cn = agentCn
	info.status = "online"
	return true
end

function LOGIN_COMMAND.offline(uid, epoch)
	local info = ONLINE[uid]
	if info and info.epoch == epoch then
		ONLINE[uid] = nil
		_INFO_F("player offline, uid:%s gate:%s", tostring(uid), tostring(info.gate_name))
	end
	return true
end

local function _CallLoginGate(cmd, ...)
	if WHANDLE.IsLoginGate then
		return LOGIN_COMMAND[cmd](...)
	end
	return skynet.call(".WGATE", "lua", cmd, ...)
end

-- 登录落地：选 agent -> 认领 epoch -> 绑定 agent/网关 -> 回登录成功包
local function _CompleteLogin(id, ctx)
	local agentName, agentCn = _PickLeastAgent()
	if not agentName then
		_WARN_F("login fail, no idle agent, uid:%s gate:%s", tostring(ctx.uid), WHANDLE.GateName)
		_Reply(id, ctx.reply_proto, { code = CODE.SERVER_FULL })
		pcall(_CallLoginGate, "offline", ctx.uid, ctx.epoch)
		WHANDLE.Close(id, 4000, "no idle agent")
		return
	end

	-- 认领失败说明期间已有更新的登录顶替，本连接直接放弃
	local isOk, claimed = pcall(_CallLoginGate, "claim", ctx.uid, ctx.epoch, WHANDLE.GateName, agentName, agentCn)
	if not isOk or not claimed then
		_WARN_F("login superseded, uid:%s epoch:%s gate:%s",
			tostring(ctx.uid), tostring(ctx.epoch), WHANDLE.GateName)
		WHANDLE.Close(id, 4000, "login superseded")
		return
	end

	-- 先占住 agent 的玩家表，再绑定网关索引，最后回包
	local bindOk, sendRet = pcall(PROXYSVR.GetProxy(agentName, agentCn, "client").send.bind,
		ctx.uid, WHANDLE.GateName, WHANDLE.GateClusterName, ctx.epoch)
	if not bindOk or sendRet == false then
		_ERROR_F("bind agent fail, uid:%s agent:%s err:%s",
			tostring(ctx.uid), tostring(agentName), tostring(sendRet))
		pcall(_CallLoginGate, "offline", ctx.uid, ctx.epoch)
		WHANDLE.Close(id, 4000, "bind agent fail")
		return
	end

	-- 网关侧索引绑定失败（连接已消失）：回收 agent 绑定与在线表
	local bindGateOk = WHANDLE.Bind(id, ctx.uid, agentName, agentCn, ctx.epoch)
	if not bindGateOk then
		_WARN_F("bind gate fail, sid:%s uid:%s", tostring(id), tostring(ctx.uid))
		pcall(PROXYSVR.GetProxy(agentName, agentCn, "client").send.unbind, ctx.uid, ctx.epoch)
		pcall(_CallLoginGate, "offline", ctx.uid, ctx.epoch)
		return
	end
	_Reply(id, ctx.reply_proto, { code = CODE.OK, uid = ctx.uid, server_id = SERVER_ID })
	_INFO_F("login ok, uid:%s phone:%s gate:%s agent:%s", tostring(ctx.uid), tostring(ctx.phone),
		WHANDLE.GateName, agentName)
end

-- 出生校验通过后进入登录：顶号 -> 登记在线表 -> 移交或本地落地
local function _LoginWithAccount(id, account, replyProto)
	if tonumber(account.status) == STATUS_BANNED then
		_Reply(id, replyProto, { code = CODE.BANNED })
		WHANDLE.Close(id, 4000, "account banned")
		return
	end

	local birthServerId = tonumber(account.server_id)
	if birthServerId ~= SERVER_ID then
		local nodeConfig = birthServerId and SERVER_CONFIG[birthServerId]
		_Reply(id, replyProto, {
			code = CODE.WRONG_NODE,
			uid = account.uid,
			server_id = birthServerId or 0,
			node_addr = nodeConfig and nodeConfig.ipport or "",
		})
		WHANDLE.Close(id, 4000, "wrong birth server")
		return
	end

	local epoch = _NewEpoch()
	local targetGate = _PickLeastGate()
	_KickOldSession(account.uid)
	ONLINE[account.uid] = {
		uid = account.uid,
		phone = account.phone,
		epoch = epoch,
		gate_name = targetGate,
		login_time = ostime(),
		status = "pending",
	}

	local ctx = { uid = account.uid, phone = account.phone, epoch = epoch, reply_proto = replyProto }
	if targetGate == WHANDLE.GateName then
		_CompleteLogin(id, ctx)
		return
	end

	local isOk, err = WHANDLE.Transfer(id, targetGate, ctx)
	if not isOk then
		local info = ONLINE[account.uid]
		if info and info.epoch == epoch then
			ONLINE[account.uid] = nil
		end
		_ERROR_F("handoff fail, uid:%s target:%s err:%s",
			tostring(account.uid), tostring(targetGate), tostring(err))
		_Reply(id, replyProto, { code = CODE.SYSTEM_ERROR })
		WHANDLE.Close(id, 4000, "handoff fail")
	end
end

local function _OnAccountLogin(id, payload)
	local req, err = PROTO.DecodeRequest("account_login", payload)
	if not req or not _ValidPhone(req.phone) then
		_WARN_F("login invalid param, sid:%s err:%s", tostring(id), tostring(err))
		_Reply(id, "account_login", { code = CODE.INVALID_PARAM })
		WHANDLE.Close(id, 4000, "invalid login param")
		return
	end
	local phone = req.phone

	if not _CheckLoginRate(phone) then
		local isBanned = _BanAccount(phone)
		_INFO_F("login too frequent, phone:%s banned:%s", phone, tostring(isBanned))
		_Reply(id, "account_login", { code = isBanned and CODE.BANNED or CODE.TOO_FREQUENT })
		WHANDLE.Close(id, 4000, "login too frequent")
		return
	end

	local isOk, account, dbErr = _DbCall("getaccount", phone)
	if not isOk or dbErr then
		_ERROR_F("query account fail, phone:%s err:%s", phone, tostring(account))
		_Reply(id, "account_login", { code = CODE.SYSTEM_ERROR })
		WHANDLE.Close(id, 4000, "db error")
		return
	end
	if not account then
		-- 账号不存在：通知客户端确认是否创角，连接保持
		_Reply(id, "account_login", { code = CODE.NEED_CREATE })
		return
	end
	_LoginWithAccount(id, account, "account_login")
end

local function _OnAccountCreate(id, payload)
	local req, err = PROTO.DecodeRequest("account_create", payload)
	if not req or not _ValidPhone(req.phone) then
		_WARN_F("create invalid param, sid:%s err:%s", tostring(id), tostring(err))
		_Reply(id, "account_create", { code = CODE.INVALID_PARAM })
		WHANDLE.Close(id, 4000, "invalid create param")
		return
	end
	local phone = req.phone

	if not req.agree then
		_Reply(id, "account_create", { code = CODE.CANCELED })
		WHANDLE.Close(id, 4000, "create canceled")
		return
	end

	-- 玩家 uid 由登录网关生成（C 层绑定见 InitUid，只有 .WGATE 会初始化）
	local uidOk, newUid = pcall(util.new_uid, SERVER_ID, skynet.self())
	if not uidOk or not newUid then
		_ERROR_F("gen uid fail, phone:%s err:%s", phone, tostring(newUid))
		_Reply(id, "account_create", { code = CODE.SYSTEM_ERROR })
		WHANDLE.Close(id, 4000, "gen uid fail")
		return
	end

	-- 第一个参数为 uid：dbserver 按 uid 哈希定向到某个 DBCELL_X
	local isOk, uid, isNew = _DbCall("createaccount", newUid, phone, SERVER_ID)
	if not isOk or not uid then
		_ERROR_F("create account fail, phone:%s err:%s", phone, tostring(isNew))
		_Reply(id, "account_create", { code = CODE.SYSTEM_ERROR })
		WHANDLE.Close(id, 4000, "create account fail")
		return
	end
	_INFO_F("create account %s, phone:%s uid:%s", isNew and "new" or "exist", phone, uid)

	-- 回查账号行：兼顾并发创角已存在（出生节点可能不同）的情况
	local getOk, account, dbErr = _DbCall("getaccount", phone)
	if not getOk or not account or dbErr then
		_ERROR_F("query created account fail, phone:%s err:%s", phone, tostring(dbErr))
		_Reply(id, "account_create", { code = CODE.SYSTEM_ERROR })
		WHANDLE.Close(id, 4000, "query account fail")
		return
	end
	_LoginWithAccount(id, account, "account_create")
end

---------------------- 供 whandle / global 调用 ----------------------

-- 初始化玩家 uid 生成器（仅登录网关 .WGATE 启动时调用）
-- util.new_uid 的 C 层要求全节点只有一个服务绑定 checkuid_service
function InitUid()
	local bindOk, bindErr = pcall(util.set_checkuid_service, skynet.self())
	if not bindOk then
		_ERROR_F("set_checkuid_service fail:%s", tostring(bindErr))
		return false
	end
	-- 序列号用启动时刻初始化，避免进程重启后同一秒内重复
	local sec, usec = util.realtime()
	local serialOk, serialErr = pcall(util.set_max_uid_serial, (sec % 8000) * 1000 + math.floor(usec / 1000))
	if not serialOk then
		_ERROR_F("set_max_uid_serial fail:%s", tostring(serialErr))
		return false
	end
	return true
end

-- 未绑定连接的上行消息入口（只接受账号登录/创角确认）
function HandleClientMessage(id, protoId, payload)
	local name = PROTO.NameById(protoId)
	if name == "account_login" then
		_OnAccountLogin(id, payload)
	elseif name == "account_create" then
		_OnAccountCreate(id, payload)
	else
		_WARN_F("need login first, sid:%s proto:%s", tostring(id), tostring(name or protoId))
		WHANDLE.Close(id, 4000, "need login first")
	end
end

-- 目标网关完成 websocket 恢复后调用：绑定 agent 并回包
function OnAdopted(id, ctx)
	_CompleteLogin(id, ctx)
end

-- 目标网关断线时通知登录网关注销在线表（非登录网关经 skynet.send 调用）
function OnOffline(uid, epoch)
	return LOGIN_COMMAND.offline(uid, epoch)
end

-- 目标网关认领登录所有权（skynet.call 调用）
function Claim(uid, epoch, gateName, agentName, agentCn)
	return LOGIN_COMMAND.claim(uid, epoch, gateName, agentName, agentCn)
end

-- 节点在线人数（调试/监控用）
function OnlineCount()
	local count = 0
	for _ in pairs(ONLINE) do
		count = count + 1
	end
	return count
end
