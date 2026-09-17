--!strict
--[[
	Grupos de colisión (además de Default = mundo):
	  • Characters: jugadores vivos.
	  • Bots: no chocan entre sí; dos bots empujándose contra la geometría disparan
	    el StuckDetector del Navigator.
	  • RagdollBodyParts: cadáveres; solo chocan con el mundo. Sin autocolisión
	    porque los hulls de R15 ya se solapan en reposo y el cuerpo tiembla.
	  • RagdollInner: cajas internas del cadáver (KillEffectUtils.addInnerColliders),
	    solo chocan entre sí para que un brazo no se hunda en el torso.

	Se registran solo en el servidor; en el cliente setGroupForCharacter es no-op.
]]

local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")

local CollisionGroups = {}

CollisionGroups.CHARACTERS = "Characters"
CollisionGroups.BOTS = "Bots"
CollisionGroups.RAGDOLL = "RagdollBodyParts"
CollisionGroups.RAGDOLL_INNER = "RagdollInner"

local _registeredOnServer = false
local _serverReady = false
-- Si falla el registro de Bots, degradan a Characters en vez de romper el spawn.
local _botsGroupReady = false

local function _registerOnServer()
	if not RunService:IsServer() then
		return
	end
	if _registeredOnServer then
		return
	end
	_registeredOnServer = true

	pcall(function()
		PhysicsService:RegisterCollisionGroup(CollisionGroups.CHARACTERS)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(CollisionGroups.BOTS)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(CollisionGroups.RAGDOLL)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(CollisionGroups.RAGDOLL_INNER)
	end)

	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(CollisionGroups.RAGDOLL, CollisionGroups.CHARACTERS, false)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(CollisionGroups.RAGDOLL, CollisionGroups.RAGDOLL, false)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(CollisionGroups.RAGDOLL, CollisionGroups.BOTS, false)
	end)

	for _, other in { "Default", CollisionGroups.CHARACTERS, CollisionGroups.BOTS, CollisionGroups.RAGDOLL } do
		pcall(function()
			PhysicsService:CollisionGroupSetCollidable(CollisionGroups.RAGDOLL_INNER, other, false)
		end)
	end
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(CollisionGroups.RAGDOLL_INNER, CollisionGroups.RAGDOLL_INNER, true)
	end)

	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(CollisionGroups.BOTS, CollisionGroups.BOTS, false)
	end)
	-- Explícito aunque sea el default: el código manda sobre lo editado en Studio.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(CollisionGroups.BOTS, CollisionGroups.CHARACTERS, true)
	end)

	-- Probe: si el registro falló en silencio, las asignaciones también fallarían.
	local probe = Instance.new("Part")
	local ok = pcall(function()
		probe.CollisionGroup = CollisionGroups.CHARACTERS
	end)
	_botsGroupReady = pcall(function()
		probe.CollisionGroup = CollisionGroups.BOTS
	end)
	probe:Destroy()
	if ok then
		_serverReady = true
	else
		warn("[CollisionGroups] No se pudieron registrar los grupos. Jugadores vivos colisionarán con cadáveres.")
	end
	if ok and not _botsGroupReady then
		warn("[CollisionGroups] Grupo 'Bots' no disponible; los NPCs colisionarán entre sí.")
	end
end

_registerOnServer()

-- Lo leen los watchers DescendantAdded y también el cliente (HealthBillboardController
-- lo usa para retirar la barra de vida del cadáver).
CollisionGroups.RAGDOLL_ATTRIBUTE = "IsRagdoll"
local RAGDOLL_TAG = CollisionGroups.RAGDOLL_ATTRIBUTE

-- Persistido porque los watchers de DescendantAdded solo reciben el Model: sin él,
-- una tool parenteada a un bot caería en CHARACTERS.
local LIVE_GROUP_TAG = "LiveCollisionGroup"

local function _resolve(group: string): string
	if group == CollisionGroups.BOTS and not _botsGroupReady then
		return CollisionGroups.CHARACTERS
	end
	return group
end

function CollisionGroups.setGroupForCharacter(char: Model, group: string)
	if RunService:IsServer() and not _serverReady then
		return
	end
	group = _resolve(group)
	-- Atributos antes de iterar: un watcher concurrente debe ver ya el estado nuevo.
	char:SetAttribute(RAGDOLL_TAG, group == CollisionGroups.RAGDOLL)
	if group ~= CollisionGroups.RAGDOLL then
		char:SetAttribute(LIVE_GROUP_TAG, group)
	end
	for _, descendant in char:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = group
		end
	end
end

-- Para callers que ya tienen la lista de parts (kill effects).
function CollisionGroups.setGroupForParts(char: Model, parts: { BasePart }, group: string)
	if RunService:IsServer() and not _serverReady then
		return
	end
	group = _resolve(group)
	char:SetAttribute(RAGDOLL_TAG, group == CollisionGroups.RAGDOLL)
	if group ~= CollisionGroups.RAGDOLL then
		char:SetAttribute(LIVE_GROUP_TAG, group)
	end
	for _, part in parts do
		part.CollisionGroup = group
	end
end

-- En un cadáver la parte nueva nace además sin query ni touch (como en
-- KillEffectUtils.makeCorpseInert): si no, un accesorio replicado tarde para balas.
function CollisionGroups.applyToNewPart(char: Model, part: BasePart)
	part.CollisionGroup = CollisionGroups.groupForNewPart(char)
	if char:GetAttribute(RAGDOLL_TAG) then
		part.CanQuery = false
		part.CanTouch = false
	end
end

function CollisionGroups.groupForNewPart(char: Model): string
	if char:GetAttribute(RAGDOLL_TAG) then
		return CollisionGroups.RAGDOLL
	end
	local live = char:GetAttribute(LIVE_GROUP_TAG)
	if type(live) == "string" then
		return _resolve(live)
	end
	return CollisionGroups.CHARACTERS
end

return CollisionGroups
