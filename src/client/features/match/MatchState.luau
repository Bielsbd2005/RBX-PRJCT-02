--!strict
--[[
	MatchState.luau
	Máquina de estados centralizada para el flujo de partida del cliente.

	Fases:
	  Lobby            — En el menú, no en partida
	  Joining          — Solicitud de unirse en vuelo (iris cerrándose)
	  InMatch          — En partida activa (gameplay)
	  Dying            — En kill cam / death screen
	  ShowingResults   — Ronda terminó, mostrando ResultsScreen
	  ReturningToMenu  — Transición de vuelta al menú (desde death screen)
]]

export type Phase = "Lobby" | "Joining" | "InMatch" | "Dying" | "ShowingResults" | "ReturningToMenu"

local MatchState = {}

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

--- Permite hook opcional para logging/debug.
function MatchState.setOnPhaseChanged(callback: ((Phase, Phase) -> ())?)
	_onPhaseChanged = callback
end

--- Reset completo (para Destroy del feature).
function MatchState.reset()
	_phase = "Lobby"
end

return MatchState
