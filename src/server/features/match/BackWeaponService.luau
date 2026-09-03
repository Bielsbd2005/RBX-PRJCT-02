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

	Gamepass:
	  El holster es el beneficio del gamepass `StoreProducts.GamePasses.ByName
	  .BackWeapon`. Se hace binding igualmente a quien no lo tenga —el binding es
	  barato y no crea nada— y la posesión se comprueba en cada `_sync`: así el
	  jugador que lo compre a mitad de partida (o cuyo prefetch de posesión
	  todavía no había resuelto al spawnear) ve el arma aparecer sin esperar al
	  respawn, vía `GamePassService.OnOwnershipGained`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticsTemplates = require(Shared.Locker.CosmeticsTemplates)
local StoreProducts = require(Shared.constants.StoreProducts)
local WeaponCategory = require(Shared.constants.WeaponCategory)
local GamePassService = require(script.Parent.Parent.Parent.core.GamePassService)

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

-- Gamepass que desbloquea el holster (ver cabecera).
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

--[[
	¿El dueño de este character tiene el gamepass del holster?

	Los bots no son Players, así que se quedan fuera por el mismo camino que
	quien no ha comprado el pass: nada que colgar de la espalda.
]]
local function _ownsBackWeaponPass(character: Model): boolean
	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return false
	end
	return GamePassService.Owns(player, BACK_WEAPON_PASS.PassId)
end

-- `equippedTool` es la Tool recién parenteada al Character, cuando el sync
-- viene de un ChildAdded. Tiene prioridad sobre el escaneo: si el desequipado
-- de la anterior aún no se ha propagado, ambas están dentro un instante y el
-- orden de GetChildren decidiría al azar qué arma se cuelga de la espalda.
local function _sync(binding: Binding, equippedTool: Instance?)
	-- El gate va lo primero: sin pass, nada que colgar. Y limpia además de
	-- salir, porque la posesión la sirve un caché que se rehace por sesión: si
	-- un "sí" pasara a "no", el arma no puede quedarse pegada a la espalda el
	-- resto de la vida del character.
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

--[[
	Engancha, una sola vez por servidor, la señal de "acaba de conseguir un
	pass" para rehacer el holster de quien ya estuviera spawneado.

	Perezoso (desde `Bind`) y no en un `Start` propio: el service no tiene otro
	ciclo de vida que el de los characters que gestiona, así que no hay un sitio
	natural donde arrancarlo en el bootstrap.
]]
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
		-- Un jugador tiene como mucho un binding vivo (el de su character
		-- actual); el barrido es sobre la tabla entera porque el índice es el
		-- character, no el jugador.
		for character, binding in _bindingByCharacter do
			if Players:GetPlayerFromCharacter(character) == player then
				_sync(binding)
			end
		end
	end)
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
