--!strict
-- KillEffectsDummyController.luau (Client Feature Library)
-- Gestiona la inicialización, ragdoll, posicionamiento y animación del dummy de prueba para Kill Effects.

local Janitor = require(game:GetService("ReplicatedStorage"):WaitForChild("Packages"):WaitForChild("janitor")) :: any
local KillEffectsRegistry = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Locker"):WaitForChild("killEffects"):WaitForChild("KillEffectsRegistry"))
local LockerUtils = require(script.Parent:WaitForChild("LockerUtils"))

local LOCKER_PREVIEW_IDLE_ANIMATION_ID = "rbxassetid://109968216239895"
local KILL_EFFECT_PREVIEW_COOLDOWN = 0.4

local KillEffectsDummyController = {}
KillEffectsDummyController.__index = KillEffectsDummyController

function KillEffectsDummyController.new(
	lockerFolder: Instance,
	dummySpawn: Instance,
	killEffectDummyTemplate: Model
)
	local self = setmetatable({}, KillEffectsDummyController)
	self.lockerFolder = lockerFolder
	self.dummySpawn = dummySpawn
	self.killEffectDummyTemplate = killEffectDummyTemplate

	self.currentKillEffectDummy = nil :: Model?
	self.killEffectIdleJanitor = nil :: any?
	self.killEffectRespawnTask = nil :: thread?
	self.currentlyPreviewingEffectId = nil :: string?
	self.nextAllowedPreviewAt = 0

	return self
end

function KillEffectsDummyController:destroyDummy()
	if self.killEffectRespawnTask then
		task.cancel(self.killEffectRespawnTask)
		self.killEffectRespawnTask = nil
	end
	if self.killEffectIdleJanitor then
		self.killEffectIdleJanitor:Destroy()
		self.killEffectIdleJanitor = nil
	end
	if self.currentKillEffectDummy and self.currentKillEffectDummy.Parent then
		self.currentKillEffectDummy:Destroy()
	end
	self.currentKillEffectDummy = nil
	self.currentlyPreviewingEffectId = nil
end

local function snapPartsToCanonicalPose(char: Model)
	local motors = {}
	for _, m in char:GetDescendants() do
		if m:IsA("Motor6D") and m.Part0 and m.Part1 then
			table.insert(motors, m)
		end
	end
	for _ = 1, 4 do
		for _, m in motors do
			m.Part1.CFrame = m.Part0.CFrame * m.C0 * m.C1:Inverse()
		end
	end
end

function KillEffectsDummyController:spawnDummy()
	self:destroyDummy()
	local clone = self.killEffectDummyTemplate:Clone()
	clone.Name = "KillEffectDummy"
	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	clone.Parent = self.lockerFolder
	LockerUtils.placePreviewCharacter(clone, self.dummySpawn)
	snapPartsToCanonicalPose(clone)

	local hrp = clone:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		hrp.Anchored = true
	end

	self.killEffectIdleJanitor = Janitor.new()
	LockerUtils.playPreviewIdleAnimation(clone, self.killEffectIdleJanitor, LOCKER_PREVIEW_IDLE_ANIMATION_ID)
	self.currentKillEffectDummy = clone
end

function KillEffectsDummyController:previewEffect(effectId: string)
	if self.currentlyPreviewingEffectId == effectId and self.killEffectRespawnTask then
		return
	end
	local now = os.clock()
	if now < self.nextAllowedPreviewAt then
		return
	end
	self.nextAllowedPreviewAt = now + KILL_EFFECT_PREVIEW_COOLDOWN

	self:spawnDummy()

	if self.killEffectIdleJanitor then
		self.killEffectIdleJanitor:Destroy()
		self.killEffectIdleJanitor = nil
	end

	self.currentlyPreviewingEffectId = effectId
	KillEffectsRegistry.apply(effectId, self.currentKillEffectDummy :: Model)

	self.killEffectRespawnTask = task.delay(2, function()
		self.killEffectRespawnTask = nil
		self.currentlyPreviewingEffectId = nil
		self:spawnDummy()
	end)
end

function KillEffectsDummyController:Destroy()
	self:destroyDummy()
end

return KillEffectsDummyController
