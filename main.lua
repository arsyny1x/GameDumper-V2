--!nocheck
------------------------------------------------------------------
-- [0] RE-EXECUTE GUARD
------------------------------------------------------------------
local genv = (typeof(getgenv) == "function" and getgenv()) or _G
if genv.__AdvancedDumper and genv.__AdvancedDumper.Destroy then
	pcall(genv.__AdvancedDumper.Destroy)
end

------------------------------------------------------------------
-- [1] SERVICES & CONFIG
------------------------------------------------------------------
local Players            = game:GetService("Players")
local UserInputService   = game:GetService("UserInputService")
local TweenService       = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")
local StarterGui         = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local Config = {
	GuiName           = "AdvancedGameDumper",
	RootFolder        = "GameDumps",
	ToggleKey         = Enum.KeyCode.Insert,

	YieldEvery        = 200,     -- Phase 1: พักเฟรมทุก ๆ N instance
	DecompileDelay    = 0.05,     -- Phase 2: พักหลัง decompile แต่ละตัว (วินาที)
	MaxBytecodeSize   = 400000,  -- ข้ามสคริปต์ที่ bytecode ใหญ่เกินนี้
	MaxNameLength     = 50,
	WriteHierarchy    = true,
	MaxHierarchyLines = 50000,
    DecompilerMode = "bytefall", -- "bytefall" | "auto" | "native" | "custom" | "bytecode"
	SaveBytecode   = false,      -- true = บันทึก .luac คู่กับ .lua ด้วย


	Services = {
		"Workspace", "ReplicatedStorage", "ReplicatedFirst", "Lighting",
		"StarterGui", "StarterPack", "StarterPlayer", "Players",
		"SoundService", "Teams", "Chat",
	},
	-- ค่าเริ่มต้นเลือกเฉพาะ Service ที่มีโค้ดเยอะและเบา
	DefaultEnabled = {
		ReplicatedStorage = true, ReplicatedFirst = true,
		StarterPlayer = true, StarterGui = true,
	},

	-- สคริปต์มาตรฐานของ Roblox (ข้ามได้ ลดโอกาสแครช + ลดเวลา)
	RobloxDefaultScripts = {
		PlayerModule = true, PlayerScriptsLoader = true, RbxCharacterSounds = true,
		Animate = true, ChatScript = true, BubbleChat = true,
		ClientChatModules = true, ChatModules = true, ChatServiceRunner = true,
	},
}

local Theme = {
	Background = Color3.fromRGB(18, 18, 24),
	Panel      = Color3.fromRGB(28, 28, 38),
	PanelLight = Color3.fromRGB(40, 40, 56),
	Accent     = Color3.fromRGB(115, 90, 255),
	AccentAlt  = Color3.fromRGB(0, 200, 255),
	Text       = Color3.fromRGB(235, 235, 245),
	SubText    = Color3.fromRGB(150, 150, 175),
	Success    = Color3.fromRGB(60, 200, 120),
	Danger     = Color3.fromRGB(235, 70, 90),
	Warning    = Color3.fromRGB(255, 180, 60),
	Font       = Enum.Font.Gotham,
	FontBold   = Enum.Font.GothamBold,
}

------------------------------------------------------------------
-- [2] UTIL
------------------------------------------------------------------
local Util = {}

local RESERVED_NAMES = { CON = true, PRN = true, AUX = true, NUL = true }
for i = 1, 9 do
	RESERVED_NAMES["COM" .. i] = true
	RESERVED_NAMES["LPT" .. i] = true
end

-- ชื่อไฟล์/โฟลเดอร์ต้องเป็น ASCII ล้วน (กัน makefolder/writefile แครช)
function Util.sanitize(name)
	name = tostring(name or "")
	name = string.gsub(name, "[\128-\255]+", "_")
	name = string.gsub(name, '[<>:"/\\|%?%*%c]', "_")
	name = string.gsub(name, "_+", "_")
	name = string.gsub(name, "^[%s%._]+", "")
	name = string.gsub(name, "[%s%.]+$", "")
	if name == "" then name = "_unnamed" end
	if #name > Config.MaxNameLength then
		name = string.sub(name, 1, Config.MaxNameLength)
	end
	if RESERVED_NAMES[string.upper(name)] then name = "_" .. name end
	return name
end

function Util.uniqueName(usedSet, base, ext)
	ext = ext or ""
	local candidate, n = base .. ext, 1
	while usedSet[string.lower(candidate)] do
		n += 1
		candidate = base .. "_" .. n .. ext
	end
	usedSet[string.lower(candidate)] = true
	return candidate
end

function Util.timestamp()
	return os.date("%Y-%m-%d_%H-%M-%S")
end

function Util.formatDuration(sec)
	sec = math.max(0, sec or 0)
	return string.format("%d นาที %d วินาที", math.floor(sec / 60), math.floor(sec % 60))
end

function Util.fullName(inst)
	local ok, result = pcall(inst.GetFullName, inst)
	return ok and result or "<unknown>"
end

function Util.getGameName()
	local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, game.PlaceId)
	if ok and type(info) == "table" and info.Name then return info.Name end
	return "Place_" .. tostring(game.PlaceId)
end

function Util.isDumpableScript(inst, className)
	if className == "LocalScript" or className == "ModuleScript" then return true end
	if className == "Script" then
		local ok, runContext = pcall(function() return inst.RunContext end)
		return ok and runContext == Enum.RunContext.Client
	end
	return false
end

function Util.isAlive(inst)
	local ok, parent = pcall(function() return inst.Parent end)
	return ok and parent ~= nil
end

-- เรียก decompile ตรง ๆ ทีละตัว (ไม่ spawn ซ้อน) + เช็ก bytecode ก่อน
------------------------------------------------------------------
-- DECOMPILER ADAPTER  (bytefall / native / custom / bytecode)
------------------------------------------------------------------
local HttpService = game:GetService("HttpService")
local Decompiler = {}

local ByteFall = {
	Endpoint   = "https://decompiler.bytefall.dev/decompile",
	Retries    = 2,   -- ลองใหม่อีกกี่ครั้งถ้าล้มเหลว
	RetryDelay = 2,   -- วินาที (คูณตามรอบ)
}

