--[[
	Mide, por función, los locales activos a la vez y los upvalues de cada archivo de
	src/ compilándolo con @lune/luau y leyendo el bytecode. Luau falla al cargar un
	script con una función de más de 200 locales ("Out of local registers") o 200
	upvalues, y no avisa antes: esto enseña qué funciones se acercan.

	Uso, desde la raíz del repo: lune run tools/luau/MeasureLocals.luau
]]
local luau = require("@lune/luau")
local fs = require("@lune/fs")
local process = require("@lune/process")

local function readVarInt(b, pos)
  local result, shift = 0, 0
  while true do
    local byte = buffer.readu8(b, pos); pos += 1
    result = bit32.bor(result, bit32.lshift(bit32.band(byte, 127), shift))
    shift += 7
    if bit32.band(byte, 128) == 0 then break end
  end
  return result, pos
end

local function parse(bc)
  local b = buffer.fromstring(bc)
  local pos = 0
  local version = buffer.readu8(b, pos); pos += 1
  if version == 0 then return nil, buffer.readstring(b, 1, buffer.len(b) - 1) end
  local typesVersion = 0
  if version >= 4 then typesVersion = buffer.readu8(b, pos); pos += 1 end
  local nstr; nstr, pos = readVarInt(b, pos)
  local strings = {}
  for i = 1, nstr do
    local len; len, pos = readVarInt(b, pos)
    strings[i] = buffer.readstring(b, pos, len); pos += len
  end
  if typesVersion == 3 then
    while true do
      local idx; idx, pos = readVarInt(b, pos)
      if idx == 0 then break end
      local _; _, pos = readVarInt(b, pos)
    end
  end
  local nprotos; nprotos, pos = readVarInt(b, pos)
  local protos = {}
  for p = 1, nprotos do
    local maxstack = buffer.readu8(b, pos); pos += 1
    local numparams = buffer.readu8(b, pos); pos += 1
    local nups = buffer.readu8(b, pos); pos += 1
    local _isvararg = buffer.readu8(b, pos); pos += 1
    if version >= 4 then
      pos += 1 -- flags
      local tsize; tsize, pos = readVarInt(b, pos); pos += tsize
    end
    local sizecode; sizecode, pos = readVarInt(b, pos)
    pos += sizecode * 4
    local sizek; sizek, pos = readVarInt(b, pos)
    for _ = 1, sizek do
      local t = buffer.readu8(b, pos); pos += 1
      if t == 0 then
      elseif t == 1 then pos += 1
      elseif t == 2 then pos += 8
      elseif t == 3 then local _; _, pos = readVarInt(b, pos)
      elseif t == 4 then pos += 4
      elseif t == 5 then
        local n; n, pos = readVarInt(b, pos)
        for _ = 1, n do local _; _, pos = readVarInt(b, pos) end
      elseif t == 6 then local _; _, pos = readVarInt(b, pos)
      elseif t == 7 then pos += 16
      else error("unknown constant type " .. t) end
    end
    local sizep; sizep, pos = readVarInt(b, pos)
    for _ = 1, sizep do local _; _, pos = readVarInt(b, pos) end
    local linedefined; linedefined, pos = readVarInt(b, pos)
    local nameref; nameref, pos = readVarInt(b, pos)
    local hasline = buffer.readu8(b, pos); pos += 1
    if hasline ~= 0 then
      local gap = buffer.readu8(b, pos); pos += 1
      local intervals = bit32.rshift(sizecode - 1, gap) + 1
      pos += sizecode
      pos += intervals * 4
    end
    local hasdebug = buffer.readu8(b, pos); pos += 1
    local nlocvars = 0
    local events = {}
    if hasdebug ~= 0 then
      nlocvars, pos = readVarInt(b, pos)
      for _ = 1, nlocvars do
        local n, sp, ep; n, pos = readVarInt(b, pos); sp, pos = readVarInt(b, pos); ep, pos = readVarInt(b, pos); pos += 1
        table.insert(events, { sp, 1 }); table.insert(events, { ep, -1 })
      end
      local nupn; nupn, pos = readVarInt(b, pos)
      for _ = 1, nupn do local _; _, pos = readVarInt(b, pos) end
    end
    table.sort(events, function(a, c) if a[1] == c[1] then return a[2] < c[2] end return a[1] < c[1] end)
    local cur, maxlive = 0, 0
    for _, e in events do cur += e[2]; if cur > maxlive then maxlive = cur end end
    protos[p] = { maxlive = maxlive, maxstack = maxstack, nups = nups, line = linedefined, name = nameref > 0 and strings[nameref] or "<anon>", locvars = nlocvars, params = numparams }
  end
  return protos
end

local files = {}
local function walk(dir)
  for _, name in fs.readDir(dir) do
    local p = dir .. "/" .. name
    if fs.isDir(p) then walk(p)
    elseif name:match("%.luau?$") then table.insert(files, p) end
  end
end
walk("src")
table.sort(files)

local rows = {}
local errors = {}
for _, f in files do
  local src = fs.readFile(f)
  local ok, bc = pcall(luau.compile, src, { optimizationLevel = 2, debugLevel = 2, coverageLevel = 0 })
  if not ok then table.insert(errors, f .. ": " .. tostring(bc)) continue end
  local protos, err = parse(bc)
  if not protos then table.insert(errors, f .. ": " .. tostring(err)) continue end
  for _, pr in protos do
    table.insert(rows, { file = f, name = pr.name, line = pr.line, regs = pr.maxstack, nups = pr.nups, live = pr.maxlive })
  end
end
table.sort(rows, function(a, b) return a.live > b.live end)
print("== Top locales activos a la vez (límite 200: 'Out of local registers') ==")
for i = 1, 20 do local r = rows[i]; if r then print(string.format("%3d locals  %3d regs  %3d ups  %s:%d %s", r.live, r.regs, r.nups, r.file, r.line, r.name)) end end
table.sort(rows, function(a, b) return a.regs > b.regs end)
print("== Top registros (límite 255) ==")
for i = 1, 10 do local r = rows[i]; if r then print(string.format("%3d regs  %3d locals  %s:%d %s", r.regs, r.live, r.file, r.line, r.name)) end end
table.sort(rows, function(a, b) return a.nups > b.nups end)
print("== Top upvalues (límite 200) ==")
for i = 1, 15 do local r = rows[i]; if r then print(string.format("%3d ups  %3d regs  %s:%d %s", r.nups, r.regs, r.file, r.line, r.name)) end end
print("== Errores de compilación ==")
for _, e in errors do print(e) end
print("files=" .. #files .. " protos=" .. #rows)
