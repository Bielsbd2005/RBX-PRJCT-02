--!strict
--[[
	LoadoutService.luau
	Gestión de loadout de partida: armas (main + special), wraps,
	sombreros (hats) y caras (faces). Extraído de MatchService para
	mantener responsabilidades separadas.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local InventoryRepository = require(Shared.data.InventoryRepository)
local WeaponCategory = require(Shared.constants.WeaponCategory)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local WeaponsConfig = require(Shared.constants.WeaponsConfig)
local CosmeticsTemplates = require(Shared.Locker.CosmeticsTemplates)
local BackWeaponService = require(script.Parent:WaitForChild("BackWeaponService"))

local LoadoutService = {}

-- ── Constantes ───────────────────────────────────────────────
local WEAPON_TOOLS_ROOT_NAME = "WeaponTools"
local BODIES_ROOT_NAME = "Bodies"
local DEFAULT_BODY_ID = "Default"
local MATCH_BODY_CLONE_ATTRIBUTE = "MatchBodyClone"
local MATCH_LOADOUT_TOOL_ATTRIBUTE = "MatchLoadoutTool"
local MATCH_LOADOUT_HAT_ATTRIBUTE = "MatchLoadoutHat"

-- ── Helpers internos ─────────────────────────────────────────

local function _getOptionalString(value: any): string?
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

-- Defense-in-depth: aunque ShopService valide ownership en la compra/equip,
-- si una sola capa upstream falla (typo en path, race en BatchUpdate, exploit
-- de mutación directa de Loadout), aquí se rechaza al equipar. Delegamos en
-- InventoryRepository para consistencia con el resto de los services.
local _ownsWeapon = InventoryRepository.ownsWeapon
local _ownsWeaponWrap = InventoryRepository.ownsWeaponWrap

local function _getWeaponToolsRoot(): Folder?
	local root = ServerStorage:FindFirstChild(WEAPON_TOOLS_ROOT_NAME)
	if root and root:IsA("Folder") then
		return root
	end
	if root ~= nil then
		warn(string.format("[LoadoutService] ServerStorage.%s existe pero no es Folder.", WEAPON_TOOLS_ROOT_NAME))
	end
	return nil
end

local function _findLoadoutToolTemplate(loadoutCategory: WeaponCategory.WeaponCategory, weaponId: string): Tool?
	if weaponId == "" then
		return nil
	end

	local root = _getWeaponToolsRoot()
	if not root then
		return nil
	end

	-- Ruta canónica: ServerStorage.WeaponTools.<categoría>.<weaponId>
	local byCategory = root:FindFirstChild(loadoutCategory)
	if byCategory then
		local direct = byCategory:FindFirstChild(weaponId)
		if direct and direct:IsA("Tool") then
			return direct
		end
	end

	return nil
end

local function _clearMatchLoadoutHat(character: Model)
	for _, child in character:GetChildren() do
		if child:IsA("Accessory") and child:GetAttribute(MATCH_LOADOUT_HAT_ATTRIBUTE) == true then
			child:Destroy()
		end
	end
end

-- Resuelve el wrap equipado para un arma concreta. Sin fallback al slot
-- `wrapsTable.Default`: esa entrada es la slot del arma con id "Default", no
-- un default que se propaga al resto de armas. Equipar es estrictamente
-- per-weapon. Un wrap global del Battle Pass solo otorga *ownership* para
-- todas las armas; equiparlo a cada una sigue siendo manual vía el locker.
local function _resolveWeaponWrapForLoadout(profileData: any, loadoutCategory: WeaponCategory.WeaponCategory, weaponId: string): string
	local loadout = profileData.Loadout
	if type(loadout) ~= "table" then
		return ItemDefaults.ITEM_ID
	end

	local wrapsTableKey = if loadoutCategory == WeaponCategory.MAIN then "MainWeaponWraps" else "SpecialWeaponWraps"
	local wrapsTableAny = loadout[wrapsTableKey]
	if type(wrapsTableAny) ~= "table" then
		return ItemDefaults.ITEM_ID
	end

	local wrapsTable = wrapsTableAny :: { [string]: any }
	local resolvedByWeapon = _getOptionalString(wrapsTable[weaponId])
	if resolvedByWeapon and _ownsWeaponWrap(profileData, loadoutCategory, weaponId, resolvedByWeapon) then
		return resolvedByWeapon
	end

	return ItemDefaults.ITEM_ID
end

local function _clearMatchLoadoutTools(player: Player)
	local containers = {
		player:FindFirstChild("Backpack"),
		player:FindFirstChild("StarterGear"),
		player.Character,
	}

	for _, container in containers do
		if not container then
			continue
		end
		for _, child in container:GetChildren() do
			if child:IsA("Tool") and child:GetAttribute(MATCH_LOADOUT_TOOL_ATTRIBUTE) == true then
				child:Destroy()
			end
		end
	end
end

-- Devuelve (éxito, reintentable, mainWeaponId, slots). `slots` lleva arma+wrap
-- ya resueltos de ambas categorías; lo consume BackWeaponService para holsterar
-- la que no se equipe.
local function _grantMatchLoadoutTools(
	player: Player,
	dataService: any
): (boolean, boolean, string?, BackWeaponService.Slots?)
	local profile = if dataService then dataService:GetProfile(player) else nil
	if not profile or not profile.Data or not profile.Data.Loadout then
		return false, true, nil, nil
	end

	local profileData = profile.Data
	local loadout = profileData.Loadout
	local mainWeaponId = if type(loadout.MainWeapon) == "string" and loadout.MainWeapon ~= "" then loadout.MainWeapon else ItemDefaults.ITEM_ID
	local specialWeaponId = if type(loadout.SpecialWeapon) == "string" and loadout.SpecialWeapon ~= "" then loadout.SpecialWeapon else ItemDefaults.ITEM_ID

	-- Defense-in-depth: rechazar weapon ID que no esté en el inventario.
	-- Mantiene al jugador con la weapon "Default" en lugar de equiparle algo
	-- que no compró, si ShopService o el flujo de equip dejaron el Loadout
	-- en un estado inválido (race, exploit, profile corrupto).
	if not _ownsWeapon(profileData, WeaponCategory.MAIN, mainWeaponId) then
		warn(string.format("[LoadoutService] %s tiene Loadout.MainWeapon=%s pero no lo posee — fallback a Default.", player.Name, mainWeaponId))
		mainWeaponId = ItemDefaults.ITEM_ID
	end
	if not _ownsWeapon(profileData, WeaponCategory.SPECIAL, specialWeaponId) then
		warn(string.format("[LoadoutService] %s tiene Loadout.SpecialWeapon=%s pero no lo posee — fallback a Default.", player.Name, specialWeaponId))
		specialWeaponId = ItemDefaults.ITEM_ID
	end

	local mainWrapId = _resolveWeaponWrapForLoadout(profileData, WeaponCategory.MAIN, mainWeaponId)
	local specialWrapId = _resolveWeaponWrapForLoadout(profileData, WeaponCategory.SPECIAL, specialWeaponId)

	local backpackNode = player:WaitForChild("Backpack", 1)
	local backpack = if backpackNode and backpackNode:IsA("Backpack") then backpackNode else nil
	if not backpack then
		return false, true, nil, nil
	end

	_clearMatchLoadoutTools(player)

	local function cloneIntoInventory(loadoutCategory: WeaponCategory.WeaponCategory, weaponId: string, wrapId: string): boolean
		local template = _findLoadoutToolTemplate(loadoutCategory, weaponId)
		if not template then
			warn(string.format("[LoadoutService] Tool no encontrada para %s/%s en ServerStorage.%s.", loadoutCategory, weaponId, WEAPON_TOOLS_ROOT_NAME))
			return false
		end

		local backpackClone = template:Clone()
		CosmeticsTemplates.applyWeaponWrapToTool(backpackClone, wrapId)
		backpackClone:SetAttribute(MATCH_LOADOUT_TOOL_ATTRIBUTE, true)
		-- Categoría de la slot ("Main"/"Special"). El nombre de la Tool es el
		-- weaponId, que no basta: el mismo id existe en los dos catálogos
		-- ("Default"). Con ella, BaseWeapon y el Hotbar resuelven la definición de
		-- WeaponsConfig en cliente y servidor, y BackWeaponService sabe qué arma
		-- cuelga de la espalda. Se reestampa aunque el template ya la traiga:
		-- aquí la categoría es autoritativa.
		WeaponsConfig.StampTool(backpackClone, loadoutCategory)
		backpackClone.Parent = backpack
		return true
	end

	local mainOk = cloneIntoInventory(WeaponCategory.MAIN, mainWeaponId, mainWrapId)
	local specialOk = cloneIntoInventory(WeaponCategory.SPECIAL, specialWeaponId, specialWrapId)
	if not mainOk or not specialOk then
		return false, false, nil, nil
	end

	local slots: BackWeaponService.Slots = {
		[WeaponCategory.MAIN] = { weaponId = mainWeaponId, wrapId = mainWrapId },
		[WeaponCategory.SPECIAL] = { weaponId = specialWeaponId, wrapId = specialWrapId },
	}

	return true, false, mainWeaponId, slots
end

local function _equipMainLoadoutTool(player: Player, mainWeaponId: string): boolean
	if player.Parent ~= Players then
		return false
	end

	local character = player.Character
	if not character then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end

	local tool = character:FindFirstChild(mainWeaponId)
	if not tool or not tool:IsA("Tool") then
		local backpack = player:FindFirstChildOfClass("Backpack")
		if backpack then
			local backpackTool = backpack:FindFirstChild(mainWeaponId)
			if backpackTool and backpackTool:IsA("Tool") then
				tool = backpackTool
			end
		end
	end

	if not tool or not tool:IsA("Tool") then
		return false
	end

	if tool:GetAttribute(MATCH_LOADOUT_TOOL_ATTRIBUTE) ~= true then
		return false
	end

	humanoid:EquipTool(tool)
	return true
end

-- ── API pública ──────────────────────────────────────────────

--- Aplica cosméticos (hat + face) al personaje de forma síncrona.
function LoadoutService.applyCosmetics(player: Player, character: Model, dataService: any)
	_clearMatchLoadoutHat(character)

	local profile = if dataService then dataService:GetProfile(player) else nil
	if not profile or not profile.Data or not profile.Data.Loadout then
		return
	end

	local loadout = profile.Data.Loadout

	local hatId = _getOptionalString(loadout.Hat)
	if hatId then
		local hatTemplate = CosmeticsTemplates.findHatTemplate(hatId)
		if hatTemplate then
			local hatClone = hatTemplate:Clone()
			hatClone:SetAttribute(MATCH_LOADOUT_HAT_ATTRIBUTE, true)
			CosmeticsTemplates.attachHatToCharacter(character, hatClone)
		else
			warn(string.format("[LoadoutService] Hat no encontrado para Loadout.Hat=%s en Shared/locker/hats.", hatId))
		end
	end

	local faceId = _getOptionalString(loadout.Face)
	if faceId then
		local headNode = character:FindFirstChild("Head")
		if headNode and headNode:IsA("BasePart") then
			CosmeticsTemplates.applyFaceToHead(headNode :: BasePart, faceId)
		end
	end
end

-- ── Body swap (StarterCharacter por jugador) ─────────────────
--
-- Roblox lee StarterPlayer.StarterCharacter al llamar player:LoadCharacter().
-- Para servir bodies distintos por jugador, clonamos el template desde
-- Shared.Bodies[outfitId], lo parenteamos como StarterCharacter,
-- llamamos LoadCharacter (yields) y limpiamos. El mutex serializa swaps
-- concurrentes para que dos LoadCharacter simultáneos no se pisen el template.

local _bodySwapBusy = false

local function _resolveFullBodyTemplate(outfitId: string?): Model?
	local bodies = Shared:FindFirstChild(BODIES_ROOT_NAME)
	if not bodies then
		return nil
	end
	local byId = if outfitId and outfitId ~= "" then bodies:FindFirstChild(outfitId) else nil
	if byId and byId:IsA("Model") then
		return byId :: Model
	end
	local fallback = bodies:FindFirstChild(DEFAULT_BODY_ID)
	return if fallback and fallback:IsA("Model") then fallback :: Model else nil
end

--- Carga el Character del jugador usando el body equipado en Loadout.Outfit.
--- Bloquea mientras otro swap esté en curso para no contaminar el StarterCharacter.
-- BODY_SWAP_LOCK_TIMEOUT: cap del busy-wait. Si un swap anterior se cuelga
-- (yield perdido en LoadCharacter, error fuera del pcall, etc.), el lock se
-- libera forzado para que respawns posteriores no queden bloqueados para
-- siempre. 10s cubre incluso un LoadCharacter lento + clone install.
local BODY_SWAP_LOCK_TIMEOUT = 10
function LoadoutService.loadCharacterWithBody(player: Player, dataService: any)
	if player.Parent ~= Players then
		return
	end

	local waitDeadline = time() + BODY_SWAP_LOCK_TIMEOUT
	while _bodySwapBusy do
		if time() >= waitDeadline then
			warn("[LoadoutService] _bodySwapBusy lock held >10s; forcing reset to recover.")
			_bodySwapBusy = false
			break
		end
		task.wait()
	end
	_bodySwapBusy = true

	-- Wrap todo el critical section en pcall para garantizar que _bodySwapBusy
	-- se libera incluso si una operación intermedia (Clone, SetAttribute,
	-- LoadCharacter, Destroy) tira un error inesperado.
	local ok, err = pcall(function()
		-- Limpieza defensiva: si un swap previo crasheó dejó su clon en StarterPlayer.
		local leftover = StarterPlayer:FindFirstChild("StarterCharacter")
		if leftover and leftover:GetAttribute(MATCH_BODY_CLONE_ATTRIBUTE) == true then
			leftover:Destroy()
			leftover = nil
		end

		local previousStarter = leftover
		local installedClone: Model? = nil

		local profile = if dataService then dataService:GetProfile(player) else nil
		local outfitId: string? = nil
		if profile and profile.Data and profile.Data.Loadout then
			outfitId = _getOptionalString(profile.Data.Loadout.Outfit)
		end

		local template = _resolveFullBodyTemplate(outfitId)
		if template then
			if previousStarter then
				previousStarter.Parent = nil
			end
			local clone = template:Clone()
			clone.Name = "StarterCharacter"
			clone:SetAttribute(MATCH_BODY_CLONE_ATTRIBUTE, true)
			clone.Parent = StarterPlayer
			installedClone = clone
		end

		player:LoadCharacter()

		if installedClone and installedClone.Parent then
			installedClone:Destroy()
		end
		if previousStarter and previousStarter.Parent == nil then
			previousStarter.Parent = StarterPlayer
		end
	end)

	_bodySwapBusy = false

	if not ok then
		warn(string.format("[LoadoutService] LoadCharacter falló para %s: %s", player.Name, tostring(err)))
	end
end

--- Entrega armas del loadout con reintentos (blocking). Llamar en task.spawn.
function LoadoutService.grantWeaponsWithRetry(player: Player, dataService: any, timeoutSec: number)
	local endAt = time() + math.max(0.5, timeoutSec)
	while player.Parent == Players do
		local success, retryable, mainWeaponId, slots = _grantMatchLoadoutTools(player, dataService)
		if success then
			-- Antes de equipar: el Bind engancha character.ChildAdded, y así el
			-- equipado de la Main de más abajo ya entra por esa vía.
			local character = player.Character
			if character and slots then
				BackWeaponService.Bind(character, slots)
			end

			if type(mainWeaponId) == "string" and mainWeaponId ~= "" then
				local equipDeadline = time() + 2
				while time() < equipDeadline and player.Parent == Players do
					if _equipMainLoadoutTool(player, mainWeaponId) then
						break
					end
					task.wait(0.1)
				end
			end
			return
		end
		if not retryable then
			return
		end
		if time() >= endAt then
			warn(string.format("[LoadoutService] Timeout entregando tools de loadout a %s (perfil/backpack no listos).", player.Name))
			return
		end
		task.wait(0.2)
	end
end

return LoadoutService
