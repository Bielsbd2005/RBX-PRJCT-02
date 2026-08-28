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

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
local AssetIds = require(Shared.constants.AssetIds)

local IDLE_ANIMATION_ID = AssetIds.Animations.CharacterIdle
local RESOLVE_TIMEOUT = 30
local HIGHLIGHT_COLOR = Color3.fromRGB(0, 0, 0)
local HIGHLIGHT_OUTLINE_ALPHA = 0.1

-- Body bloqueado por nivel: el contorno pasa a blanco y el relleno se vuelve casi
-- opaco, de modo que la silueta se ve "apagada" y se lee como no disponible.
local LOCKED_OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
local LOCKED_FILL_TRANSPARENCY = 0.1

-- Billboard de ReplicatedStorage que se clona en el LowerTorso del preview
-- mientras el body está bloqueado (LevelLock.Status.Level → "Lv. X"). Solo aplica
-- al body: un hat bloqueado se marca con el highlight pero SIN billboard.
local LEVEL_LOCK_TEMPLATE_NAME = "LevelLock"

-- Highlight propio del hat bloqueado, dentro de su Handle (el del modelo cubre
-- todo el rig y marcaría también el body, que puede estar desbloqueado).
local HAT_LOCK_HIGHLIGHT_NAME = "HatLockHighlight"

-- Paneles del lobby (hijos directos de PlayerGui.UserInterface) que ocultan el
-- contorno del preview mientras están abiertos: tapan al personaje o se lo
-- llevan fuera de cámara, y el contorno quedaría flotando sobre la GUI.
--
-- El Locker NO está aquí a propósito: es el único panel donde el preview es el
-- protagonista, y el contorno es justo lo que marca la silueta del outfit que
-- se está probando.
local HIGHLIGHT_HIDING_PANELS = {
	"Gifting",
	"Store",
	"Settings",
	"Credits",
	"Rewards",
	"Voting",
	"GiftAlert",
	"BattlePass",
}

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
		-- MoveTo NO: desplaza el modelo hacia arriba si choca con algo, y durante el
		-- swap el preview saliente sigue en el mismo sitio. Pivote directo.
		local pivot = model:GetPivot()
		model:PivotTo(CFrame.new(target.Position) * (pivot - pivot.Position))
		return
	end

	if target:IsA("Model") then
		model:PivotTo(target:GetPivot())
	end
end

-- Animación idle COMPARTIDA y precargada: reutilizar la misma Animation (y
-- precargar su asset una sola vez) evita que al cambiar de outfit se vea "cargar"
-- la animación; con el asset listo, LoadAnimation/Play aplican la pose al instante.
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

-- Mientras el entrante espera su pose convive en el mismo sitio que el saliente.
-- Sin congelarlo los dos rigs se empujan y acaban desplazados unos studs: se le
-- quitan las colisiones y se ancla su root hasta el swap. El resto del rig sigue
-- posándose por Motor6D, que no depende de la física.
type FrozenPhysics = { collide: { [BasePart]: boolean }, root: BasePart?, rootAnchored: boolean }

local function freezePreviewPhysics(model: Model): FrozenPhysics
	local collide: { [BasePart]: boolean } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.CanCollide then
			collide[descendant] = true
			descendant.CanCollide = false
		end
	end

	local rootNode = model:FindFirstChild("HumanoidRootPart", true)
	local root = if rootNode and rootNode:IsA("BasePart") then rootNode else nil
	local rootAnchored = if root then root.Anchored else false
	if root then
		root.Anchored = true
	end

	return { collide = collide, root = root, rootAnchored = rootAnchored }
end

local function unfreezePreviewPhysics(frozen: FrozenPhysics)
	for part in frozen.collide do
		if part.Parent then
			part.CanCollide = true
		end
	end

	local root = frozen.root
	if root and root.Parent then
		root.Anchored = frozen.rootAnchored
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end

