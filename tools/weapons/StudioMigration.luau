--[[
	tools/weapons/StudioMigration.luau
	Pegar en la barra de comandos de Studio tras crear/editar definiciones en
	Definitions/<Category>/<Id>.luau y haber sincronizado con Rojo. Volver a
	ejecutarlo es la forma de dar de alta un arma nueva creada en Studio.

	Qué hace, por cada Tool de ServerStorage.WeaponTools.<Category>.<Id>:
	  1. Estampa el atributo `WeaponCategory` (el id es el nombre del Tool). Es
	     lo único que no se puede deducir del clon en runtime, porque la carpeta
	     se pierde al clonar el arma a la mochila; los clones lo heredan.
	  2. Elimina lo que la definición ya cubre SI existe una definición para esa
	     arma en Shared.constants.WeaponsConfig: la `Configuration` legacy, el
	     atributo `WeaponType` (el tipo lo dicta la definición), el StringValue
	     `AmmoType` (nadie lo lee) y los atributos `CurrentAmmo` / `IsReloading`
	     (los escribe BaseWeapon en runtime desde la definición, escalados por
	     nivel; autorarlos a mano solo servía para que se desincronizaran) y el
	     `WeaponId` que estampaban versiones anteriores de este script.
	     Si no existe definición, no toca nada y avisa: esa Tool no se
	     instanciará como arma hasta tenerla.
	  3. Lista cualquier otra Tool con el tag WeaponsSystemWeapon fuera de
	     WeaponTools (prototipos sueltos) para que decidas si migrarla,
	     quitarle el tag o borrarla.

	Es idempotente: se puede volver a ejecutar. Pon DRY_RUN = true para ver
	qué haría sin tocar nada. Recuerda guardar el place después.
]]

local DRY_RUN = false

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

-- No se hace require de WeaponsConfig a propósito: en la Command Bar el
-- require se cachea, y un registro cargado antes de sincronizar definiciones
-- nuevas seguiría diciendo que no existen. Se mira el árbol directamente.
local WeaponsConfigFolder = ReplicatedStorage.Shared.constants.WeaponsConfig
local Definitions = WeaponsConfigFolder:FindFirstChild("Definitions")
if not Definitions then
	error("No existe WeaponsConfig.Definitions: ¿está rojo serve conectado?")
end

local function hasDefinitionFor(category, weaponId)
	local folder = Definitions:FindFirstChild(category)
	local module = folder and folder:FindFirstChild(weaponId)
	return module ~= nil and module:IsA("ModuleScript")
end

local function migrateTool(tool, category, weaponId)
	local hasDefinition = hasDefinitionFor(category, weaponId)
	local configuration = tool:FindFirstChildOfClass("Configuration")

	print(string.format(
		"[Migration] %s -> %s/%s  definición=%s  Configuration=%s",
		tool:GetFullName(), category, weaponId, tostring(hasDefinition), tostring(configuration ~= nil)
	))
	if DRY_RUN then
		return
	end

	if not hasDefinition then
		warn(string.format("[Migration] %s/%s sin definición: no se toca. Crea Definitions/%s/%s.luau y vuelve a ejecutar.", category, weaponId, category, weaponId))
		return
	end

	-- Mismo atributo que estampa WeaponsConfig.StampTool en runtime.
	tool:SetAttribute("WeaponCategory", category)
	-- Redundantes: el id es el nombre del Tool, el tipo lo dicta la definición,
	-- y CurrentAmmo/IsReloading los escribe BaseWeapon al instanciar el arma
	-- (CurrentAmmo = AmmoCapacity de la definición, ya escalado por nivel).
	tool:SetAttribute("WeaponId", nil)
	tool:SetAttribute("WeaponType", nil)
	tool:SetAttribute("CurrentAmmo", nil)
	tool:SetAttribute("IsReloading", nil)
	if configuration then
		configuration:Destroy()
	end
	-- Resto del template original de las Tools: ningún código lo lee.
	local ammoType = tool:FindFirstChild("AmmoType")
	if ammoType and ammoType:IsA("StringValue") then
		ammoType:Destroy()
	end
end

local root = ServerStorage:FindFirstChild("WeaponTools")
if not root then
	error("No existe ServerStorage.WeaponTools")
end

for _, category in { "Main", "Special" } do
	local folder = root:FindFirstChild(category)
	if folder then
		for _, tool in folder:GetChildren() do
			if tool:IsA("Tool") then
				migrateTool(tool, category, tool.Name)
			end
		end
	end
end

-- Tools con el tag del WeaponsSystem fuera del catálogo: no tienen definición
-- y no se instanciarán. Migrarlas a WeaponTools, quitarles el tag o borrarlas.
local CollectionService = game:GetService("CollectionService")
for _, tagged in CollectionService:GetTagged("WeaponsSystemWeapon") do
	if tagged:IsA("Tool") and not tagged:IsDescendantOf(root) then
		warn(string.format("[Migration] Tool suelta con tag WeaponsSystemWeapon: %s (sin definición; no se instanciará).", tagged:GetFullName()))
	end
end

print(if DRY_RUN then "[Migration] DRY_RUN: nada modificado." else "[Migration] Hecho. Guarda el place.")