-- หาฟังก์ชัน HTTP request ของ Executor
local function getRequestFn()
	if typeof(request) == "function" then return request end
	if typeof(http_request) == "function" then return http_request end
	if typeof(syn) == "table" and typeof(syn.request) == "function" then return syn.request end
	if typeof(http) == "table" and typeof(http.request) == "function" then return http.request end
	return nil
end

-- Base64 สำรอง (เร็วกว่าตัวเดิมมาก + พักเฟรมกันค้าง)
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64Fallback(data)
	local out, len, count = {}, #data, 0
	for i = 1, len, 3 do
		local a, b, c = string.byte(data, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1 = bit32.band(bit32.rshift(n, 18), 63)
		local c2 = bit32.band(bit32.rshift(n, 12), 63)
		local c3 = bit32.band(bit32.rshift(n, 6), 63)
		local c4 = bit32.band(n, 63)
		out[#out + 1] = string.sub(B64, c1 + 1, c1 + 1)
			.. string.sub(B64, c2 + 1, c2 + 1)
			.. (b and string.sub(B64, c3 + 1, c3 + 1) or "=")
			.. (c and string.sub(B64, c4 + 1, c4 + 1) or "=")
		count += 1
		if count % 20000 == 0 then task.wait() end
	end
	return table.concat(out)
end

local function getBase64Encoder()
	if typeof(crypt) == "table" then
		if typeof(crypt.base64encode) == "function" then return crypt.base64encode end
		if typeof(crypt.base64) == "table" and typeof(crypt.base64.encode) == "function" then
			return crypt.base64.encode
		end
	end
	if typeof(base64_encode) == "function" then return base64_encode end
	return base64Fallback
end

-- ส่ง bytecode ไป ByteFall -> คืน (success, source/error)
function ByteFall.decompile(bytecode)
	local req = getRequestFn()
	if not req then return false, "Executor ไม่มีฟังก์ชัน request()" end

	local okEnc, encoded = pcall(getBase64Encoder(), bytecode)
	if not okEnc or type(encoded) ~= "string" then
		return false, "Base64 encode ล้มเหลว: " .. tostring(encoded)
	end

	local okJson, body = pcall(HttpService.JSONEncode, HttpService, { script = encoded })
	if not okJson then return false, "JSON encode ล้มเหลว: " .. tostring(body) end

	local lastErr = "unknown"
	for attempt = 1, ByteFall.Retries + 1 do
		local okReq, res = pcall(req, {
			Url = ByteFall.Endpoint,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		})

		local code = 0
		if okReq and type(res) == "table" then
			code = tonumber(res.StatusCode or res.Status) or 0
			local text = tostring(res.Body or "")
			if code == 200 and #text > 0 then
				return true, text
			end
			lastErr = ("ByteFall HTTP %d: %s"):format(code, string.sub(text, 1, 200))
			if code == 400 or code == 404 or code == 500 then
				break -- error ถาวร ลองใหม่ก็ไม่ผ่าน
			end
		else
			lastErr = "request ล้มเหลว: " .. tostring(res)
		end

		if attempt <= ByteFall.Retries then
			local wait = ByteFall.RetryDelay * attempt
			if code == 429 then wait *= 3 end -- โดน rate limit
			task.wait(wait)
		end
	end
	return false, lastErr
end

function Decompiler.getBytecode(inst)
	if typeof(getscriptbytecode) ~= "function" then
		return nil, "Executor ไม่รองรับ getscriptbytecode()"
	end
	local ok, bc = pcall(getscriptbytecode, inst)
	if not ok then return nil, tostring(bc) end
	if type(bc) ~= "string" or #bc == 0 then
		return nil, "ไม่มี bytecode (สคริปต์ว่าง หรือยังไม่ถูกโหลด)"
	end
	return bc
end

-- คืนค่า: ชื่อโหมด, ฟังก์ชัน (เฉพาะ native/custom)
function Decompiler.resolve()
	local mode = Config.DecompilerMode or "bytefall"
	local custom = genv.CustomDecompile
	local native = (typeof(decompile) == "function") and decompile or nil
	local canByteFall = getRequestFn() ~= nil and typeof(getscriptbytecode) == "function"

	if mode == "auto" then
		if typeof(custom) == "function" then return "custom", custom end
		if canByteFall then return "bytefall", nil end
		if native then return "native", native end
		return "bytecode", nil
	elseif mode == "bytefall" then
		if canByteFall then return "bytefall", nil end
		return "bytecode", nil -- Executor ไม่รองรับ จึงบันทึก .luac แทน
	elseif mode == "custom" then
		return "custom", custom
	elseif mode == "native" then
		return "native", native
	end
	return "bytecode", nil
end

function Util.decompile(scriptInst)
	local mode, fn = Decompiler.resolve()
	if mode == "bytecode" then
		return false, "โหมด Bytecode: ไม่ได้ decompile ในเกม"
	end

	-- ตรวจ bytecode ก่อน
	local bc, why
	if typeof(getscriptbytecode) == "function" then
		bc, why = Decompiler.getBytecode(scriptInst)
		if not bc then return false, why end
		if #bc > Config.MaxBytecodeSize then
			return false, ("bytecode ใหญ่เกินไป (%d bytes) จึงข้าม"):format(#bc)
		end
	end

	if mode == "bytefall" then
		return ByteFall.decompile(bc)
	end

	if typeof(fn) ~= "function" then
		return false, "ไม่พบฟังก์ชัน decompiler สำหรับโหมด '" .. mode .. "'"
	end
	local ok, result = pcall(fn, scriptInst, bc)
	if not ok then return false, tostring(result) end
	if type(result) ~= "string" or #result == 0 then
		return false, "decompiler คืนค่าว่างเปล่า"
	end
	return true, result
end

function Util.notify(title, text, duration)
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = duration or 6 })
	end)
end

------------------------------------------------------------------
-- [3] FILE SYSTEM  (Executor-aware, multi-API)
------------------------------------------------------------------
local FS = {}

-- ค้นหา API ที่ Executor รองรับ (writefile / syn.writefile / write_file / ฯลฯ)
local function findFn(...)
	for _, fn in ipairs({...}) do
		if typeof(fn) == "function" then return fn end
	end
	return nil
