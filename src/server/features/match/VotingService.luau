--!strict
--[[
	VotingService.luau
	Flujo completo de votación de mapas. Extraído de MatchService como parte
	del split estructural (audit AAA).

	Estado propio:
		_activeVote, _voteCooldownsByUserId, _hasCompletedInitialVote,
		_lastVoteBroadcastKey

	Dependencias inyectadas (via Start):
		log, setPhase  -- logging y phase transitions del state machine
		getIsMapLoading, getIsPlayEnabled  -- gates externos para no arrancar voto
		onVoteFinished  -- callback con winnerMapName, MatchService inicia mapload

	El handler `_onRequestVoteSync` permanece en MatchService porque hace 5
	SendTo (sólo uno es voto). VotingService expone `SendSnapshotTo(player)`
	para la parte de votación.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local _ = ServerStorage  -- silenciar selene unused warning, no usado directo

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)
local GameConfig = require(Shared.GameConfig)

type MapDefinition = typeof(GameConfig.Maps[1])

type ActiveVoteState = {
	options: { MapDefinition },
	optionNames: { string },
	optionImages: { [string]: string },
	optionModes: { [string]: string },
	voteCounts: { [string]: number },
	votesByUserId: { [number]: string },
	endAt: number,
	duration: number,
}

type Deps = {
	log: (msg: string) -> (),
	setPhase: (phase: string, reason: string) -> (),
	getIsMapLoading: () -> boolean,
	getIsPlayEnabled: () -> boolean,
	onVoteFinished: (winnerMapName: string) -> (),
}

local VotingService = {}
VotingService.__index = VotingService

-- ── Constantes ───────────────────────────────────────────────

-- Cooldown entre cambios de voto del mismo jugador. 0.5s permite ~2 cambios/seg
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
local _hasCompletedInitialVote = false
local _castVoteConn: any = nil
-- Retención: ninguna votación puede arrancar antes de este time() (se usa para
-- que la votación no empiece hasta que termine la pantalla de Resultados).
local _voteHoldUntil = 0

-- ── Helpers privados ─────────────────────────────────────────

local function _containsMode(modes: { string }, mode: string): boolean
	for _, candidate in modes do
		if candidate == mode then
			return true
		end
	end
	return false
end

local function _collectCompatibleMaps(mode: string): { MapDefinition }
	local compatible = {} :: { MapDefinition }
	for _, mapDef in GameConfig.Maps do
		if mapDef.Name ~= "" and _containsMode(mapDef.Modes, mode) then
			table.insert(compatible, mapDef)
		end
	end
	return compatible
end

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
		_deps.log(string.format("Ignored vote from %s: no active vote.", player.Name))
		return
	end

	if not _isVoteChangeAllowed(player) then
		_deps.log(string.format("Rate-limited vote from %s.", player.Name))
		return
	end

	local mapName = data.mapName
	if mapName == "" or not _isValidOption(vote, mapName) then
		_deps.log(string.format("Ignored invalid vote from %s for map '%s'.", player.Name, mapName))
		return
	end

	local previous = vote.votesByUserId[player.UserId]
	if previous == mapName then
		_deps.log(string.format("Ignored duplicate vote from %s for map '%s'.", player.Name, mapName))
		return
	end

	if previous then
		local oldCount = vote.voteCounts[previous] or 0
		vote.voteCounts[previous] = math.max(0, oldCount - 1)
	end

	vote.votesByUserId[player.UserId] = mapName
	vote.voteCounts[mapName] = (vote.voteCounts[mapName] or 0) + 1
	_deps.log(string.format("Vote updated: %s -> '%s' (previous: %s)", player.Name, mapName, previous or "none"))

	-- Broadcast inmediato: sin esto el cambio solo se vería en el siguiente tick
	-- del timer (hasta ~1s de latencia). El dedupe-key evita reenvíos redundantes.
	_broadcastVoteState(vote)
end

local function _runVoteTimer(vote: ActiveVoteState)
	_deps.setPhase("Voting", string.format(
		"options=[%s, %s, %s], duration=%ds",
		vote.optionNames[1], vote.optionNames[2], vote.optionNames[3], vote.duration
	))

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
	_deps.setPhase("VoteEnded", "winner=" .. winner)
	_deps.log(string.format("Vote finished. Winner map: '%s'.", winner))

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
	_hasCompletedInitialVote = true
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
	_hasCompletedInitialVote = false
	_lastVoteBroadcastKey = nil
	_voteHoldUntil = 0
	table.clear(_voteCooldownsByUserId)

	_castVoteConn = Network.Match.CastVote.Listen(_onCastVote)
end

-- Retiene el arranque de la votación durante `seconds` (p. ej. la duración de la
-- pantalla de Resultados, para que el voto no empiece hasta que esta termine).
function VotingService:HoldVotingFor(seconds: number)
	_voteHoldUntil = time() + math.max(0, seconds)
end

function VotingService:HasActiveVote(): boolean
	return _activeVote ~= nil
end

function VotingService:HasCompletedInitialVote(): boolean
	return _hasCompletedInitialVote
end

function VotingService:ResetCompletedFlag()
	_hasCompletedInitialVote = false
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
		_deps.log("Skipped active vote snapshot: incomplete option names.")
		return
	end

	local okStart, errStart = pcall(function()
		Network.Match.StartVote.SendTo({
			option1Name = option1Name,
			option1Image = vote.optionImages[option1Name] or DEFAULT_PLACEHOLDER_IMAGE,
			option1Mode = vote.optionModes[option1Name] or "TeamDeathmatch",
			option2Name = option2Name,
			option2Image = vote.optionImages[option2Name] or DEFAULT_PLACEHOLDER_IMAGE,
			option2Mode = vote.optionModes[option2Name] or "TeamDeathmatch",
			option3Name = option3Name,
			option3Image = vote.optionImages[option3Name] or DEFAULT_PLACEHOLDER_IMAGE,
			option3Mode = vote.optionModes[option3Name] or "TeamDeathmatch",
			duration = vote.duration,
		}, player)
	end)

	if not okStart then
		_deps.log(string.format("Failed StartVote snapshot to %s: %s", player.Name, tostring(errStart)))
		return
	end

	local timeLeft = math.ceil(math.max(0, vote.endAt - time()))
	local okState, errState = pcall(function()
		Network.Match.VoteState.SendTo(_buildVoteStatePacket(vote, timeLeft), player)
	end)

	if not okState then
		_deps.log(string.format("Failed VoteState snapshot to %s: %s", player.Name, tostring(errState)))
		return
	end

	_deps.log(string.format("Sent active vote snapshot to %s (timeLeft=%ds).", player.Name, timeLeft))
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
		_deps.log(string.format("Player %d left vote. Removed vote from map '%s'.", userId, previous))
		_broadcastVoteState(vote)
	end
	_voteCooldownsByUserId[userId] = nil
end

function VotingService:StartVoteIfPossible(): boolean
	-- Retención post-Results: la votación no arranca hasta que termina la pantalla
	-- de Resultados (cualquier disparador —RequestVoteSync, etc.— respeta esto).
	if time() < _voteHoldUntil then
		_deps.log("Vote start held: Results window still active.")
		return false
	end

	if _activeVote ~= nil or _hasCompletedInitialVote then
		if _activeVote ~= nil then
			_deps.log("Vote start skipped: already voting.")
		else
			_deps.log("Vote start skipped: initial vote already completed.")
		end
		return false
	end

	if _deps.getIsMapLoading() or _deps.getIsPlayEnabled() then
		_deps.log("Vote start skipped: map flow already active.")
		return false
	end

	local playerCount = #Players:GetPlayers()
	if playerCount < GameConfig.MinPlayersToStart then
		_deps.log(string.format("Vote start blocked: players=%d, required=%d.", playerCount, GameConfig.MinPlayersToStart))
		return false
	end

	local pool = _collectCompatibleMaps("TeamDeathmatch")
	if #pool < 3 then
		_deps.log(string.format("Vote start blocked: compatible maps=%d, required=3.", #pool))
		warn("[VotingService] Se requieren al menos 3 mapas compatibles para iniciar la votacion.")
		return false
	end

	local options = _pickRandomMapOptions(pool, 3)
	if #options < 3 then
		_deps.log(string.format("Vote start blocked: random option selection returned %d maps.", #options))
		return false
	end

	_deps.setPhase("VoteStarting", string.format("players=%d", playerCount))

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
	local optionModes = {
		[optionNames[1]] = options[1].Modes[1] or "TeamDeathmatch",
		[optionNames[2]] = options[2].Modes[1] or "TeamDeathmatch",
		[optionNames[3]] = options[3].Modes[1] or "TeamDeathmatch",
	}

	local voteState: ActiveVoteState = {
		options = options,
		optionNames = optionNames,
		optionImages = optionImages,
		optionModes = optionModes,
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
	_deps.log(string.format("Vote started with maps: '%s', '%s', '%s'.", optionNames[1], optionNames[2], optionNames[3]))

	Network.Match.StartVote.SendToAll({
		option1Name = optionNames[1],
		option1Image = optionImages[optionNames[1]],
		option1Mode = optionModes[optionNames[1]],
		option2Name = optionNames[2],
		option2Image = optionImages[optionNames[2]],
		option2Mode = optionModes[optionNames[2]],
		option3Name = optionNames[3],
		option3Image = optionImages[optionNames[3]],
		option3Mode = optionModes[optionNames[3]],
		duration = GameConfig.VoteDuration,
	})

	_broadcastVoteState(voteState)
	task.spawn(_runVoteTimer, voteState)
	return true
end

return VotingService
