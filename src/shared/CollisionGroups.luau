--!strict
--[[
	CollisionGroups — registro y helpers para los grupos de colisión del juego.

	Tres grupos relevantes (más el Default de Roblox para el mundo/mapa):
	  • Characters: jugadores vivos. Colisionan con el mundo (Default), entre
	    sí y con Bots (comportamiento Roblox normal).
	  • Bots: NPCs vivos. Colisionan con el mundo y con Characters, pero NO
	    entre sí. Razón: dos bots empujándose se bloquean mutuamente contra
	    la geometría y el walk loop del Navigator lo lee como "moving sin
	    progreso" → StuckDetector escala, repaths en cadena y el rig da
	    pasos a tirones. Atravesarse elimina la clase entera de bug sin
	    afectar la sensación de choque contra un NPC desde el lado del
	    jugador.
	  • RagdollBodyParts: cadáveres (jugadores muertos + bots muertos). NO
	    colisionan con Characters, con Bots ni entre sí. Sí colisionan con
	    Default (el mundo) para que el cuerpo caiga al suelo en vez de
	    atravesarlo.

	El registro corre una sola vez en server. Llamar `setGroupForCharacter`
	en client es no-op (el grupo no está registrado allí). RegisterCollisionGroup
	tira error si el grupo ya existe — lo absorbemos con pcall.

	Migra el `"RagdollBodyParts"` que vivía hardcoded en Gravity.luau a una
	fuente única de verdad (Default.luau no lo usaba — los cadáveres con
	kill effect Default colisionaban con jugadores vivos, fix de este módulo).
]]

local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")

local CollisionGroups = {}

CollisionGroups.CHARACTERS = "Characters"
CollisionGroups.BOTS = "Bots"
CollisionGroups.RAGDOLL = "RagdollBodyParts"

local _registeredOnServer = false
local _serverReady = false
-- El grupo BOTS se valida por separado: si su registro falla, los bots
-- degradan a CHARACTERS (vuelven a chocar entre sí) en vez de romper el
-- spawn con un assign a un grupo inexistente.
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

	-- Reglas cruzadas: el orden importa solo en términos de claridad, el
	-- comportamiento es simétrico.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(CollisionGroups.RAGDOLL, CollisionGroups.CHARACTERS, false)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(CollisionGroups.RAGDOLL, CollisionGroups.RAGDOLL, false)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(CollisionGroups.RAGDOLL, CollisionGroups.BOTS, false)
	end)

	-- Bot ↔ bot OFF: es el punto de todo el grupo.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(CollisionGroups.BOTS, CollisionGroups.BOTS, false)
	end)
	-- Bot ↔ jugador ON. Es el default de Roblox, pero lo seteamos explícito:
	-- si alguien edita las reglas desde el editor de Studio, el registro en
	-- código sigue siendo la fuente de verdad y se reaplica en cada arranque.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(CollisionGroups.BOTS, CollisionGroups.CHARACTERS, true)
	end)

	-- Validar via probe — si RegisterCollisionGroup falló silenciosamente, las
	-- asignaciones posteriores también fallarían. Detectarlo acá nos permite
	-- warnear una vez y degradar setGroupForCharacter a no-op.
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

-- Atributo que los watchers DescendantAdded consultan para saber qué grupo
-- aplicar a partes nuevas. Lo seteamos en setGroupForCharacter/Parts y el
-- caller (MatchService, AIService) lo usa para decidir.
local RAGDOLL_TAG = "IsRagdoll"

-- Grupo "vivo" del char (CHARACTERS o BOTS). Lo persistimos como atributo
-- porque `groupForNewPart` corre desde watchers DescendantAdded que solo
-- reciben el Model — sin esto, una tool parenteada a un bot volvería a
-- CHARACTERS y ese único basepart chocaría contra los demás NPCs.
local LIVE_GROUP_TAG = "LiveCollisionGroup"

-- Degrada BOTS → CHARACTERS si el grupo no llegó a registrarse. Sin esto un
-- assign a un grupo inexistente tira error en medio del spawn del bot.
local function _resolve(group: string): string
	if group == CollisionGroups.BOTS and not _botsGroupReady then
		return CollisionGroups.CHARACTERS
	end
	return group
end

-- Asigna `group` a todos los BaseParts descendientes del Model.
-- Se llama:
--   • Al spawnear un char (live → CHARACTERS players / BOTS npcs), desde
--     MatchService y AIService.
--   • Al ragdollizar (live → RAGDOLL), desde los kill effects.
function CollisionGroups.setGroupForCharacter(char: Model, group: string)
	if RunService:IsServer() and not _serverReady then
		return
	end
	group = _resolve(group)
	-- Stampear los tags ANTES de iterar baseparts: si un DescendantAdded watcher
	-- corre concurrentemente sobre una part nueva, ve el estado correcto y
	-- aplica el grupo coherente.
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

-- Variante para cuando ya tenés la lista de baseparts cacheada. Los kill
-- effects ya la construyen para otros propósitos (anti-gravity, joints) así
-- que evitamos un GetDescendants extra.
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

-- Devuelve el grupo que un BasePart recién parentado debe tomar según el
-- estado actual del char. Usado por watchers DescendantAdded.
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
