--!strict
--[[
	CasesService.luau  (Server)
	Gestiona la apertura de cajas, el sistema de pity y el lucky boost.

	Flujo de summon:
	  1. Cliente envía Network.Cases.Summon { caseId, multi }
	  2. Validar: cooldown → case existe → cash suficiente
	  3. Determinar si lucky está activo (LuckyExpiresAt > os.time())
	  4. Elegir skin con weighted random (pesos lucky o normales)
	  5. Applicar pity: si contador >= threshold → forzar pity drop y resetear
	  6. DataService:BatchUpdate: cash - precio, skin al inventario, pity counter
	  7. Enviar Network.Cases.SummonResult al cliente

	Lucky Boost:
	  Se procesa via MarketplaceService.PromptProductPurchaseFinished.
	  Al confirmar, se setea Cases.LuckyExpiresAt = os.time() + duración.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

local Network = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)
local InventoryRepository = require(Shared.data.InventoryRepository)
local CasesConfig = require(Shared.constants.CasesConfig)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local StoreProducts = require(Shared.constants.StoreProducts)

local M = NetGuards.MAX

local BattlePassService = require(script.Parent.Parent.battlepass.BattlePassService)

local STORE_PRODUCTS_BY_ID = StoreProducts.ProductsByProductId :: { [number]: { CashAmount: number } }

local COOLDOWN = 0.5
type WeaponCategory = "Main" | "Special"
type OwnedWeaponEntry = {
	category: WeaponCategory,
	weaponId: string,
}

-- ────────────────────────────────────────────────────────────
-- ESTADO
-- ────────────────────────────────────────────────────────────

local _dataService: DataService = nil :: any
local _started = false
local _cooldowns: { [number]: { [string]: number } } = {}
-- Lock per-player para evitar TOCTOU en runningPity/Cash con summons
-- concurrentes. ByteNet podría despachar handlers en coroutines paralelas;
-- el lock garantiza que solo una transacción de cajas esté en vuelo por
-- jugador hasta que el BatchUpdate termine.
local _processingByUserId: { [number]: boolean } = {}

local CasesService = {}

-- ────────────────────────────────────────────────────────────
-- HELPERS
-- ────────────────────────────────────────────────────────────

local function checkCooldown(player: Player, action: string): boolean
	local playerCooldowns = _cooldowns[player.UserId]
	if not playerCooldowns then
		playerCooldowns = {}
		_cooldowns[player.UserId] = playerCooldowns
	end

	local last = playerCooldowns[action] or 0
	if time() - last < COOLDOWN then
		return false
	end

	playerCooldowns[action] = time()
	return true
end

local function isLuckyActive(profile: any): boolean
	local casesData = profile.Data.Cases
	if not casesData or type(casesData.LuckyExpiresAt) ~= "number" then
		return false
	end
	return casesData.LuckyExpiresAt > os.time()
end

local function weightedRandomPick(drops: { CasesConfig.CaseDrop }, useLucky: boolean): CasesConfig.CaseDrop
	local totalWeight = 0
	for _, drop in drops do
		totalWeight += if useLucky then drop.LuckyWeight else drop.Weight
	end

	local roll = math.random() * totalWeight
	local cumulative = 0
	for _, drop in drops do
		cumulative += if useLucky then drop.LuckyWeight else drop.Weight
		if roll <= cumulative then
			return drop
		end
	end

	-- Fallback: último drop
	return drops[#drops]
end

-- Delega en InventoryRepository (single source of truth para schema de inventario).
-- El cast es seguro porque OwnedWeapon de la repo y OwnedWeaponEntry local
-- son estructuralmente idénticos.
local function collectOwnedWeapons(profileData: any): { OwnedWeaponEntry }
	return InventoryRepository.listOwnedWeapons(profileData) :: any
end

local function pickRandomOwnedWeapon(ownedWeapons: { OwnedWeaponEntry }): OwnedWeaponEntry
	local idx = math.random(1, math.max(1, #ownedWeapons))
	return ownedWeapons[idx]
end

-- ────────────────────────────────────────────────────────────
-- SUMMON HANDLER
-- ────────────────────────────────────────────────────────────

local function _processSummon(data: { caseId: string, multi: boolean }, player: Player): ()

	local caseId = data.caseId
	local caseDef = CasesConfig.Cases[caseId]
	if not caseDef then
		Network.Cases.Response.SendTo({ success = false, message = "Case no encontrado." }, player)
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile then
		Network.Cases.Response.SendTo({ success = false, message = "Perfil no disponible." }, player)
		return
	end

	local count = if data.multi then CasesConfig.MultiCount else 1
	local totalPrice = if data.multi then caseDef.PriceMulti else caseDef.Price

	-- Validar cash
	local currentCash: number = profile.Data.Stats.Cash or 0
	if currentCash < totalPrice then
		Network.Cases.Response.SendTo({
			success = false,
			message = "Cash insuficiente. Necesitas " .. tostring(totalPrice) .. ".",
		}, player)
		return
	end

	-- Procesar cada tirada
	local results = {} :: { { skinId: string, weaponCategory: WeaponCategory, weaponId: string, isPity: boolean, newPity: number } }

	-- Usamos el profile actual para todas las tiradas en secuencia
	-- El pity se acumula dentro del batch
	local runningPity: number
	do
		local casesData = profile.Data.Cases or {}
		local pityCounters = if type(casesData.PityCounters) == "table" then casesData.PityCounters else {}
		runningPity = if type(pityCounters[caseId]) == "number" then pityCounters[caseId] else 0
	end

	local useLucky = isLuckyActive(profile)
	local ownedWeapons = collectOwnedWeapons(profile.Data)
	local wrapsWonByWeapon = {} :: { [WeaponCategory]: { [string]: { [string]: number } } }

	for _ = 1, count do
		local isPity = false
		local chosenSkinId: string

		if (runningPity + 1) >= caseDef.PityThreshold then
			chosenSkinId = caseDef.PityDropSkinId
			isPity = true
			runningPity = 0
		else
			local chosenDrop = weightedRandomPick(caseDef.Drops, useLucky)
			chosenSkinId = chosenDrop.SkinId
			runningPity = runningPity + 1
		end

		local targetWeapon = pickRandomOwnedWeapon(ownedWeapons)
		local categoryLookup = wrapsWonByWeapon[targetWeapon.category]
		if not categoryLookup then
			categoryLookup = {}
			wrapsWonByWeapon[targetWeapon.category] = categoryLookup
		end

		local weaponLookup = categoryLookup[targetWeapon.weaponId]
		if not weaponLookup then
			weaponLookup = {}
			categoryLookup[targetWeapon.weaponId] = weaponLookup
		end

		weaponLookup[chosenSkinId] = (weaponLookup[chosenSkinId] or 0) + 1

		table.insert(results, {
			skinId = chosenSkinId,
			weaponCategory = targetWeapon.category,
			weaponId = targetWeapon.weaponId,
			isPity = isPity,
			newPity = runningPity,
		})
	end

	-- Construir batch de updates. Cash con delta para evitar TOCTOU.
	local updates = {
		{ path = { "Stats", "Cash" }, delta = -totalPrice },
		{ path = { "Cases", "PityCounters", caseId }, value = runningPity },
	}

	-- Agregar skins al inventario por arma (WeaponSkinsByWeapon).
	-- Delta para mantener consistencia con el resto del codebase y resilencia
	-- ante futuras introducciones de yields entre el read y el write.
	-- También marcar NEW! flag y metadata para que el Locker pinte badge.
	local seenSkinIds: { [string]: boolean } = {}
	for weaponCategory, weaponsLookup in wrapsWonByWeapon do
		for weaponId, skinsLookup in weaponsLookup do
			for skinId, amountWon in skinsLookup do
				if ItemsConfig.WeaponSkins and ItemsConfig.WeaponSkins[skinId] then
					table.insert(updates, {
						path = { "Inventory", "WeaponSkinsByWeapon", weaponCategory, weaponId, skinId },
						delta = amountWon,
					})
					if not seenSkinIds[skinId] then
						seenSkinIds[skinId] = true
						table.insert(updates, {
							path = { "InventoryMeta", "WeaponSkins", skinId },
							value = { AcquiredAt = os.time(), Source = "Case" },
						})
						table.insert(updates, {
							path = { "NewItemFlags", "WeaponSkins", skinId },
							value = true,
						})
					end
				end
			end
		end
	end

	local success = _dataService:BatchUpdate(player, updates)

	if not success then
		Network.Cases.Response.SendTo({ success = false, message = "Error al guardar datos." }, player)
		return
	end

	Network.Cases.Response.SendTo({ success = true, message = "OK" }, player)

	-- Enviar cada resultado individualmente (para futura animación secuencial)
	for _, result in results do
		Network.Cases.SummonResult.SendTo({
			caseId = caseId,
			skinId = result.skinId,
			weaponCategory = result.weaponCategory,
			weaponId = result.weaponId,
			isPity = result.isPity,
			newPity = result.newPity,
		}, player)
	end
end

-- Wrapper con lock + cooldown + cleanup ante errores.
-- ByteNet handlers pueden ser concurrentes; el lock garantiza que solo una
-- transacción esté en vuelo por jugador (TOCTOU-safe para runningPity).
local function onSummon(data: { caseId: string, multi: boolean }, player: Player): ()
	-- Validación de payload + cap de longitud (ByteNet no impone maxLength).
	if not NetGuards.validate(data, { caseId = M.Id }) or data.caseId == "" then
		Network.Cases.Response.SendTo({ success = false, message = "Payload inválido." }, player)
		return
	end

	if not checkCooldown(player, "summon") then
		Network.Cases.Response.SendTo({ success = false, message = "Demasiadas peticiones." }, player)
		return
	end

	if _processingByUserId[player.UserId] then
		Network.Cases.Response.SendTo({ success = false, message = "Procesando caja anterior." }, player)
		return
	end
	_processingByUserId[player.UserId] = true

	local ok, err = pcall(_processSummon, data, player)
	_processingByUserId[player.UserId] = nil

	if not ok then
		warn("[CasesService] onSummon error:", err)
		Network.Cases.Response.SendTo({ success = false, message = "Error inesperado." }, player)
	end
end

-- ────────────────────────────────────────────────────────────
-- LUCKY BOOST (DevProduct)
-- ────────────────────────────────────────────────────────────

local function onLuckyProductPurchased(receiptInfo: any): Enum.ProductPurchaseDecision
	local productId = receiptInfo.ProductId
	local luckyProductId = CasesConfig.LuckyBoost.ProductId

	if productId ~= luckyProductId or luckyProductId <= 0 then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local playerId = receiptInfo.PlayerId
	local player = Players:GetPlayerByUserId(playerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local profile = _dataService:GetProfile(player)
	if not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Idempotencia: si ya procesamos este PurchaseId, no re-otorgar.
	local purchaseId = tostring(receiptInfo.PurchaseId)
	if _dataService:IsReceiptProcessed(player, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local durationSeconds = CasesConfig.LuckyBoost.DurationMinutes * 60
	local currentExpiry: number = 0
	local casesData = profile.Data.Cases
	if casesData and type(casesData.LuckyExpiresAt) == "number" then
		currentExpiry = casesData.LuckyExpiresAt
	end

	-- Si ya tiene lucky activo, sumar tiempo
	local baseTime = math.max(os.time(), currentExpiry)
	local newExpiry = baseTime + durationSeconds

	-- Atómico: grant + mark en el mismo BatchUpdate. Sin esto, si el jugador
	-- se va entre SetValue y MarkReceiptProcessed, el receipt queda sin marcar
	-- y un futuro reintento de Roblox dupea el lucky boost.
	local success = _dataService:BatchUpdate(player, {
		{ path = { "Cases", "LuckyExpiresAt" }, value = newExpiry },
		{ path = { "ProcessedReceipts", purchaseId }, value = os.time() },
	})
	if not success then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	Network.Cases.Response.SendTo({ success = true, message = "Lucky boost activado!" }, player)

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ────────────────────────────────────────────────────────────
-- LIFECYCLE
-- ────────────────────────────────────────────────────────────

function CasesService:Start(dataService: DataService): ()
	if _started then return end
	_started = true
	_dataService = dataService

	-- Listeners de red
	Network.Cases.Summon.Listen(function(data: any, player: Player)
		onSummon(data, player)
	end)

	-- ProcessReceipt centralizado: maneja lucky boost y delega productos de tienda
	MarketplaceService.ProcessReceipt = function(receiptInfo: any): Enum.ProductPurchaseDecision
		-- Battle Pass Premium: el servicio devuelve nil si el productId no es suyo.
		local bpDecision = BattlePassService:ProcessReceipt(receiptInfo)
		if bpDecision ~= nil then
			return bpDecision
		end

		-- Lucky boost
		if receiptInfo.ProductId == CasesConfig.LuckyBoost.ProductId and CasesConfig.LuckyBoost.ProductId > 0 then
			return onLuckyProductPurchased(receiptInfo)
		end

		-- Store cash products
		local storeProduct = STORE_PRODUCTS_BY_ID[receiptInfo.ProductId]
		if storeProduct then
			local buyer = Players:GetPlayerByUserId(receiptInfo.PlayerId)
			if not buyer or not _dataService then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end

			-- Idempotencia: si ya procesamos este PurchaseId, no re-otorgar Cash.
			local purchaseId = tostring(receiptInfo.PurchaseId)
			if _dataService:IsReceiptProcessed(buyer, purchaseId) then
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end

			-- Atómico: grant Cash + mark receipt en el mismo BatchUpdate.
			local ok = _dataService:BatchUpdate(buyer, {
				{ path = { "Stats", "Cash" }, delta = storeProduct.CashAmount },
				{ path = { "ProcessedReceipts", purchaseId }, value = os.time() },
			})
			if ok then
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		warn("[CasesService] Unknown ProductId:", receiptInfo.ProductId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Limpiar cooldowns + lock al salir
	Players.PlayerRemoving:Connect(function(player: Player)
		_cooldowns[player.UserId] = nil
		_processingByUserId[player.UserId] = nil
	end)
end

return CasesService
