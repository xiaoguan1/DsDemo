local posix = require "posix"
local sformat = string.format
local endswith = assert(string.endswith) -- 先加载string.lua再加载posix.lua

local Invalid_File_Type = {
	["."] = true,
	[".."] = true,
	[".git"] = true,
	[".svn"] = true,
}

-- 创建文件夹
function posix.mkdir_p(path)
	if not path then
		return
	end
	local loop, index = 1, 1
	while true do
		if loop >= 100 then
			error("loop too must")
		end
		loop = loop + 1
		local sIndex = string.find(path, "/", index)
		if not sIndex then
			break
		end
		index = sIndex + 1
		local p = string.sub(path, 1, sIndex)
		if not p then
			error("path sub error!")
		end
		posix.mkdir(p)
	end
end

-- 读取某个文件夹下的所有文件
function posix.scandir(path, extData)
	extData = extData or {}
	extData.result = extData.result or {}
	extData.deep = extData.deep or 0
	if extData.deep > 100 then
		error(sformat("%s too deep!", extData.deep))
	end
	for file in posix.files(path) do
		if not Invalid_File_Type[file] then
			file = path .. "/" .. file
			local ftat = posix.stat(file) or {}
			if ftat.type == "directory" then		-- 目录
				-- 不能对extData进行深复制，因为需要extData.result记录结果
				posix.scandir(file, table.copy(extData))
			elseif ftat.type == "regular" then		-- 文件
				if extData.ftype then
					if endswith(file, extData.ftype) then
						extData.result[file] = file
					end
				else
					extData.result[file] = file
				end
			else
				print(sformat("%s type:%s error!", file, ftat.type))
			end
		end
	end
	return extData.result
end

-- 获取文件的最近一次修改时间
function posix.fmtime(path)
	return posix.stat(path, "mtime")
end

function _G.Pid()
	local pinfo = posix.getpid()
	return pinfo and pinfo.pid
end

function _G.Pwd()
	local sinfo = posix.getenv()
	return sinfo and sinfo.PWD
end

function _G.HostName()
	local sinfo = posix.getenv()
	return sinfo and sinfo.HOSTNAME
end

function _G.SysUser()
	local sinfo = posix.getenv()
	return sinfo and sinfo.USER
end