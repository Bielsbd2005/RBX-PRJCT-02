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
	  3. Regenera el modelo de display del locker en
	     Shared.Locker.weapons.<Category>.<Id> a partir del `WeaponModel` de la
	     Tool. La geometría del arma se autora UNA vez, en la Tool.
	  4. Lista cualquier otra Tool con el tag WeaponsSystemWeapon fuera de
	     WeaponTools (prototipos sueltos) para que decidas si migrarla,
	     quitarle el tag o borrarla, y los modelos de display que ya no
	     corresponden a ninguna Tool.

	Es idempotente: se puede volver a ejecutar. Pon DRY_RUN = true para ver
	qué haría sin tocar nada. Recuerda guardar el place después.
]]

local DRY_RUN = false
-- El paso 3 reemplaza sin preguntar los modelos de display que generó él mismo
-- (los marca con el atributo `GeneratedFromWeaponTool`). Los que siguen
-- autorados a mano se respetan y solo se avisa: son irreemplazables si el
-- `WeaponModel` de la Tool no es equivalente, y no están en el repo. Ponlo a
-- true una vez para migrarlos, comprobando antes el listado con DRY_RUN.
local OVERWRITE_HANDAUTHORED = false

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

-- ── Modelos de display del locker ────────────────────────────
--[[
	`Shared.Locker.weapons.<Category>.<Id>` es la geometría pura que enseñan el
	locker (WeaponWrapPreviewer, dentro de un ViewportFrame) y el holster
	(BackWeaponService, soldada a la espalda del rig). No es una Tool a
	propósito: clonar la Tool para algo que sólo se mira arrastraría Handle,
	sonidos y el tag `WeaponsSystemWeapon`.

	Pero tampoco se autora aparte: era la única pieza del arma que había que
	montar dos veces, y las dos copias se desincronizaban. Se GENERA aquí desde
	el `WeaponModel` de la Tool, que es la fuente única.

	Rojo crea las carpetas vacías con ignoreUnknownInstances, así que lo que
	genera este script se queda en el place y no se sobrescribe al sincronizar.
]]
local DISPLAY_ROOT_NAME = "weapons"
local WEAPON_MODEL_NODE_NAME = "WeaponModel"
-- Marca de propiedad: distingue lo que generó este script (reemplazable sin
-- preguntar) de lo que sigue autorado a mano.
local GENERATED_ATTRIBUTE = "GeneratedFromWeaponTool"
-- Las pinta el wrap en runtime sobre la PrimaryPart (CosmeticsTemplates); si se
-- guardó el place tras un playtest pueden haber quedado grabadas en el asset y
-- el display saldría con la skin de otro.
local WRAP_TEXTURE_PREFIX = "ScrollTexture_"

local lockerFolder = ReplicatedStorage.Shared:FindFirstChild("Locker")
local displayRoot = lockerFolder and lockerFolder:FindFirstChild(DISPLAY_ROOT_NAME)
if not displayRoot then
	error("No existe Shared.Locker.weapons: ¿está rojo serve conectado?")
end

