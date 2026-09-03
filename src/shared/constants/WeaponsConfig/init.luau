--!strict
--[[
	WeaponsConfig (Shared/constants/WeaponsConfig)
	Fuente única de verdad de la configuración de COMBATE de cada arma.

	Antes cada Tool de ServerStorage.WeaponTools llevaba una `Configuration`
	con ValueBases que BaseWeapon escuchaba. Eso vivía en el .rbxl (sin diff ni
	review), no se replicaba al cliente (el locker necesitaba un round-trip de
	red para enseñar stats) y duplicaba defaults en varios sitios.

	Ahora:
	  • Definitions/<Category>/<Id>.luau  — un módulo por arma. Devuelve
	    { WeaponType, Config } (ver Types.luau). Category e Id salen de la ruta.
	  • Schema.luau   — claves válidas, tipo y default POR TIPO DE ARMA.
	  • DisplayStats  — stats derivados para UI (locker), sin red.

	Identidad de un Tool en runtime:
	  Los templates de ServerStorage.WeaponTools y los clones que reparte el
	  servidor (LoadoutService, BotAI) llevan los atributos `WeaponCategory` y
	  `WeaponId` (ver StampTool). Como respaldo (Tools colocadas a mano para
	  probar) se acepta sólo Tool.Name, buscando en Main y luego Special. Un
	  Tool sin definición no se instancia como arma (WeaponsSystem avisa).

	Validación:
	  Al cargar se valida cada definición contra el esquema. En Studio un
	  problema es un error (falla rápido); en producción es un warn y la
	  definición se registra igual.
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

-- Atributos que identifican el arma de un Tool clonado (los estampa el server).
WeaponsConfig.CATEGORY_ATTRIBUTE = "WeaponCategory"
WeaponsConfig.ID_ATTRIBUTE = "WeaponId"

WeaponsConfig.Schema = Schema

-- ── Carga ────────────────────────────────────────────────────

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

-- Un arma del catálogo (ItemsConfig) sin definición jugará con la
-- Configuration legacy de su Tool (o con defaults si tampoco la tiene).
-- Se avisa una vez, consolidado, para que no pase desapercibido.
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

-- ── Consulta ─────────────────────────────────────────────────

--- Definición registrada de un arma, o nil si no existe.
function WeaponsConfig.Get(category: string, weaponId: string): RegisteredWeapon?
	local byCategory = _registry[category]
	return if byCategory then byCategory[weaponId] else nil
end

--- Config de un arma (tabla congelada), o nil si no hay definición.
function WeaponsConfig.GetConfig(category: string, weaponId: string): WeaponConfig?
	local definition = WeaponsConfig.Get(category, weaponId)
	return if definition then definition.Config else nil
end

--[[
	Valor de una clave para un arma: lo definido o, si no está, el default del
	esquema de su WeaponType. nil si el arma no existe o la clave es desconocida.
]]
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

--- Todas las definiciones: { [category] = { [weaponId] = RegisteredWeapon } }.
function WeaponsConfig.GetAll(): { [string]: { [string]: RegisteredWeapon } }
	return _registry
end

--- Ids de las armas definidas en una categoría (orden alfabético).
function WeaponsConfig.GetIds(category: string): { string }
	local ids: { string } = {}
	for id in _registry[category] or {} do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- ── Identidad de Tools ───────────────────────────────────────

--- Estampa la identidad en un Tool clonado para que cliente y servidor la resuelvan igual.
function WeaponsConfig.StampTool(tool: Instance, category: string, weaponId: string)
	tool:SetAttribute(WeaponsConfig.CATEGORY_ATTRIBUTE, category)
	tool:SetAttribute(WeaponsConfig.ID_ATTRIBUTE, weaponId)
end

--[[
	Resuelve (category, weaponId) de un Tool. Orden:
	  1. Atributos WeaponCategory + WeaponId.
	  2. Tool.Name buscado en Main y luego en Special (Tools sin estampar).
	Devuelve nil, nil si no hay ninguna definición que encaje.
]]
function WeaponsConfig.ResolveToolIdentity(tool: Instance): (string?, string?)
	local category = tool:GetAttribute(WeaponsConfig.CATEGORY_ATTRIBUTE)
	local weaponId = tool:GetAttribute(WeaponsConfig.ID_ATTRIBUTE)
	if type(category) == "string" and type(weaponId) == "string" and WeaponsConfig.Get(category, weaponId) then
		return category, weaponId
	end

	for _, candidate in WeaponCategory.ALL do
		if WeaponsConfig.Get(candidate, tool.Name) then
			return candidate, tool.Name
		end
	end

	return nil, nil
end

--- Definición del arma que representa un Tool, o nil.
function WeaponsConfig.GetForTool(tool: Instance): RegisteredWeapon?
	local category, weaponId = WeaponsConfig.ResolveToolIdentity(tool)
	if not category or not weaponId then
		return nil
	end
	return WeaponsConfig.Get(category, weaponId)
end

--- Valor (o default del esquema) de una clave para el arma de un Tool; nil si no se resuelve.
function WeaponsConfig.GetValueForTool(tool: Instance, keyName: string): any
	local category, weaponId = WeaponsConfig.ResolveToolIdentity(tool)
	if not category or not weaponId then
		return nil
	end
	return WeaponsConfig.GetValue(category, weaponId, keyName)
end

return table.freeze(WeaponsConfig)
