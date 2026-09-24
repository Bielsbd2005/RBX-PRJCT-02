--!strict
--[[
	Máquina de estados del flujo de partida del cliente.

	Fases:
	  Lobby            — En el menú, no en partida
	  Joining          — Solicitud de unirse en vuelo (iris cerrándose)
	  InMatch          — En partida activa (gameplay)
	  Dying            — En kill cam / death screen
	  ShowingResults   — Ronda terminó, mostrando ResultsScreen
	  ReturningToMenu  — Transición de vuelta al menú (desde death screen)
]]

export type Phase = "Lobby" | "Joining" | "InMatch" | "Dying" | "ShowingResults" | "ReturningToMenu"

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TeamUtils = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("utils"):WaitForChild("TeamUtils"))

local MatchState = {}

-- Bando del jugador local en partida. MatchSide (MatchService) lo mantiene mientras está
-- muerto: a los 4.5 s el cuerpo pasa al lobby con Team=nil. Solo cliente; en el servidor
-- los bots leen TeamUtils y no deben ver ese cuerpo como objetivo.
function MatchState.getLocalSide(): string?
	local player = Players.LocalPlayer
	if player.Team then
		return TeamUtils.normalize(player.Team.Name)
	end
	local attr = player:GetAttribute("MatchSide")
	if type(attr) == "string" then
		return TeamUtils.normalize(attr)
	end
	return nil
end

-- Aliado del jugador local (false si alguno de los dos no tiene bando).
function MatchState.isLocalAlly(model: Model): boolean
	local localSide = MatchState.getLocalSide()
	return localSide ~= nil and TeamUtils.getSide(model) == localSide
end

local _phase: Phase = "Lobby"
local _onPhaseChanged: ((Phase, Phase) -> ())? = nil

function MatchState.getPhase(): Phase
	return _phase
end

function MatchState.setPhase(nextPhase: Phase)
	if _phase == nextPhase then
		return
	end

	local prev = _phase
	_phase = nextPhase

	if _onPhaseChanged then
		_onPhaseChanged(prev, nextPhase)
	end
end

--- Está en gameplay activo (en partida o muriendo).
function MatchState.isActive(): boolean
	return _phase == "InMatch" or _phase == "Dying"
end

--- No está en el lobby (menú debería estar oculto).
function MatchState.shouldKeepMenuHidden(): boolean
	return _phase ~= "Lobby"
end

--- Callback de cada cambio de fase (anterior, nueva). MatchFeature lo usa para
--- alternar lighting, DoF, controles táctiles y el reset de personaje, y para
--- capturar el podio de Resultados. nil lo quita.
function MatchState.setOnPhaseChanged(callback: ((Phase, Phase) -> ())?)
	_onPhaseChanged = callback
end

function MatchState.reset()
	_phase = "Lobby"
end

return MatchState