-- Oculta/revela el preview localmente (LocalTransparencyModifier no toca la
-- transparencia base ni replica). Cubre partes, decals y texturas (cara incluida).
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
	-- Sin fade: la pose idle (sentado) se fija de inmediato. El modelo se mantiene
	-- oculto en _rebuild hasta que esta pose se aplica, así que no se ve el frame en
	-- pie del template antes de "sentarse".
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
}

local LobbyCharacterPreview = {}
LobbyCharacterPreview.__index = LobbyCharacterPreview

local _instance: any = nil

local function _new(): any
	local self = setmetatable({}, LobbyCharacterPreview)
	self._janitor = Janitor.new()
	self._previewJanitor = Janitor.new()
	-- Janitor del preview SALIENTE mientras el entrante se posa (ver _rebuild).
	self._outgoingJanitor = nil :: any
	self._janitor:Add(function()
		if self._outgoingJanitor then
			self._outgoingJanitor:Destroy()
			self._outgoingJanitor = nil
		end
		self._previewJanitor:Destroy()
	end, true)
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
	return self
end

--- Devuelve el singleton del preview del personaje del lobby.
function LobbyCharacterPreview.get(): LobbyCharacterPreview
	if not _instance then
		_instance = _new()
	end
	return _instance
end

-- Resuelve P1 y el ScreenGui de la UI (para el highlight). Idempotente; tras el
-- primer intento (éxito o timeout) no vuelve a esperar. Devuelve si P1 existe.
function LobbyCharacterPreview:_ensureResolved(): boolean
	if self._resolved then
		return self._p1 ~= nil
	end

	local lobby = Workspace:WaitForChild("Lobby", RESOLVE_TIMEOUT)
	local spawners = lobby and lobby:WaitForChild("Spawners", RESOLVE_TIMEOUT)
	local p1 = spawners and spawners:WaitForChild("P1", RESOLVE_TIMEOUT)
	if not p1 then
		-- NO marcar _resolved aquí: si la geometría del lobby aún no replicó
		-- (móvil lento / stall), dejarlo en false permite reintentar en la
		-- siguiente llamada (son por acción del usuario, no por frame). Marcarlo
		-- antes del WaitForChild deshabilitaba el preview el resto de la sesión.
		warn("[LobbyCharacterPreview] Workspace.Lobby.Spawners.P1 no encontrado (timeout)")
		return false
	end
	self._p1 = p1
	self._resolved = true

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	self._uiGui = playerGui:WaitForChild("UserInterface")

	-- Limpiar preview previo (hot reload / re-arranque del feature).
	local previous = p1:FindFirstChild("CharacterPreview")
	if previous then
		previous:Destroy()
	end

	return true
end

function LobbyCharacterPreview:_bindHighlight(preview: Model)
	-- El body template puede traer Highlight o no; se crea si falta para que el
	-- contorno no dependa de cómo esté montado cada asset.
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
	-- Colores/relleno según esté bloqueado o no (ver _applyLockVisuals).
	self:_applyLockVisuals()

	-- Con cualquier panel de HIGHLIGHT_HIDING_PANELS abierto, fuera el contorno.
	-- Se resuelve en cada _rebuild (no una sola vez al arrancar) para que un panel
	-- que replicó tarde entre en la cuenta sin reiniciar el feature; las conexiones
	-- viven en _previewJanitor, que se limpia justo antes de cada rebind.
	local panels: { GuiObject } = {}
	local uiGui = self._uiGui
	if uiGui then
		for _, name in HIGHLIGHT_HIDING_PANELS do
			local node = uiGui:FindFirstChild(name)
			if node and node:IsA("GuiObject") then
				table.insert(panels, node :: GuiObject)
			end
		end
	end

	if #panels == 0 then
		return
	end

	local function applyVisibility()
		local anyPanelOpen = false
		for _, panel in panels do
			if panel.Visible then
				anyPanelOpen = true
				break
			end
		end
		self._highlightHidden = anyPanelOpen
		highlight.Enabled = not anyPanelOpen
		local levelLock = self._levelLock
		if levelLock and levelLock:IsA("BillboardGui") then
			levelLock.Enabled = not anyPanelOpen
		end
		self:_applyHatLock()
	end

	for _, panel in panels do
		self._previewJanitor:Add(
			panel:GetPropertyChangedSignal("Visible"):Connect(applyVisibility),
			"Disconnect"
		)
	end
	applyVisibility()
