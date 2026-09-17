--!strict
--[[
	Estado de la partida replicado servidor → clientes como attributes de un Folder
	en ReplicatedStorage (un late joiner lee el estado actual; re-escribir el mismo
	valor no replica). Los countdowns viajan como deadline (`PhaseEndsAt`).

	El schema completo es DEFAULTS. Escritores: MatchService (Phase / PhaseEndsAt /
	MapName / Score*) y VotingService (Option* / Votes* / WinnerMapName).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local FOLDER_NAME = "MatchSnapshot"

export type Phase = "Idle" | "Voting" | "Loading" | "InRound" | "Results"

local DEFAULTS: { [string]: string | number } = {
	Phase = "Idle",
	-- Deadline (GetServerTimeNow) del fin de la fase actual; 0 = sin deadline (Idle/Loading).
	PhaseEndsAt = 0,
	-- Mapa activo o en carga ("" fuera de Loading/InRound).
	MapName = "",
	ScoreA = 0,
	ScoreB = 0,
	-- Se fija al cerrar el voto y se limpia al arrancar el siguiente.
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
	-- Validar TODAS antes de escribir ninguna: un assert a mitad rompería la invariante de Phase.
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

-- También invoca `callback` de inmediato con el valor actual.
function MatchSnapshot.observe(key: string, callback: (value: any) -> ()): RBXScriptConnection
	local folder = getFolder()
	local connection = folder:GetAttributeChangedSignal(key):Connect(function()
		callback(folder:GetAttribute(key))
	end)
	callback(folder:GetAttribute(key))
	return connection
end

return MatchSnapshot
