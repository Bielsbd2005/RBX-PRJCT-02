--!strict
--[[
	LobbyCharacterPreview  (Client, singleton)

	Dueño único del preview del personaje del jugador local en
	Workspace.Lobby.Spawners.P1 (el que se ve en el lobby, "P1"). Antes este
	preview lo construía LobbyFeature y, por separado, el Locker clonaba su propio
	maniquí en Workspace.Locker.CharacterSpawn. Ahora ambos comparten ESTE modelo:

	  • LobbyFeature lo sincroniza al loadout equipado (:syncToEquippedIfIdle).
	  • El Locker lo toma prestado mientras está abierto (:beginPreview) para
	    previsualizar la selección (:applyOutfit/:applyFaceImage/:applyHatItem) y
	    lo restaura al cerrar (:endPreview → vuelve a lo equipado).

	El flag de preview evita que el observer de loadout de LobbyFeature pise lo que
	el Locker está mostrando: mientras el Locker tiene el preview, syncToEquippedIfIdle
	es no-op.

	Las modificaciones de Workspace desde un LocalScript no replican, así que cada
	cliente clona su propio preview y cada jugador ve solo el suyo.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Core = script.Parent.Parent
local ClientRoot = Core.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any

local FaceApplier = require(ClientRoot.features.locker.Appliers.FaceApplier)
local HatApplier = require(ClientRoot.features.locker.Appliers.HatApplier)
local DataController = require(Core.data.DataController)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any

local IDLE_ANIMATION_ID = "rbxassetid://109968216239895"
local RESOLVE_TIMEOUT = 30

local function getOptionalString(value: any): string?
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function placeCharacter(model: Model, target: Instance)
	local humanoid = model:FindFirstChildWhichIsA("Humanoid", true)
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

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

local function playIdleAnimation(model: Model, janitor: any)
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

	if not animator then
		return
	end

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

local function resolveBodyTemplate(outfitId: string?): Model?
	local folder = Shared:WaitForChild("LockerBodies", RESOLVE_TIMEOUT)
	if not folder then
		return nil
	end
	local byId = if outfitId and outfitId ~= "" then folder:FindFirstChild(outfitId) else nil
	if byId and byId:IsA("Model") then
		return byId :: Model
	end
	local fallback = folder:FindFirstChild("Default")
	return if fallback and fallback:IsA("Model") then fallback :: Model else nil
end

export type LobbyCharacterPreview = {
	syncToEquipped: (self: LobbyCharacterPreview) -> (),
	syncToEquippedIfIdle: (self: LobbyCharacterPreview) -> (),
	beginPreview: (self: LobbyCharacterPreview) -> (),
	endPreview: (self: LobbyCharacterPreview) -> (),
	applyOutfit: (self: LobbyCharacterPreview, outfitId: string?) -> (),
	applyFaceImage: (self: LobbyCharacterPreview, image: string?) -> (),
	applyFaceId: (self: LobbyCharacterPreview, faceId: string?) -> (),
	applyHatItem: (self: LobbyCharacterPreview, itemData: any) -> (),
	applyHatId: (self: LobbyCharacterPreview, hatId: string?) -> (),
}

local LobbyCharacterPreview = {}
LobbyCharacterPreview.__index = LobbyCharacterPreview

local _instance: any = nil

local function _new(): any
	local self = setmetatable({}, LobbyCharacterPreview)
	self._janitor = Janitor.new()
	self._previewJanitor = Janitor.new()
	self._janitor:Add(self._previewJanitor, "Destroy")
	self._p1 = nil :: Instance?
	self._battlePassFrame = nil :: Instance?
	self._model = nil :: Model?
	self._faceApplier = nil :: any
	self._hatApplier = nil :: any
	self._lastOutfitId = nil :: string?
	self._previewActive = false
	self._resolved = false
	return self
end

--- Devuelve el singleton del preview del personaje del lobby.
function LobbyCharacterPreview.get(): LobbyCharacterPreview
	if not _instance then
		_instance = _new()
	end
	return _instance
end

-- Resuelve P1 y el frame del BattlePass (para el highlight). Idempotente; tras el
-- primer intento (éxito o timeout) no vuelve a esperar. Devuelve si P1 existe.
function LobbyCharacterPreview:_ensureResolved(): boolean
	if self._resolved then
		return self._p1 ~= nil
	end
	self._resolved = true

	local lobby = Workspace:WaitForChild("Lobby", RESOLVE_TIMEOUT)
	local spawners = lobby and lobby:WaitForChild("Spawners", RESOLVE_TIMEOUT)
	local p1 = spawners and spawners:WaitForChild("P1", RESOLVE_TIMEOUT)
	if not p1 then
		warn("[LobbyCharacterPreview] Workspace.Lobby.Spawners.P1 no encontrado (timeout)")
		return false
	end
	self._p1 = p1

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local uiGui = playerGui:WaitForChild("UserInterface")
	self._battlePassFrame = uiGui:FindFirstChild("BattlePass")

	-- Limpiar preview previo (hot reload / re-arranque del feature).
	local previous = p1:FindFirstChild("CharacterPreview")
	if previous then
		previous:Destroy()
	end

	return true
end

function LobbyCharacterPreview:_bindHighlight(preview: Model)
	local highlight = preview:FindFirstChildOfClass("Highlight")
	local frame = self._battlePassFrame
	if highlight and frame and frame:IsA("GuiObject") then
		local guiFrame = frame :: GuiObject
		local function applyVisibility()
			highlight.Enabled = not guiFrame.Visible
		end
		self._previewJanitor:Add(
			guiFrame:GetPropertyChangedSignal("Visible"):Connect(applyVisibility),
			"Disconnect"
		)
		applyVisibility()
	end
end

-- Reconstruye el body desde cero (cambio de outfit). Recrea los appliers, así que
-- cualquier cara/hat debe re-aplicarse después.
function LobbyCharacterPreview:_rebuild(outfitId: string?)
	if not self:_ensureResolved() then
		return
	end

	self._previewJanitor:Cleanup()
	self._model = nil
	self._faceApplier = nil
	self._hatApplier = nil

	local template = resolveBodyTemplate(outfitId)
	if not template then
		return
	end

	local preview = template:Clone()
	preview.Name = "CharacterPreview"
	preview.Parent = self._p1
	self._previewJanitor:Add(preview, "Destroy")

	placeCharacter(preview, self._p1 :: Instance)
	playIdleAnimation(preview, self._previewJanitor)

	self._model = preview
	self._faceApplier = FaceApplier.new(preview, ItemsConfig)
	self._hatApplier = HatApplier.new(preview, ItemsConfig)
	self:_bindHighlight(preview)

	self._lastOutfitId = outfitId
end

--- Reconstruye el body solo si el outfit cambió respecto al actual.
function LobbyCharacterPreview:applyOutfit(outfitId: string?)
	if outfitId ~= self._lastOutfitId or not self._faceApplier then
		self:_rebuild(outfitId)
	end
end

function LobbyCharacterPreview:applyFaceImage(image: string?)
	if self._faceApplier then
		self._faceApplier:ApplyImage(image)
	end
end

function LobbyCharacterPreview:applyFaceId(faceId: string?)
	if self._faceApplier then
		self._faceApplier:ApplyItemId(faceId)
	end
end

function LobbyCharacterPreview:applyHatItem(itemData: any)
	if self._hatApplier then
		self._hatApplier:Apply(itemData)
	end
end

function LobbyCharacterPreview:applyHatId(hatId: string?)
	if self._hatApplier then
		self._hatApplier:ApplyItemId(hatId)
	end
end

--- Sincroniza el preview con el loadout equipado (outfit/cara/hat).
function LobbyCharacterPreview:syncToEquipped()
	local loadout = Fusion.peek(DataController.Loadout) :: { [string]: any }
	if type(loadout) ~= "table" then
		return
	end
	self:applyOutfit(getOptionalString(loadout.Outfit))
	self:applyFaceId(getOptionalString(loadout.Face))
	self:applyHatId(getOptionalString(loadout.Hat))
end

--- Igual que syncToEquipped, pero respeta al Locker: si tiene el preview tomado,
--- no hace nada (el Locker está mostrando una selección sin equipar).
function LobbyCharacterPreview:syncToEquippedIfIdle()
	if self._previewActive then
		return
	end
	self:syncToEquipped()
end

--- El Locker toma el preview: a partir de aquí los syncs de loadout del lobby se
--- ignoran y el Locker controla qué se muestra.
function LobbyCharacterPreview:beginPreview()
	self._previewActive = true
end

--- El Locker suelta el preview y se restaura lo equipado.
function LobbyCharacterPreview:endPreview()
	self._previewActive = false
	self:syncToEquipped()
end

return LobbyCharacterPreview