end

-- Aplica el estado de bloqueo al contorno y al billboard de nivel. Se llama tanto
-- tras reconstruir el body como al cambiar solo el estado (mismo outfit).
function LobbyCharacterPreview:_applyLockVisuals()
	local highlight = self._highlight
	if highlight then
		if self._lockedLevel then
			-- Bloqueado: relleno casi opaco + contorno blanco.
			highlight.FillColor = HIGHLIGHT_COLOR
			highlight.FillTransparency = LOCKED_FILL_TRANSPARENCY
			highlight.OutlineColor = LOCKED_OUTLINE_COLOR
		else
			-- Contorno negro sin relleno: marca la silueta sin tapar el outfit que se
			-- está previsualizando. Mismo criterio que CharacterHighlightController usa
			-- para el personaje del local player en partida.
			highlight.FillColor = HIGHLIGHT_COLOR
			highlight.FillTransparency = 1
			highlight.OutlineColor = HIGHLIGHT_COLOR
		end
	end

	self:_updateLevelLock()
end

-- Marca el hat bloqueado con el mismo contorno de bloqueo que el body, pero
-- dentro de su Handle y sin billboard: el nivel requerido ya lo cuenta el
-- ActionFrame del locker.
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
		highlight.Enabled = not self._highlightHidden
	end
end

-- Clona/actualiza/destruye ReplicatedStorage.LevelLock en el LowerTorso del preview.
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
		local template = ReplicatedStorage:FindFirstChild(LEVEL_LOCK_TEMPLATE_NAME)
		if not template then
			warn("[LobbyCharacterPreview] ReplicatedStorage.LevelLock no encontrado")
			return
		end

		-- El rig es R15; si el asset viniera con otro torso, se cae a lo que haya
		-- para que el billboard no desaparezca por un nombre distinto.
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
		billboard.Enabled = not self._highlightHidden
	end

	local status = billboard:FindFirstChild("Status")
	local levelLabel = (status and status:FindFirstChild("Level")) or billboard:FindFirstChild("Level", true)
	if levelLabel and levelLabel:IsA("TextLabel") then
		levelLabel.Text = string.format("Lv. %d", level)
	end
end

