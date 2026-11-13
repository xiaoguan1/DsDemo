local skynet = require "skynet"
local socket = require "skynet.socket"
local websocket = require "http.websocket"
local tdump = tool.dump
local SERVICE_NAME = SERVICE_NAME

ACCEPT = {}
RESPONSE = {}

-- 生成 管理玩家的websocket table。其主要目的是不需要通过table.size获取长度
local function _CreateWsInfo()
	local data = {}
	local count = 0
	return setmetatable({}, {
		__index = data,
		__newindex = function (_, key, newvalue)
			local oldvalue = rawget(data, key)
			local isOk
			if not oldvalue and newvalue then
				-- 插入新值
				count = count + 1
				isOk = true
			elseif oldvalue and not newvalue then
				-- 去除旧值
				count = count - 1
				isOk = true
			elseif oldvalue and newvalue then
				-- 替换操作，原则上是不允许的！
				_ERROR_F("%s WScoketToInfo replace!!! key:%s oldvalue:%s newvalue:%s",
					SERVICE_NAME, key, tdump(oldvalue), tdump(newvalue))
				isOk = true
			else
				-- 未知情况
				_ERROR_F("%s WScoketToInfo unknown error!!! key:%s oldvalue:%s newvalue:%s",
					SERVICE_NAME, key, tdump(oldvalue), tdump(newvalue))
				return
			end

			if isOk then
				rawset(data, key, newvalue)
			end
		end,
		__len = function ()
			return count
		end,
		__pairs = function (_)
			local function filter(t, k)
				local v
				k, v = next(t, k)
				return k, v
			end
			return filter, data, nil
		end
	})
end

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = skynet.unpack,
	pack = skynet.pack,
}

skynet.start(function (gate_index)
	gate_index = tonumber(gate_index) or 1

	-- 无状态多实例：端口按实例序号错开（30001、30011、30021...）
	local wsocket_port = assert(tonumber(skynet.getenv("wsocket_port"))) + (gate_index - 1) * 10
	-- 命名：首实例 .WGATE，其余 .WGATE2、.WGATE3...
	local gate_name = gate_index == 1 and ".WGATE" or (".WGATE" .. gate_index)

	dofile "./game/global/log.lua"
	dofile "./game/service/wgate/global.lua"
	_G.WHANDLE.WScoketToInfo = _CreateWsInfo()
	_G.WHANDLE.GateName = gate_name
	_G.WHANDLE.GateClusterName = SELF_CLUSTERNAME

	skynet.dispatch("lua", function(session, source, cmd, ...)
		local f
		if session == 0 then
			f = assert(ACCEPT[cmd], cmd)
			f(...)
		else
			f = assert(RESPONSE[cmd], cmd)
			skynet.retpack(f(...))
		end
	end)

	local listend = socket.listen("0.0.0.0", wsocket_port, 128)
	_INFO_F("wgate:%s open listen:%s", gate_name, wsocket_port)

	-- 向 jlogin 注册本网关监听地址并维持心跳（登录决策时挑选存活网关下发）
	_G.WHANDLE.StartGateRegister(wsocket_port)

	socket.start(listend, function (newsd, addr)
		skynet.fork(function ()
			_INFO_F("new client adds:%s connect beginning.", addr)
			local ok, err = websocket.accept(newsd, WHANDLE.handle, "ws", addr)
			if not ok then
				print(err)
			end
		end)
	end)
end)