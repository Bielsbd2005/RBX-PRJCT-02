--!strict
--[[
	EconomyAnalytics.luau
	Wrapper sobre AnalyticsService:LogEconomyEvent para rastrear la salud de la
	economía desde el dashboard de Roblox (Creator Hub → Analytics → Economy).

	Todos los flujos de Cash (sources y sinks) deben pasar por aquí. El módulo
	es fire-and-forget: nunca lanza errores ni bloquea al caller.

	Documentación Roblox:
	  flowType: Enum.AnalyticsEconomyFlowType.Source | .Sink
	  currencyType: string libre ("Cash")
	  amount: número positivo
	  endingBalance: balance tras la operación
	  transactionType: string libre (la categoría en el dashboard)
	  itemSku: string opcional (identifica el ítem concreto)
]]

local AnalyticsService = game:GetService("AnalyticsService")

local EconomyAnalytics = {}

local function _log(
	player: Player,
	flowType: Enum.AnalyticsEconomyFlowType,
	amount: number,
	endingBalance: number,
	transactionType: string,
	itemSku: string?
)
	if amount <= 0 then return end

	pcall(function()
		AnalyticsService:LogEconomyEvent(
			player,
			flowType,
			"Cash",
			amount,
			math.max(0, math.floor(endingBalance)),
			transactionType,
			itemSku
		)
	end)
end

function EconomyAnalytics.Source(
	player: Player,
	amount: number,
	endingBalance: number,
	transactionType: string,
	itemSku: string?
)
	_log(player, Enum.AnalyticsEconomyFlowType.Source, amount, endingBalance, transactionType, itemSku)
end

function EconomyAnalytics.Sink(
	player: Player,
	amount: number,
	endingBalance: number,
	transactionType: string,
	itemSku: string?
)
	_log(player, Enum.AnalyticsEconomyFlowType.Sink, amount, endingBalance, transactionType, itemSku)
end

return EconomyAnalytics