-- Reconstruye el body desde cero (cambio de outfit). Recrea los appliers, así que
-- cualquier cara/hat debe re-aplicarse después.
--
-- Doble buffer para que el cambio de body no parpadee: el modelo entrante se clona
-- OCULTO y el saliente se mantiene en pantalla hasta que el entrante tiene su pose
-- idle; solo entonces se destruye el saliente y se revela el entrante, en el mismo
-- frame. Antes se destruía el saliente al empezar, así que el spawner quedaba vacío
-- los 2+ frames (hasta 1s si el asset de animación tardaba) que tarda el rig en
-- posarse — ese era el parpadeo.
function LobbyCharacterPreview:_rebuild(outfitId: string?)
	if not self:_ensureResolved() then
		return
	end

	-- Se resuelve ANTES de tocar nada: si el outfit no tiene template, no merece la
	-- pena tirar el preview actual.
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

	-- El saliente pasa a su propio janitor; si ya había uno esperando (cambios muy
	-- rápidos) se destruye ya: solo el último visible merece quedarse.
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
	-- Oculto ANTES de entrar al Workspace: así nunca se renderiza el frame en pie
	-- del template ni se solapa con el saliente.
	setPreviewHidden(preview, true)
	self._previewHidden = true
	local frozen = freezePreviewPhysics(preview)
	preview.Parent = self._p1
	self._previewJanitor:Add(preview, "Destroy")

	placeCharacter(preview, self._p1 :: Instance)
	local idleTrack = playIdleAnimation(preview, self._previewJanitor)

	self._model = preview
	self._faceApplier = FaceApplier.new(preview, ItemsConfig)
	self._hatApplier = HatApplier.new(preview, ItemsConfig)
	self:_bindHighlight(preview)

	self._lastOutfitId = outfitId

	-- Se revela cuando el asset de animación cargó (Length > 0) + un par de frames
	-- para que el Animator pose el rig.
	task.spawn(function()
		local deadline = os.clock() + 1
		while idleTrack and idleTrack.Length <= 0 and os.clock() < deadline do
			RunService.RenderStepped:Wait()
		end
		RunService.RenderStepped:Wait()
		RunService.RenderStepped:Wait()

		-- Swap atómico: fuera el saliente, dentro el entrante. Si otro _rebuild ya
		-- se llevó por delante a `outgoing`, aquí no queda nada que destruir.
		if self._outgoingJanitor == outgoing then
			self._outgoingJanitor = nil
			outgoing:Destroy()
		end

		if self._model == preview and preview.Parent then
			-- Recolocar justo antes de revelar: deja fuera cualquier deriva de los
			-- frames en que ambos previews coexistieron.
			placeCharacter(preview, self._p1 :: Instance)
			unfreezePreviewPhysics(frozen)
			self._previewHidden = false
			setPreviewHidden(preview, false)
		else
			unfreezePreviewPhysics(frozen)
		end
	end)
end

-- Cara y hat se aplican DESPUÉS de reconstruir el body, mientras el entrante sigue
-- oculto esperando su pose. Sus partes nacen con LocalTransparencyModifier 0, así
-- que sin esto un hat nuevo se vería flotando sobre el personaje saliente.
function LobbyCharacterPreview:_reapplyHiddenState()
	local model = self._model
	if self._previewHidden and model then
		setPreviewHidden(model, true)
	end
end

--- Reconstruye el body solo si el outfit cambió respecto al actual.
--- `lockedLevel` es el nivel requerido cuando el body está bloqueado (nil si no
--- lo está): pinta el contorno de bloqueo y muestra el billboard LevelLock.
function LobbyCharacterPreview:applyOutfit(outfitId: string?, lockedLevel: number?)
	self._lockedLevel = lockedLevel
	if outfitId ~= self._lastOutfitId or not self._faceApplier then
		-- _rebuild → _bindHighlight → _applyLockVisuals ya deja el estado aplicado.
		self:_rebuild(outfitId)
	else
		self:_applyLockVisuals()
	end
end

function LobbyCharacterPreview:applyFaceImage(image: string?)
	if self._faceApplier then
		self._faceApplier:ApplyImage(image)
	end
	self:_reapplyHiddenState()
end

function LobbyCharacterPreview:applyFaceId(faceId: string?)
	if self._faceApplier then
		self._faceApplier:ApplyItemId(faceId)
	end
	self:_reapplyHiddenState()
end

--- `lockedLevel` no-nil marca el hat como bloqueado (contorno de bloqueo en su
--- Handle; el billboard LevelLock es solo del body).
function LobbyCharacterPreview:applyHatItem(itemData: any, lockedLevel: number?)
	self._hatLockedLevel = lockedLevel
	if self._hatApplier then
		self._hatApplier:Apply(itemData)
	end
	self:_applyHatLock()
	self:_reapplyHiddenState()
end

function LobbyCharacterPreview:applyHatId(hatId: string?, lockedLevel: number?)
	self._hatLockedLevel = lockedLevel
	if self._hatApplier then
		self._hatApplier:ApplyItemId(hatId)
	end
	self:_applyHatLock()
	self:_reapplyHiddenState()
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
