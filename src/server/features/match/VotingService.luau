--!strict
--[[
	Votación de mapas: estado del voto activo, cooldowns, timer y resolución del ganador.

	El estado visible (opciones, votos por opción, ganador) se publica en el
	snapshot replicado (Shared/MatchSnapshot); los clientes leen los attributes.
	El único paquete es CastVote (C→S).

	El CUÁNDO lo decide la máquina de fases de MatchService: StartVote solo se llama
	desde Idle → Voting, y al cerrar se invoca `onVoteFinished(winnerMapName)`
	(inyectado vía Start), con el que MatchService transiciona a Loading.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)
local GameConfig = require(Shared.GameConfig)
local MatchSnapshot = require(Shared.MatchSnapshot)
local TelemetryService = require(script.Parent.Parent.Parent.core.TelemetryService)
local RateLimiter = require(script.Parent.Parent.Parent.utils.RateLimiter)

type MapDefinition = typeof(GameConfig.Maps[1])

type ActiveVoteState = {
	optionNames: { string },
	votesByUserId: { [number]: string },
}

type Deps = {
	onVoteFinished: (winnerMapName: string) -> (),
	-- Id de la partida que decide esta votación (lo acuña MatchService), para unir
	-- MAP_VOTE con el MATCH_END de la ronda. Opcional: sin él se emite sin matchId.
	currentMatchId: (() -> string)?,
}

local VotingService = {}
VotingService.__index = VotingService

-- Claramente por debajo de LOCAL_VOTE_COOLDOWN del cliente (0.3): el cliente mide el
-- envío y el servidor la llegada, y con jitter un cambio legítimo se descartaría en
-- silencio con la UI marcando otro mapa.
local VOTE_CHANGE_COOLDOWN = 0.15
local DEFAULT_PLACEHOLDER_IMAGE = "rbxasset://textures/ui/GuiImagePlaceholder.png"

-- Opción "Random": cuarto candidato siempre presente, sin mapa concreto. Si gana
-- (o gana el desempate), se resuelve a un mapa aleatorio entre las 3 opciones.
local RANDOM_KEY = GameConfig.RandomVoteKey

local _deps: Deps = nil :: any
local _started = false
local _activeVote: ActiveVoteState? = nil
local _voteLimiter = RateLimiter.new(VOTE_CHANGE_COOLDOWN)

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

-- Publica los votantes por opción en el snapshot. Re-escribir un CSV sin
-- cambios es un no-op de replicación, así que no hace falta dedupe manual.
local function _publishVotes(vote: ActiveVoteState)
	MatchSnapshot.set({
		Votes1 = _collectVoterIds(vote, vote.optionNames[1]),
		Votes2 = _collectVoterIds(vote, vote.optionNames[2]),
		Votes3 = _collectVoterIds(vote, vote.optionNames[3]),
		VotesRandom = _collectVoterIds(vote, RANDOM_KEY),
	})
end

local function _isVoteChangeAllowed(player: Player): boolean
	return _voteLimiter:tryConsume(player)
end

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

-- Devuelve siempre un mapa concreto: si gana Random, se resuelve entre los 3.
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

local function _onCastVote(data: Network.CastVotePayload, player: Player)
	-- Cap de longitud antes de cualquier procesado.
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

	if vote.votesByUserId[player.UserId] == mapName then
		return
	end

	vote.votesByUserId[player.UserId] = mapName
	_publishVotes(vote)
end

-- Cierre de la votación (al expirar VoteDuration): resuelve el ganador, lo
-- publica en el snapshot (limpiando las opciones) y notifica a MatchService.
local function _finishVote(vote: ActiveVoteState)
	if _activeVote ~= vote then
		return
	end

	local winner = _resolveWinner(vote)

	local totalVoters = 0
	for _ in vote.votesByUserId do
		totalVoters += 1
	end
	-- Se envía el reparto COMPLETO (opciones ofrecidas, votos por opción y abstención):
	-- con el ganador solo no se distingue un mapa querido de uno sin rivales fuertes.
	local votesByMap: { [string]: number } = {}
	local randomVotes = 0
	for _, mapName in vote.votesByUserId do
		if mapName == RANDOM_KEY then
			randomVotes += 1
		else
			votesByMap[mapName] = (votesByMap[mapName] or 0) + 1
		end
	end

	-- Las opciones con CERO votos se envían igual: son el denominador de exposición.
	local options = {}
	for _, mapName in vote.optionNames do
		table.insert(options, { mapName = mapName, votes = votesByMap[mapName] or 0 })
	end

	local matchId = ""
	if _deps and _deps.currentMatchId then
		local ok, resolved = pcall(_deps.currentMatchId :: any)
		if ok and type(resolved) == "string" then
			matchId = resolved
		end
	end

	TelemetryService.Enqueue("MAP_VOTE", {
		voteId = HttpService:GenerateGUID(false),
		matchId = matchId,
		winnerMap = winner,
			-- Elegibles frente a emitidos: no votar es señal de indiferencia.
		eligibleVoters = #Players:GetPlayers(),
		castVotes = totalVoters,
		randomVotes = randomVotes,
		options = options,
	})

	MatchSnapshot.set({
		WinnerMapName = winner,
		Option1Name = "", Option1Image = "",
		Option2Name = "", Option2Image = "",
		Option3Name = "", Option3Image = "",
		Votes1 = "", Votes2 = "", Votes3 = "", VotesRandom = "",
	})

	_activeVote = nil
	task.defer(function()
		_deps.onVoteFinished(winner)
	end)
end

function VotingService:Start(deps: Deps)
	if _started then
		return
	end
	_started = true
	_deps = deps
	_activeVote = nil
	_voteLimiter:clearAll()

	Network.Match.CastVote.Listen(_onCastVote)
end

function VotingService:DisconnectPlayer(userId: number)
	local vote = _activeVote
	if vote and vote.votesByUserId[userId] then
		vote.votesByUserId[userId] = nil
		_publishVotes(vote)
	end
	_voteLimiter:clearPlayer(userId)
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
	local vote: ActiveVoteState = {
		optionNames = { options[1].Name, options[2].Name, options[3].Name },
		votesByUserId = {},
	}

	_activeVote = vote
	-- Limpiar cooldowns para que el primer voto del nuevo ciclo no quede bloqueado.
	_voteLimiter:clearAll()

	local function imageOf(definition: MapDefinition): string
		return if definition.PlaceholderImage ~= "" then definition.PlaceholderImage else DEFAULT_PLACEHOLDER_IMAGE
	end
	MatchSnapshot.set({
		WinnerMapName = "",
		Option1Name = vote.optionNames[1], Option1Image = imageOf(options[1]),
		Option2Name = vote.optionNames[2], Option2Image = imageOf(options[2]),
		Option3Name = vote.optionNames[3], Option3Image = imageOf(options[3]),
		Votes1 = "", Votes2 = "", Votes3 = "", VotesRandom = "",
	})

	task.delay(GameConfig.VoteDuration, _finishVote, vote)
	return true
end

return VotingService
