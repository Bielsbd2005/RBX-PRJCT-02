--!strict
--[[
	LobbyFeature  (Client)
	Spawnea un preview del personaje del jugador local en
	Workspace.Lobby.Spawners.P1 con la cara y los hats equipados según el
	loadout. Reactivo a cambios de loadout (DataController.Loadout).

	Mismo patrón que el preview del Locker: clona el body equipado desde
	Shared.LockerBodies[Loadout.Outfit] (con fallback a "Default"), aplica idle
	animation, y delega face/hats a FaceApplier/HatApplier. Si el Outfit cambia,
	el preview se reconstruye desde cero.

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

	local lockerBodiesFolder = Shared:FindFirstChild("LockerBodies")
	if not lockerBodiesFolder then
		warn("[LobbyFeature] Shared.LockerBodies no encontrado")
		return janitor
	end

	local function _resolveLobbyBodyTemplate(outfitId: string?): Model?
		local byId = if outfitId and outfitId ~= "" then lockerBodiesFolder:FindFirstChild(outfitId) else nil
		if byId and byId:IsA("Model") then
			return byId :: Model
		end
		local fallback = lockerBodiesFolder:FindFirstChild("Default")
		return if fallback and fallback:IsA("Model") then fallback :: Model else nil
	end

	-- Limpiar preview previo en P1 (hot reload o re-arranque del feature).
	local previousPreview = p1:FindFirstChild("CharacterPreview")
	if previousPreview then previousPreview:Destroy() end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local uiGui = playerGui:WaitForChild("UserInterface")
	local battlePassFrame = uiGui:FindFirstChild("BattlePass")

	local previewJanitor = Janitor.new()
	janitor:Add(previewJanitor, "Destroy")

	local faceApplier: any = nil
	local hatApplier: any = nil
	local lastLobbyOutfitId: string? = nil

	local function _rebuildLobbyPreview(outfitId: string?)
		previewJanitor:Cleanup()
		faceApplier = nil
		hatApplier = nil

		local template = _resolveLobbyBodyTemplate(outfitId)
		if not template then
			return
		end

		local preview = template:Clone()
		preview.Name = "CharacterPreview"
		preview.Parent = p1
		previewJanitor:Add(preview, "Destroy")

		_placeCharacter(preview, p1)
		_playIdleAnimation(preview, previewJanitor)

		faceApplier = FaceApplier.new(preview, ItemsConfig)
		hatApplier = HatApplier.new(preview, ItemsConfig)

		local highlight = preview:FindFirstChildOfClass("Highlight")
		if highlight and battlePassFrame and battlePassFrame:IsA("GuiObject") then
			local frame = battlePassFrame :: GuiObject
			local function _applyHighlightVisibility()
				highlight.Enabled = not frame.Visible
			end
			previewJanitor:Add(
				frame:GetPropertyChangedSignal("Visible"):Connect(_applyHighlightVisibility),
				"Disconnect"
			)
			_applyHighlightVisibility()
		end

		lastLobbyOutfitId = outfitId
	end

	local function _applyEquipped()
		local loadout = Fusion.peek(DataController.Loadout) :: { [string]: any }
		if type(loadout) ~= "table" then return end
		local outfitId = _getOptionalString(loadout.Outfit)
		if not faceApplier or outfitId ~= lastLobbyOutfitId then
			_rebuildLobbyPreview(outfitId)
		end
		if faceApplier then
			faceApplier:ApplyItemId(_getOptionalString(loadout.Face))
		end
		if hatApplier then
			hatApplier:ApplyItemId(_getOptionalString(loadout.Hat))
		end
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

	return janitor
end

return LobbyFeature
