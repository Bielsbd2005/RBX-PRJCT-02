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

-- ── Onboarding Funnel ──────────────────────────────────────────
-- Steps:
--   1 = Joined (player entered game)
--   2 = FirstMatchStarted (pressed Play for the first time ever)
--   3 = FirstKill (got first kill ever)
--   4 = FirstMatchCompleted (finished first round)
--   5 = ReturnedToLobby (back in menu after first round)

local ONBOARDING_FUNNEL = "PlayerOnboarding"

function EconomyAnalytics.OnboardingStep(player: Player, step: number)
	pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, ONBOARDING_FUNNEL)
	end)
end

-- ── Custom Funnels ─────────────────────────────────────────────
-- BattlePass Premium conversion:
--   1 = ClickedBuyPremium (client requested purchase)
--   2 = PromptShown (Roblox purchase modal shown)
--   3 = Purchased (receipt processed, premium granted)

local BP_PREMIUM_FUNNEL = "BattlePassPremium"

function EconomyAnalytics.BPPremiumStep(player: Player, step: number, sessionId: string?)
	pcall(function()
		AnalyticsService:LogFunnelStepEvent(player, BP_PREMIUM_FUNNEL, sessionId, step)
	end)
end

return EconomyAnalytics
