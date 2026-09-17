--!strict
--[[
	Holster visual: clona en la parte `BackWeapon` del body el arma NO equipada
	(Main ↔ Special). Usa Shared.Locker.weapons.<cat>.<id> (geometría pura) y no
	la Tool de ServerStorage.WeaponTools: esa no replica y lleva el tag
	`WeaponsSystemWeapon`, que registraría un arma fantasma.
	Equipar reparenta la Tool Backpack→Character y eso replica, así que basta
	character.ChildAdded; la categoría sale del atributo que estampa LoadoutService.
	Requiere el gamepass BackWeapon: la posesión se comprueba en cada _sync para
	que una compra a mitad de partida lo muestre sin esperar al respawn.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticsTemplates = require(Shared.Locker.CosmeticsTemplates)
local StoreProducts = require(Shared.constants.StoreProducts)
local WeaponCategory = require(Shared.constants.WeaponCategory)
local WeaponsConfig = require(Shared.constants.WeaponsConfig)
local GamePassService = require(script.Parent.Parent.Parent.core.GamePassService)

local BackWeaponService = {}

-- Parte del body autorada en Studio que marca posición y orientación del arma.
-- Búsqueda recursiva: puede colgar del Torso, del UpperTorso o de una carpeta.
local BACK_WEAPON_PART_NAME = "BackWeapon"
local BACK_WEAPON_CLONE_NAME = "BackWeaponModel"
-- Debe coincidir con ShoulderCamera.BACK_WEAPON_CLONE_ATTRIBUTE: la cámara lo
-- lee para difuminar el holster al apuntar.
local BACK_WEAPON_CLONE_ATTRIBUTE = "BackWeaponClone"
local BACK_WEAPON_CATEGORY_ATTRIBUTE = "BackWeaponCategory"
local LOADOUT_CATEGORY_ATTRIBUTE = WeaponsConfig.CATEGORY_ATTRIBUTE

local BACK_WEAPON_PASS = StoreProducts.GamePasses.ByName.BackWeapon

export type Slot = {
	weaponId: string,
	wrapId: string,
}

-- Indexado por WeaponCategory ("Main" | "Special").
export type Slots = { [string]: Slot }

type Binding = {
	character: Model,
	slots: Slots,
	-- Categoría actualmente colgada de la espalda; nil = nada colgado.
	holstered: string?,
	-- Un rig sin la parte `BackWeapon` deja el holster en no-op: se avisa una
	-- vez por character.
	warnedMissingAnchor: boolean,
	connections: { RBXScriptConnection },
}

local _bindingByCharacter: { [Model]: Binding } = {}

local function _findBackWeaponPart(character: Model): BasePart?
	local node = character:FindFirstChild(BACK_WEAPON_PART_NAME, true)
	if node and node:IsA("BasePart") then
		return node :: BasePart
	end
	return nil
end

local function _clearHolster(character: Model)
	for _, child in character:GetChildren() do
		if child:GetAttribute(BACK_WEAPON_CLONE_ATTRIBUTE) == true then
			child:Destroy()
		end
	end
end

-- CanQuery=false es crítico: sin él el arma de la espalda entra en los raycasts
-- de WeaponsSystem y absorbe disparos dirigidos al torso.
local function _prepareHolsterPart(part: BasePart, anchor: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true

	-- WeldConstraint por parte contra el anchor: los modelos de display suelen
	-- venir anclados y sin soldar entre sí, y al desanclarlos se desmontarían.
	local weld = Instance.new("WeldConstraint")
	weld.Name = "BackWeaponWeld"
	weld.Part0 = part
	weld.Part1 = anchor
	weld.Parent = part
end

local function _attach(binding: Binding, category: string, slot: Slot): boolean
	local character = binding.character

	local anchor = _findBackWeaponPart(character)
	if not anchor then
		if not binding.warnedMissingAnchor then
			binding.warnedMissingAnchor = true
			warn(string.format(
				"[BackWeaponService] El body de %s no tiene una BasePart '%s' — sin holster.",
				character.Name,
				BACK_WEAPON_PART_NAME
			))
		end
		return false
	end

	local template = CosmeticsTemplates.findWeaponDisplayTemplate(category, slot.weaponId)
	if not template then
		warn(string.format(
			"[BackWeaponService] Sin modelo de display para %s/%s en Shared.Locker.weapons — no se holstera.",
			category,
			slot.weaponId
		))
		return false
	end

	local clone = template:Clone()
	clone.Name = BACK_WEAPON_CLONE_NAME
	clone:SetAttribute(BACK_WEAPON_CLONE_ATTRIBUTE, true)
	clone:SetAttribute(BACK_WEAPON_CATEGORY_ATTRIBUTE, category)

	CosmeticsTemplates.applyWeaponWrapToModel(clone, slot.wrapId)

	-- Orden fijo y sin yields: parentear → posicionar → soldar. WeldConstraint
	-- congela el offset al activarse, y sin ceder el hilo las partes no caen
	-- entre el desanclado y la soldadura.
	clone.Parent = character

	if clone:IsA("Model") then
		(clone :: Model):PivotTo(anchor.CFrame)
	elseif clone:IsA("BasePart") then
		(clone :: BasePart).CFrame = anchor.CFrame
	end

	if clone:IsA("BasePart") then
		_prepareHolsterPart(clone :: BasePart, anchor)
	end
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			_prepareHolsterPart(descendant :: BasePart, anchor)
		end
	end

	return true
end

local function _loadoutCategoryOf(tool: Instance, slots: Slots): string?
	local category = tool:GetAttribute(LOADOUT_CATEGORY_ATTRIBUTE)
	if type(category) == "string" and slots[category] then
		return category
	end
	return nil
end

local function _equippedCategory(character: Model, slots: Slots): string?
	for _, child in character:GetChildren() do
		if child:IsA("Tool") then
			local category = _loadoutCategoryOf(child, slots)
			if category then
				return category
			end
		end
	end
	return nil
end

-- Los bots no son Players: nunca tienen holster.
local function _ownsBackWeaponPass(character: Model): boolean
	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return false
	end
	return GamePassService.Owns(player, BACK_WEAPON_PASS.PassId)
end

-- `equippedTool` (la Tool del ChildAdded) tiene prioridad sobre el escaneo: si
-- el desequipado de la anterior no se ha propagado, ambas están dentro un
-- instante y el orden de GetChildren decidiría al azar.
local function _sync(binding: Binding, equippedTool: Instance?)
	-- Sin pass limpia además de salir: la posesión viene de un caché por sesión
	-- y un "sí" puede pasar a "no".
	if not _ownsBackWeaponPass(binding.character) then
		if binding.holstered ~= nil then
			_clearHolster(binding.character)
			binding.holstered = nil
		end
		return
	end

	local equipped = (if equippedTool then _loadoutCategoryOf(equippedTool, binding.slots) else nil)
		or _equippedCategory(binding.character, binding.slots)
	if not equipped then
		-- Al cambiar de arma Roblox saca la vieja antes de meter la nueva:
		-- reconstruir en ese hueco haría parpadear el holster.
		if binding.holstered ~= nil then
			return
		end
		-- Estado inicial (tools sin repartir): el loadout acaba equipando la
		-- Main, así que se holstera ya la Special y no habrá rebuild.
		equipped = WeaponCategory.MAIN
	end

	local holsterCategory = if equipped == WeaponCategory.MAIN
		then WeaponCategory.SPECIAL
		else WeaponCategory.MAIN

	if binding.holstered == holsterCategory then
		return
	end

	_clearHolster(binding.character)
	binding.holstered = nil

	local slot = binding.slots[holsterCategory]
	if not slot then
		return
	end

	if _attach(binding, holsterCategory, slot) then
		binding.holstered = holsterCategory
	end
end

-- Se engancha perezosamente desde Bind: el service no tiene Start propio en el
-- bootstrap.
local _ownershipListenerConnected = false

local function _ensureOwnershipListener()
	if _ownershipListenerConnected then
		return
	end
	_ownershipListenerConnected = true

	GamePassService.OnOwnershipGained(function(player, passId)
		if passId ~= BACK_WEAPON_PASS.PassId then
			return
		end
		-- El índice es el character, no el jugador: hay que barrer la tabla.
		for character, binding in _bindingByCharacter do
			if Players:GetPlayerFromCharacter(character) == player then
				_sync(binding)
			end
		end
	end)
end

function BackWeaponService.Unbind(character: Model)
	local binding = _bindingByCharacter[character]
	if not binding then
		return
	end

	_bindingByCharacter[character] = nil
	for _, connection in binding.connections do
		connection:Disconnect()
	end
	table.clear(binding.connections)

	if character.Parent then
		_clearHolster(character)
	end
end

--[[
	`slots` trae las dos categorías resueltas (arma + wrap) como las calcula
	LoadoutService. Llamar ANTES de equipar la Main para que su ChildAdded ya
	encuentre el binding. Re-llamar sobre el mismo character es seguro.
]]
function BackWeaponService.Bind(character: Model, slots: Slots)
	BackWeaponService.Unbind(character)
	_ensureOwnershipListener()

	local binding: Binding = {
		character = character,
		slots = slots,
		holstered = nil,
		warnedMissingAnchor = false,
		connections = {},
	}
	_bindingByCharacter[character] = binding

	table.insert(
		binding.connections,
		character.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				_sync(binding, child)
			end
		end)
	)

	-- Sin ChildRemoved a propósito (ver _sync). El binding muere con el
	-- character: respawn y salida del jugador pasan ambos por Destroy().
	table.insert(
		binding.connections,
		character.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				BackWeaponService.Unbind(character)
			end
		end)
	)

	_sync(binding)
end

return BackWeaponService
