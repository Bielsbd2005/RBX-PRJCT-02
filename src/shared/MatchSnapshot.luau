--!strict
--[[
	MatchSnapshot.luau  (shared)
	Estado ambiental de la partida replicado servidor → clientes vía attributes
	de un Folder en ReplicatedStorage. Sustituye a los viejos paquetes
	edge-triggered (MapLoadState / StartVote / VoteState / EndVote / RoundState):

	  • Un late joiner lee el estado ACTUAL al conectar — no hay paquete que
	    perder ni resync que pedir.
	  • Los cambios llegan por GetAttributeChangedSignal.
	  • Re-escribir el mismo valor no replica ni dispara la señal — el dedupe
	    de broadcasts es gratis.
	  • Los countdowns viajan como deadline (`PhaseEndsAt`, reloj de
	    GetServerTimeNow, sincronizado entre server y clientes); cada cliente
	    computa el tiempo restante localmente, sin ticks de red periódicos.

	El schema completo es DEFAULTS: el servidor solo puede escribir esas claves
	(set valida contra typos). Escritores: MatchService (Phase / PhaseEndsAt /
	MapName / Score*) y VotingService (Option* / Votes* / WinnerMapName).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local FOLDER_NAME = "MatchSnapshot"

export type Phase = "Idle" | "Voting" | "Loading" | "InRound" | "Results"

local DEFAULTS: { [string]: string | number } = {
	Phase = "Idle",
	-- Deadline (GetServerTimeNow) del fin programado de la fase actual; 0 = sin
	-- deadline (Idle/Loading). Voting/InRound/Results lo fijan al entrar.
	PhaseEndsAt = 0,
	-- Mapa activo o en carga ("" fuera de Loading/InRound).
	MapName = "",
	ScoreA = 0,
	ScoreB = 0,
	-- Ganador de la última votación; se fija al cerrar el voto (para la
	-- animación de ganador en clientes) y se limpia al arrancar el siguiente.
	WinnerMapName = "",
	-- Opciones de la votación activa ("" fuera de Voting).
	Option1Name = "",
	Option1Image = "",
	Option2Name = "",
	Option2Image = "",
	Option3Name = "",
	Option3Image = "",
	-- CSV de userIds que votaron cada opción (Random es la opción fija extra).
	Votes1 = "",
	Votes2 = "",
	Votes3 = "",
	VotesRandom = "",
}

local MatchSnapshot = {}

local _folder: Folder? = nil

local function getFolder(): Folder
	if _folder then
		return _folder :: Folder
	end

	if RunService:IsServer() then
		local folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		for key, value in DEFAULTS do
			folder:SetAttribute(key, value)
		end
		folder.Parent = ReplicatedStorage
		_folder = folder
	else
		_folder = ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
	end

	return _folder :: Folder
end

-- Reloj compartido para PhaseEndsAt (server y clientes leen el mismo).
function MatchSnapshot.now(): number
	return Workspace:GetServerTimeNow()
end

function MatchSnapshot.getString(key: string): string
	local value = getFolder():GetAttribute(key)
	return if type(value) == "string" then value else ""
end

function MatchSnapshot.getNumber(key: string): number
	local value = getFolder():GetAttribute(key)
	return if type(value) == "number" then value else 0
end

function MatchSnapshot.getPhase(): Phase
	local value = getFolder():GetAttribute("Phase")
	return if type(value) == "string" then value :: Phase else "Idle"
end

-- Server-only. Escribe `Phase` SIEMPRE en último lugar: cuando un cliente ve
-- cambiar la fase, el resto de claves del mismo set ya están aplicadas.
function MatchSnapshot.set(values: { [string]: string | number })
	assert(RunService:IsServer(), "MatchSnapshot.set es server-only")
	local folder = getFolder()
	-- Validar TODAS las claves ANTES de escribir ninguna: si una clave inválida
	-- aborta a mitad del bucle, las previas ya quedaban replicadas y se saltaba
	-- Phase (escrito al final a propósito), violando la invariante "al cambiar la
	-- fase, el resto ya está aplicado".
	for key in values do
		assert(DEFAULTS[key] ~= nil, "MatchSnapshot: clave desconocida " .. tostring(key))
	end
	for key, value in values do
		if key ~= "Phase" then
			folder:SetAttribute(key, value)
		end
	end
	if values.Phase ~= nil then
		folder:SetAttribute("Phase", values.Phase)
	end
end

-- Conecta `callback` a los cambios de `key` y lo invoca de inmediato con el
-- valor actual (el caller reconcilia su UI al estado vigente al suscribirse).
function MatchSnapshot.observe(key: string, callback: (value: any) -> ()): RBXScriptConnection
	local folder = getFolder()
	local connection = folder:GetAttributeChangedSignal(key):Connect(function()
		callback(folder:GetAttribute(key))
	end)
	callback(folder:GetAttribute(key))
	return connection
end

return MatchSnapshot
