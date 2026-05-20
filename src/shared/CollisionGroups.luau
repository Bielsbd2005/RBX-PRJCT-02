--!strict
--[[
	CollisionGroups — registro y helpers para los grupos de colisión del juego.

	Tres grupos relevantes (más el Default de Roblox para el mundo/mapa):
	  • Characters: jugadores vivos + bots vivos. Colisionan con el mundo
	    (Default) y entre sí (comportamiento Roblox normal).
	  • RagdollBodyParts: cadáveres (jugadores muertos + bots muertos). NO
	    colisionan con Characters ni entre sí. Sí colisionan con Default
	    (el mundo) para que el cuerpo caiga al suelo en vez de atravesarlo.

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
CollisionGroups.RAGDOLL = "RagdollBodyParts"

local _registeredOnServer = false
local _serverReady = false

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

	-- Validar via probe — si RegisterCollisionGroup falló silenciosamente, las
	-- asignaciones posteriores también fallarían. Detectarlo acá nos permite
	-- warnear una vez y degradar setGroupForCharacter a no-op.
	local probe = Instance.new("Part")
	local ok = pcall(function()
		probe.CollisionGroup = CollisionGroups.CHARACTERS
	end)
	probe:Destroy()
	if ok then
		_serverReady = true
	else
		warn("[CollisionGroups] No se pudieron registrar los grupos. Jugadores vivos colisionarán con cadáveres.")
	end
end

_registerOnServer()

-- Atributo que los watchers DescendantAdded consultan para saber qué grupo
-- aplicar a partes nuevas. Lo seteamos en setGroupForCharacter/Parts y el
-- caller (MatchService, AIService) lo usa para decidir.
local RAGDOLL_TAG = "IsRagdoll"

-- Asigna `group` a todos los BaseParts descendientes del Model.
-- Se llama:
--   • Al spawnear un char (live → CHARACTERS), desde MatchService y AIService.
--   • Al ragdollizar (live → RAGDOLL), desde los kill effects.
function CollisionGroups.setGroupForCharacter(char: Model, group: string)
	if RunService:IsServer() and not _serverReady then
		return
	end
	-- Stampear el tag ANTES de iterar baseparts: si un DescendantAdded watcher
	-- corre concurrentemente sobre una part nueva, ve el estado correcto y
	-- aplica el grupo coherente.
	char:SetAttribute(RAGDOLL_TAG, group == CollisionGroups.RAGDOLL)
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
	char:SetAttribute(RAGDOLL_TAG, group == CollisionGroups.RAGDOLL)
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
	return CollisionGroups.CHARACTERS
end

return CollisionGroups
