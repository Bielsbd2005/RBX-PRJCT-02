--!strict
--[[
	TrainingDummyService — Área de testing con enemigos quietos para probar armas.

	Cada dummy es un clon de un cuerpo (Shared.Bodies.<BODY>) que:
	  · está ANCLADO (no se mueve, "quieto").
	  · NO tiene equipo → cualquiera le hace daño (y los headshots aplican x2,
	    igual que contra un jugador; ver WeaponsSystem._defaultDamageCallback +
	    TeamUtils.isSameTeam, que sólo bloquea entre equipos resueltos).
	  · RESPAWNEA unos segundos después de morir.
	  · REGENERA vida si dejas de dispararle un rato (para probar DPS sin matarlo;
	    si sigues disparando el daño gana a la regeneración y muere igual).

	DÓNDE APARECEN — dos formas, combinables:
	  1. PARTES CON TAG: pon partes en el mapa/lobby con el tag de CollectionService
	     "TrainingDummy" (en Studio: Tags → TrainingDummy). Aparece un dummy sobre
	     cada parte. Esto es tu "área de testing" persistente.
	  2. COMANDO: escribe "/dummy" en el chat para spawnear uno enfrente de ti, y
	     "/cleardummies" para quitar los del comando.

	SEGURIDAD: por defecto sólo corre en Studio (ENABLED). Si montas un place de
	testing dedicado y lo quieres publicado, pon ENABLED = true.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CollisionGroups = require(Shared:WaitForChild("CollisionGroups"))

-- ─────────────────────────────  AJUSTES  ──────────────────────────────────

-- Sólo en Studio por defecto. Cambia a `true` para un place de testing live.
local ENABLED = RunService:IsStudio()

local SPAWN_TAG = "TrainingDummy" -- tag de CollectionService en las partes-marcador
local SPAWN_COMMAND = "/dummy"
local CLEAR_COMMAND = "/cleardummies"

local BODY = "Default" -- cuerpo de Shared.Bodies a clonar
local MAX_HEALTH = 100
local RESPAWN_DELAY = 3 -- s tras morir hasta reaparecer
local SPAWN_DISTANCE = 8 -- studs por delante del jugador (comando /dummy)

local REGEN_ENABLED = true
local REGEN_DELAY = 3 -- s sin recibir daño antes de empezar a curar
local REGEN_RATE = 25 -- vida/s de regeneración
local REGEN_TICK = 0.2 -- cada cuánto corre el bucle de regen

-- ──────────────────────────────  ESTADO  ──────────────────────────────────

type Slot = {
	cframe: CFrame,
	manual: boolean, -- true = spawneado por /dummy (lo borra /cleardummies)
	dummy: Model?,
	humanoid: Humanoid?,
	prevHealth: number,
	lastDamageAt: number,
}

local TrainingDummyService = {}

local _started = false
local _slots: { Slot } = {}
local _container: Folder? = nil

-- ──────────────────────────────  HELPERS  ─────────────────────────────────

local function _getContainer(): Folder
	if _container and _container.Parent then
		return _container
	end
	local folder = Instance.new("Folder")
	folder.Name = "TrainingDummies"
	folder.Parent = workspace
	_container = folder
	return folder
end

local function _bodyTemplate(): Model?
	local bodies = Shared:FindFirstChild("Bodies")
	if not bodies then
		return nil
	end
	local template = bodies:FindFirstChild(BODY)
	if template and template:IsA("Model") then
		return template
	end
	-- Fallback: cualquier Model en Bodies.
	for _, child in bodies:GetChildren() do
		if child:IsA("Model") then
			return child
		end
	end
	return nil
end

-- Construye un dummy anclado y sin equipo en `cframe`. Devuelve (model, humanoid).
local function _spawnDummy(cframe: CFrame): (Model?, Humanoid?)
	local template = _bodyTemplate()
	if not template then
		warn("[TrainingDummyService] No se encontró Shared.Bodies." .. BODY)
		return nil, nil
	end

	local dummy = template:Clone()
	dummy.Name = "TrainingDummy"

	local humanoid = dummy:FindFirstChildOfClass("Humanoid")
	local root = dummy:FindFirstChild("HumanoidRootPart")
	if not humanoid or not (root and root:IsA("BasePart")) then
		dummy:Destroy()
		warn("[TrainingDummyService] El template no tiene Humanoid/HumanoidRootPart")
		return nil, nil
	end

	-- PrimaryPart = HumanoidRootPart es lo que mira WeaponsSystem.getHumanoid
	-- para reconocer el modelo como personaje damageable.
	dummy.PrimaryPart = root

	humanoid.MaxHealth = MAX_HEALTH
	humanoid.Health = MAX_HEALTH
	humanoid.DisplayName = "Dummy"
	humanoid.BreakJointsOnDeath = false
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0

	-- Desactivar estados que harían que se caiga/ragdollee (está anclado).
	for _, state in {
		Enum.HumanoidStateType.Climbing,
		Enum.HumanoidStateType.Swimming,
		Enum.HumanoidStateType.Seated,
		Enum.HumanoidStateType.PlatformStanding,
		Enum.HumanoidStateType.FallingDown,
		Enum.HumanoidStateType.Ragdoll,
		Enum.HumanoidStateType.GettingUp,
		Enum.HumanoidStateType.Jumping,
	} do
		humanoid:SetStateEnabled(state, false)
	end

	dummy:SetAttribute("DisplayName", "Dummy")
	dummy:SetAttribute("IsTrainingDummy", true)

	-- Posicionar ANTES de parentar (evita un frame de física en el sitio del
	-- template) y anclar el root para que quede totalmente quieto.
	dummy:PivotTo(cframe)
	root.Anchored = true
	dummy.Parent = _getContainer()

	-- Mismo grupo de colisión que players/bots: no empuja ni es empujado.
	CollisionGroups.setGroupForCharacter(dummy, CollisionGroups.CHARACTERS)

	return dummy, humanoid
end

-- (Re)spawnea un dummy en un slot y engancha su muerte → respawn.
local function _fillSlot(slot: Slot)
	local dummy, humanoid = _spawnDummy(slot.cframe)
	slot.dummy = dummy
	slot.humanoid = humanoid
	slot.prevHealth = humanoid and humanoid.Health or 0
	slot.lastDamageAt = os.clock()

	if humanoid then
		humanoid.Died:Once(function()
			task.delay(RESPAWN_DELAY, function()
				-- Si el slot fue limpiado mientras tanto, no respawnear.
				if not table.find(_slots, slot) then
					if slot.dummy then
						slot.dummy:Destroy()
					end
					return
				end
				if slot.dummy then
					slot.dummy:Destroy()
					slot.dummy = nil
				end
				_fillSlot(slot)
			end)
		end)
	end
end

local function _addSlot(cframe: CFrame, manual: boolean)
	local slot: Slot = {
		cframe = cframe,
		manual = manual,
		dummy = nil,
		humanoid = nil,
		prevHealth = 0,
		lastDamageAt = 0,
	}
	table.insert(_slots, slot)
	_fillSlot(slot)
end

-- Bucle de regeneración: cura los dummies que llevan REGEN_DELAY sin recibir
-- daño. Throttle a REGEN_TICK para que sea barato.
local function _startRegenLoop()
	if not REGEN_ENABLED then
		return
	end
	local accum = 0
	RunService.Heartbeat:Connect(function(dt)
		accum += dt
		if accum < REGEN_TICK then
			return
		end
		local step = accum
		accum = 0
		local now = os.clock()
		for _, slot in _slots do
			local humanoid = slot.humanoid
			if humanoid and humanoid.Health > 0 then
				if humanoid.Health < slot.prevHealth - 0.01 then
					slot.lastDamageAt = now -- detectó daño
				end
				if humanoid.Health < humanoid.MaxHealth and now - slot.lastDamageAt >= REGEN_DELAY then
					humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + REGEN_RATE * step)
				end
				slot.prevHealth = humanoid.Health
			end
		end
	end)
end

-- ──────────────────────────────  COMANDOS  ────────────────────────────────

local function _frontOfPlayer(player: Player): CFrame?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil
	end
	-- SPAWN_DISTANCE studs por delante, mirando de vuelta hacia el jugador.
	return root.CFrame * CFrame.new(0, 0, -SPAWN_DISTANCE) * CFrame.Angles(0, math.pi, 0)
end

local function _clearManualDummies()
	for i = #_slots, 1, -1 do
		local slot = _slots[i]
		if slot.manual then
			if slot.dummy then
				slot.dummy:Destroy()
			end
			table.remove(_slots, i)
		end
	end
end

local function _onChatted(player: Player, message: string)
	local cmd = string.lower((message:gsub("^%s*(.-)%s*$", "%1")))
	if cmd == SPAWN_COMMAND then
		local cframe = _frontOfPlayer(player)
		if cframe then
			_addSlot(cframe, true)
		end
	elseif cmd == CLEAR_COMMAND then
		_clearManualDummies()
	end
end

-- ──────────────────────────────  START  ───────────────────────────────────

function TrainingDummyService:Start()
	if _started or not ENABLED then
		return
	end
	_started = true

	-- 1. Dummies de las partes con tag (el "área" persistente).
	for _, marker in CollectionService:GetTagged(SPAWN_TAG) do
		if marker:IsA("BasePart") then
			_addSlot(marker.CFrame, false)
		end
	end
	-- Partes con tag añadidas en runtime (p.ej. al cargar un mapa).
	CollectionService:GetInstanceAddedSignal(SPAWN_TAG):Connect(function(marker)
		if marker:IsA("BasePart") then
			_addSlot(marker.CFrame, false)
		end
	end)

	-- 2. Comandos de chat.
	local function hook(player: Player)
		player.Chatted:Connect(function(message)
			_onChatted(player, message)
		end)
	end
	for _, player in Players:GetPlayers() do
		hook(player)
	end
	Players.PlayerAdded:Connect(hook)

	-- 3. Regeneración.
	_startRegenLoop()
end

return TrainingDummyService
