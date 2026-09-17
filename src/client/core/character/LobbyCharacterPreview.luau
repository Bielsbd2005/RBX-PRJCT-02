--!strict
--[[
	Singleton dueño del preview del personaje local en Workspace.Lobby.Spawners.P1,
	compartido por LobbyFeature (lo sincroniza a lo equipado) y el Locker (lo toma
	entre :beginPreview y :endPreview; mientras tanto syncToEquippedIfIdle es no-op).
	Es local al cliente: cada jugador ve solo el suyo.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Core = script.Parent.Parent
local ClientRoot = Core.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Templates = ReplicatedStorage:WaitForChild("Templates")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any

local FaceApplier = require(ClientRoot.features.locker.Appliers.FaceApplier)
local HatApplier = require(ClientRoot.features.locker.Appliers.HatApplier)
local DataController = require(Core.data.DataController)
local PreviewHighlightPanels = require(Core.ui.PreviewHighlightPanels)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local AssetIds = require(Shared.constants.AssetIds)

local IDLE_ANIMATION_ID = AssetIds.Animations.CharacterIdle
local RESOLVE_TIMEOUT = 30
local HIGHLIGHT_COLOR = Color3.fromRGB(0, 0, 0)
local HIGHLIGHT_OUTLINE_ALPHA = 0.1

local LOCKED_OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
local LOCKED_FILL_TRANSPARENCY = 0.1

-- ReplicatedStorage.Templates.LevelLock (TextLabel en Status.Level), clonado en el
-- LowerTorso solo con el body bloqueado; el hat bloqueado no lleva billboard.
local LEVEL_LOCK_TEMPLATE_NAME = "LevelLock"

-- Va en el Handle del hat: el Highlight del modelo cubriría también el body.
local HAT_LOCK_HIGHLIGHT_NAME = "HatLockHighlight"

local function getOptionalString(value: any): string?
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

-- Llamar siempre justo después de colocar el modelo: así `yaw` es absoluto respecto
-- a la pose de frente y repetirlo cada frame no acumula deriva.
local function spinAround(model: Model, center: Vector3, yaw: number)
	if yaw == 0 then
		return
	end
	local axis = CFrame.new(center.X, 0, center.Z)
	model:PivotTo(axis * CFrame.Angles(0, yaw, 0) * axis:Inverse() * model:GetPivot())
end

-- Se llama cada frame durante el arrastre del Locker (:setYaw): solo colocar.
local function positionCharacter(model: Model, target: Instance, yaw: number?)
	local spin = yaw or 0

	if target:IsA("BasePart") then
		local rootPart = model:FindFirstChild("HumanoidRootPart", true)
		if rootPart and rootPart:IsA("BasePart") then
			local rootOffset = model:GetPivot():ToObjectSpace(rootPart.CFrame)
			model:PivotTo(target.CFrame * rootOffset:Inverse())
			spinAround(model, target.Position, spin)
			return
		end
		-- MoveTo no: sube el modelo si choca, y durante el swap el saliente ocupa el sitio.
		local pivot = model:GetPivot()
		model:PivotTo(CFrame.new(target.Position) * (pivot - pivot.Position))
		spinAround(model, target.Position, spin)
		return
	end

	if target:IsA("Model") then
		local targetPivot = target:GetPivot()
		model:PivotTo(targetPivot)
		spinAround(model, targetPivot.Position, spin)
	end
end

local function placeCharacter(model: Model, target: Instance, yaw: number?)
	local humanoid = model:FindFirstChildWhichIsA("Humanoid", true)
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	positionCharacter(model, target, yaw)
end

-- Animation compartida y precargada para que al cambiar de outfit la pose se aplique
-- al instante.
local _idleAnimation: Animation? = nil
local _idlePreloadStarted = false
local function getIdleAnimation(): Animation
	local anim = _idleAnimation
	if not anim then
		anim = Instance.new("Animation")
		anim.Name = "LobbyPreviewIdle"
		anim.AnimationId = IDLE_ANIMATION_ID
		_idleAnimation = anim
	end
	if not _idlePreloadStarted then
		_idlePreloadStarted = true
		task.spawn(function()
			pcall(function()
				ContentProvider:PreloadAsync({ anim })
			end)
		end)
	end
	return anim
end

-- El root va anclado siempre: suelto, el Humanoid, la gravedad o el jugador lo
-- desplazan. El resto del rig se posa por Motor6D, así que el idle sigue funcionando.
local function anchorPreviewRoot(model: Model)
	local root = model:FindFirstChild("HumanoidRootPart", true)
	if root and root:IsA("BasePart") then
		root.Anchored = true
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end

local function disableCollisions(model: Model): { BasePart }
	local disabled: { BasePart } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.CanCollide then
			table.insert(disabled, descendant)
			descendant.CanCollide = false
		end
	end
	return disabled
end

local function restoreCollisions(parts: { BasePart })
	for _, part in parts do
		if part.Parent then
			part.CanCollide = true
		end
	end
end

local function setPreviewHidden(model: Model, hidden: boolean)
	local modifier = if hidden then 1 else 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then
			(d :: any).LocalTransparencyModifier = modifier
		end
	end
end

local function playIdleAnimation(model: Model, janitor: any): AnimationTrack?
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

	local track = animator:LoadAnimation(getIdleAnimation())
	track.Name = "LobbyPreviewIdle"
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Idle
	-- Sin fade: _rebuild mantiene el modelo oculto hasta que esta pose se aplica.
	track:Play(0)

	janitor:Add(function()
		track:Stop(0)
		track:Destroy()
	end, true)

	return track
end

local function resolveBodyTemplate(outfitId: string?): Model?
	local folder = Shared:WaitForChild("Bodies", RESOLVE_TIMEOUT)
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
	buildLookClone: (self: LobbyCharacterPreview) -> Model?,
	setHiddenByOwner: (self: LobbyCharacterPreview, hidden: boolean) -> (),
	setYaw: (self: LobbyCharacterPreview, yaw: number) -> (),
}

local LobbyCharacterPreview = {}
LobbyCharacterPreview.__index = LobbyCharacterPreview

local _instance: any = nil

local function _new(): any
	local self = setmetatable({}, LobbyCharacterPreview)
	self._previewJanitor = Janitor.new()
	self._outgoingJanitor = nil :: any
	self._p1 = nil :: Instance?
	self._uiGui = nil :: Instance?
	self._model = nil :: Model?
	self._faceApplier = nil :: any
	self._hatApplier = nil :: any
	self._lastOutfitId = nil :: string?
	self._previewActive = false
	self._resolved = false
	self._highlight = nil :: Highlight?
	self._highlightHidden = false
	self._levelLock = nil :: Instance?
	self._lockedLevel = nil :: number?
	self._hatLockedLevel = nil :: number?
	self._previewHidden = false
	-- Radianes; 0 = de frente.
	self._yaw = 0
	self._hiddenByOwner = false
	self._ownerNoCollide = nil :: { BasePart }?
	self._lastFace = nil :: { image: string?, id: string? }?
	self._lastHat = nil :: { itemData: any, id: string? }?
	return self
end

function LobbyCharacterPreview.get(): LobbyCharacterPreview
	if not _instance then
		_instance = _new()
	end
	return _instance
end

function LobbyCharacterPreview:_ensureResolved(): boolean
	if self._resolved then
		return self._p1 ~= nil
	end

	local lobby = Workspace:WaitForChild("Lobby", RESOLVE_TIMEOUT)
	local spawners = lobby and lobby:WaitForChild("Spawners", RESOLVE_TIMEOUT)
	local p1 = spawners and spawners:WaitForChild("P1", RESOLVE_TIMEOUT)
	if not p1 then
		-- Sin marcar _resolved: si el lobby aún no replicó (móvil lento), la siguiente
		-- llamada reintenta en vez de dejar el preview deshabilitado toda la sesión.
		warn("[LobbyCharacterPreview] Workspace.Lobby.Spawners.P1 no encontrado (timeout)")
		return false
	end
	self._p1 = p1
	self._resolved = true

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	self._uiGui = playerGui:WaitForChild("UserInterface")

	-- Restos de un arranque anterior (hot reload).
	local previous = p1:FindFirstChild("CharacterPreview")
	if previous then
		previous:Destroy()
	end

	return true
end

function LobbyCharacterPreview:_bindHighlight(preview: Model)
	local existing = preview:FindFirstChildOfClass("Highlight")
	local highlight: Highlight
	if existing then
		highlight = existing
	else
		highlight = Instance.new("Highlight")
		highlight.Name = "PreviewHighlight"
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = preview
	end

	self._highlight = highlight
	self._highlightHidden = false
	highlight.OutlineTransparency = HIGHLIGHT_OUTLINE_ALPHA
	highlight.Enabled = true
	self:_applyLockVisuals()

	local stopObserving = PreviewHighlightPanels.observe(self._uiGui, function(hidden: boolean)
		self._highlightHidden = hidden
		highlight.Enabled = not hidden
		local levelLock = self._levelLock
		if levelLock and levelLock:IsA("BillboardGui") then
			levelLock.Enabled = not hidden
		end
		self:_applyHatLock()
	end)

	self._previewJanitor:Add(stopObserving, true)
end

function LobbyCharacterPreview:_applyLockVisuals()
	local highlight = self._highlight
	if highlight then
		if self._lockedLevel then
			highlight.FillColor = HIGHLIGHT_COLOR
			highlight.FillTransparency = LOCKED_FILL_TRANSPARENCY
			highlight.OutlineColor = LOCKED_OUTLINE_COLOR
		else
			-- Mismo criterio que CharacterHighlightController en partida.
			highlight.FillColor = HIGHLIGHT_COLOR
			highlight.FillTransparency = 1
			highlight.OutlineColor = HIGHLIGHT_COLOR
		end
	end

	self:_updateLevelLock()
end

-- Sin billboard para el hat: el nivel requerido ya lo muestra el ActionFrame del locker.
function LobbyCharacterPreview:_applyHatLock()
	local model = self._model
	if not model then
		return
	end

	for _, child in model:GetChildren() do
		if not (child:IsA("Accessory") and child:GetAttribute("CosmeticHat") == true) then
			continue
		end

		local handle = child:FindFirstChild("Handle")
		if not (handle and handle:IsA("BasePart")) then
			continue
		end

		local existing = handle:FindFirstChild(HAT_LOCK_HIGHLIGHT_NAME)
		if not self._hatLockedLevel then
			if existing then
				existing:Destroy()
			end
			continue
		end

		local highlight: Highlight
		if existing and existing:IsA("Highlight") then
			highlight = existing
		else
			highlight = Instance.new("Highlight")
			highlight.Name = HAT_LOCK_HIGHLIGHT_NAME
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			highlight.Adornee = handle
			highlight.Parent = handle
		end

		highlight.FillColor = HIGHLIGHT_COLOR
		highlight.FillTransparency = LOCKED_FILL_TRANSPARENCY
		highlight.OutlineColor = LOCKED_OUTLINE_COLOR
		highlight.OutlineTransparency = HIGHLIGHT_OUTLINE_ALPHA
		highlight.Enabled = not self._highlightHidden and not self._hiddenByOwner
	end
end

function LobbyCharacterPreview:_updateLevelLock()
	local level = self._lockedLevel
	local model = self._model
	local existing = self._levelLock

	if not level or not model then
		if existing then
			existing:Destroy()
		end
		self._levelLock = nil
		return
	end

	local billboard = existing
	if not billboard or not billboard.Parent then
		local template = Templates:FindFirstChild(LEVEL_LOCK_TEMPLATE_NAME)
		if not template then
			warn("[LobbyCharacterPreview] ReplicatedStorage.Templates.LevelLock no encontrado")
			return
		end

		local anchorPart = model:FindFirstChild("LowerTorso", true)
			or model:FindFirstChild("Torso", true)
			or model:FindFirstChild("HumanoidRootPart", true)
		if not anchorPart then
			return
		end

		billboard = template:Clone()
		billboard.Parent = anchorPart
		self._levelLock = billboard
	end

	if billboard:IsA("BillboardGui") then
		billboard.Enabled = not self._highlightHidden and not self._hiddenByOwner
	end

	local status = billboard:FindFirstChild("Status")
	local levelLabel = (status and status:FindFirstChild("Level")) or billboard:FindFirstChild("Level", true)
	if levelLabel and levelLabel:IsA("TextLabel") then
		levelLabel.Text = string.format("Lv. %d", level)
	end
end

-- Recrea los appliers: cara/hat deben re-aplicarse después.
-- Doble buffer contra el parpadeo: el entrante se clona oculto y el saliente sigue
-- visible hasta que el entrante tiene su pose idle; el swap ocurre en un solo frame.
function LobbyCharacterPreview:_rebuild(outfitId: string?)
	if not self:_ensureResolved() then
		return
	end

	local template = resolveBodyTemplate(outfitId)
	if not template then
		self._previewJanitor:Cleanup()
		self._model = nil
		self._faceApplier = nil
		self._hatApplier = nil
		self._highlight = nil
		self._levelLock = nil
		return
	end

	-- Si ya había un saliente esperando (cambios muy rápidos), se destruye ya.
	local previousOutgoing = self._outgoingJanitor
	local outgoing = self._previewJanitor
	self._outgoingJanitor = outgoing
	self._previewJanitor = Janitor.new()
	if previousOutgoing then
		previousOutgoing:Destroy()
	end

	self._model = nil
	self._faceApplier = nil
	self._hatApplier = nil
	self._highlight = nil
	self._levelLock = nil

	local preview = template:Clone()
	preview.Name = "CharacterPreview"
	-- Oculto antes de entrar al Workspace para no renderizar nunca la pose del template.
	setPreviewHidden(preview, true)
	self._previewHidden = true
	anchorPreviewRoot(preview)
	local noCollide = disableCollisions(preview)
	preview.Parent = self._p1
	self._previewJanitor:Add(preview, "Destroy")

	placeCharacter(preview, self._p1 :: Instance, self._yaw)
	local idleTrack = playIdleAnimation(preview, self._previewJanitor)

	self._model = preview
	self._faceApplier = FaceApplier.new(preview, ItemsConfig)
	self._hatApplier = HatApplier.new(preview, ItemsConfig)
	self:_bindHighlight(preview)

	self._lastOutfitId = outfitId

	-- Revelar cuando la animación cargó (Length > 0) + dos frames para que el Animator pose.
	task.spawn(function()
		local deadline = os.clock() + 1
		while idleTrack and idleTrack.Length <= 0 and os.clock() < deadline do
			RunService.RenderStepped:Wait()
		end
		RunService.RenderStepped:Wait()
		RunService.RenderStepped:Wait()

		if self._outgoingJanitor == outgoing then
			self._outgoingJanitor = nil
			outgoing:Destroy()
		end

		if self._model == preview and preview.Parent then
			placeCharacter(preview, self._p1 :: Instance, self._yaw)
			anchorPreviewRoot(preview)
			self._previewHidden = false
			setPreviewHidden(preview, self._hiddenByOwner)
			if self._hiddenByOwner then
				-- La colisión se devuelve en setHiddenByOwner.
				self._ownerNoCollide = noCollide
			else
				restoreCollisions(noCollide)
			end
		else
			restoreCollisions(noCollide)
		end
	end)
end

-- Las partes de cara/hat nacen con LocalTransparencyModifier 0: sin esto un hat
-- aplicado durante el swap se vería flotando sobre el saliente.
function LobbyCharacterPreview:_reapplyHiddenState()
	local model = self._model
	if (self._previewHidden or self._hiddenByOwner) and model then
		setPreviewHidden(model, true)
	end
end

--- `lockedLevel`: nivel requerido si el body está bloqueado, nil si no.
function LobbyCharacterPreview:applyOutfit(outfitId: string?, lockedLevel: number?)
	self._lockedLevel = lockedLevel
	if outfitId ~= self._lastOutfitId or not self._faceApplier then
		self:_rebuild(outfitId)
	else
		self:_applyLockVisuals()
	end
end

function LobbyCharacterPreview:applyFaceImage(image: string?)
	self._lastFace = { image = image }
	if self._faceApplier then
		self._faceApplier:ApplyImage(image)
	end
	self:_reapplyHiddenState()
end

function LobbyCharacterPreview:applyFaceId(faceId: string?)
	self._lastFace = { id = faceId }
	if self._faceApplier then
		self._faceApplier:ApplyItemId(faceId)
	end
	self:_reapplyHiddenState()
end

function LobbyCharacterPreview:applyHatItem(itemData: any, lockedLevel: number?)
	self._hatLockedLevel = lockedLevel
	self._lastHat = { itemData = itemData }
	if self._hatApplier then
		self._hatApplier:Apply(itemData)
	end
	self:_applyHatLock()
	self:_reapplyHiddenState()
end

function LobbyCharacterPreview:applyHatId(hatId: string?, lockedLevel: number?)
	self._hatLockedLevel = lockedLevel
	self._lastHat = { id = hatId }
	if self._hatApplier then
		self._hatApplier:ApplyItemId(hatId)
	end
	self:_applyHatLock()
	self:_reapplyHiddenState()
end

function LobbyCharacterPreview:syncToEquipped()
	local loadout = Fusion.peek(DataController.Loadout) :: { [string]: any }
	if type(loadout) ~= "table" then
		return
	end
	self:applyOutfit(getOptionalString(loadout.Outfit))
	self:applyFaceId(getOptionalString(loadout.Face))
	self:applyHatId(getOptionalString(loadout.Hat))
end

function LobbyCharacterPreview:syncToEquippedIfIdle()
	if self._previewActive then
		return
	end
	self:syncToEquipped()
end

function LobbyCharacterPreview:beginPreview()
	self._previewActive = true
	self:setYaw(0)
end

--- Radianes, absoluto respecto a la pose de frente; se conserva al reconstruir el body.
function LobbyCharacterPreview:setYaw(yaw: number)
	if self._yaw == yaw then
		return
	end
	self._yaw = yaw

	local model = self._model
	local p1 = self._p1
	if model and model.Parent and p1 then
		positionCharacter(model, p1, yaw)
		-- PivotTo deja velocidades residuales; se limpian por si algo desancla el root.
		anchorPreviewRoot(model)
	end
end

local function relativePath(instance: Instance, root: Instance): string
	local names = {}
	local current: Instance? = instance
	while current and current ~= root do
		table.insert(names, 1, current.Name)
		current = current.Parent
	end
	return table.concat(names, "/")
end

--- Doble para recibir un kill effect: el look actual construido limpio desde las
--- plantillas (clonar el preview vivo arrastra animación, anclaje y contornos que
--- estropean el efecto) pero con la misma pose por parte. Sin Parent; del caller.
function LobbyCharacterPreview:buildLookClone(): Model?
	local template = resolveBodyTemplate(self._lastOutfitId)
	if not template then
		return nil
	end

	local clone = template:Clone()
	clone.Name = "KillEffectPreview"
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("Highlight") or descendant:IsA("BillboardGui") then
			descendant:Destroy()
		end
	end

	local face = self._lastFace
	local faceApplier = FaceApplier.new(clone, ItemsConfig)
	if face and face.image ~= nil then
		faceApplier:ApplyImage(face.image)
	else
		faceApplier:ApplyItemId(if face then face.id else nil)
	end

	local hat = self._lastHat
	local hatApplier = HatApplier.new(clone, ItemsConfig)
	if hat and hat.itemData ~= nil then
		hatApplier:Apply(hat.itemData)
	else
		hatApplier:ApplyItemId(if hat then hat.id else nil)
	end

	-- Copiar la pose antes de tener Parent: fuera del Workspace los Motor6D/welds no
	-- arrastran al resto del rig al fijar cada CFrame.
	local model = self._model
	if model and model.Parent then
		local liveByPath: { [string]: BasePart } = {}
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				liveByPath[relativePath(descendant, model)] = descendant
			end
		end
		for _, descendant in clone:GetDescendants() do
			if descendant:IsA("BasePart") then
				local live = liveByPath[relativePath(descendant, clone)]
				if live then
					descendant.CFrame = live.CFrame
				end
			end
		end
	end

	return clone
end

--- Independiente del ocultado interno del swap: un rebuild que termine mientras
--- tanto no lo revela antes de tiempo.
function LobbyCharacterPreview:setHiddenByOwner(hidden: boolean)
	if self._hiddenByOwner == hidden then
		return
	end
	self._hiddenByOwner = hidden

	local model = self._model
	if model and model.Parent and not self._previewHidden then
		setPreviewHidden(model, hidden)
	end
	-- Invisible no basta: con colisión, el doble ragdoll se apoya en el cuerpo fantasma.
	if hidden then
		if model and model.Parent then
			self._ownerNoCollide = disableCollisions(model)
		end
	else
		local noCollide = self._ownerNoCollide
		self._ownerNoCollide = nil
		if noCollide then
			restoreCollisions(noCollide)
		end
	end
	local highlight = self._highlight
	if highlight then
		highlight.Enabled = not self._highlightHidden and not hidden
	end
	local levelLock = self._levelLock
	if levelLock and levelLock:IsA("BillboardGui") then
		levelLock.Enabled = not self._highlightHidden and not hidden
	end
	self:_applyHatLock()
end

function LobbyCharacterPreview:endPreview()
	self._previewActive = false
	self:setYaw(0)
	self:syncToEquipped()
end

return LobbyCharacterPreview