end

local function findWorkspace()
	for _, fn in ipairs({ getworkspace, get_workspace, syn and syn.getworkspace }) do
		if typeof(fn) == "function" then
			local ok, ws = pcall(fn)
			if ok and type(ws) == "string" and #ws > 0 then return ws end
		end
	end
	return nil
end

FS.WriteFn      = findFn(writefile,    write_file,    syn and syn.writefile)
FS.MakeFolderFn = findFn(makefolder,   make_folder,   syn and syn.makefolder)
FS.IsFolderFn   = findFn(isfolder,     is_folder,     syn and syn.isfolder)
FS.IsFileFn     = findFn(isfile,       is_file,       syn and syn.isfile)
FS.ReadFileFn   = findFn(readfile,     read_file,     syn and syn.readfile)
FS.Workspace    = findWorkspace()

FS.Supported = FS.WriteFn ~= nil and FS.MakeFolderFn ~= nil

-- แปลง path แบบ relative -> absolute (ถ้า Executor บอก workspace ได้)
function FS.AbsolutePath(relPath)
	if not FS.Workspace then return nil end
	local ws = string.gsub(FS.Workspace, "\\", "/")
	if string.sub(ws, -1) ~= "/" then ws = ws .. "/" end
	relPath = string.gsub(relPath, "^[/\\]+", "")
	return ws .. relPath
end

function FS.DisplayPath(relPath)
	local abs = FS.AbsolutePath(relPath)
	return abs or relPath
end

-- เรียก writefile โดยลองทั้ง relative และ absolute
local function callWrite(fn, path, content)
	local ok, err = pcall(fn, path, content)
	if ok then return true end
	local abs = FS.AbsolutePath(path)
	if abs and abs ~= path then
		local ok2, err2 = pcall(fn, abs, content)
		if ok2 then return true end
		return false, err2
	end
	return false, err
end

local function callMakeFolder(fn, path)
	if FS.IsFolderFn then
		local ok, exists = pcall(FS.IsFolderFn, path)
		if ok and exists then return true end
	end
	pcall(fn, path) -- may return false if folder already exists; verify below
	if FS.IsFolderFn then
		local ok, exists = pcall(FS.IsFolderFn, path)
		return ok and exists == true
	end
	return true -- ถ้าไม่มี isfolder ให้ถือว่าสำเร็จ (writeFile จะเป็นตัวตัดสิน)
end

function FS.makeFolder(path)
	if not FS.MakeFolderFn then return false end
	return callMakeFolder(FS.MakeFolderFn, path)
end

function FS.ensurePath(path, cache)
	cache = cache or {}
	if cache[path] then return true end
	local current = ""
	for part in string.gmatch(path, "[^/\\]+") do
		current = (current == "") and part or (current .. "/" .. part)
		if not cache[current] then
			if not FS.makeFolder(current) then return false end
			cache[current] = true
		end
	end
	return true
end

function FS.writeFile(path, content)
	if not FS.WriteFn then return false, "Executor ไม่มี writefile" end
	return callWrite(FS.WriteFn, path, content)
end

function FS.readFile(path)
	if not FS.ReadFileFn then return nil end
	if FS.IsFileFn then
		local ok, exists = pcall(FS.IsFileFn, path)
		if not ok or not exists then return nil end
	end
	local ok, data = pcall(FS.ReadFileFn, path)
	return (ok and type(data) == "string") and data or nil
end

------------------------------------------------------------------
-- [4] CRASH GUARD
------------------------------------------------------------------
local CrashGuard = { Blacklist = {}, LastCrash = nil }

local GUARD_FILE     = Config.RootFolder .. "/_crashguard.txt"
local BLACKLIST_FILE = Config.RootFolder .. "/_blacklist.txt"

function CrashGuard.Key(fullName)
	local clean = string.gsub(tostring(fullName), "[\r\n]", "")
	return tostring(game.PlaceId) .. "|" .. clean
end

function CrashGuard.Save()
	local lines = {}
	for key in pairs(CrashGuard.Blacklist) do table.insert(lines, key) end
	table.sort(lines)
	FS.writeFile(BLACKLIST_FILE, table.concat(lines, "\n"))
end

-- เรียกตอนเปิดสคริปต์: ถ้าไฟล์ guard ไม่ว่าง = ครั้งก่อนแครชที่สคริปต์นั้น
function CrashGuard.Load()
	if not FS.Supported then return end
	FS.makeFolder(Config.RootFolder)

	local list = FS.readFile(BLACKLIST_FILE)
	if list then
		for line in string.gmatch(list, "[^\r\n]+") do
			CrashGuard.Blacklist[line] = true
		end
	end

	local last = FS.readFile(GUARD_FILE)
	if last and last ~= "" then
		CrashGuard.LastCrash = last
		CrashGuard.Blacklist[last] = true
		CrashGuard.Save()
		FS.writeFile(GUARD_FILE, "")
	end
end

function CrashGuard.Mark(key)  FS.writeFile(GUARD_FILE, key) end
function CrashGuard.Clear()    FS.writeFile(GUARD_FILE, "") end

function CrashGuard.Count()
	local n = 0
	for _ in pairs(CrashGuard.Blacklist) do n += 1 end
	return n
end

function CrashGuard.Reset()
	CrashGuard.Blacklist, CrashGuard.LastCrash = {}, nil
	CrashGuard.Save()
end

------------------------------------------------------------------
-- [5] DUMPER ENGINE
------------------------------------------------------------------
local Dumper = { Running = false, StopRequested = false }

local function safeHooks(hooks)
	local out = {}
	for key, fn in pairs(hooks) do
		out[key] = function(...) pcall(fn, ...) end
	end
	return out
end

local function newContext(rootPath, options, hooks)
	return {
		rootPath    = rootPath,
		options     = options,
		hooks       = hooks,
		phase       = 1,
		stats       = {
			total = 0, scanned = 0, scripts = 0, done = 0,
			decompiled = 0, failed = 0, skipped = 0, written = 0, errors = 0, percent = 0,
		},
		scripts     = {},
		fileLog     = {},
		hierarchy   = {},
		used        = {},
		folderCache = {},
	}
