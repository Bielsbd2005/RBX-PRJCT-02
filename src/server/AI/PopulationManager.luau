--!strict

local NPCEntity = require(script.Parent.NPCEntity)

export type Side = "A" | "B"

type OnBotDiedCallback = (Side, string) -> ()

type SpawnMap = {
	A: { BasePart },
	B: { BasePart },
}

type BotEntry = {
	id: number,
	entity: NPCEntity.NPCEntityType,
}

export type PopulationManagerType = {
	startRound: (self: PopulationManagerType, spawnPoints: SpawnMap, onBotDied: OnBotDiedCallback?) -> (),
	setBotTargets: (self: PopulationManagerType, targetA: number, targetB: number) -> (),
	clearAll: (self: PopulationManagerType) -> (),
	getBotCounts: (self: PopulationManagerType) -> (number, number),
}

type PopulationManagerPrivate = PopulationManagerType & {
	_template: Instance,
	_spawnPoints: SpawnMap,
	_onBotDied: OnBotDiedCallback?,
	_targetByTeam: { A: number, B: number },
	_botsByTeam: { A: { BotEntry }, B: { BotEntry } },
	_nextBotId: number,
}

local PopulationManager = {}
PopulationManager.__index = PopulationManager

local function _removeBotById(entries: { BotEntry }, botId: number)
	for index, entry in ipairs(entries) do
		if entry.id == botId then
			table.remove(entries, index)
			return true
		end
	end

	return false
end

function PopulationManager.new(template: Instance): PopulationManagerType
	local self = setmetatable({} :: PopulationManagerPrivate, PopulationManager)
	self._template = template
	self._spawnPoints = { A = {}, B = {} }
	self._onBotDied = nil
	self._targetByTeam = { A = 0, B = 0 }
	self._botsByTeam = { A = {}, B = {} }
	self._nextBotId = 0
	return self
end

function PopulationManager:_spawnOne(side: Side)
	self._nextBotId += 1
	local botId = self._nextBotId
	local entity = NPCEntity.new(botId, side, self._template, self._spawnPoints[side], function(deadSide, _botName)
		_removeBotById(self._botsByTeam[deadSide], botId)
		if self._onBotDied then
			self._onBotDied(deadSide, _botName)
		end
		self:_reconcileTeam(deadSide)
	end)
	if not entity then
		return
	end

	table.insert(self._botsByTeam[side], {
		id = botId,
		entity = entity,
	})
end

function PopulationManager:_despawnOne(side: Side)
	local entries = self._botsByTeam[side]
	local entry = entries[#entries]
	if not entry then
		return
	end

	table.remove(entries, #entries)
	entry.entity:destroy(true)
end

function PopulationManager:_reconcileTeam(side: Side)
	local target = self._targetByTeam[side]
	local entries = self._botsByTeam[side]

	while #entries < target do
		self:_spawnOne(side)
	end

	while #entries > target do
		self:_despawnOne(side)
	end
end

function PopulationManager:startRound(spawnPoints: SpawnMap, onBotDied: OnBotDiedCallback?)
	self:clearAll()
	self._spawnPoints = {
		A = spawnPoints.A,
		B = spawnPoints.B,
	}
	self._onBotDied = onBotDied
end

function PopulationManager:setBotTargets(targetA: number, targetB: number)
	self._targetByTeam.A = math.max(0, math.floor(targetA))
	self._targetByTeam.B = math.max(0, math.floor(targetB))
	self:_reconcileTeam("A")
	self:_reconcileTeam("B")
end

function PopulationManager:clearAll()
	for _, entry in ipairs(self._botsByTeam.A) do
		entry.entity:destroy(true)
	end
	for _, entry in ipairs(self._botsByTeam.B) do
		entry.entity:destroy(true)
	end
	table.clear(self._botsByTeam.A)
	table.clear(self._botsByTeam.B)
	self._targetByTeam.A = 0
	self._targetByTeam.B = 0
end

function PopulationManager:getBotCounts(): (number, number)
	return #self._botsByTeam.A, #self._botsByTeam.B
end

return PopulationManager
