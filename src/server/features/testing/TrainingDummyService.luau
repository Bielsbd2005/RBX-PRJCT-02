--!strict
--[[
	Dummies anclados para probar armas: clon de Shared.Bodies.<BODY>, sin equipo
	(TeamUtils.isSameTeam solo bloquea entre equipos resueltos, así que todos le
	dañan), respawnean y regeneran vida si dejan de recibir daño.

	Aparecen sobre cada BasePart con el tag "TrainingDummy" y con "/dummy" en el chat.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CollisionGroups = require(Shared:WaitForChild("CollisionGroups"))

-- Por defecto solo en Studio: los comandos de chat no tienen control de permisos.
local ENABLED = RunService:IsStudio()

local SPAWN_TAG = "TrainingDummy"
local SPAWN_COMMAND = "/dummy"
local CLEAR_COMMAND = "/cleardummies"

local BODY = "Default"
local MAX_HEALTH = 100
local RESPAWN_DELAY = 3 -- s
local SPAWN_DISTANCE = 8 -- studs

local REGEN_ENABLED = true
local REGEN_DELAY = 3 -- s sin daño antes de curar
local REGEN_RATE = 25 -- vida/s
local REGEN_TICK = 0.2 -- s

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
	for _, child in bodies:GetChildren() do
		if child:IsA("Model") then
			return child
		end
	end
	return nil
end

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

	-- Posicionar antes de parentar: evita un frame de física en el sitio del template.
	dummy:PivotTo(cframe)
	root.Anchored = true
	dummy.Parent = _getContainer()

	-- Mismo grupo de colisión que players/bots: no empuja ni es empujado.
	CollisionGroups.setGroupForCharacter(dummy, CollisionGroups.CHARACTERS)

	return dummy, humanoid
end

local function _fillSlot(slot: Slot)
	local dummy, humanoid = _spawnDummy(slot.cframe)
	slot.dummy = dummy
	slot.humanoid = humanoid
	slot.prevHealth = humanoid and humanoid.Health or 0
	slot.lastDamageAt = os.clock()

	if humanoid then
		humanoid.Died:Once(function()
			task.delay(RESPAWN_DELAY, function()
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

-- El daño se detecta comparando con prevHealth en cada tick.
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
					slot.lastDamageAt = now
				end
				if humanoid.Health < humanoid.MaxHealth and now - slot.lastDamageAt >= REGEN_DELAY then
					humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + REGEN_RATE * step)
				end
				slot.prevHealth = humanoid.Health
			end
		end
	end)
end

local function _frontOfPlayer(player: Player): CFrame?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil
	end
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

function TrainingDummyService:Start()
	if _started or not ENABLED then
		return
	end
	_started = true

	for _, marker in CollectionService:GetTagged(SPAWN_TAG) do
		if marker:IsA("BasePart") then
			_addSlot(marker.CFrame, false)
		end
	end
	CollectionService:GetInstanceAddedSignal(SPAWN_TAG):Connect(function(marker)
		if marker:IsA("BasePart") then
			_addSlot(marker.CFrame, false)
		end
	end)

	local function hook(player: Player)
		player.Chatted:Connect(function(message)
			_onChatted(player, message)
		end)
	end
	for _, player in Players:GetPlayers() do
		hook(player)
	end
	Players.PlayerAdded:Connect(hook)

	_startRegenLoop()
end

return TrainingDummyService
