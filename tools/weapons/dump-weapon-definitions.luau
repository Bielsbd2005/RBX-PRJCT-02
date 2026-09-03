--[[
	tools/weapons/dump-weapon-definitions.luau  (lune)

	Genera src/shared/constants/WeaponsConfig/Definitions/<Category>/<Id>.luau
	a partir de las `Configuration` de los Tools de ServerStorage.WeaponTools
	de un place guardado (.rbxl / .rbxlx).

	Uso:
	  lune run tools/weapons/dump-weapon-definitions.luau -- <ruta al .rbxl> [--dry-run]

	Reglas:
	  • Sólo se emiten claves que existan en el esquema del WeaponType del
	    Tool (atributo `WeaponType`). Las demás se listan como descartadas.
	  • Las claves se emiten ordenadas alfabéticamente (diff estable).
	  • Se sobreescribe la definición existente del arma; no se borran las que
	    no aparezcan en el place.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Schema = require("../../src/shared/constants/WeaponsConfig/Schema")

local OUTPUT_ROOT = "src/shared/constants/WeaponsConfig/Definitions"
local CATEGORIES = { "Main", "Special" }

-- `lune run script -- args` puede pasar el propio "--" como primer argumento.
local args = table.clone(process.args)
if args[1] == "--" then
	table.remove(args, 1)
end
local placePath = args[1]
local dryRun = table.find(args, "--dry-run") ~= nil
if not placePath or placePath:sub(1, 2) == "--" then
	print("Uso: lune run tools/weapons/dump-weapon-definitions.luau -- <place.rbxl> [--dry-run]")
	process.exit(1)
end

local game = roblox.deserializePlace(fs.readFile(placePath))
local root = game:GetService("ServerStorage"):FindFirstChild("WeaponTools")
if not root then
	print("El place no tiene ServerStorage.WeaponTools")
	process.exit(1)
end

local function formatNumber(n: number): string
	if n ~= n or n == math.huge or n == -math.huge then
		error(string.format("valor numérico no serializable: %s", tostring(n)))
	end
	if math.floor(n) == n and math.abs(n) < 2 ^ 53 then
		return string.format("%d", n)
	end
	-- 17 dígitos significativos: round-trip exacto de un double.
	local s = string.format("%.17g", n)
	-- Preferir la representación corta si round-tripea.
	for digits = 1, 16 do
		local short = string.format("%." .. digits .. "g", n)
		if tonumber(short) == n then
			s = short
			break
		end
	end
	if not s:find("[%.eE]") then
		s ..= ".0"
	end
	return s
end

local function formatValue(value: any): string
	local t = type(value)
	if t == "number" then
		return formatNumber(value)
	elseif t == "string" then
		return string.format("%q", value)
	elseif t == "boolean" then
		return tostring(value)
	end
	error("tipo no soportado: " .. t)
end

local function renderDefinition(category: string, id: string, weaponType: string, config: { [string]: any }): string
	local keys = {}
	for name in config do
		table.insert(keys, name)
	end
	table.sort(keys)

	local lines = {
		"--!strict",
		"-- Generado por tools/weapons/dump-weapon-definitions.luau a partir de",
		string.format("-- ServerStorage.WeaponTools.%s.%s. Editar a mano es válido: este", category, id),
		"-- fichero ES la fuente de verdad. Claves y defaults: WeaponsConfig/Schema.luau.",
		"local Types = require(script.Parent.Parent.Parent.Types)",
		"",
		"return {",
		string.format("\tWeaponType = %q,", weaponType),
		"\tConfig = {",
	}
	for _, name in keys do
		table.insert(lines, string.format("\t\t%s = %s,", name, formatValue(config[name])))
	end
	table.insert(lines, "\t},")
	table.insert(lines, "} :: Types.WeaponDefinition")
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

local written, dropped = 0, {}

for _, category in CATEGORIES do
	local folder = root:FindFirstChild(category)
	if not folder then
		print(string.format("  (sin carpeta WeaponTools.%s)", category))
		continue
	end

	for _, tool in folder:GetChildren() do
		if not tool:IsA("Tool") then
			continue
		end

		local outDir = string.format("%s/%s", OUTPUT_ROOT, category)
		local outPath = string.format("%s/%s.luau", outDir, tool.Name)
		local configuration = tool:FindFirstChildOfClass("Configuration")

		-- Tool ya migrada (sin Configuration) con definición existente: nada que
		-- volcar, la definición es la fuente de verdad.
		if not configuration and fs.isFile(outPath) then
			print(string.format("  ok   %s/%s ya migrada (definición existente)", category, tool.Name))
			continue
		end

		local weaponType = tool:GetAttribute("WeaponType")
		if not Schema.IsWeaponType(weaponType) then
			print(string.format("  SKIP %s/%s: atributo WeaponType inválido (%s); ponlo en la Tool (BulletWeapon | BowWeapon)", category, tool.Name, tostring(weaponType)))
			continue
		end

		local config = {}
		if configuration then
			for _, child in configuration:GetChildren() do
				local ok, value = pcall(function()
					return child.Value
				end)
				if not ok then
					continue
				end
				local spec = Schema.GetKeySpec(weaponType, child.Name)
				if not spec then
					table.insert(dropped, string.format("%s/%s.%s (no está en el esquema de %s)", category, tool.Name, child.Name, weaponType))
				elseif #Schema.Validate(weaponType, { [child.Name] = value }) > 0 then
					table.insert(dropped, string.format("%s/%s.%s (tipo %s, esperado %s)", category, tool.Name, child.Name, typeof(value), spec.type))
				else
					config[child.Name] = value
				end
			end
		end

		local source = renderDefinition(category, tool.Name, weaponType, config)
		if dryRun then
			print(string.format("---- %s\n%s", outPath, source))
		else
			if not fs.isDir(outDir) then
				fs.writeDir(outDir)
			end
			fs.writeFile(outPath, source)
			print(string.format("  wrote %s", outPath))
		end
		written += 1
	end
end

print(string.format("%d definiciones %s.", written, if dryRun then "(dry-run)" else "escritas"))
if #dropped > 0 then
	print("Claves descartadas (ningún código las lee):")
	for _, line in dropped do
		print("  - " .. line)
	end
end