end

local function reportProgress(ctx)
	local s = ctx.stats
	local scan = s.total > 0 and math.clamp(s.scanned / s.total, 0, 1) or 0
	if ctx.phase >= 2 then scan = 1 end
	local work = 0
	if ctx.phase >= 2 then
		work = s.scripts > 0 and (s.done / s.scripts) or 1
	end
	s.percent = scan * 0.3 + work * 0.7
	ctx.hooks.onProgress(s)
end

local function getUsedSet(ctx, path)
	local set = ctx.used[path]
	if not set then
		set = {}
		ctx.used[path] = set
	end
	return set
end

---------------- Phase 1: สแกนโครงสร้าง (ยังไม่ decompile) ----------------
local function scanNode(node, ctx, stack)
	local inst = node.inst
	local okInfo, name, className = pcall(function()
		return inst.Name, inst.ClassName
	end)
	if not okInfo then
		ctx.stats.errors += 1
		return
	end

	if Config.WriteHierarchy and #ctx.hierarchy < Config.MaxHierarchyLines then
		table.insert(ctx.hierarchy, string.rep("    ", node.depth) .. name .. "  [" .. className .. "]")
	end

	local segment = Util.uniqueName(getUsedSet(ctx, node.parentPath), Util.sanitize(name), "")
	local myPath = (node.parentPath == "") and segment or (node.parentPath .. "/" .. segment)
	local isDefault = node.isDefault or Config.RobloxDefaultScripts[name] == true

	if Util.isDumpableScript(inst, className) then
		ctx.stats.scripts += 1
		table.insert(ctx.scripts, {
			inst      = inst,
			className = className,
			fullName  = Util.fullName(inst),
			dir       = node.parentPath,
			fileName  = segment .. "." .. className .. ".lua",
			isDefault = isDefault,
		})
	end

	local okChildren, children = pcall(inst.GetChildren, inst)
	if not okChildren then return end
	for i = #children, 1, -1 do
		table.insert(stack, {
			inst = children[i], parentPath = myPath,
			depth = node.depth + 1, isDefault = isDefault,
		})
	end
end

local function scanTree(rootInst, ctx)
	local stack = { { inst = rootInst, parentPath = "", depth = 0, isDefault = false } }
	while #stack > 0 do
		if Dumper.StopRequested then return end
		local node = table.remove(stack)
		local ok, err = pcall(scanNode, node, ctx, stack)
		if not ok then
			ctx.stats.errors += 1
			warn("[Dumper] Scan error:", err)
		end
		ctx.stats.scanned += 1
		if ctx.stats.scanned % Config.YieldEvery == 0 then
			reportProgress(ctx)
			task.wait()
		end
	end
end

---------------- Phase 2: decompile ทีละตัว ----------------
local function buildHeader(entry)
	return table.concat({
		"--[[",
		"    Dumper v2.0 by arsyny1x",
		"    Path  : " .. entry.fullName,
		"    Class : " .. entry.className,
		"    Date  : " .. os.date("%Y-%m-%d %H:%M:%S"),
		"]]",
		"", "",
	}, "\n")
end

local function buildFailBody(reason)
	return table.concat({
		"-- ==================================================",
		"-- [!] ไม่สามารถ Decompile สคริปต์นี้ได้",
		"-- เหตุผล: " .. string.gsub(tostring(reason), "[\r\n]+", " "),
		"-- ==================================================",
	}, "\n")
end

local function dumpScript(entry, ctx)
	local s = ctx.stats

	-- ข้ามสคริปต์มาตรฐาน Roblox (ไม่เขียนไฟล์)
	if entry.isDefault and ctx.options.skipDefault then
		s.skipped += 1
		return
	end

	local key = CrashGuard.Key(entry.fullName)
	local success, result

	if CrashGuard.Blacklist[key] then
		success, result = false, "อยู่ใน Blacklist (เคยทำให้เกมแครช) จึงข้าม"
		s.skipped += 1
	elseif ctx.options.safeMode then
		success, result = false, "Safe Mode เปิดอยู่ จึงไม่ได้ decompile"
		s.skipped += 1
	elseif not Util.isAlive(entry.inst) then
		success, result = false, "สคริปต์ถูกลบออกจากเกมระหว่างดัมพ์"
		s.failed += 1
	else
		CrashGuard.Mark(key)              -- จดไว้ก่อน ถ้าแครชตรงนี้ ครั้งหน้าจะข้าม
		success, result = Util.decompile(entry.inst)
		CrashGuard.Clear()
		if success then s.decompiled += 1 else s.failed += 1 end
	end

	local content = buildHeader(entry) .. (success and result or buildFailBody(result))
	local dir = ctx.rootPath .. ((entry.dir ~= "") and ("/" .. entry.dir) or "")
	local relPath = ((entry.dir ~= "") and (entry.dir .. "/") or "") .. entry.fileName
	local reason = (not success) and result or nil

	if not FS.ensurePath(dir, ctx.folderCache) then
		s.errors += 1
		table.insert(ctx.fileLog, { path = relPath, ok = false, reason = "makefolder ล้มเหลว" })
		return
	end

	local okWrite, writeErr = FS.writeFile(dir .. "/" .. entry.fileName, content)
	if okWrite then
		s.written += 1
	else
		s.errors += 1
		reason = "writefile ล้มเหลว: " .. tostring(writeErr)
	end

	table.insert(ctx.fileLog, { path = relPath, ok = success and okWrite, reason = reason })
end

