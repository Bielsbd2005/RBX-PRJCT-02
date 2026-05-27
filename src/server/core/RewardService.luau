--!strict
--[[
	RewardService.luau
	Punto único de aplicación de recompensas (XP + Cash) para jugadores.

	Sustituye el patrón disperso de `DataService:Increment(player, {"Stats",
	"Cash"}, n)` + `DataService:AddXP(player, n)` que estaba esparcido por
	MatchService, WeaponsSystem, DailyTasksService y RewardsService.

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
local EconomyAnalytics = require(script.Parent.EconomyAnalytics)

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
	Award: concede XP y Cash de `actionKey` al jugador, aplicando opcionalmente
	`extraUpdates` atómicamente con el Cash.

	Retorna (ok, xpGranted, cashGranted). ok=true incluso si xpGranted=0 o
	cashGranted=0 (acciones cuya tabla tenga 0 son legítimas — siempre que la
	clave exista). Devuelve (false, 0, 0) si la clave no existe o el profile
	no está cargado.
]]
function RewardService.Award(
	player: Player,
	actionKey: string,
	extraUpdates: { BatchUpdateEntry }?,
	itemSku: string?
): (boolean, number, number)
	if not _dataService or not player then
		return false, 0, 0
	end

	if not ActionRewards.Has(actionKey) then
		warn(("[RewardService] Acción desconocida: %s — no se concede nada"):format(tostring(actionKey)))
		return false, 0, 0
	end

	if not _dataService:GetProfile(player) then
		-- Sin profile no podemos persistir nada. Los callers que necesiten esperar
		-- al ProfileLoaded deben encolar ellos mismos (p.ej. MatchService ya tiene
		-- _deferUntilProfile para kills durante el join window).
		return false, 0, 0
	end

	local xpAmount = ActionRewards.GetXP(actionKey)
	local cashAmount = ActionRewards.GetCash(actionKey)

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

	local ok = true
	if #updates > 0 then
		local batchOk, batchErr = pcall(function()
			return _dataService:BatchUpdate(player, updates)
		end)
		if not batchOk then
			warn(("[RewardService] BatchUpdate falló para %s (action=%s): %s"):format(player.Name, actionKey, tostring(batchErr)))
			ok = false
		elseif batchErr == false then
			-- BatchUpdate devolvió false (sin error pero sin éxito).
			ok = false
		end
	end

	if xpAmount > 0 then
		local xpOk, xpErr = pcall(function()
			_dataService:AddXP(player, xpAmount)
		end)
		if not xpOk then
			warn(("[RewardService] AddXP falló para %s (action=%s): %s"):format(player.Name, actionKey, tostring(xpErr)))
			ok = false
		end
	end

	if ok and cashAmount > 0 then
		local profile = _dataService:GetProfile(player)
		local balance = if profile and profile.Data then profile.Data.Stats.Cash else 0
		EconomyAnalytics.Source(player, cashAmount, balance, actionKey, itemSku)
	end

	return ok, xpAmount, cashAmount
end

return RewardService
