--!strict
--[[
	VotingService.luau
	Flujo completo de votación de mapas: estado del voto activo, cooldowns,
	timer, broadcasts y resolución del ganador.

	El CUÁNDO votar lo decide la máquina de fases de MatchService — StartVote
	solo se llama desde la transición Idle → Voting. Al cerrar la votación se
	invoca `onVoteFinished(winnerMapName)` (inyectado via Start), con el que
	MatchService transiciona a Loading.

	El handler `_onRequestVoteSync` permanece en MatchService porque hace 5
	SendTo (sólo uno es voto). VotingService expone `SendSnapshotTo(player)`
	para la parte de votación.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)
local GameConfig = require(Shared.GameConfig)

type MapDefinition = typeof(GameConfig.Maps[1])

type ActiveVoteState = {
	options: { MapDefinition },
	optionNames: { string },
	optionImages: { [string]: string },
	voteCounts: { [string]: number },
	votesByUserId: { [number]: string },
	endAt: number,
	duration: number,
}

type Deps = {
	onVoteFinished: (winnerMapName: string) -> (),
}

local VotingService = {}
VotingService.__index = VotingService

-- ── Constantes ───────────────────────────────────────────────

-- Cooldown entre cambios de voto del mismo jugador. 0.3s permite ~3 cambios/seg
-- — suficiente para UX responsive sin permitir spam que sature broadcasts.
local VOTE_CHANGE_COOLDOWN = 0.3
local DEFAULT_PLACEHOLDER_IMAGE = "rbxasset://textures/ui/GuiImagePlaceholder.png"

-- Opción "Random": cuarto candidato siempre presente, sin mapa concreto. Si gana
-- (o gana el desempate), se resuelve a un mapa aleatorio entre las 3 opciones.
local RANDOM_KEY = GameConfig.RandomVoteKey

-- ── Estado ───────────────────────────────────────────────────

local _deps: Deps = nil :: any
local _started = false
local _activeVote: ActiveVoteState? = nil
local _voteCooldownsByUserId: { [number]: number } = {}
local _lastVoteBroadcastKey: string? = nil
local _castVoteConn: any = nil

-- ── Helpers privados ─────────────────────────────────────────

local function _pickRandomMapOptions(pool: { MapDefinition }, count: number): { MapDefinition }
	local shuffled = table.clone(pool)
	for i = #shuffled, 2, -1 do
		local j = math.random(1, i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end

	local picked = {} :: { MapDefinition }
	for i = 1, math.min(count, #shuffled) do
		table.insert(picked, shuffled[i])
	end
	return picked
end

local function _collectVoterIds(vote: ActiveVoteState, mapName: string): string
	local ids = {}
	for userId, votedMap in vote.votesByUserId do
		if votedMap == mapName then
			table.insert(ids, tostring(userId))
		end
	end
	return table.concat(ids, ",")
end

local function _buildVoteStatePacket(vote: ActiveVoteState, timeLeft: number)
	return {
		option1Name = vote.optionNames[1],
		option1VoterIds = _collectVoterIds(vote, vote.optionNames[1]),
		option2Name = vote.optionNames[2],
		option2VoterIds = _collectVoterIds(vote, vote.optionNames[2]),
		option3Name = vote.optionNames[3],
		option3VoterIds = _collectVoterIds(vote, vote.optionNames[3]),
		randomVoterIds = _collectVoterIds(vote, RANDOM_KEY),
		timeLeft = math.max(0, timeLeft),
	}
end

local function _broadcastVoteState(vote: ActiveVoteState)
	local timeLeft = math.ceil(math.max(0, vote.endAt - time()))
	local packet = _buildVoteStatePacket(vote, timeLeft)
	local key = string.format(
		"%s|%s|%s|%s|%s|%s|%s|%d",
		tostring(packet.option1Name), packet.option1VoterIds,
		tostring(packet.option2Name), packet.option2VoterIds,
		tostring(packet.option3Name), packet.option3VoterIds,
		packet.randomVoterIds,
		packet.timeLeft
	)
	if key == _lastVoteBroadcastKey then
		return
	end
	_lastVoteBroadcastKey = key
	Network.Match.VoteState.SendToAll(packet)
end

local function _isVoteChangeAllowed(player: Player): boolean
	local now = time()
	local last = _voteCooldownsByUserId[player.UserId] or 0
	if now - last < VOTE_CHANGE_COOLDOWN then
		return false
	end
	_voteCooldownsByUserId[player.UserId] = now
	return true
end

-- La opción Random es válida además de los 3 mapas concretos.
local function _isValidOption(vote: ActiveVoteState, mapName: string): boolean
	if mapName == RANDOM_KEY then
		return true
	end
	for _, optionName in vote.optionNames do
		if optionName == mapName then
			return true
		end
	end
	return false
end

-- Devuelve siempre un mapa concreto. Candidatos = 3 mapas + Random; si gana
-- Random (o el desempate lo elige), se resuelve a un mapa aleatorio entre los 3.
local function _resolveWinner(vote: ActiveVoteState): string
	local connectedByUserId = {} :: { [number]: true }
	for _, player in Players:GetPlayers() do
		connectedByUserId[player.UserId] = true
	end

	local candidates = table.clone(vote.optionNames)
	table.insert(candidates, RANDOM_KEY)

	local validCounts = {} :: { [string]: number }
	for _, optionKey in candidates do
		validCounts[optionKey] = 0
	end

	for userId, mapName in vote.votesByUserId do
		if connectedByUserId[userId] and validCounts[mapName] ~= nil then
			validCounts[mapName] += 1
		end
	end

	local maxVotes = -1
	local tied = {} :: { string }
	for _, optionKey in candidates do
		local count = validCounts[optionKey] or 0
		if count > maxVotes then
			maxVotes = count
			table.clear(tied)
			table.insert(tied, optionKey)
		elseif count == maxVotes then
			table.insert(tied, optionKey)
		end
	end

	local winner = if #tied == 0
		then candidates[math.random(1, #candidates)]
		else tied[math.random(1, #tied)]

	if winner == RANDOM_KEY then
		winner = vote.optionNames[math.random(1, #vote.optionNames)]
	end
	return winner
end

local function _onCastVote(data: { mapName: string }, player: Player)
	-- Cap longitud antes de cualquier processing — protege contra payloads
	-- arbitrariamente grandes que harían trabajo en _isValidOption / format.
	if not NetGuards.validate(data, { mapName = NetGuards.MAX.MapName }) then
		return
	end

	local vote = _activeVote
	if not vote then
		return
	end

	if not _isVoteChangeAllowed(player) then
		return
	end

	local mapName = data.mapName
	if mapName == "" or not _isValidOption(vote, mapName) then
		return
	end

	local previous = vote.votesByUserId[player.UserId]
	if previous == mapName then
		return
	end

	if previous then
		local oldCount = vote.voteCounts[previous] or 0
		vote.voteCounts[previous] = math.max(0, oldCount - 1)
	end

	vote.votesByUserId[player.UserId] = mapName
	vote.voteCounts[mapName] = (vote.voteCounts[mapName] or 0) + 1

	-- Broadcast inmediato: sin esto el cambio solo se vería en el siguiente tick
	-- del timer (hasta ~1s de latencia). El dedupe-key evita reenvíos redundantes.
	_broadcastVoteState(vote)
end

local function _runVoteTimer(vote: ActiveVoteState)
	while _activeVote == vote do
		local remaining = vote.endAt - time()
		if remaining <= 0 then
			break
		end
		_broadcastVoteState(vote)
		task.wait(1)
	end

	if _activeVote ~= vote then
		return
	end

	_broadcastVoteState(vote)
	local winner = _resolveWinner(vote)

	local totalVoters = 0
	for _ in vote.votesByUserId do
		totalVoters += 1
	end
	local anyPlayer = Players:GetPlayers()[1]
	if anyPlayer then
		pcall(function()
			AnalyticsService:LogCustomEvent(anyPlayer, "MapVoteWinner", 1, {
				map = winner,
				voters = tostring(totalVoters),
				playerCount = tostring(#Players:GetPlayers()),
			})
		end)
	end

	Network.Match.EndVote.SendToAll({ winnerMapName = winner })

	_activeVote = nil
	task.defer(function()
		_deps.onVoteFinished(winner)
	end)
end

-- ── API pública ──────────────────────────────────────────────

function VotingService:Start(deps: Deps)
	if _started then
		return
	end
	_started = true
	_deps = deps
	_activeVote = nil
	_lastVoteBroadcastKey = nil
	table.clear(_voteCooldownsByUserId)

	_castVoteConn = Network.Match.CastVote.Listen(_onCastVote)
end

function VotingService:HasActiveVote(): boolean
	return _activeVote ~= nil
end

function VotingService:SendSnapshotTo(player: Player)
	local vote = _activeVote
	if not vote then
		return
	end

	local option1Name = vote.optionNames[1]
	local option2Name = vote.optionNames[2]
	local option3Name = vote.optionNames[3]
	if not option1Name or not option2Name or not option3Name then
		return
	end

	local okStart = pcall(function()
		Network.Match.StartVote.SendTo({
			option1Name = option1Name,
			option1Image = vote.optionImages[option1Name] or DEFAULT_PLACEHOLDER_IMAGE,
			option2Name = option2Name,
			option2Image = vote.optionImages[option2Name] or DEFAULT_PLACEHOLDER_IMAGE,
			option3Name = option3Name,
			option3Image = vote.optionImages[option3Name] or DEFAULT_PLACEHOLDER_IMAGE,
			duration = vote.duration,
		}, player)
	end)

	if not okStart then
		return
	end

	local timeLeft = math.ceil(math.max(0, vote.endAt - time()))
	pcall(function()
		Network.Match.VoteState.SendTo(_buildVoteStatePacket(vote, timeLeft), player)
	end)
end

function VotingService:DisconnectPlayer(userId: number)
	local vote = _activeVote
	if not vote then
		_voteCooldownsByUserId[userId] = nil
		return
	end

	local previous = vote.votesByUserId[userId]
	if previous then
		vote.votesByUserId[userId] = nil
		local oldCount = vote.voteCounts[previous] or 0
		vote.voteCounts[previous] = math.max(0, oldCount - 1)
		_broadcastVoteState(vote)
	end
	_voteCooldownsByUserId[userId] = nil
end

-- Arranca una votación. Devuelve false si ya hay una activa o faltan mapas.
-- Las condiciones de flujo (fase Idle, jugadores suficientes) las valida la
-- máquina de fases de MatchService antes de llamar.
function VotingService:StartVote(): boolean
	if _activeVote ~= nil then
		return false
	end

	local pool = GameConfig.Maps
	if #pool < 3 then
		warn("[VotingService] Se requieren al menos 3 mapas para iniciar la votacion.")
		return false
	end

	local options = _pickRandomMapOptions(pool, 3)
	local optionNames = { options[1].Name, options[2].Name, options[3].Name }
	local voteCounts = {
		[optionNames[1]] = 0,
		[optionNames[2]] = 0,
		[optionNames[3]] = 0,
		[RANDOM_KEY] = 0,
	}
	local optionImages = {
		[optionNames[1]] = options[1].PlaceholderImage ~= "" and options[1].PlaceholderImage or DEFAULT_PLACEHOLDER_IMAGE,
		[optionNames[2]] = options[2].PlaceholderImage ~= "" and options[2].PlaceholderImage or DEFAULT_PLACEHOLDER_IMAGE,
		[optionNames[3]] = options[3].PlaceholderImage ~= "" and options[3].PlaceholderImage or DEFAULT_PLACEHOLDER_IMAGE,
	}

	local voteState: ActiveVoteState = {
		options = options,
		optionNames = optionNames,
		optionImages = optionImages,
		voteCounts = voteCounts,
		votesByUserId = {},
		endAt = time() + GameConfig.VoteDuration,
		duration = GameConfig.VoteDuration,
	}

	_activeVote = voteState
	-- Reset del dedupe key — el nuevo vote tiene otras opciones, debemos
	-- broadcastear el primer estado aunque numéricamente coincida con basura.
	_lastVoteBroadcastKey = nil
	-- Limpiar cooldowns viejos del voto anterior para que el primer voto del
	-- nuevo ciclo no quede bloqueado.
	table.clear(_voteCooldownsByUserId)

	Network.Match.StartVote.SendToAll({
		option1Name = optionNames[1],
		option1Image = optionImages[optionNames[1]],
		option2Name = optionNames[2],
		option2Image = optionImages[optionNames[2]],
		option3Name = optionNames[3],
		option3Image = optionImages[optionNames[3]],
		duration = GameConfig.VoteDuration,
	})

	_broadcastVoteState(voteState)
	task.spawn(_runVoteTimer, voteState)
	return true
end

return VotingService