---------------- Phase 3: รายงาน ----------------
local function writeReports(ctx, meta)
	local s = ctx.stats
	local lines = {
		"==================================================",
		"         Dumper v2.0 by arsyny1x  - SUMMARY",
		"==================================================",
		"Game        : " .. meta.gameName,
		"PlaceId     : " .. tostring(game.PlaceId),
		"JobId       : " .. tostring(game.JobId),
		"Dump Date   : " .. os.date("%Y-%m-%d %H:%M:%S"),
		"Duration    : " .. Util.formatDuration(meta.duration),
		"Status      : " .. (meta.stopped and "ถูกหยุดโดยผู้ใช้ (ไม่สมบูรณ์)" or "เสร็จสมบูรณ์"),
		"Services    : " .. table.concat(meta.services, ", "),
		"Safe Mode   : " .. (ctx.options.safeMode and "เปิด" or "ปิด"),
		"Skip Default: " .. (ctx.options.skipDefault and "เปิด" or "ปิด"),
		"Decompiler  : " .. (typeof(decompile) == "function" and "พร้อมใช้งาน" or "ไม่รองรับ"),
		"Blacklist   : " .. CrashGuard.Count() .. " รายการ",
		"--------------------------------------------------",
		("Instances scanned : %d / %d"):format(s.scanned, s.total),
		("Scripts found     : %d"):format(s.scripts),
		("Decompiled OK     : %d"):format(s.decompiled),
		("Decompile failed  : %d"):format(s.failed),
		("Skipped           : %d"):format(s.skipped),
		("Files written     : %d"):format(s.written),
		("Errors            : %d"):format(s.errors),
		"--------------------------------------------------",
		"FILE LIST",
		"--------------------------------------------------",
	}
	for _, entry in ipairs(ctx.fileLog) do
		if entry.ok then
			table.insert(lines, "[OK]   " .. entry.path)
		else
			table.insert(lines, "[FAIL] " .. entry.path .. "  ->  " .. tostring(entry.reason or "unknown"))
		end
	end

	FS.writeFile(ctx.rootPath .. "/summary.txt", table.concat(lines, "\n"))
	if Config.WriteHierarchy then
		FS.writeFile(ctx.rootPath .. "/hierarchy.txt", table.concat(ctx.hierarchy, "\n"))
	end
end

---------------- Main ----------------
local function runDump(serviceNames, options, hooks)
	local startClock = os.clock()

	-- path เป็น ASCII ล้วน (ไม่ใช้ชื่อเกม)
	local rootPath = ("%s/Place_%d/%s"):format(Config.RootFolder, game.PlaceId, Util.timestamp())
	local ctx = newContext(rootPath, options, hooks)

  if not FS.ensurePath(rootPath, ctx.folderCache) then
    error(("สร้างโฟลเดอร์หลักไม่สำเร็จ: %s\n(ตรวจสอบว่า Executor รองรับ makefolder/writefile)")
      :format(FS.DisplayPath(rootPath)))
  end

	-- Phase 1
	hooks.onStatus("กำลังนับจำนวน Instance...")
	local services = {}
	for _, name in ipairs(serviceNames) do
		local okSvc, svc = pcall(game.GetService, game, name)
		if okSvc and svc then
			local okDesc, desc = pcall(svc.GetDescendants, svc)
			ctx.stats.total += 1 + ((okDesc and desc) and #desc or 0)
			table.insert(services, { name = name, inst = svc })
		else
			ctx.stats.errors += 1
		end
		task.wait()
	end

	for _, svc in ipairs(services) do
		if Dumper.StopRequested then break end
		hooks.onStatus("กำลังสแกนโครงสร้าง: " .. svc.name)
		scanTree(svc.inst, ctx)
	end

	-- Phase 2
	ctx.phase = 2
	reportProgress(ctx)
	local total = #ctx.scripts
	for i, entry in ipairs(ctx.scripts) do
		if Dumper.StopRequested then break end
		hooks.onStatus(("[%d/%d] กำลังดัมพ์: %s"):format(i, total, entry.fullName))

		local ok, err = pcall(dumpScript, entry, ctx)
		if not ok then
			ctx.stats.errors += 1
			warn("[Dumper] Dump error:", err)
		end

		ctx.stats.done = i
		reportProgress(ctx)
		task.wait(options.safeMode and 0 or Config.DecompileDelay)
	end
	CrashGuard.Clear()

	-- Phase 3
	ctx.phase = 3
	hooks.onStatus("กำลังเขียน summary.txt ...")
	local meta = {
		gameName = Util.getGameName(),
		services = serviceNames,
		stopped  = Dumper.StopRequested,
		duration = os.clock() - startClock,
	}
	writeReports(ctx, meta)
	return ctx.stats, rootPath, meta
end

function Dumper.Start(serviceNames, options, hooks)
	if Dumper.Running then return false end
	Dumper.Running, Dumper.StopRequested = true, false
	local h = safeHooks(hooks)

	task.spawn(function()
		local ok, stats, rootPath, meta = pcall(runDump, serviceNames, options, h)
		Dumper.Running = false
		if ok then
			h.onFinished(stats, rootPath, meta)
		else
			h.onError(tostring(stats))
		end
	end)
	return true
end

function Dumper.Stop()
	if Dumper.Running then Dumper.StopRequested = true end
end

------------------------------------------------------------------
-- [6] UI
------------------------------------------------------------------
local UI = {}

local function create(className, props, children)
	local inst = Instance.new(className)
	for key, value in pairs(props or {}) do
		if key ~= "Parent" then inst[key] = value end
	end
	for _, child in ipairs(children or {}) do child.Parent = inst end
	if props and props.Parent then inst.Parent = props.Parent end
	return inst
end

local function corner(radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius or 8) })
end

local function stroke(color, thickness)
	return create("UIStroke", {
		Color = color, Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function label(props)
	props.BackgroundTransparency = 1
	props.Font           = props.Font or Theme.Font
	props.TextColor3     = props.TextColor3 or Theme.Text
	props.TextSize       = props.TextSize or 14
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return create("TextLabel", props)
end

local function button(props, baseColor)
	props.BackgroundColor3 = baseColor
	props.AutoButtonColor  = false
	props.Font             = props.Font or Theme.FontBold
	props.TextColor3       = props.TextColor3 or Theme.Text
	props.TextSize         = props.TextSize or 14
	local btn = create("TextButton", props, { corner(8) })
	btn:SetAttribute("BaseColor", baseColor)

	btn.MouseEnter:Connect(function()
		if btn.Active then
			local base = btn:GetAttribute("BaseColor") or baseColor
			TweenService:Create(btn, TweenInfo.new(0.12), {
				BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.12),
			}):Play()
		end
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.12), {
			BackgroundColor3 = btn:GetAttribute("BaseColor") or baseColor,
		}):Play()
	end)
	return btn
