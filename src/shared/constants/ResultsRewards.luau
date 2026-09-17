--!strict
--[[
	Recompensas de CASH de fin de partida. Tocar CashRewards basta: server y cliente
	no necesitan más cambios. No cuentan para MatchCashCap.
	  Id          → telemetría como "MatchEnd::<Id>"
	  RequiresVIP → los no-VIP la ven en gris + "Locked" como upsell, sin concederse
	Condiciones: "Defeat" incluye empate; "MVP" = más kills de su equipo (kills > 0).
	Los items desbloqueados en la partida no se configuran aquí (MatchResultsService).
]]

export type RewardCondition = "Always" | "Victory" | "Defeat" | "MVP"

export type CashRewardDef = {
	Id: string,
	Title: string,
	Condition: RewardCondition,
	Cash: number,
	RequiresVIP: boolean?,
}

export type MatchContext = {
	won: boolean,
	lost: boolean,
	isMVP: boolean,
	isVIP: boolean,
}

-- `locked` = mostrar pero NO conceder.
export type ResolvedCashReward = {
	id: string,
	title: string,
	cash: number,
	locked: boolean,
}

local ResultsRewards = {}

ResultsRewards.CashIcon = "rbxassetid://113694528712529"

-- Remate visible, no la fuente principal de Cash (esa es el combate): solo se paga
-- por ganar o ser el mejor, nunca por participar. Una entry con Cash = 0 el server
-- la ignora pero el cliente la pintaría.
ResultsRewards.CashRewards = {
	{ Id = "Victory", Title = "VICTORY", Condition = "Victory", Cash = 30 },
	{ Id = "MVP", Title = "MVP", Condition = "MVP", Cash = 20 },
	{ Id = "VIP", Title = "VIP PASS", Condition = "Always", Cash = 25, RequiresVIP = true },
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

-- En orden de config, incluidas las bloqueadas (locked) para mostrarlas.
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
