--!strict
--[[
	WrapCasesService.luau  (Server)
	Unboxing de cases de wraps (WrapCasesConfig). Flujo de Open:
	  1. Cliente envía Network.WrapCases.Open { caseId }
	  2. Validaciones: payload → cooldown → case existe → perfil → cash
	  3. Roll en dos pasos sobre el espacio VÁLIDO:
	       a) wrap ponderado por Weight, considerando solo wraps con ≥1 arma
	          válida (arma del inventario del jugador SIN ese wrap ya poseído)
	       b) arma uniforme entre las válidas de ese wrap
	     → nunca puede tocar una combinación wrap+arma ya poseída, ni un arma
	       que el jugador no tenga en el inventario.
	  4. BatchUpdate atómico: cash − precio, grant del wrap para ese arma.
	     NO auto-equipa (a diferencia de la compra directa del Shop): el
	     unboxing premia ownership; equipar es decisión del jugador.
	  5. Network.WrapCases.Result con el roll para que el cliente lo anime.

	Si el jugador ya posee TODAS las combinaciones de la case, se rechaza
	antes de cobrar ("case completada").
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
local EconomyAnalytics = require(script.Parent.Parent.Parent.core.EconomyAnalytics)
type DataService = DataServiceMod.DataServiceModule

local Network = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)
local InventoryRepository = require(Shared.data.InventoryRepository)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local WeaponCategoryMod = require(Shared.constants.WeaponCategory)
local WrapCasesConfig = require(Shared.constants.WrapCasesConfig)

local M = NetGuards.MAX

type WeaponCategory = WeaponCategoryMod.WeaponCategory

type WeaponRef = {
	category: WeaponCategory,
	weaponId: string,
}

-- Candidato del roll: un wrap de la case con ≥1 arma válida donde caer.
type WrapCandidate = {
	wrapId: string,
	weight: number,
	validWeapons: { WeaponRef },
}

-- Cooldown entre Opens por jugador (la animación del cliente dura más, esto
-- solo frena spam de paquetes).
local COOLDOWN = 1

local _cooldowns: { [number]: number } = {}
local _dataService: DataService = nil :: any
local _started = false
local _rng = Random.new()

local function _sendResult(player: Player, success: boolean, message: string, caseId: string, wrapId: string?, weaponCategory: string?, weaponId: string?)
	Network.WrapCases.Result.SendTo({
		success = success,
		message = message,
		caseId = caseId,
		wrapId = wrapId or "",
		weaponCategory = weaponCategory or "",
		weaponId = weaponId or "",
	}, player)
end

-- Armas del inventario del jugador que EXISTEN en ItemsConfig. Incluye el
-- arma Default de cada categoría solo si está definida en el catálogo
-- (Main la tiene; Special no) — el WeaponLane del cliente sigue el mismo
-- criterio para que el resultado siempre sea representable.
local function _getOwnedWeapons(profileData: any): { WeaponRef }
	local owned = {} :: { WeaponRef }
	for _, category in { WeaponCategoryMod.MAIN, WeaponCategoryMod.SPECIAL } do
		local categoryConfig = (ItemsConfig :: any)[category]
		if type(categoryConfig) ~= "table" then
			continue
		end
		for weaponId in categoryConfig do
			local id = tostring(weaponId)
			local isOwned = id == ItemDefaults.ITEM_ID
				or InventoryRepository.ownsItem(profileData, category, id)
			if isOwned then
				table.insert(owned, { category = category :: WeaponCategory, weaponId = id })
			end
		end
	end
	return owned
end

-- Construye los candidatos del roll: wraps de la case con peso > 0, que
-- existan en ItemsConfig.WeaponWraps y tengan ≥1 arma poseída sin ese wrap.
local function _buildCandidates(caseDefinition: WrapCasesConfig.WrapCaseDefinition, profileData: any, ownedWeapons: { WeaponRef }): { WrapCandidate }
	local candidates = {} :: { WrapCandidate }
	for _, caseItem in caseDefinition.Items do
		if caseItem.Weight <= 0 then
			continue
		end
		if type(ItemsConfig.WeaponWraps[caseItem.WrapId]) ~= "table" then
			warn("[WrapCasesService] Wrap de case no existe en ItemsConfig.WeaponWraps:", caseItem.WrapId)
			continue
		end

		local validWeapons = {} :: { WeaponRef }
		for _, weapon in ownedWeapons do
			if not InventoryRepository.ownsWeaponWrap(profileData, weapon.category, weapon.weaponId, caseItem.WrapId) then
				table.insert(validWeapons, weapon)
			end
		end

		if #validWeapons > 0 then
			table.insert(candidates, {
				wrapId = caseItem.WrapId,
				weight = caseItem.Weight,
				validWeapons = validWeapons,
			})
		end
	end
	return candidates