end

local function makeDraggable(handle, target, connections)
	local state = { Moved = false }
	local dragging, dragStart, startPos = false, nil, nil

	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging, state.Moved = true, false
			dragStart, startPos = input.Position, target.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)

	table.insert(connections, UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - dragStart
			if delta.Magnitude > 5 then state.Moved = true end
			target.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end))
	return state
end

function UI.Mount(gui)
	local candidates = {}
	if typeof(gethui) == "function" then
		local ok, hui = pcall(gethui)
		if ok and hui then table.insert(candidates, hui) end
	end
	local okCore, coreGui = pcall(game.GetService, game, "CoreGui")
	if okCore and coreGui then table.insert(candidates, coreGui) end
	table.insert(candidates, LocalPlayer:WaitForChild("PlayerGui"))

	for _, parent in ipairs(candidates) do
		local ok = pcall(function() gui.Parent = parent end)
		if ok and gui.Parent == parent then return parent end
	end
end

-- position = nil -> ใช้ใน ListLayout, ไม่ nil -> วางตำแหน่งเอง
function UI.Checkbox(parent, text, default, order, position)
	local state = default
	local row = create("TextButton", {
		Size = position and UDim2.new(1, -28, 0, 28) or UDim2.new(1, -4, 0, 28),
		Position = position or UDim2.new(),
		BackgroundColor3 = Theme.PanelLight, AutoButtonColor = false,
		Text = "", LayoutOrder = order or 0, Parent = parent,
	}, { corner(6) })

	local box = create("Frame", {
		Size = UDim2.fromOffset(18, 18), Position = UDim2.new(0, 8, 0.5, -9),
		BackgroundColor3 = Theme.Background, Parent = row,
	}, { corner(4), stroke(Theme.Accent, 1) })

	local mark = label({
		Size = UDim2.fromScale(1, 1), Text = "✓", Font = Theme.FontBold, TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Center, Parent = box,
	})

	label({
		Text = text, Position = UDim2.new(0, 36, 0, 0), Size = UDim2.new(1, -42, 1, 0),
		TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd, Parent = row,
	})

	local function render()
		box.BackgroundColor3 = state and Theme.Accent or Theme.Background
		mark.Visible = state
	end

	row.MouseButton1Click:Connect(function()
		if Dumper.Running then return end
		state = not state
		render()
	end)
	render()

	return {
		Get = function() return state end,
		Set = function(value) state = value; render() end,
	}
end

function UI.Build()
	local refs = { Checkboxes = {}, Connections = {} }

	local gui = create("ScreenGui", {
		Name = Config.GuiName, ResetOnSpawn = false, IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999,
	})
	UI.Mount(gui)
	refs.Gui = gui

	local main = create("Frame", {
		Name = "Main", Size = UDim2.fromOffset(360, 560),
		Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Theme.Background, Parent = gui,
	}, { corner(10), stroke(Theme.Accent, 1.5) })
	refs.Main = main

	-- Title bar
	local titleBar = create("Frame", {
		Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = Theme.Panel, Parent = main,
	}, { corner(10) })
	create("Frame", {
		Size = UDim2.new(1, 0, 0, 10), Position = UDim2.new(0, 0, 1, -10),
		BackgroundColor3 = Theme.Panel, BorderSizePixel = 0, Parent = titleBar,
	})
	create("Frame", {
		Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = titleBar,
	}, { create("UIGradient", { Color = ColorSequence.new(Theme.Accent, Theme.AccentAlt) }) })

	label({
		Text = "◆ Dumper v2.0 by arsyny1x", Font = Theme.FontBold, TextSize = 15,
		Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -100, 1, 0), Parent = titleBar,
	})
	refs.MinBtn = button({
		Text = "–", Size = UDim2.fromOffset(28, 26), Position = UDim2.new(1, -68, 0.5, -13), Parent = titleBar,
	}, Theme.PanelLight)
	refs.CloseBtn = button({
		Text = "×", TextSize = 18, Size = UDim2.fromOffset(28, 26), Position = UDim2.new(1, -36, 0.5, -13), Parent = titleBar,
	}, Theme.Danger)
	makeDraggable(titleBar, main, refs.Connections)

	-- Services
	label({
		Text = "เลือก Service ที่ต้องการ Dump", TextColor3 = Theme.SubText, TextSize = 13,
		Position = UDim2.fromOffset(14, 50), Size = UDim2.new(1, -28, 0, 20), Parent = main,
	})
	local list = create("ScrollingFrame", {
		Position = UDim2.fromOffset(14, 74), Size = UDim2.new(1, -28, 0, 150),
		BackgroundColor3 = Theme.Panel, BorderSizePixel = 0, ScrollBarThickness = 4,
		ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = main,
	}, {
		corner(8),
		create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
		create("UIPadding", {
			PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
			PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
		}),
	})
	for i, name in ipairs(Config.Services) do
		refs.Checkboxes[name] = UI.Checkbox(list, name, Config.DefaultEnabled[name] == true, i)
	end

	refs.SelectAllBtn = button({
		Text = "เลือกทั้งหมด", TextSize = 12, Font = Theme.Font,
		Position = UDim2.fromOffset(14, 230), Size = UDim2.new(0.5, -18, 0, 24), Parent = main,
	}, Theme.PanelLight)
	refs.ClearBtn = button({
		Text = "ล้างการเลือก", TextSize = 12, Font = Theme.Font,
		Position = UDim2.new(0.5, 4, 0, 230), Size = UDim2.new(0.5, -18, 0, 24), Parent = main,
	}, Theme.PanelLight)

	-- Options
	label({
		Text = "ตัวเลือก", TextColor3 = Theme.SubText, TextSize = 13,
		Position = UDim2.fromOffset(14, 262), Size = UDim2.new(1, -28, 0, 18), Parent = main,
	})
	refs.SafeMode = UI.Checkbox(main, "Safe Mode (ไม่ decompile — ไว้ทดสอบ)", false, 0, UDim2.fromOffset(14, 282))
	refs.SkipDefault = UI.Checkbox(main, "ข้ามสคริปต์มาตรฐานของ Roblox", true, 0, UDim2.fromOffset(14, 314))

	-- Progress
	label({
		Text = "ความคืบหน้า", TextColor3 = Theme.SubText, TextSize = 13,
		Position = UDim2.fromOffset(14, 352), Size = UDim2.new(0.4, 0, 0, 18), Parent = main,
	})
	refs.PercentLabel = label({
		Text = "0%", Font = Theme.FontBold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(0.4, 0, 0, 352), Size = UDim2.new(0.6, -14, 0, 18), Parent = main,
	})
	local barBg = create("Frame", {
		Position = UDim2.fromOffset(14, 374), Size = UDim2.new(1, -28, 0, 12),
		BackgroundColor3 = Theme.Panel, Parent = main,
	}, { corner(6) })
	refs.ProgressFill = create("Frame", {
		Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1), Parent = barBg,
	}, { corner(6), create("UIGradient", { Color = ColorSequence.new(Theme.Accent, Theme.AccentAlt) }) })

	refs.StatusLabel = label({
		Text = "พร้อมใช้งาน — เลือก Service แล้วกด Start", TextSize = 12, TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top, TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(14, 394), Size = UDim2.new(1, -28, 0, 34), Parent = main,
	})
	refs.StatsLabel = label({
		Text = "สคริปต์: 0 | สำเร็จ: 0 | ล้มเหลว: 0 | ข้าม: 0", TextColor3 = Theme.SubText, TextSize = 12,
		Position = UDim2.fromOffset(14, 430), Size = UDim2.new(1, -28, 0, 18), Parent = main,
	})

	-- Buttons
	refs.StartBtn = button({
		Text = "▶  Start", Position = UDim2.fromOffset(14, 456),
		Size = UDim2.new(0.5, -18, 0, 40), Parent = main,
	}, Theme.Success)
	refs.StopBtn = button({
		Text = "■  Stop", Position = UDim2.new(0.5, 4, 0, 456),
		Size = UDim2.new(0.5, -18, 0, 40), Parent = main,
	}, Theme.Danger)
	refs.ResetBlacklistBtn = button({
		Text = "ล้าง Blacklist (0)", TextSize = 12, Font = Theme.Font,
		Position = UDim2.fromOffset(14, 504), Size = UDim2.new(1, -28, 0, 24), Parent = main,
	}, Theme.PanelLight)

	label({
		Text = "กด [Insert] หรือปุ่มลอย GD เพื่อซ่อน/แสดง", TextColor3 = Theme.SubText, TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 534), Size = UDim2.new(1, 0, 0, 20), Parent = main,
	})

	-- Floating toggle
	refs.ToggleBtn = button({
		Text = "GD", TextSize = 15, Size = UDim2.fromOffset(48, 48),
		Position = UDim2.new(0, 20, 0.5, -24), Parent = gui,
	}, Theme.Accent)
	refs.ToggleBtn:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(1, 0)
	stroke(Theme.AccentAlt, 2).Parent = refs.ToggleBtn
	refs.ToggleDrag = makeDraggable(refs.ToggleBtn, refs.ToggleBtn, refs.Connections)

	UI.SetRunning(refs, false)
	return refs
