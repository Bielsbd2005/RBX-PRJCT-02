--!strict
--[[
	EconomyAnalytics.luau
	Wrapper sobre AnalyticsService para rastrear:
	  • Economía (LogEconomyEvent) — Creator Hub → Analytics → Economy
	  • Onboarding funnel (LogOnboardingFunnelStepEvent) — retención D1
	  • Funnels custom (LogFunnelStepEvent) — conversión BP Premium

	Fire-and-forget: nunca lanza errores ni bloquea al caller.
]]

local AnalyticsService = game:GetService("AnalyticsService")

local EconomyAnalytics = {}

-- ── Economy ────────────────────────────────────────────────────

local function _logEconomy(
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
	_logEconomy(player, Enum.AnalyticsEconomyFlowType.Source, amount, endingBalance, transactionType, itemSku)
end

function EconomyAnalytics.Sink(
	player: Player,
	amount: number,
	endingBalance: number,
	transactionType: string,
	itemSku: string?
)
	_logEconomy(player, Enum.AnalyticsEconomyFlowType.Sink, amount, endingBalance, transactionType, itemSku)
end

-- ── Items (virtual goods, no currency amount) ─────────────────
-- Registra la adquisición de un item como source de "Items" (amount=1).
-- Permite rastrear en qué proporción los items entran al juego vía
-- BattlePass, mastery, shop, etc.

function EconomyAnalytics.ItemSource(
	player: Player,
	transactionType: string,
	itemSku: string
)
	pcall(function()
		AnalyticsService:LogEconomyEvent(
			player,
			Enum.AnalyticsEconomyFlowType.Source,
			"Items",
			1,
			0,
			transactionType,
			itemSku
		)
	end)
end

-- ── Onboarding Funnel ──────────────────────────────────────────
-- LogOnboardingFunnelStepEvent(player, step, stepName, customData?)
-- Roblox tiene un único funnel de onboarding por experiencia; el tercer
-- argumento es el NOMBRE del paso (label visible en Creator Hub), no un
-- nombre de funnel.

local ONBOARDING_STEP_NAMES = {
	[1] = "Joined",
	[2] = "FirstMatchStarted",
	[3] = "FirstKill",
	[4] = "FirstMatchCompleted",
	[5] = "ReturnedToLobby",
}

function EconomyAnalytics.OnboardingStep(player: Player, step: number)
	local stepName = ONBOARDING_STEP_NAMES[step] or ("Step" .. tostring(step))
	pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, stepName)
	end)
end

-- ── Custom Funnels ─────────────────────────────────────────────
-- LogFunnelStepEvent(player, funnelName, funnelSessionId, step, stepName?)
-- BattlePass Premium conversion:

local BP_PREMIUM_FUNNEL = "BattlePassPremium"
local BP_PREMIUM_STEP_NAMES = {
	[1] = "ClickedBuyPremium",
	[2] = "PromptShown",
	[3] = "Purchased",
}

function EconomyAnalytics.BPPremiumStep(player: Player, step: number, sessionId: string?)
	local stepName = BP_PREMIUM_STEP_NAMES[step]
	pcall(function()
		AnalyticsService:LogFunnelStepEvent(player, BP_PREMIUM_FUNNEL, sessionId, step, stepName)
	end)
end

return EconomyAnalytics
