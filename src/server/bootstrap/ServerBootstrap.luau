--!strict

local StarterGui = game:GetService("StarterGui")

local ServerBootstrap = {}

local _started = false

function ServerBootstrap.start(serverRoot: Script): ()
	if _started then
		return
	end

	_started = true
	StarterGui.ResetPlayerGuiOnSpawn = false

	local DataService = require(serverRoot.core.data.DataService)
	local ShopService = require(serverRoot.features.shop.ShopService)
	local StoreService = require(serverRoot.features.store.StoreService)
	local SettingsService = require(serverRoot.features.settings.SettingsService)
	local RewardsService = require(serverRoot.features.rewards.RewardsService)
	local CasesService = require(serverRoot.features.cases.CasesService)
	local MatchService = require(serverRoot.features.match.MatchService)
	local ClearDataCommandService = require(serverRoot.features.testing.ClearDataCommandService)

	DataService:Start()
	ShopService:Start(DataService)
	StoreService:Start(DataService)
	SettingsService:Start(DataService)
	RewardsService:Start(DataService)
	CasesService:Start(DataService)
	MatchService:Start(DataService)
	ClearDataCommandService:Start(DataService)
end

return ServerBootstrap