end

function UI.SetRunning(refs, running)
	local function setBtn(btn, enabled, color)
		btn.Active = enabled
		local c = enabled and color or Theme.PanelLight
		btn:SetAttribute("BaseColor", c)
		btn.BackgroundColor3 = c
		btn.TextTransparency = enabled and 0 or 0.45
	end
	setBtn(refs.StartBtn, not running, Theme.Success)
	setBtn(refs.StopBtn, running, Theme.Danger)
	refs.StartBtn.Text = running and "กำลังทำงาน..." or "▶  Start"
end

function UI.SetProgress(refs, stats)
	local pct = math.clamp(stats.percent or 0, 0, 1)
	refs.ProgressFill.Size = UDim2.fromScale(pct, 1)
	refs.PercentLabel.Text = ("%d%%  (สคริปต์ %d/%d)"):format(
		math.floor(pct * 100), stats.done or 0, stats.scripts or 0)
	refs.StatsLabel.Text = ("สคริปต์: %d | สำเร็จ: %d | ล้มเหลว: %d | ข้าม: %d"):format(
		stats.scripts or 0, stats.decompiled or 0, stats.failed or 0, stats.skipped or 0)
end

function UI.UpdateBlacklistButton(refs)
	refs.ResetBlacklistBtn.Text = ("ล้าง Blacklist (%d)"):format(CrashGuard.Count())
end

function UI.ShowPopup(refs, title, message, accentColor)
	local old = refs.Gui:FindFirstChild("Popup")
	if old then old:Destroy() end

	local popup = create("Frame", {
		Name = "Popup", Size = UDim2.fromOffset(340, 240),
		Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Theme.Background, ZIndex = 50, Parent = refs.Gui,
	}, { corner(10), stroke(accentColor or Theme.Accent, 2) })

	label({
		Text = title, Font = Theme.FontBold, TextSize = 16, ZIndex = 51,
		TextColor3 = accentColor or Theme.Text, TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 0, 24), Parent = popup,
	})
	label({
		Text = message, TextSize = 13, TextWrapped = true, ZIndex = 51,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(18, 46), Size = UDim2.new(1, -36, 1, -100), Parent = popup,
	})
	local okBtn = button({
		Text = "ตกลง", ZIndex = 51, Size = UDim2.fromOffset(120, 34),
		Position = UDim2.new(0.5, -60, 1, -46), Parent = popup,
	}, accentColor or Theme.Accent)
	okBtn.MouseButton1Click:Connect(function() popup:Destroy() end)
end

------------------------------------------------------------------
-- [7] APP CONTROLLER
------------------------------------------------------------------
local App = {}

