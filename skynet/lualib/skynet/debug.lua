local table = table
local extern_dbgcmd = {}

local function init(skynet, export)
	local internal_info_func

	function skynet.info_func(func)
		internal_info_func = func
	end

	local dbgcmd

	local function init_dbgcmd()
		dbgcmd = {}

		function dbgcmd.MEM()
			local kb = collectgarbage "count"
			skynet.ret(skynet.pack(kb))
		end

		local gcing = false
		function dbgcmd.GC()
			if gcing then
				return
			end
			gcing = true
			local before = collectgarbage "count"
			local before_time = skynet.now()
			collectgarbage "collect"
			-- skip subsequent GC message
			skynet.yield()
			local after = collectgarbage "count"
			local after_time = skynet.now()
			skynet.error(string.format("GC %.2f Kb -> %.2f Kb, cost %.2f sec", before, after, (after_time - before_time) / 100))
			gcing = false
		end

		function dbgcmd.SHAREDATA_FLUSH()
			if SHAREDATA_NEED_FLUSH then
				local sharedata = require "skynet.sharedata"
				sharedata.flush()
			end
			skynet.ret(skynet.pack(nil))
		end

		function dbgcmd.STAT()
			local stat = {}
			stat.task = skynet.task()
			stat.mqlen = skynet.stat "mqlen"
			stat.cpu = skynet.stat "cpu"
			stat.message = skynet.stat "message"
			skynet.ret(skynet.pack(stat))
		end

		function dbgcmd.KILLTASK(threadname)
			local co = skynet.killthread(threadname)
			if co then
				skynet.error(string.format("Kill %s", co))
				skynet.ret()
			else
				skynet.error(string.format("Kill %s : Not found", threadname))
				skynet.ret(skynet.pack "Not found")
			end
		end

		function dbgcmd.TASK(session)
			if session then
				skynet.ret(skynet.pack(skynet.task(session)))
			else
				local task = {}
				skynet.task(task)
				skynet.ret(skynet.pack(task))
			end
		end

		function dbgcmd.UNIQTASK()
			skynet.ret(skynet.pack(skynet.uniqtask()))
		end

		function dbgcmd.INFO(...)
			if internal_info_func then
				skynet.ret(skynet.pack(internal_info_func(...)))
			else
				skynet.ret(skynet.pack(nil))
			end
		end

		-- 非 protosvr服务 更新协议逻辑
		function dbgcmd.PROTO_UPDATE(...)
			if SERVICE_NAME == "protosvr" then
				return
			end
			local _loaded = debug.getregistry()._LOADED or {}
			if _loaded["protobuf"] then
				local utilc = require "util.core"
				local protobuf = require "protobuf"
				if protobuf.P == utilc.get_pbenv() then
					skynet.error(string.format("[%s] update protobuf fail", SERVICE_NAME))
					return
				end
				utilc.load_pbenv()
				protobuf.P = debug.getregistry().PROTOBUF_ENV
				protobuf.update_local_pgc()
				skynet.error(string.format("[%s] update protobuf succeed", SERVICE_NAME))
			end
			skynet.ret(skynet.pack(nil))
		end

		local old_snapshot = nil
		function dbgcmd.SNAPSHOT(isCover)
			if SERVICE_NAME == "sharedatad" then		-- 共享数据的要遍历太久了
				return skynet.ret(skynet.pack(nil))
			end
			local snapshot = require "snapshot"
			local snapshot_utils = require "snapshot_utils"
			local snapshot_search = require "snapshot_search"
			collectgarbage("collect")	-- 为什么两次gc？
			collectgarbage("collect")
			local new_snapshot = snapshot()
			if not old_snapshot then
				old_snapshot = new_snapshot
				return skynet.ret(skynet.pack({}))
			end
			local diff = {}
			for k, v in pairs(new_snapshot) do
				if not old_snapshot[k] then
					diff[k] = v
				end
			end
			if isCover then					-- 默认不覆盖，保证下次也能看到哪里有问题
				old_snapshot = new_snapshot
			end
			local ret = snapshot_utils.construct_indentation(diff)
			local KEY_MAP = {}
			for k, v in pairs(new_snapshot) do
				local key = tostring(k)
				local clean_key = key:match("userdata: 0x(%w+)")
				KEY_MAP[clean_key] = k
			end
			local cache_search = {}
			for _addr, _data in pairs (ret) do
				local path = snapshot_search.search_addresspath(KEY_MAP, _addr, new_snapshot, cache_search)
				_data.snapshot_path = path
			end
			return skynet.ret(skynet.pack(ret))
		end

		local start_snapshot = nil
		function dbgcmd.SNAPSHOT_COMPSTART()
			if SERVICE_NAME == "sharedatad" then		-- 共享数据的要遍历太久了
				return skynet.ret(skynet.pack({"sharedatad can't start snapshot"}))
			end
			local snapshot = require "snapshot"
			local snapshot_utils = require "snapshot_utils"
			local snapshot_search = require "snapshot_search"
			collectgarbage("collect")	-- 为什么两次gc？
			collectgarbage("collect")
			if not start_snapshot then
				return skynet.ret(skynet.pack({"not start snapshot"}))
			end
			local new_snapshot = snapshot()
			local diff = {}
			for k, v in pairs(new_snapshot) do
				if not start_snapshot[k] then
					diff[k] = v
				end
			end
			local ret = snapshot_utils.construct_indentation(diff)
			local KEY_MAP = {}
			for k, v in pairs(new_snapshot) do
				local key = tostring(k)
				local clean_key = key:match("userdata: 0x(%w+)")
				KEY_MAP[clean_key] = k
			end
			local cache_search = {}
			for _addr, _data in pairs(ret) do
				local path = snapshot_search.search_addresspath(KEY_MAP, _addr, new_snapshot, cache_search)
				_data.snapshot_path = path
			end
			return skynet.ret(skynet.pack(ret))

		end

		local isStartSnapshot = nil
		function dbgcmd.STARTSTOP_SNAPSHOT()
			if SERVICE_NAME == "sharedatad" then		-- 共享数据的要遍历太久了
				return skynet.ret(skynet.pack({}))
			end

			-- 内存快照
			local snapshot = require "snapshot"
			local snapshot_utils = require "snapshot_utils"
			local snapshot_search = require "snapshot_search"
			collectgarbage("collect")	-- 为什么两次gc？
			collectgarbage("collect")
			local new_snapshot = snapshot()
			if not start_snapshot then
				start_snapshot = new_snapshot
				return skynet.ret(skynet.pack({}))
			end
			local diff = {}
			for k, v in pairs(new_snapshot) do
				if not start_snapshot[k] then
					diff[k] = v
				end
			end
			local ret = snapshot_utils.construct_indentation(diff)
			local KEY_MAP = {}
			for k, v in pairs(new_snapshot) do
				local key = tostring(k)
				local clean_key = key:match("userdata: 0x(%w+)")
				KEY_MAP[clean_key] = k
			end
			local cache_search = {}
			for _addr, _data in pairs(ret) do
				local path = snapshot_search.search_addresspath(KEY_MAP, _addr, new_snapshot, cache_search)
				_data.snapshot_path = path
			end
			return skynet.ret(skynet.pack(ret))

























		end

		function dbgcmd.PROFILE_CMD(cmd)
			if Import then
				local PROFILE_CMD = Import("global/profile_cmd.lua")
				if cmd == "on" then
					PROFILE_CMD.Profile_On()
				elseif cmd == "off" then
					PROFILE_CMD. Profile_Off()
				elseif cmd == "info" then
					skynet.retpack(PROFILE_CMD.Profile_Info())
					return
				else
					error("not cmd:" .. cmd)
				end
				skynet.retpack(true)
			else
				skynet.retpack(nil)
			end
		end

		local function _table_hasvalue(tbl, value)
			for k, v in pairs(tbl) do
				if v == value then
					return true
				end
			end
		end

		function dbgcmd.UPDATE_DOFILE_CMD(updatefile)
			if UPDATE_DOFILE_FILE and UPDATE_DOFILE_FILE[updatefile] then
				if DOFILELIST and _table_hasvalue(DOFILELIST, updatefile) then
					skynet.error("auto dofile file:" .. updatefile)
					dofile(updatefile)
				end
			end
			skynet.retpack(nil)
		end

		function dbgcmd.UPDATE_AUTO_CMD(updatefile)
			if Import then
				skynet.retpack(UpdateAuto(updatefile))
			else
				skynet.retpack(nil)
			end
		end

		function dbgcmd.UPDATE_MACROS_CMD(updatefile)
			if Import then
				skynet.retpack(UpdateMacro(updatefile))
			else
				skynet.retpack(nil)
			end
		end

		local function _UpdateAutoListByOrder(updatefiles, UPDATE_TYPE)
			local reterr = nil
			-- 优先macros,再其他更新，再dofile
			for _, _updateType in ipairs({UPDATE_TYPE.MACROS, UPDATE_TYPE.IMPORT, UPDATE_TYPE.DOFILE}) do
				for _, _fData in ipairs(updatefiles) do
					local updatefile = _fData.file
					local utype = _fData.utype
					if utype == _updateType then
						local ok, ret = nil, nil
						if utype == UPDATE_TYPE.DOFILE then
							if UPDATE_DOFILE_FILE and UPDATE_DOFILE_FILE[updatefile] then
								if DOFILELIST and _table_hasvalue(DOFILELIST, updatefile) then
									skynet.error(string.format("[%s] auto update defile file:%s", SERVICE_NAME, updatefile))
									ok, ret = xpcall(dofile, debug.traceback, updatefile)
								end
							end
						elseif utype == UPDATE_TYPE.MACROS then
							ok, ret = xpcall(UpdateMacro, debug.traceback, updatefile)
						elseif utype == UPDATE_TYPE.IMPORT then
							ok, ret = xpcall(UpdateAuto, debug.traceback, updatefile)
						else
							error(string.format("not updateType:%s updateFile:%s", utype, updatefile))
						end
						if not ok and ret then
							if reterr then
								reterr = reterr .. "\n" .. ret
							else
								reterr = ret
							end
						end
					end
				end
			end
			return reterr
		end

		-- return true/false, updateList
		local function _GetUpdateImportFilesOnceList(autoUpdateFiles)
			local _ImportModule = _ImportModule or {}
			local m = {}
			local queue = require "queue"
			local q = queue.new()
			for _, _fnode in ipairs(autoUpdateFiles) do
				if _ImportModule[_fnode.file] then
					q:push({file = _fnode.file, orderno = 1, prefile = _fnode.prefile})
				end
			end
			local node = q:pop()
			while node do
				if node.orderno > 100 then
					skynet.error(string.format("_GetUpdateImportFilesOnceList, file:%s orderno:%s error", node.file, node.orderno))
					return false
				end
				local needUpdateNext = false
				local mNode = m[node.file]
				if mNode then
					if node.orderno > mNode.orderno then
						needUpdateNext = true
					else
						-- 不比已存在的大则不用处理
					 end
				else
					needUpdateNext = true
				end
				if needUpdateNext then
					local nfile = node.file
					m[nfile] = node
					local nextFiles = GetImportTypeNextUpdateFiles(nfile)
					if nextFiles then
						for _file, _t in pairs(nextFiles) do
							q:push({file = _file, orderno = node.orderno + 1, prefile = nfile})	-- 后续更新的都只是是Import
						end
					end
				end

				node = q:pop()
			end

			-- 根据m的orderno排序
			local updateList = {}
			for _file, _node in pairs(m) do
				table.insert(updateList, _node)
			end
			table.sort(updateList, function (n1, n2)
				if n1.orderno < n2.orderno then
					return true
				end
			end)

			return true, updateList
		end

		function dbgcmd.UPDATE_FILES(updatefiles)
			if not Import then
				return skynet.retpack(nil)
			end

			local TOOL_FILES = TOOL_FILES or {}
			local MACRO_FILES = MACRO_FILES or {}
			local _ImportModule = _ImportModule or {}

			local updateToolFiles = updatefiles[UPDATE_TYPE.TOOL] or {}
			local updateMacosFiles = updatefiles[UPDATE_TYPE.MACROS] or {}
			local updateImportFiles = updatefiles[UPDATE_TYPE.IMPORT] or {}

			local _MetaImport = getmetatable(_ImportModule)
			if not _MetaImport then
				setmetatable(_ImportModule, {
					__newindex = function (modules, file, modEnv)
						skynet.error(string.format("[%s] auto add file:%s", SERVICE_NAME, file))
						return rawset(modules, file, modEnv)
					end
				})
			end
			local UPDATE_TYPE = UPDATE_TYPE or {TOOL = 1, MACROS = 2, IMPORT = 3}

			-- 热更新（注意：热更新代码里面也有可能加载新的代码文件）
			local ok, ret, reterr = nil, nil, nil

			-- 1.更新tool工具类的拓展
			for _, file in ipairs(updateToolFiles) do
				if table.has_value(TOOL_FILES, file) then
					skynet.error(string.format("[%s] auto update dofile tool file:%s", SERVICE_NAME, file))
					ok, ret = xpcall(dofile, debug.traceback, file)
					if not ok and ret then
						if reterr then
							reterr = reterr .. "\n".. ret
						else
							reterr = ret
						end
					end
				end
			end

			-- 2.更新宏定义
			for _, file in ipairs(updateMacosFiles) do
				if table.has_value(MACRO_FILES, file) then
					skynet.error(string.format("[%s] auto update dofile macros file:%s", SERVICE_NAME, file))
					ok, ret = xpcall(dofile, debug.traceback, file)
					if not ok and ret then
						if reterr then
							reterr = reterr .. "\n".. ret
						else
							reterr = ret
						end
					end
				end
			end

			-- 3.更新Import文件
			for _, file in ipairs(updateImportFiles) do
				if _ImportModule[file] then
					skynet.error(string.format("[%s] auto update import file:%s", SERVICE_NAME, file))
					ok, ret = xpcall(Update, debug.traceback, file)
					if not ok and ret then
						if reterr then
							reterr = reterr .. "\n".. ret
						else
							reterr = ret
						end
					end
				end
			end

			if reterr then
				error(reterr)
			else
				skynet.retpack(nil)
			end
		end

		-- ailin的热更逻辑
		function dbgcmd.UPDATE_AUTO_LISTFILE(updatefiles)
			if Import then
				local UPDATE_TYPE = UPDATE_TYPE or {MACROS = 1, IMPORT = 2, DOFILE = 3}
				local autoUpdateFiles = {}       --记录目动更新的文件

				local reterr = nil
				local ok, ret = nil, nil
				-- 1.优先更新macros
				for _, _fData in ipairs(updatefiles) do
					local updatefile = _fData.file
					local utype = _fData.utype
					if utype == UPDATE_TYPE.MACROS then
						ok, ret, needUpdateFilesMap = xpcall(UpdateMacro, debug.traceback, updatefile, true)
						if not ok and ret then
							if reterr then
								reterr = reterr .. "\n".. ret
							else
								reterr = ret
							end
						end
						if ret and needUpdateFilesMap then
							for _file, _ in pairs(needUpdateFilesMap) do
								table.insert(autoUpdateFiles, {file = _file, utype = UPDATE_TYPE.IMPORT, prefile = updatefile})
							end
						end
					end
				end

				-- 2.更新Import文件
				for _, _fData in ipairs(updatefiles) do
					local updatefile = _fData.file
					local utype = _fData.utype
					if utype == UPDATE_TYPE.IMPORT then
						table.insert(autoUpdateFiles, _fData)
					end
				end
				-- 使用autoUpdateFiles判断看是否可以按顺序热更工次，如果不行，则使用普通的_UpdateAutoListByOrder
				local canUpdateImportFilesOnce, updateList = _GetUpdateImportFilesOnceList(autoUpdateFiles)
				if canUpdateImportFilesOnce then
					for _, _node in ipairs(updateList) do
						skynet.error(string.format("[%s] auto update import file:%s prefile:%s orderno:%s", SERVICE_NAME, _node.file, _node.prefile, _node.orderno))
						ok, ret = xpcall(Update, debug.traceback, _node.file)
						if not ok and ret then
							if reterr then
								reterr = reterr .. "\n".. ret
							else
								reterr = ret
							end
						end
					end
				else
					local terr = _UpdateAutoListByOrder(autoUpdateFiles, UPDATE_TYPE)
					if terr then
						reterr = reterr .. "\n".. terr
					end
				end

				-- 3.更新dofile文件
				for _, _fData in ipairs(updatefiles) do
					local updatefile = _fData.file
					local utype = _fData.utype
					if utype == UPDATE_TYPE.DOFILE then
						if UPDATE_DOFILE_FILE and UPDATE_DOFILE_FILE[updatefile] then
							if DOFILELIST and _table_hasvalue(DOFILELIST, updatefile) then
								skynet.error(string.format("[%s] auto dofile file:%s", SERVICE_NAME, updatefile))
								ok, ret = xpcall(dofile, debug.traceback, updatefile)
								if not ok and ret then
									if reterr then
										reterr = reterr .. "\n" .. ret
									else
										reterr = ret
									end
								end
							end
						end
					end
				end

				if reterr then
					error(reterr)
				else
					skynet.retpack(nil)
				end
			else
				skynet.retpack(nil)
			end
		end

		function dbgcmd.GTABLE_STATE_CMD(file, tname, layer, dumpsize)
			if Import then
				skynet.retpack(ImportGTablestate(file, tname, layer, dumpsize))
			else
				skynet.retpack(nil)
			end
		end

		function dbgcmd.ATABLE_STATE_CMD(dumpsize)
			local dumpsize = dumpsize or 512
			local SNODE = skynet.getenv("node_name") or "unknow"
			local BASE_DIR = "log/" .. SNODE .. "/ftablecheck/point"
			local ftablecheck = require "ftablecheck"
			local addr = skynet.format("%08x", skynet.self())
			collectgarbage("collect")
			collectgarbage("collect")
			local file = string.format("%s/%s", BASE_DIR, addr)
			os.remove(file)				-- 删除文件
			ftablecheck(file, dumpsize)

			-- 尽量不直接在这里搜索，因为比较占用内存和时间
			-- local fabnormalsearch = require "fabnormalsearch"
			-- local abnormal = fabnormalsearch.GetAbnormal(file)
			-- return skynet.ret(skynet.pack(abnormal))
			return skynet.ret(skynet.pack({}))
		end

		function dbgcmd.PROFILE_INFOSTRING(...)
			if Import then
				local PROFILE_CMD = Import("global/profile_cmd")
				skynet.retpack(PROFILE_CMD.Profile_InfoString())
			else
				skynet.retpack(nil)
			end
		end

		function dbgcmd.EXIT()
			skynet.exit()
		end

		function dbgcmd.RUN(source, filename, ...)
			local inject = require "skynet.inject"
			local args = table.pack(...)
			local ok, output = inject(skynet, source, filename, args, export.dispatch, skynet.register_protocol)
			collectgarbage "collect"
			skynet.ret(skynet.pack(ok, table.concat(output, "\n")))
		end

		function dbgcmd.TERM(service)
			skynet.term(service)
		end

		function dbgcmd.REMOTEDEBUG(...)
			local remotedebug = require "skynet.remotedebug"
			remotedebug.start(export, ...)
		end

		function dbgcmd.SUPPORT(pname)
			return skynet.ret(skynet.pack(skynet.dispatch(pname) ~= nil))
		end

		function dbgcmd.PING()
			return skynet.ret()
		end

		function dbgcmd.LINK()
			skynet.response()	-- get response , but not return. raise error when exit
		end

		function dbgcmd.TRACELOG(proto, flag)
			if type(proto) ~= "string" then
				flag = proto
				proto = "lua"
			end
			skynet.error(string.format("Turn trace log %s for %s", flag, proto))
			skynet.traceproto(proto, flag)
			skynet.ret()
		end

		function dbgcmd.STARTIME(offset)
			skynet.offset_starttime(offset)
			skynet.ret()
		end

		return dbgcmd
	end -- function init_dbgcmd

	local function _debug_dispatch(session, address, cmd, ...)
		dbgcmd = dbgcmd or init_dbgcmd() -- lazy init dbgcmd
		local f = dbgcmd[cmd] or extern_dbgcmd[cmd]
		assert(f, cmd)
		f(...)
	end

	skynet.register_protocol {
		name = "debug",
		id = assert(skynet.PTYPE_DEBUG),
		pack = assert(skynet.pack),
		unpack = assert(skynet.unpack),
		dispatch = _debug_dispatch,
	}
end

local function reg_debugcmd(name, fn)
	extern_dbgcmd[name] = fn
end

return {
	init = init,
	reg_debugcmd = reg_debugcmd,
}