end

-- Roll ponderado por peso sobre los candidatos (la lista nunca llega vacía).
local function _rollCandidate(candidates: { WrapCandidate }): WrapCandidate
	local totalWeight = 0
	for _, candidate in candidates do
		totalWeight += candidate.weight
	end

	local roll = _rng:NextNumber() * totalWeight
	for _, candidate in candidates do
		roll -= candidate.weight
		if roll <= 0 then
			return candidate
		end
	end

	-- Fallback por imprecisión flotante: el último candidato.
	return candidates[#candidates]
end

local function _onOpenCase(data: { caseId: string }, player: Player): ()
	-- Validación 0: tipos + caps de longitud (ver ShopService._onBuyItem).
	if not NetGuards.validate(data, { caseId = M.Id }) or data.caseId == "" then
		_sendResult(player, false, "Payload inválido.", "")
		return
	end

	-- Validación 1: cooldown.
	local lastOpen = _cooldowns[player.UserId] or 0
	if time() - lastOpen < COOLDOWN then
		_sendResult(player, false, "Demasiadas peticiones.", data.caseId)
		return
	end

	-- Validación 2: la case existe.
	local caseDefinition = WrapCasesConfig.GetCaseById(data.caseId)
	if not caseDefinition then
		_sendResult(player, false, "Case no encontrada.", data.caseId)
		return
	end

	-- Validación 3: perfil cargado.
	local profile = _dataService:GetProfile(player)
	if not profile then
		_sendResult(player, false, "Perfil no disponible.", data.caseId)
		return
	end

	-- Validación 4: cash suficiente.
	local currentCash: number = profile.Data.Stats.Cash or 0
	if currentCash < caseDefinition.Price then
		_sendResult(player, false, "Cash insuficiente. Necesitas " .. tostring(caseDefinition.Price) .. ".", data.caseId)
		return
	end

	-- Validación 5: queda al menos una combinación wrap+arma por obtener.
	local ownedWeapons = _getOwnedWeapons(profile.Data)
	local candidates = _buildCandidates(caseDefinition, profile.Data, ownedWeapons)
	if #candidates == 0 then
		_sendResult(player, false, "Ya tienes todas las combinaciones de esta case.", data.caseId)
		return
	end

	-- ── Roll ─────────────────────────────────────────────────
	local candidate = _rollCandidate(candidates)
	local weapon = candidate.validWeapons[_rng:NextInteger(1, #candidate.validWeapons)]

	-- ── Transacción atómica ──────────────────────────────────
	-- Cash con delta (evita TOCTOU con otros flujos que muten Stats.Cash).
	local success = _dataService:BatchUpdate(player, {
		{ path = { "Stats", "Cash" }, delta = -caseDefinition.Price },
		{
			path = { "Inventory", "WeaponWrapsByWeapon", weapon.category, weapon.weaponId, candidate.wrapId },
			value = true,
		},
		{
			path = { "InventoryMeta", "WeaponWraps", candidate.wrapId },
			value = { AcquiredAt = os.time(), Source = "WrapCase::" .. caseDefinition.Id },
		},
		{
			path = { "NewItemFlags", "WeaponWraps", candidate.wrapId },
			value = true,
		},
	})

	if not success then
		_sendResult(player, false, "Error interno. Inténtalo de nuevo.", data.caseId)
		return
	end

	_cooldowns[player.UserId] = time()

	local refreshedProfile = _dataService:GetProfile(player)
	local balance = if refreshedProfile and refreshedProfile.Data then refreshedProfile.Data.Stats.Cash else 0
	EconomyAnalytics.Sink(player, caseDefinition.Price, balance, "WrapCase::" .. caseDefinition.Id)
	EconomyAnalytics.ItemSource(player, "WrapCase::" .. caseDefinition.Id, candidate.wrapId)

	_sendResult(player, true, "Unboxed!", data.caseId, candidate.wrapId, weapon.category, weapon.weaponId)
end

-- ────────────────────────────────────────────────────────────
-- MÓDULO PRINCIPAL
-- ────────────────────────────────────────────────────────────

local WrapCasesService = {}

function WrapCasesService:Start(dataService: DataService): ()
	if _started then
		return
	end

	_started = true
	_dataService = dataService

	Players.PlayerRemoving:Connect(function(player: Player)
		_cooldowns[player.UserId] = nil
	end)

	Network.WrapCases.Open.Listen(_onOpenCase)
end

return WrapCasesService
