--!strict
--[[
	BackWeaponService.luau
	Holster visual: clona en la parte `BackWeapon` del body el arma que NO está
	equipada (Main ↔ Special) y la mantiene sincronizada con los cambios de arma.

	Por qué el modelo y no la Tool:
	  ServerStorage.WeaponTools.<cat>.<id> es la Tool funcional — Handle,
	  Configuration, sonidos, scripts y el tag `WeaponsSystemWeapon` que hace
	  que WeaponsSystem la instancie como arma viva. Clonarla para algo que
	  sólo se mira pagaría todo eso (y registraría un arma fantasma). El
	  holster usa Shared.Locker.weapons.<cat>.<id>, geometría pura, la misma
	  que ya usan los previews del locker.

	Detección de equipado:
	  Roblox reparenta la Tool Backpack→Character al equipar, y eso replica al
	  servidor, así que `character.ChildAdded` es señal suficiente y no hace
	  falta ningún remote. La categoría se lee del atributo
	  `MatchLoadoutCategory` que estampa LoadoutService al clonar.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticsTemplates = require(Shared.Locker.CosmeticsTemplates)
local WeaponCategory = require(Shared.constants.WeaponCategory)

local BackWeaponService = {}

-- Parte del body (autorada en Studio) que marca dónde y con qué orientación
-- se coloca el arma holsterada. Búsqueda recursiva: puede colgar del Torso,
-- del UpperTorso o de una carpeta intermedia según el rig.
local BACK_WEAPON_PART_NAME = "BackWeapon"
local BACK_WEAPON_CLONE_NAME = "BackWeaponModel"
-- Espejo de ShoulderCamera.BACK_WEAPON_CLONE_ATTRIBUTE (mismo string literal,
-- misma convención que MatchLoadoutHat): la cámara lo lee para difuminar el
-- holster al apuntar, igual que hace con los hats del loadout.
local BACK_WEAPON_CLONE_ATTRIBUTE = "BackWeaponClone"
local BACK_WEAPON_CATEGORY_ATTRIBUTE = "BackWeaponCategory"
local LOADOUT_CATEGORY_ATTRIBUTE = "MatchLoadoutCategory"

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
	-- Los bodies se autoran en Studio: un rig sin la parte `BackWeapon` deja el
	-- holster en no-op silencioso. Se avisa una vez por character en lugar de en
	-- cada cambio de arma.
	warnedMissingAnchor: boolean,
	connections: { RBXScriptConnection },
}

local _bindingByCharacter: { [Model]: Binding } = {}

-- ── Helpers internos ─────────────────────────────────────────

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

--[[
	Prepara una parte del clon para vivir soldada al rig.

	CanQuery=false es el flag crítico: sin él el arma de la espalda entra en los
	raycasts de WeaponsSystem y absorbe disparos dirigidos al torso, comiéndose
	daño que debería registrar hit. CanCollide/CanTouch/Massless evitan además
	que un adorno puramente visual altere la física del personaje.
]]
local function _prepareHolsterPart(part: BasePart, anchor: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true

	-- WeldConstraint por parte contra el anchor en vez de confiar en las welds
	-- internas del asset: los modelos de display se autoran en Studio para
	-- verse en un ViewportFrame (a menudo anclados y sin soldar entre sí), así
	-- que al desanclarlos se desmontarían en el aire.
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

	-- Orden fijo y sin yields: parentear → posicionar → soldar. Un
	-- WeldConstraint congela el offset del momento en que se activa, así que
	-- mover después dejaría el arma flotando lejos del cuerpo; y como no se
	-- cede el hilo, las partes nunca llegan a caer entre el desanclado y la
	-- soldadura.
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

--- Categoría de loadout de la Tool que el jugador lleva en la mano, o nil.
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

-- `equippedTool` es la Tool recién parenteada al Character, cuando el sync
-- viene de un ChildAdded. Tiene prioridad sobre el escaneo: si el desequipado
-- de la anterior aún no se ha propagado, ambas están dentro un instante y el
-- orden de GetChildren decidiría al azar qué arma se cuelga de la espalda.
local function _sync(binding: Binding, equippedTool: Instance?)
	local equipped = (if equippedTool then _loadoutCategoryOf(equippedTool, binding.slots) else nil)
		or _equippedCategory(binding.character, binding.slots)
	if not equipped then
		-- Al cambiar de arma Roblox saca la vieja del Character antes de meter
		-- la nueva: reconstruir en ese hueco haría parpadear el holster. Se
		-- conserva lo que hubiera y se espera al ChildAdded de la nueva Tool.
		if binding.holstered ~= nil then
			return
		end
		-- Estado inicial (tools aún sin repartir): el loadout siempre acaba
		-- equipando la Main, así que se holstera la Special desde ya y el
		-- equipado real no provocará ningún rebuild.
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

-- ── API pública ──────────────────────────────────────────────

--- Suelta el tracking de un character y destruye su holster. Idempotente.
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
	Empieza a mantener el holster del character. `slots` debe traer las dos
	categorías ya resueltas (arma + wrap equipados), tal como las calcula
	LoadoutService al repartir las tools.

	Llamar ANTES de equipar la Main: así el ChildAdded de esa Tool ya encuentra
	el binding montado. Re-llamar sobre el mismo character es seguro (rebinding
	limpio); el binding se suelta solo cuando el character se destruye.
]]
function BackWeaponService.Bind(character: Model, slots: Slots)
	BackWeaponService.Unbind(character)

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
