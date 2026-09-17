--!strict
--[[
	Punto único de aplicación de recompensas (XP + Cash) para jugadores.

	API:
	  RewardService.Award(player, actionKey, extraUpdates?) -> (ok, xp, cash)

	`actionKey` se resuelve contra `shared/constants/ActionRewards.luau`. La
	clave debe existir; si no, se warn-ea y se devuelve (false, 0, 0).

	`extraUpdates` son entries adicionales para `DataService:BatchUpdate` que
	deben aplicarse atómicamente junto al Cash. Casos típicos:
	  - Assist: { path={"Stats","Assists"}, delta=1 }
	  - Daily task claim: { path={"DailyTasks","Claimed",id}, value=true } + progreso
	  - LikeJoin/Notifications: { path={"Rewards","GroupClaimed"}, value=true }
	  - Códigos: { path={"Rewards","ClaimedCodes",code}, value=true }

	XP se aplica por separado vía `DataService:AddXP` (no se puede meter en el
	BatchUpdate porque AddXP encapsula la cascada de level-up sobre múltiples
	campos: Stats.XP, Stats.Level, Stats.XPToNextLevel).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ActionRewards = require(Shared:WaitForChild("constants"):WaitForChild("ActionRewards"))
local TelemetryService = require(script.Parent.TelemetryService)

local DataServiceMod = require(script.Parent.data.DataService)
type DataService = DataServiceMod.DataServiceModule
type BatchUpdateEntry = DataServiceMod.BatchUpdateEntry

local RewardService = {}

local _dataService: DataService = nil :: any
local _started = false

function RewardService.Start(dataService: DataService): ()
	if _started then return end
	_started = true
	_dataService = dataService
end

--[[
	Award: concede XP y Cash de `actionKey`, aplicando `extraUpdates` atómicamente con el Cash.
	Retorna (ok, xpGranted, cashGranted); ok=true aunque una tabla dé 0. (false, 0, 0) si la
	clave no existe o el profile no está cargado.
	`opts.skipCash` / `opts.skipXP` suprimen una moneda de forma independiente: su monto
	vuelve como 0 y no se persiste ni registra. `extraUpdates` se aplican siempre.
]]
type AwardOptions = {
	skipCash: boolean?,
	skipXP: boolean?,
}

function RewardService.Award(
	player: Player,
	actionKey: string,
	extraUpdates: { BatchUpdateEntry }?,
	itemSku: string?,
	opts: AwardOptions?
): (boolean, number, number)
	if not _dataService or not player then
		return false, 0, 0
	end

	local skipCash = if opts then opts.skipCash == true else false
	local skipXP = if opts then opts.skipXP == true else false

	if not ActionRewards.Has(actionKey) then
		warn(("[RewardService] Acción desconocida: %s — no se concede nada"):format(tostring(actionKey)))
		return false, 0, 0
	end

	if not _dataService:GetProfile(player) then
		-- Sin profile no se persiste nada: los callers que deban esperar al ProfileLoaded
		-- encolan ellos mismos (p.ej. MatchService._deferUntilProfile).
		return false, 0, 0
	end

	local xpAmount = if skipXP then 0 else ActionRewards.GetXP(actionKey)
	local cashAmount = if skipCash then 0 else ActionRewards.GetCash(actionKey)

	local updates: { BatchUpdateEntry } = {}
	if cashAmount > 0 then
		table.insert(updates, { path = { "Stats", "Cash" }, delta = cashAmount })
		table.insert(updates, { path = { "Stats", "TotalCashEarned" }, delta = cashAmount })
	end
	if extraUpdates then
		for _, entry in extraUpdates do
			table.insert(updates, entry)
		end
	end

	-- `cashOk` va aparte de `ok` a propósito: si falla la XP, el Cash ya persistido debe
	-- registrarse igual o el balance faucet/sink del dashboard queda corto.
	local cashOk = true
	if #updates > 0 then
		local batchOk, batchErr = pcall(function()
			return _dataService:BatchUpdate(player, updates)
		end)
		if not batchOk then
			warn(("[RewardService] BatchUpdate falló para %s (action=%s): %s"):format(player.Name, actionKey, tostring(batchErr)))
			cashOk = false
		elseif batchErr == false then
			cashOk = false
		end
	end

	local ok = cashOk

	local xpOk = true
	if xpAmount > 0 then
		local xpCallOk, xpErr = pcall(function()
			_dataService:AddXP(player, xpAmount, actionKey)
		end)
		if not xpCallOk then
			warn(("[RewardService] AddXP falló para %s (action=%s): %s"):format(player.Name, actionKey, tostring(xpErr)))
			ok = false
			xpOk = false
		end
	end

	-- Se registra lo que se persistió, no lo que salió redondo del todo.
	if cashOk and cashAmount > 0 then
		TelemetryService.RecordFlow(player, "source", actionKey, cashAmount, itemSku, "Cash")
	end

	-- La XP se registra fuera de la guarda del cash: muchas acciones dan XP sin Cash
	-- y sin este registro el ritmo de XP/hora no se puede medir.
	if xpOk and xpAmount > 0 then
		TelemetryService.RecordXP(player, actionKey, xpAmount, itemSku)
	end

	return ok, xpAmount, cashAmount
end

--[[
	AwardCash: concede un monto de cash arbitrario (no atado a ActionRewards), p. ej. los
	bonus de fin de partida (montos en shared/constants/ResultsRewards.luau).

	`sourceLabel` es el transactionType de telemetría ("MatchEnd::Victory"). Devuelve true
	si se persistió. `itemSku` une el movimiento con otra serie: los bonus de fin de
	partida pasan el `matchId`, sin el cual no se puede cruzar con MATCH_END.
]]
function RewardService.AwardCash(player: Player, amount: number, sourceLabel: string, itemSku: string?): boolean
	if not _dataService or not player or type(amount) ~= "number" or amount <= 0 then
		return false
	end

	amount = math.floor(amount)
	if not _dataService:GetProfile(player) then
		return false
	end

	local updates: { BatchUpdateEntry } = {
		{ path = { "Stats", "Cash" }, delta = amount },
		{ path = { "Stats", "TotalCashEarned" }, delta = amount },
	}

	local batchOk, batchErr = pcall(function()
		return _dataService:BatchUpdate(player, updates)
	end)
	if not batchOk then
		warn(("[RewardService] AwardCash BatchUpdate falló para %s (%s): %s"):format(player.Name, sourceLabel, tostring(batchErr)))
		return false
	elseif batchErr == false then
		return false
	end

	TelemetryService.RecordFlow(player, "source", sourceLabel, amount, itemSku, "Cash")
	return true
end

--[[
	AwardGems: concede Gems (moneda premium).
	Deliberadamente NO pasa por `ActionRewards` (lo que se gana JUGANDO): los Gems solo
	salen del Battle Pass o de packs con Robux, y así nadie añade un faucet de Gems a una kill.
	Únicos callers legítimos:
	  • BattlePassService — recompensa de tier con Kind = "Gems".
	  • ServerBootstrap.ProcessReceipt — compra de un pack de Gems con Robux.

	`sourceLabel` es el transactionType para analytics. Devuelve true si se persistió.
]]
function RewardService.AwardGems(player: Player, amount: number, sourceLabel: string, itemSku: string?): boolean
	if not _dataService or not player or type(amount) ~= "number" or amount <= 0 then
		return false
	end

	amount = math.floor(amount)
	if not _dataService:GetProfile(player) then
		return false
	end

	local updates: { BatchUpdateEntry } = {
		{ path = { "Stats", "Gems" }, delta = amount },
		{ path = { "Stats", "TotalGemsEarned" }, delta = amount },
	}

	local batchOk, batchErr = pcall(function()
		return _dataService:BatchUpdate(player, updates)
	end)
	if not batchOk then
		warn(("[RewardService] AwardGems BatchUpdate falló para %s (%s): %s"):format(player.Name, sourceLabel, tostring(batchErr)))
		return false
	elseif batchErr == false then
		return false
	end

	TelemetryService.RecordFlow(player, "source", sourceLabel, amount, itemSku, "Gems")
	return true
end

--[[
	SpendGems: descuenta Gems. Devuelve false si el saldo es insuficiente.
	El descuento va por `delta` negativo, no por asignación: un `value` absoluto perdería
	cambios concurrentes a Stats.Gems entre la lectura del saldo y la escritura.
]]
function RewardService.SpendGems(player: Player, amount: number, sinkLabel: string, itemSku: string?): boolean
	if not _dataService or not player or type(amount) ~= "number" or amount <= 0 then
		return false
	end

	amount = math.floor(amount)
	local profile = _dataService:GetProfile(player)
	if not profile or not profile.Data then
		return false
	end

	local current = profile.Data.Stats.Gems or 0
	if current < amount then
		return false
	end

	local batchOk, batchErr = pcall(function()
		return _dataService:BatchUpdate(player, {
			{ path = { "Stats", "Gems" }, delta = -amount },
		})
	end)
	if not batchOk then
		warn(("[RewardService] SpendGems BatchUpdate falló para %s (%s): %s"):format(player.Name, sinkLabel, tostring(batchErr)))
		return false
	elseif batchErr == false then
		return false
	end

	TelemetryService.RecordFlow(player, "sink", sinkLabel, amount, itemSku, "Gems")
	return true
end

return RewardService