local function stripNonDisplayContent(model)
	local strippedScripts = 0
	local strippedTextures = 0

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") then
			-- El holster parentea el clon al character: un LocalScript de la
			-- Tool correría ahí como si el arma estuviera empuñada.
			descendant:Destroy()
			strippedScripts += 1
		elseif descendant:IsA("Texture") and string.sub(descendant.Name, 1, #WRAP_TEXTURE_PREFIX) == WRAP_TEXTURE_PREFIX then
			descendant:Destroy()
			strippedTextures += 1
		end
	end

	return strippedScripts, strippedTextures
end

--[[
	Se genera aunque la Tool no tenga definición de combate: el display depende
	del catálogo (ItemsConfig), no de WeaponsConfig, y un arma que todavía no
	dispara puede estar ya en el locker.
]]
local function generateDisplayModel(tool, category, weaponId)
	local source = tool:FindFirstChild(WEAPON_MODEL_NODE_NAME, true)
	if not source or not source:IsA("Model") then
		warn(string.format(
			"[Migration] %s no tiene un Model '%s': sin modelo de display. El locker y el holster caerán al fallback (Default).",
			tool:GetFullName(), WEAPON_MODEL_NODE_NAME
		))
		return
	end

	local categoryFolder = displayRoot:FindFirstChild(category)
	local existing = categoryFolder and categoryFolder:FindFirstChild(weaponId)
	local isGenerated = existing ~= nil and existing:GetAttribute(GENERATED_ATTRIBUTE) == true

	print(string.format(
		"[Migration] display %s/%s <- %s  existía=%s  generado=%s",
		category, weaponId, source:GetFullName(), tostring(existing ~= nil), tostring(isGenerated)
	))
	if DRY_RUN then
		return
	end

	if existing and not isGenerated and not OVERWRITE_HANDAUTHORED then
		warn(string.format(
			"[Migration] display %s/%s está autorado a mano: no se toca. Comprueba que el WeaponModel de la Tool sirve y pon OVERWRITE_HANDAUTHORED = true para migrarlo.",
			category, weaponId
		))
		return
	end

	if not categoryFolder then
		warn(string.format("[Migration] Shared.Locker.weapons.%s no existía; se crea.", category))
		local created = Instance.new("Folder")
		created.Name = category
		created.Parent = displayRoot
		categoryFolder = created
	end

	local clone = source:Clone()
	clone.Name = weaponId
	clone:SetAttribute(GENERATED_ATTRIBUTE, true)
	local strippedScripts, strippedTextures = stripNonDisplayContent(clone)

	-- Clone preserva PrimaryPart. Sin él los consumidores caen a buscar una
	-- BasePart llamada `primaryPart`/`Main`, y el wrap sobre la Tool
	-- (applyWeaponWrapToTool) es estricto y no-opea.
	if not clone.PrimaryPart then
		warn(string.format(
			"[Migration] %s no tiene PrimaryPart: el wrap no se pintará sobre la Tool y el encuadre del locker dependerá del fallback de partes.",
			source:GetFullName()
		))
	end

	if existing then
		existing:Destroy()
	end
	clone.Parent = categoryFolder

	if strippedScripts > 0 or strippedTextures > 0 then
		print(string.format(
			"[Migration] display %s/%s: %d script(s) y %d textura(s) de wrap eliminadas del clon.",
			category, weaponId, strippedScripts, strippedTextures
		))
	end
end

local root = ServerStorage:FindFirstChild("WeaponTools")
if not root then
	error("No existe ServerStorage.WeaponTools")
end

local CATEGORIES = { "Main", "Special" }

for _, category in CATEGORIES do
	local folder = root:FindFirstChild(category)
	if folder then
		for _, tool in folder:GetChildren() do
			if tool:IsA("Tool") then
				migrateTool(tool, category, tool.Name)
				generateDisplayModel(tool, category, tool.Name)
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

-- Modelos de display sin Tool detrás: armas borradas de WeaponTools o copias
-- antiguas nombradas por el display name del catálogo en vez de por el id. Sólo
-- se avisa —borrarlas es decisión tuya—, pero ojo: la cadena de resolución
-- prefiere el id, así que una copia por nombre ya no se usa para nada.
for _, category in CATEGORIES do
	local displayFolder = displayRoot:FindFirstChild(category)
	local toolFolder = root:FindFirstChild(category)
	if displayFolder then
		for _, node in displayFolder:GetChildren() do
			local tool = toolFolder and toolFolder:FindFirstChild(node.Name)
			if not (tool and tool:IsA("Tool")) then
				warn(string.format(
					"[Migration] display %s/%s no corresponde a ninguna Tool de WeaponTools.%s: sobra o está mal nombrado (debe llamarse como el id del arma).",
					category, node.Name, category
				))
			end
		end
	end
end

print(if DRY_RUN then "[Migration] DRY_RUN: nada modificado." else "[Migration] Hecho. Guarda el place.")
