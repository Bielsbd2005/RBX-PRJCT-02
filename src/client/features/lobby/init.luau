--!strict
--[[
	LobbyFeature  (Client)
	Spawnea un preview del personaje del jugador local en
	Workspace.Lobby.Spawners.P1 con la cara y los hats equipados según el
	loadout. Reactivo a cambios de loadout (DataController.Loadout).

	Mismo patrón que el preview del Locker: clona Shared.templates.CharacterTemplate,
	aplica idle animation, y delega face/hats a FaceApplier/HatApplier.

	Las modificaciones de Workspace desde un LocalScript no replican, así que
	cada cliente clona su propio preview y cada jugador ve solo el suyo.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any

local FaceApplier = require(Client.features.locker.Appliers.FaceApplier)
local HatApplier = require(Client.features.locker.Appliers.HatApplier)
local DataController = require(Client.core.data.DataController)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any

local IDLE_ANIMATION_ID = "rbxassetid://115197033304718"

local function _placeCharacter(model: Model, target: Instance)
	if target:IsA("BasePart") then
		local rootPart = model:FindFirstChild("HumanoidRootPart", true)
		if rootPart and rootPart:IsA("BasePart") then
			local rootOffset = model:GetPivot():ToObjectSpace(rootPart.CFrame)
			model:PivotTo(target.CFrame * rootOffset:Inverse())
			return
		end
		model:MoveTo(target.Position)
		return
	end

	if target:IsA("Model") then
		model:PivotTo(target:GetPivot())
	end
end

local function _playIdleAnimation(model: Model, janitor: any)
	local humanoid = model:FindFirstChildWhichIsA("Humanoid", true)
	local animator: Animator? = nil
	if humanoid then
		animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			local newAnimator = Instance.new("Animator")
			newAnimator.Parent = humanoid
			animator = newAnimator
		end
	else
		animator = model:FindFirstChildWhichIsA("Animator", true)
	end

	if not animator then return end

	local animation = Instance.new("Animation")
	animation.Name = "LobbyPreviewIdle"
	animation.AnimationId = IDLE_ANIMATION_ID

	local track = animator:LoadAnimation(animation)
	track.Name = "LobbyPreviewIdle"
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Idle
	track:Play(0.1)

	janitor:Add(function()
		track:Stop(0.1)
		track:Destroy()
		animation:Destroy()
	end, true)
end

local function _getOptionalString(value: any): string?
	if type(value) == "string" and value ~= "" then return value end
	return nil
end

local LobbyFeature = {}

function LobbyFeature.start(_menuController: any): any
	local janitor = Janitor.new()

	local lobby = Workspace:FindFirstChild("Lobby")
	local spawners = lobby and lobby:FindFirstChild("Spawners")
	local p1 = spawners and spawners:FindFirstChild("P1")
	if not p1 then
		warn("[LobbyFeature] Workspace.Lobby.Spawners.P1 no encontrado")
		return janitor
	end

	local sharedTemplates = Shared:FindFirstChild("templates")
	local characterTemplate = sharedTemplates and sharedTemplates:FindFirstChild("CharacterTemplate")
	if not characterTemplate or not characterTemplate:IsA("Model") then
		warn("[LobbyFeature] Shared.templates.CharacterTemplate no encontrado")
		return janitor
	end

	-- Limpiar preview previo en P1 (hot reload o re-arranque del feature).
	local previousPreview = p1:FindFirstChild("CharacterPreview")
	if previousPreview then previousPreview:Destroy() end

	local preview = (characterTemplate :: Model):Clone()
	preview.Name = "CharacterPreview"
	preview.Parent = p1
	janitor:Add(preview, "Destroy")

	_placeCharacter(preview, p1)
	_playIdleAnimation(preview, janitor)

	local faceApplier = FaceApplier.new(preview, ItemsConfig)
	local hatApplier = HatApplier.new(preview, ItemsConfig)

	local function _applyEquipped()
		local loadout = Fusion.peek(DataController.Loadout) :: { [string]: any }
		if type(loadout) ~= "table" then return end
		faceApplier:ApplyFromLoadoutFace(_getOptionalString(loadout.Face))
		hatApplier:ApplyFromLoadoutHat(_getOptionalString(loadout.Hat))
	end

	DataController:WhenReady():andThen(function()
		_applyEquipped()
		local scope = Fusion.scoped(Fusion)
		janitor:Add(function()
			Fusion.doCleanup(scope)
		end, true)
		local obs = scope:Observer(DataController.Loadout :: any)
		janitor:Add(obs:onBind(_applyEquipped), true)
	end)

	-- ── Highlight: ocultar mientras BattlePass está abierto ─────────────
	local highlight = preview:FindFirstChildOfClass("Highlight")
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local battlePassGui = playerGui:FindFirstChild("BattlePass")
	if highlight and battlePassGui then
		local function _applyHighlightVisibility()
			highlight.Enabled = not (battlePassGui :: ScreenGui).Enabled
		end

		janitor:Add(
			battlePassGui:GetPropertyChangedSignal("Enabled"):Connect(_applyHighlightVisibility),
			"Disconnect"
		)
		_applyHighlightVisibility()
	end

	return janitor
end

return LobbyFeature
