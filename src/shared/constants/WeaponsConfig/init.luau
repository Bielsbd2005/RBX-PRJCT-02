--!strict
--[[
	Fuente única de verdad de la config de combate de cada arma (replicada, así el
	locker enseña stats sin red). Los Tools no llevan `Configuration`.
	  Definitions/<Category>/<Id>.luau → { WeaponType, Config }; Category e Id salen de la ruta.
	  Schema.luau → claves válidas, tipo y default por WeaponType.

	El id de un Tool es su NOMBRE. La categoría va en el atributo `WeaponCategory`
	(StampTool) porque la carpeta se pierde al clonar a la mochila y "Default" existe
	en Main y en Special; sin atributo se busca por nombre en ese orden.
	Una definición inválida es error en Studio y warn en producción (se registra igual).
]]

local RunService = game:GetService("RunService")

local Types = require(script.Types)
local Schema = require(script.Schema)
local WeaponCategory = require(script.Parent.WeaponCategory)
local ItemsConfig = require(script.Parent.ItemsConfig)

export type WeaponCategory = Types.WeaponCategory
export type WeaponType = Types.WeaponType
export type WeaponConfig = Types.WeaponConfig
export type WeaponDefinition = Types.WeaponDefinition
export type RegisteredWeapon = Types.RegisteredWeapon

local WeaponsConfig = {}

WeaponsConfig.CATEGORY_ATTRIBUTE = "WeaponCategory"

WeaponsConfig.Schema = Schema

local _registry: { [string]: { [string]: RegisteredWeapon } } = {}

local function report(message: string)
	if RunService:IsStudio() then
		error("[WeaponsConfig] " .. message, 0)
	end
	warn("[WeaponsConfig] " .. message)
end

local function registerDefinition(category: WeaponCategory, module: ModuleScript)
	local id = module.Name
	local ok, definition = pcall(require, module)
	if not ok then
		report(string.format("%s/%s no se pudo requerir: %s", category, id, tostring(definition)))
		return
	end
	if type(definition) ~= "table" then
		report(string.format("%s/%s debe devolver una tabla { WeaponType, Config }", category, id))
		return
	end

	local weaponType = definition.WeaponType
	if not Schema.IsWeaponType(weaponType) then
		report(string.format("%s/%s: WeaponType inválido (%s)", category, id, tostring(weaponType)))
		return
	end

	local config = definition.Config
	if type(config) ~= "table" then
		report(string.format("%s/%s: Config debe ser una tabla", category, id))
		return
	end

	local problems = Schema.Validate(weaponType, config)
	if #problems > 0 then
		report(string.format("%s/%s: %s", category, id, table.concat(problems, "; ")))
	end

	local frozenConfig: { [string]: any } = table.clone(config)
	table.freeze(frozenConfig)

	local registered: RegisteredWeapon = table.freeze({
		Category = category,
		Id = id,
		WeaponType = weaponType :: WeaponType,
		Config = frozenConfig :: any,
	}) :: any

	_registry[category][id] = registered
end

local function loadAll()
	local definitionsFolder = script:FindFirstChild("Definitions")
	for _, category in WeaponCategory.ALL do
		_registry[category] = {}
		local folder = if definitionsFolder then definitionsFolder:FindFirstChild(category) else nil
		if not folder then
			warn(string.format("[WeaponsConfig] Sin carpeta Definitions/%s", category))
			continue
		end
		for _, child in folder:GetChildren() do
			if child:IsA("ModuleScript") then
				registerDefinition(category :: WeaponCategory, child)
			end
		end
	end
end

local function warnCatalogWithoutDefinition()
	local missing: { string } = {}
	for _, category in WeaponCategory.ALL do
		local items = (ItemsConfig :: any)[category]
		if type(items) ~= "table" then
			continue
		end
		for weaponId in items do
			if not _registry[category][weaponId] then
				table.insert(missing, category .. "/" .. weaponId)
			end
		end
	end
	if #missing > 0 then
		table.sort(missing)
		warn("[WeaponsConfig] Armas del catálogo sin definición (Definitions/<Category>/<Id>.luau): " .. table.concat(missing, ", "))
	end
end

loadAll()
warnCatalogWithoutDefinition()

function WeaponsConfig.Get(category: string, weaponId: string): RegisteredWeapon?
	local byCategory = _registry[category]
	return if byCategory then byCategory[weaponId] else nil
end

function WeaponsConfig.GetConfig(category: string, weaponId: string): WeaponConfig?
	local definition = WeaponsConfig.Get(category, weaponId)
	return if definition then definition.Config else nil
end

-- Cae al default del Schema de su WeaponType.
function WeaponsConfig.GetValue(category: string, weaponId: string, keyName: string): any
	local definition = WeaponsConfig.Get(category, weaponId)
	if not definition then
		return nil
	end
	local value = (definition.Config :: any)[keyName]
	if value ~= nil then
		return value
	end
	return Schema.GetDefault(definition.WeaponType, keyName)
end

function WeaponsConfig.GetAll(): { [string]: { [string]: RegisteredWeapon } }
	return _registry
end

function WeaponsConfig.GetIds(category: string): { string }
	local ids: { string } = {}
	for id in _registry[category] or {} do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

function WeaponsConfig.StampTool(tool: Instance, category: string)
	tool:SetAttribute(WeaponsConfig.CATEGORY_ATTRIBUTE, category)
end

function WeaponsConfig.ResolveToolIdentity(tool: Instance): (string?, string?)
	local weaponId = tool.Name

	local category = tool:GetAttribute(WeaponsConfig.CATEGORY_ATTRIBUTE)
	if type(category) == "string" and WeaponsConfig.Get(category, weaponId) then
		return category, weaponId
	end

	for _, candidate in WeaponCategory.ALL do
		if WeaponsConfig.Get(candidate, weaponId) then
			return candidate, weaponId
		end
	end

	return nil, nil
end

function WeaponsConfig.GetForTool(tool: Instance): RegisteredWeapon?
	local category, weaponId = WeaponsConfig.ResolveToolIdentity(tool)
	if not category or not weaponId then
		return nil
	end
	return WeaponsConfig.Get(category, weaponId)
end

function WeaponsConfig.GetValueForTool(tool: Instance, keyName: string): any
	local category, weaponId = WeaponsConfig.ResolveToolIdentity(tool)
	if not category or not weaponId then
		return nil
	end
	return WeaponsConfig.GetValue(category, weaponId, keyName)
end

return table.freeze(WeaponsConfig)
