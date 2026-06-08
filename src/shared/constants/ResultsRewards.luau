--!strict
--[[
	ResultsRewards.luau
	Catálogo ÚNICO y editable de las recompensas de CASH que se conceden al
	terminar una partida (pantalla de Resultados).

	── Cómo personalizar ────────────────────────────────────────
	Editá la lista `ResultsRewards.CashRewards`. Cada entry es una recompensa
	que se evalúa por jugador según su contexto de fin de partida:

	  {
	    Id        = "Victory",   -- identificador único (analytics: "MatchEnd::Victory")
	    Title     = "VICTORY",   -- texto que se pinta en CashTemplate.Title.Value
	    Condition = "Victory",   -- cuándo aplica (ver RewardCondition)
	    Cash      = 100,         -- monto que se concede
	    RequiresVIP = true,      -- (opcional) solo VIP la reciben; los no-VIP la
	                             --            ven en gris + "Locked" como upsell.
	  }

	Para añadir/quitar/retocar recompensas, basta con tocar esta tabla — ni el
	server ni el cliente necesitan otros cambios. Los montos NO están sujetos al
	MatchCashCap (son bonus fijos de fin de partida, no de combate).

	Condiciones disponibles (RewardCondition):
	  • "Always"  → todos los jugadores que jugaron la partida.
	  • "Victory" → solo el equipo ganador.
	  • "Defeat"  → solo el equipo perdedor (incluye empate).
	  • "MVP"     → el jugador con más kills de su equipo (kills > 0).

	Los items (locker / pase de batalla) NO se configuran acá: la pantalla solo
	MUESTRA lo desbloqueado durante la partida (lo computa el server desde el
	nivel y el tier de BP). Ver MatchResultsService.
]]

export type RewardCondition = "Always" | "Victory" | "Defeat" | "MVP"

export type CashRewardDef = {
	Id: string,
	Title: string,
	Condition: RewardCondition,
	Cash: number,
	RequiresVIP: boolean?,
}

-- Contexto de fin de partida de UN jugador, para evaluar las condiciones.
export type MatchContext = {
	won: boolean,
	lost: boolean,
	isMVP: boolean,
	isVIP: boolean,
}

-- Recompensa de cash ya resuelta para un jugador concreto. `locked` = true
-- significa "mostrar en gris + Locked, NO conceder" (caso no-VIP de un bonus VIP).
export type ResolvedCashReward = {
	id: string,
	title: string,
	cash: number,
	locked: boolean,
}

local ResultsRewards = {}

-- Icono (ImageLabel.Image) que se muestra para las recompensas de CASH en el
-- template de Resultados. Editable.
ResultsRewards.CashIcon = "rbxassetid://113694528712529"

-- ÚNICA fuente de verdad de las recompensas de cash de fin de partida.
ResultsRewards.CashRewards = {
	{ Id = "Match", Title = "MATCH", Condition = "Always", Cash = 50 },
	{ Id = "Victory", Title = "VICTORY", Condition = "Victory", Cash = 100 },
	{ Id = "Defeat", Title = "DEFEAT", Condition = "Defeat", Cash = 25 },
	{ Id = "MVP", Title = "MVP", Condition = "MVP", Cash = 75 },
	{ Id = "VIP", Title = "VIP PASS", Condition = "Always", Cash = 100, RequiresVIP = true },
} :: { CashRewardDef }

local function _conditionMet(condition: RewardCondition, ctx: MatchContext): boolean
	if condition == "Always" then
		return true
	elseif condition == "Victory" then
		return ctx.won
	elseif condition == "Defeat" then
		return ctx.lost
	elseif condition == "MVP" then
		return ctx.isMVP
	end
	return false
end

--[[
	resolveCash: devuelve, en orden de config, las recompensas de cash que
	APLICAN a este jugador (para mostrar). Cada una trae `locked` calculado:
	un bonus RequiresVIP que el jugador no posee se devuelve `locked = true`
	(se muestra pero no se concede).
]]
function ResultsRewards.resolveCash(ctx: MatchContext): { ResolvedCashReward }
	local out: { ResolvedCashReward } = {}
	for _, def in ResultsRewards.CashRewards do
		if _conditionMet(def.Condition, ctx) then
			table.insert(out, {
				id = def.Id,
				title = def.Title,
				cash = def.Cash,
				locked = def.RequiresVIP == true and not ctx.isVIP,
			})
		end
	end
	return out
end

return ResultsRewards
