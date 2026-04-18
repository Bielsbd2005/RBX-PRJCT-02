--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopulationManager = require(script.PopulationManager)

export type OnBotDiedCallback = ("A" | "B", string) -> ()

type RoundStartOptions = {
	spawnPointsA: { BasePart },
	spawnPointsB: { BasePart },
	onBotDied: OnBotDiedCallback?,
}

local AIService = {}

local _populationManager: PopulationManager.PopulationManagerType? = nil
local _startedRound = false

local function _log(message: string)
	print("[AIService] " .. message)
end

local function _resolveTemplate(): Instance?
	local templatesFolder = Shared:FindFirstChild("templates")
	if not templatesFolder then
		return nil
	end

	local direct = templatesFolder:FindFirstChild("CharacterTemplate")
	if direct then
		return direct
	end

	for _, child in templatesFolder:GetChildren() do
		if child:IsA("Model") or child:IsA("Folder") then
			return child
		end
	end

	return nil
end

local function _getPopulationManager(): PopulationManager.PopulationManagerType?
	if _populationManager then
		return _populationManager
	end

	local template = _resolveTemplate()
	if not template then
		warn("[AIService] CharacterTemplate not found in ReplicatedStorage.Shared.templates")
		return nil
	end

	_populationManager = PopulationManager.new(template)
	return _populationManager
end

function AIService:OnRoundStart(options: RoundStartOptions)
	local manager = _getPopulationManager()
	if not manager then
		return
	end

	manager:startRound({
		A = options.spawnPointsA,
		B = options.spawnPointsB,
	}, options.onBotDied)
	_startedRound = true
	_log("Round started.")
end

function AIService:SetBotTargets(targetA: number, targetB: number)
	if not _startedRound then
		return
	end

	local manager = _getPopulationManager()
	if not manager then
		return
	end

	manager:setBotTargets(targetA, targetB)
end

function AIService:GetBotCounts(): (number, number)
	local manager = _getPopulationManager()
	if not manager then
		return 0, 0
	end

	return manager:getBotCounts()
end

function AIService:OnRoundEnd()
	_startedRound = false
	if _populationManager then
		_populationManager:clearAll()
	end
	_log("Round ended.")
end

return AIService