function App.ReportResult(stats, rootPath, meta)
	local refs = App.Refs
	local title = meta.stopped and "หยุดการดัมพ์แล้ว" or "ดัมพ์เสร็จสมบูรณ์!"
	local color = meta.stopped and Theme.Warning or Theme.Success

	local message = table.concat({
		("ไฟล์ที่บันทึก: %d ไฟล์"):format(stats.written),
		("Decompile สำเร็จ: %d | ล้มเหลว: %d | ข้าม: %d"):format(stats.decompiled, stats.failed, stats.skipped),
		("Instance ที่สแกน: %d | Error: %d"):format(stats.scanned, stats.errors),
		("ใช้เวลา: %s"):format(Util.formatDuration(meta.duration)),
		"",
		"บันทึกที่: " .. FS.DisplayPath(rootPath),
	}, "\n")

	refs.StatusLabel.Text = (meta.stopped and "■ หยุดแล้ว — " or "✓ เสร็จ — ") .. rootPath
	UI.SetProgress(refs, stats)
	UI.ShowPopup(refs, title, message, color)
	Util.notify("Game Dumper", title .. " (" .. stats.written .. " ไฟล์)")

	print("\n========== [Dumper v2.0 by arsyny1x] ==========")
	print(title)
	print(message)
	print("===============================================\n")
end

function App.StartDump()
	local refs = App.Refs
	if Dumper.Running then return end

  if not FS.Supported then
    UI.ShowPopup(refs, "ไม่รองรับ",
      "Executor ของคุณไม่มีฟังก์ชันเขียนไฟล์\n\n" ..
      "ต้องมี:  writefile + makefolder\n" ..
      "หรือ:   syn.writefile + syn.makefolder\n\n" ..
      "ลองอัปเดต Executor หรือใช้ตัวที่รองรับ",
      Theme.Danger)
    return
  end

	local selected = {}
	for _, name in ipairs(Config.Services) do
		if refs.Checkboxes[name].Get() then table.insert(selected, name) end
	end
	if #selected == 0 then
		refs.StatusLabel.Text = "⚠ กรุณาเลือกอย่างน้อย 1 Service"
		return
	end

	local options = {
		safeMode    = refs.SafeMode.Get(),
		skipDefault = refs.SkipDefault.Get(),
	}

	UI.SetRunning(refs, true)
	UI.SetProgress(refs, {})

	Dumper.Start(selected, options, {
		onStatus = function(text) refs.StatusLabel.Text = text end,
		onProgress = function(stats) UI.SetProgress(refs, stats) end,
		onFinished = function(stats, rootPath, meta)
			UI.SetRunning(refs, false)
			App.ReportResult(stats, rootPath, meta)
		end,
		onError = function(msg)
			UI.SetRunning(refs, false)
			refs.StatusLabel.Text = "✕ เกิดข้อผิดพลาด: " .. msg
			UI.ShowPopup(refs, "เกิดข้อผิดพลาด", msg, Theme.Danger)
			warn("[Dumper] Fatal:", msg)
		end,
	})
end

function App.Destroy()
	Dumper.Stop()
	local refs = App.Refs
	if refs then
		for _, conn in ipairs(refs.Connections) do
			pcall(function() conn:Disconnect() end)
		end
		if refs.Gui then refs.Gui:Destroy() end
	end
	genv.__AdvancedDumper = nil
end

function App.Init()
	CrashGuard.Load()

	local refs = UI.Build()
	App.Refs = refs
	UI.UpdateBlacklistButton(refs)

	local function toggleMain() refs.Main.Visible = not refs.Main.Visible end

	refs.ToggleBtn.MouseButton1Click:Connect(function()
		if refs.ToggleDrag.Moved then return end
		toggleMain()
	end)
	table.insert(refs.Connections, UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Config.ToggleKey and not UserInputService:GetFocusedTextBox() then
			toggleMain()
		end
	end))

	refs.MinBtn.MouseButton1Click:Connect(function() refs.Main.Visible = false end)
	refs.CloseBtn.MouseButton1Click:Connect(App.Destroy)

	refs.SelectAllBtn.MouseButton1Click:Connect(function()
		if Dumper.Running then return end
		for _, cb in pairs(refs.Checkboxes) do cb.Set(true) end
	end)
	refs.ClearBtn.MouseButton1Click:Connect(function()
		if Dumper.Running then return end
		for _, cb in pairs(refs.Checkboxes) do cb.Set(false) end
	end)

	refs.StartBtn.MouseButton1Click:Connect(function()
		if refs.StartBtn.Active then App.StartDump() end
	end)
	refs.StopBtn.MouseButton1Click:Connect(function()
		if Dumper.Running then
			Dumper.Stop()
			refs.StatusLabel.Text = "กำลังหยุด... (รอสคริปต์ปัจจุบันเสร็จ)"
		end
	end)
	refs.ResetBlacklistBtn.MouseButton1Click:Connect(function()
		if Dumper.Running then return end
		CrashGuard.Reset()
		UI.UpdateBlacklistButton(refs)
		refs.StatusLabel.Text = "ล้าง Blacklist เรียบร้อย"
	end)

	-- แจ้งสถานะเริ่มต้น
	if not FS.Supported then
		refs.StatusLabel.Text = "✕ Executor ไม่รองรับ makefolder/writefile"
	elseif CrashGuard.LastCrash then
		local name = string.match(CrashGuard.LastCrash, "|(.+)$") or CrashGuard.LastCrash
		UI.ShowPopup(refs, "ตรวจพบการแครชครั้งก่อน",
			"เกมแครชขณะ decompile:\n" .. name ..
			"\n\nเพิ่มเข้า Blacklist แล้ว ครั้งนี้จะข้ามสคริปต์นี้อัตโนมัติ กด Start ใหม่ได้เลย",
			Theme.Warning)
	elseif typeof(decompile) ~= "function" then
		refs.StatusLabel.Text = "⚠ ไม่พบ decompile() — จะบันทึกแค่โครงสร้าง + คอมเมนต์"
  else
		local mode = Decompiler.resolve()
		local labels = {
			bytefall = "ใช้ ByteFall (decompile ผ่านเซิร์ฟเวอร์ภายนอก)",
			native   = "ใช้ decompile() ของ Executor",
			custom   = "ใช้ Custom Decompiler",
			bytecode = "โหมด Bytecode (บันทึก .luac)",
		}
		refs.StatusLabel.Text = "Decompiler: " .. (labels[mode] or mode)
	end

	genv.__AdvancedDumper = { Destroy = App.Destroy }
	print("[Dumper v2.0 by arsyny1x] โหลดสำเร็จ — กด Insert เพื่อเปิด/ปิด")
end

App.Init()