--!strict

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any
local LockerCameraController = require(Client.core.camera.LockerCameraController)
local CameraLock = require(Client.core.camera.CameraLock)
local ScenePresetController = require(Client.core.lighting.ScenePresetController)
local LobbyCharacterPreview = require(Client.core.character.LobbyCharacterPreview)
local LockerCatalog = require(script:WaitForChild("LockerCatalog"))
local LockerGrid = require(script:WaitForChild("LockerGrid"))
local LockerBanners = require(script:WaitForChild("LockerBanners"))
local BannerPreviewer = require(script:WaitForChild("Previewers"):WaitForChild("BannerPreviewer"))
local LockerUtils = require(script:WaitForChild("LockerUtils"))
local WeaponPreviewController = require(script:WaitForChild("WeaponPreviewController"))
local WeaponStatsPanel = require(script:WaitForChild("WeaponStatsPanel"))
local CharacterRotateController = require(script:WaitForChild("CharacterRotateController"))
local MenuHover = require(Client.core.ui.MenuHover)
local NavStaggerController = require(Client.core.ui.NavStaggerController)
local UIUtils = require(Client.core.ui.UIUtils)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local AssetIds = require(Shared.constants.AssetIds)
local WeaponDisplayStats = require(Shared.constants.WeaponsConfig.DisplayStats)
local LockerConfig = require(Shared.constants.LockerConfig)
local WeaponCategoryMod = require(Shared.constants.WeaponCategory)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local LockerCategory = require(Shared.constants.LockerCategory)
local CurrencyMod = require(Shared.constants.Currency)
local LockerMainCategory = require(Shared.constants.LockerMainCategory)
local Network = require(Shared.networking.Network)
local KillEffectsRegistry = require(Shared.Locker.killEffects.KillEffectsRegistry)
local EmotePlayer = require(Shared.Locker.emotes.EmotePlayer)
local DataController = require(Client.core.data.DataController)
local StoreProducts = require(Shared.constants.StoreProducts)
local UITheme = require(Client.core.ui.UITheme)
local NavTabController = require(Client.core.ui.NavTabController)
local Confetti = require(Client.core.ui.Confetti)
local ScreenFade = require(Client.core.ui.ScreenFade)
local GameSounds = require(Client.core.ui.GameSounds)
local Notify = require(Client.core.ui.NotificationController)

local LockerFeature = {}

local STROKE_DEFAULT = UITheme.StrokeDefault
local STROKE_WHITE = UITheme.StrokeHover
local PURCHASE_BUTTON_HOVER_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PURCHASE_BUTTON_CLICK_TWEEN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PURCHASE_BUTTON_DEFAULT_SCALE = 1
local PURCHASE_BUTTON_HOVER_SCALE = 1.03
local PURCHASE_BUTTON_CLICK_SCALE = 0.96
local DEFAULT_NAV_THUMBNAIL = "rbxasset://textures/ui/GuiImagePlaceholder.png"
local ACTION_FRAME_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local ACTION_ICON_LOCKED = AssetIds.Images.LockerLocked
local ACTION_ICON_PURCHASE = AssetIds.Images.LockerPurchase
-- Mismo icono de gema que el grid (LockerGrid.STATUS_ICON_GEMS): el panel de acción
-- anuncia la moneda antes de pulsar comprar.
local ACTION_ICON_PURCHASE_GEMS = AssetIds.Images.LockerStatusGems
local ACTION_BTN_COLOR_PURCHASE = Color3.fromRGB(255, 0, 127)
local ACTION_BTN_COLOR_LOCKED = Color3.fromRGB(161, 161, 161)
local SHOP_REQUEST_TIMEOUT = 5

type LockerCategoryKey = LockerMainCategory.LockerMainCategory

type LockerNavItemDefinition = {
	key: string,
	title: string,
	thumbnail: string,
}

type LockerCatalogItem = {
	qualifiedId: string,
	Category: string,
	id: string,
	Name: string,
	Price: number,
	LevelRequired: number,
	Rarity: string,
	Image: string,
	CanPurchase: boolean,
	TextureID: string?,
	BaseColor: Color3?,
	isAnimated: boolean?,
	StudsPerTile: number?,
	PreviewWeaponCategory: string?,
	PreviewWeaponId: string?,
	PreviewWeaponDisplayName: string?,
	KillGoal: number?,
	KillProgress: number?,
	ChallengeUnlocked: boolean?,
}

type PendingShopAction = {
	kind: "buy" | "equip",
	item: LockerCatalogItem,
}

type StatsData = {
	Level: number,
	Cash: number,
	Gems: number?,
}

type InventoryData = {
	[string]: { [string]: boolean },
	WeaponWrapsByWeapon: {
		Main: { [string]: { [string]: number | boolean } },
		Special: { [string]: { [string]: number | boolean } },
	}?,
}

type LoadoutData = {
	[string]: string?,
}

type WeaponCategory = WeaponCategoryMod.WeaponCategory


local LOCKER_NAV_ITEMS = LockerConfig.NavItems :: { [LockerCategoryKey]: { LockerNavItemDefinition } }
local ITEMS_CONFIG_BY_NAV = LockerConfig.ItemsConfigByNav :: { [LockerCategoryKey]: { [string]: string } }
local CATEGORY_TO_LOADOUT_SLOT = LockerConfig.CategoryToLoadoutSlot :: { [string]: string }
local RARITY_RANK = LockerConfig.RarityRank :: { [string]: number }

local WEAPONS_CAMERA_TARGET = "weapons"
local CAMERA_TARGET_BY_MAIN_CATEGORY = {
	Style = "character",
	Arsenal = WEAPONS_CAMERA_TARGET,
	Effects = "killEffects",
} :: { [LockerCategoryKey]: string }
local MAIN_CATEGORY_SWITCH_COOLDOWN = 0.2
-- Margen para que replique un nodo de la GUI. Solo se consume si el nodo NO está
-- ya (búsqueda inmediata primero).
local GUI_NODE_TIMEOUT = 5

function LockerFeature.start(menuController: any, options: { autoOpen: boolean? }?): any
	local janitor = Janitor.new()
	local fusionScope = Fusion.scoped(Fusion)
	local navItemsJanitor = Janitor.new()
	janitor:Add(function()
		Fusion.doCleanup(fusionScope)
	end, true)
	janitor:Add(navItemsJanitor, "Destroy")
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()
	local bodiesFolder = Shared:WaitForChild("Bodies") :: Folder
	local killEffectDummyTemplate = bodiesFolder:WaitForChild("KillEffectDummy") :: Model

	-- El preview de outfit/cara/hat se hace sobre el personaje del lobby
	-- (Workspace.Lobby.Spawners.P1), singleton compartido con LobbyFeature.
	local lobbyCharacter = LobbyCharacterPreview.get()

	local lockerFolder = Workspace:WaitForChild("Locker")

	-- Lighting por atributo: el look lo lleva Workspace.Locker (LightingPreset="Locker")
	-- y la vuelta usa ScenePresetController.applyLobbyOrRestore (como el BattlePass).
	local dummySpawn = lockerFolder:WaitForChild("DummySpawn")
	-- Anclas del preview de armas por ROL (mesa/pared, ver WeaponPreviewController).
	-- MainSpawn/SpecialSpawn son los nombres antiguos, aceptados como fallback.
	local function resolveWeaponAnchor(preferredName: string, legacyName: string): Instance?
		local preferred = lockerFolder:FindFirstChild(preferredName)
		if preferred then
			return preferred
		end
		local legacy = lockerFolder:FindFirstChild(legacyName)
		if not legacy then
			warn(`[Locker] Ancla de arma no encontrada: Locker.{preferredName} (ni {legacyName})`)
		end
		return legacy
	end
	local tableWeaponSpawn = resolveWeaponAnchor("TableSpawn", "MainSpawn")
	local wallWeaponSpawn = resolveWeaponAnchor("WallSpawn", "SpecialSpawn")
	-- Stats del arma: BillboardGui del mundo bajo Workspace.Locker.Stats.
	local weaponStatsAnchor = lockerFolder:WaitForChild("Stats", 10)
	-- Tarjeta de banner en el mundo (Workspace.Locker.Banner.Part.Card): solo se
	-- enciende en Effects → Banners.
	local bannerPreview = BannerPreviewer.new(lockerFolder:WaitForChild("Banner", 10))
	janitor:Add(bannerPreview, "Destroy")
	if not weaponStatsAnchor then
		warn("[Locker] Ancla del billboard de stats no encontrada: Workspace.Locker.Stats")
	end

	local container = menuGui:FindFirstChild("Container")
	local lockerBtnInstance = container and container:FindFirstChild("Locker")
	local lockerBtn: GuiButton? = if lockerBtnInstance and lockerBtnInstance:IsA("GuiButton")
		then lockerBtnInstance
		else nil
	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local lockerFrame = uiGui:WaitForChild("Locker") :: Frame

	-- Registrado como panel para que hasOpenPanel() lo cuente: MapVote (auto-hide) y
	-- el estado MUFFLED de la música del lobby dependen de ello.
	menuController:registerPanel(lockerFrame)
	janitor:Add(function()
		menuController:unregisterPanel(lockerFrame)
	end, true)
	-- La GUI del locker se reagrupa a menudo en Studio, así que cada pieza se busca
	-- por NOMBRE a cualquier profundidad, no por ruta fija. Lo que falte se reporta
	-- junto y el locker no se monta (en vez de un WaitForChild infinito).
	local missingNodes: { string } = {}
	local function expectNode(root: Instance?, name: string): Instance?
		if not root then
			return nil
		end
		-- Hijo directo primero: la búsqueda recursiva podría devolver antes un nodo
		-- anidado del mismo nombre (Template, Title, Icon…).
		local found = root:FindFirstChild(name)
			or root:FindFirstChild(name, true)
			or root:WaitForChild(name, GUI_NODE_TIMEOUT)
		if not found then
			table.insert(missingNodes, `{root.Name}.{name}`)
		end
		return found
	end

	local function hasMissingNodes(): boolean
		if #missingNodes == 0 then
			return false
		end
		warn(`[Locker] Nodos no encontrados bajo UserInterface.Locker: {table.concat(missingNodes, ", ")} — el locker no se monta.`)
		return true
	end

	local navNode = expectNode(lockerFrame, "Nav2")
	local navTemplateNode = expectNode(navNode, "Template")
	local nav1Node = expectNode(lockerFrame, "Nav1")
	local closeBtnNode = expectNode(nav1Node, "CloseBtn")
	-- Los tabs de Nav1 se clonan de Nav1.Template según el modo: normal
	-- Character/Effects/Weapons (Style/Effects/Arsenal) o wraps Maestry/Owned. El Name
	-- de cada botón clonado ES la key (nav1TabController y nav1Stagger indexan por Name).
	local nav1TemplateNode = expectNode(nav1Node, "Template")
	local itemGridNode = expectNode(lockerFrame, "ScrollingFrame")
	-- Única plantilla del grid, también en la vista de wraps (trae ViewportFrame para
	-- el preview 3D; el progreso de desafío va como texto en Status.Value).
	local itemGridTemplateNode = expectNode(itemGridNode, "ItemTemplate")
	-- Vista de banners (Effects → Banners): ScrollingFrame hermano de la grid
	-- (Locker.Content.Banners) que la sustituye mientras esa nav está activa.
	local bannersNode = expectNode(if itemGridNode then itemGridNode.Parent else nil, "Banners")
	local bannersTemplateNode = expectNode(bannersNode, "Template")
	local actionFrameNode = expectNode(lockerFrame, "ActionFrame")
	-- Botón separado del ActionFrame para personalizar los wraps del arma poseída.
	local wrapsButtonNode = expectNode(lockerFrame, "Wraps")
	-- Indicator: nº de wraps poseídos para el arma seleccionada (sin contar Default).
	local wrapsIndicatorNode = expectNode(wrapsButtonNode, "Indicator")

	if hasMissingNodes() then
		return janitor
	end

	local nav = navNode :: Instance
	local navTemplate = navTemplateNode :: GuiButton
	local defaultNavItemSize = navTemplate.Size
	local nav1 = nav1Node :: Instance
	local closeBtn = closeBtnNode :: GuiButton
	local nav1Template = nav1TemplateNode :: GuiButton
	local defaultNav1ItemSize = nav1Template.Size
	local itemGrid = itemGridNode :: ScrollingFrame
	local itemGridTemplate = itemGridTemplateNode :: GuiObject
	local bannersFrame = bannersNode :: ScrollingFrame
	local bannersTemplate = bannersTemplateNode :: ImageButton
	local wrapsButton = wrapsButtonNode :: GuiButton
	local wrapsIndicator = wrapsIndicatorNode :: TextLabel
	local function resolveActionButtonTextTarget(button: GuiButton): Instance?
		for _, name in { "Title", "Label", "Text", "Price", "Value" } do
			local child = button:FindFirstChild(name)
			if child and child:IsA("TextLabel") then
				return child
			end
		end
		if button:IsA("TextButton") then
			return button
		end
		return button:FindFirstChildWhichIsA("TextLabel", true)
	end

	-- Panel de acción (compra / bloqueo), único para todos los ítems:
	--   <Frame>.Title.Text.Title / .Subtitle  → título y subtítulo
	--   <Frame>.Title.Icon                     → icono (candado / compra)
	--   <Frame>**.ActionBtn                    → botón de acción (búsqueda recursiva)
	type ActionPanel = {
		frame: GuiObject,
		titleLabel: TextLabel,
		subtitleLabel: TextLabel,
		icon: ImageLabel,
		button: GuiButton,
		buttonTextTarget: Instance?,
		visiblePosition: UDim2,
		hiddenPosition: UDim2,
		activeTween: Tween?,
	}

	local function makeActionPanel(frame: GuiObject): ActionPanel
		local title = expectNode(frame, "Title")
		local textContainer = expectNode(title, "Text")
		local button = expectNode(frame, "ActionBtn") :: GuiButton
		-- El deslizamiento de ocultar es relativo al PADRE del ActionFrame: si en
		-- Studio se mueve dentro de otro contenedor, `1.15` deja de ser "bajo el
		-- borde de la pantalla" y pasa a ser "bajo el borde del contenedor".
		local visiblePosition = frame.Position
		return {
			frame = frame,
			titleLabel = expectNode(textContainer, "Title") :: TextLabel,
			subtitleLabel = expectNode(textContainer, "Subtitle") :: TextLabel,
			icon = expectNode(title, "Icon") :: ImageLabel,
			button = button,
			buttonTextTarget = if button then resolveActionButtonTextTarget(button) else nil,
			visiblePosition = visiblePosition,
			hiddenPosition = UDim2.new(visiblePosition.X.Scale, visiblePosition.X.Offset, 1.15, visiblePosition.Y.Offset),
			activeTween = nil,
		}
	end

	local actionPanel = makeActionPanel(actionFrameNode :: GuiObject)
	if hasMissingNodes() then
		return janitor
	end
	local isActionFrameVisible = false

	local function setPanelButtonText(panel: ActionPanel, text: string)
		if panel.buttonTextTarget then
			(panel.buttonTextTarget :: any).Text = text
		end
	end

	local cameraController = LockerCameraController.new(WEAPONS_CAMERA_TARGET)
	janitor:Add(cameraController, "Destroy")

	-- Arrastrar sobre la escena gira el personaje del preview (ratón y táctil).
	-- Solo escucha en la categoría Character (Body/Faces/Hats): lo activa y lo
	-- desactiva selectItem, y el cierre lo devuelve al frente.
	local characterRotate = CharacterRotateController.new({
		playerGui = playerGui,
		uiGui = uiGui,
		onYawChanged = function(yaw: number)
			lobbyCharacter:setYaw(yaw)
		end,
	})
	janitor:Add(characterRotate, "Destroy")
	-- Fundido a negro para los cambios de cámara entre pestañas (como el BattlePass):
	-- la cámara salta tapada en vez de cruzar la escena. Singleton por playerGui: no
	-- va al janitor.
	local fade = ScreenFade.new(playerGui)
	-- Hay un `cover` en vuelo esperando a la pantalla negra. El cierre del locker
	-- lo descubre para no dejar un parpadeo negro encima de su propia salida.
	local pendingCameraFade = false
	-- Hay un cierre esperando a la pantalla negra (salida desde Weapons).
	-- `isOpen` ya está a false, pero la escena del locker sigue montada hasta el
	-- callback: el teardown del feature debe limpiarla igualmente.
	local closeFadePending = false
	lockerFrame.Visible = false

	MenuHover.bindButton(closeBtn, janitor)

	local NAV1_MAIN_CATEGORY_ITEMS: { { key: LockerCategoryKey, title: string } } = {
		{ key = LockerMainCategory.STYLE, title = "Character" },
		{ key = LockerMainCategory.EFFECTS, title = "Effects" },
		{ key = LockerMainCategory.ARSENAL, title = "Weapons" },
	}
	-- Tabs de Nav1 en modo wraps. Las keys son las mismas que consume `wrapsView`.
	local NAV1_WRAPS_VIEW_ITEMS: { { key: string, title: string } } = {
		{ key = "owned", title = "Owned" },
		{ key = "maestry", title = "Maestry" },
	}
	local navButtons = {} :: { GuiButton }
	-- Se limpia en cada repoblación para no acumular listeners de tabs destruidos.
	local nav1ButtonsJanitor = Janitor.new()
	janitor:Add(nav1ButtonsJanitor, "Destroy")
	local selectedMainCategory: LockerCategoryKey? = nil
	local selectedCatalogItem: LockerCatalogItem? = nil
	local wrapsTargetWeaponCategory: WeaponCategory = WeaponCategoryMod.MAIN
	local wrapsTargetWeaponIdByCategory = {
		Main = "",
		Special = "",
	} :: { [WeaponCategory]: string }
	local pendingShopAction: PendingShopAction? = nil
	local activePurchaseButtonScaleTween: Tween? = nil
	local activePurchaseButtonStrokeTween: Tween? = nil
	local purchaseButtonIsHovered = false
	local canUseHoverAnimations = UserInputService.MouseEnabled and not UserInputService.TouchEnabled
	local ownedLookup = {} :: { [string]: { [string]: boolean } }
	local ownedWrapsByWeaponLookup = {
		Main = {},
		Special = {},
	} :: { [WeaponCategory]: { [string]: { [string]: number } } }
	local equippedLookup = {} :: { [string]: string }
	local selectedNavKey: string? = nil
	-- Forward decl: se construyen más abajo, pero populateNavButtons y setWrapsMode
	-- ya los re-tweenean.
	local nav1Stagger: NavStaggerController.NavStaggerController
	local nav2Stagger: NavStaggerController.NavStaggerController
	-- Forward decl: setWrapsMode las usa; se asignan cuando sus dependencias existen.
	local populateMainCategoryNav: () -> ()
	local populateWrapsViewNav: () -> ()
	local isOpen = false
	local dirtyWhileClosed = false
	local nextAllowedMainCategorySwitchAt = 0
	local sharedLockerAssets = Shared:WaitForChild("Locker")
	local sharedWeaponAssets = sharedLockerAssets:WaitForChild("weapons")
	local catalog: any = nil
	local grid: any = nil

	local isWrapsMode = false
	-- Sub-vista de la pantalla de wraps (tabs de Nav1 en modo wraps):
	--   "maestry" → desafíos de kills del arma
	--   "owned"   → wraps que posees en el inventario
	local wrapsView = "owned"

	-- Billboard en el mundo: se construye pronto porque setWrapsMode y selectItem lo
	-- ocultan. Arranca apagado.
	local weaponStatsPanel = WeaponStatsPanel.new(weaponStatsAnchor, janitor)

	-- El HUD de monedas (LobbyStats) es compartido y por defecto sigue al Menu, que
	-- el Locker esconde. Con el Locker abierto manda él: visible salvo en la vista de
	-- wraps. Al cerrarse devuelve el control al Menu (nil).
	local function syncSharedStatsHud()
		menuController:setStatsHudOverride(if isOpen then not isWrapsMode else nil)
	end

	local function setWrapsMode(enabled: boolean)
		isWrapsMode = enabled
		-- La vista de wraps zooma sobre la mesa: el billboard de stats sobra ahí.
		if enabled then
			weaponStatsPanel:hide()
		end
		syncSharedStatsHud()
		nav.Visible = not enabled
		-- Al salir, updateActionFrameForSelected lo vuelve a mostrar si toca.
		if enabled then wrapsButton.Visible = false end
		if enabled then
			populateWrapsViewNav()
		else
			populateMainCategoryNav()
		end
		nav1Stagger:play()
	end

	actionPanel.frame.Visible = false
	wrapsButton.Visible = false
	nav1Template.Visible = false
	actionPanel.frame.Position = actionPanel.hiddenPosition

	local function getOptionalString(value: any): string?
		if type(value) == "string" and value ~= "" then
			return value
		end

		return nil
	end

	local function getCurrentLoadout(): LoadoutData
		return Fusion.peek(DataController.Loadout) :: LoadoutData
	end

	local function getCurrentStats(): StatsData
		return Fusion.peek(DataController.Stats) :: StatsData
	end

	local function getCurrentLevel(): number
		return math.max(0, math.floor(tonumber(getCurrentStats().Level) or 0))
	end

	local function cancelTween(tween: Tween?): Tween?
		if tween then
			tween:Cancel()
		end

		return nil
	end

	local KILL_EFFECT_PREVIEW_COOLDOWN = 0.4

	-- El preview de kill effects se hace SOBRE el personaje del lobby (P1), al que
	-- apunta Workspace.Cameras.killEffects: al clic se oculta y en su sitio y pose
	-- aparece un doble (LobbyCharacterPreview:buildLookClone) que recibe el efecto;
	-- pasado KillEffectsRegistry.previewTime el doble se destruye. Sin preview del
	-- lobby se usa el maniquí KillEffectDummy en DummySpawn.
	local currentKillEffectDummy: Model? = nil
	local killEffectRespawnTask: thread? = nil
	local currentlyPreviewingEffectId: string? = nil
	local nextAllowedPreviewAt = 0
	-- Al entrar a la nav KillEffects el grid auto-selecciona el primer item: esta flag
	-- consume esa notificación para que el preview solo arranque por clic.
	local suppressNextKillEffectPreview = false

	local function destroyKillEffectDummy()
		if killEffectRespawnTask then
			task.cancel(killEffectRespawnTask)
			killEffectRespawnTask = nil
		end
		if currentKillEffectDummy and currentKillEffectDummy.Parent then
			currentKillEffectDummy:Destroy()
		end
		currentKillEffectDummy = nil
		currentlyPreviewingEffectId = nil
		cameraController:followSubject(nil)
		lobbyCharacter:setHiddenByOwner(false)
	end

	-- Doble del personaje del lobby (o el maniquí), listo para recibir el efecto.
	local function spawnKillEffectDummy()
		destroyKillEffectDummy()

		local clone = lobbyCharacter:buildLookClone()
		if clone then
			-- Ya viene con la pose del personaje vivo: no se recoloca ni se pasa a
			-- la pose canónica, o dejaría de coincidir con lo que se ve.
			local hrp = clone:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				hrp.Anchored = true
			end
			clone.Parent = lockerFolder
			lobbyCharacter:setHiddenByOwner(true)
		else
			clone = killEffectDummyTemplate:Clone()
			clone.Parent = lockerFolder
			LockerUtils.placePreviewCharacter(clone, dummySpawn)
			LockerUtils.snapPartsToCanonicalPose(clone)
			-- Anclar HRP para que el maniquí no caiga antes de que el efecto lo
			-- suelte (los kill effects desanclan todo en su paso final).
			local hrp = clone:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				hrp.Anchored = true
			end
		end
		currentKillEffectDummy = clone
	end

	local function previewKillEffect(effectId: string)
		if currentlyPreviewingEffectId == effectId and killEffectRespawnTask then
			return
		end
		local now = os.clock()
		if now < nextAllowedPreviewAt then
			return
		end
		nextAllowedPreviewAt = now + KILL_EFFECT_PREVIEW_COOLDOWN

		spawnKillEffectDummy()
		currentlyPreviewingEffectId = effectId
		-- La cámara sigue un poco al cuerpo si sale volando hacia arriba. Se engancha
		-- antes de aplicar el efecto para medir la subida desde la pose de reposo.
		local dummy = currentKillEffectDummy :: Model
		local followPart = dummy:FindFirstChild("LowerTorso")
			or dummy:FindFirstChild("Torso")
			or dummy:FindFirstChild("HumanoidRootPart")
		if followPart and followPart:IsA("BasePart") then
			cameraController:followSubject(followPart)
		end
		KillEffectsRegistry.apply(effectId, dummy)
		killEffectRespawnTask = task.delay(KillEffectsRegistry.previewTime(effectId), function()
			killEffectRespawnTask = nil
			destroyKillEffectDummy()
		end)
	end

	janitor:Add(destroyKillEffectDummy, true)

	-- Emotes: se previsualizan sobre el mismo dummy que los kill effects. Si el
	-- dummy está a medio kill effect (o no existe), se respawnea antes.
	local function previewEmote(emoteId: string)
		if not currentKillEffectDummy or killEffectRespawnTask then
			spawnKillEffectDummy()
		end
		EmotePlayer.play(currentKillEffectDummy :: Model, emoteId)
	end

	local function applyEquippedFacePreview()
		lobbyCharacter:applyFaceId(getOptionalString(equippedLookup.Faces) or getCurrentLoadout().Face)
	end

	local function applyEquippedHatPreview()
		lobbyCharacter:applyHatId(getOptionalString(equippedLookup.Hats) or getCurrentLoadout().Hat)
	end

	local function applySelectedFacePreview(item: LockerCatalogItem?)
		if item and item.Category == LockerCategory.FACES then
			lobbyCharacter:applyFaceImage(item.Image)
			return
		end

		applyEquippedFacePreview()
	end

	local function applySelectedHatPreview(item: LockerCatalogItem?)
		if item and item.Category == LockerCategory.HATS then
			-- Hat bloqueado por nivel: contorno de bloqueo (sin billboard, solo es del body).
			local lockedLevel: number? = if getCurrentLevel() < item.LevelRequired
				then item.LevelRequired
				else nil
			lobbyCharacter:applyHatItem(item, lockedLevel)
			return
		end

		applyEquippedHatPreview()
	end

	-- El body reconstruye el modelo entero (solo si el outfit cambió) y recrea los
	-- appliers: los applySelectedFace/HatPreview posteriores ya ven los nuevos.
	local function applyEquippedBodyPreview()
		lobbyCharacter:applyOutfit(getOptionalString(equippedLookup.Outfits) or getCurrentLoadout().Outfit)
	end

	local function applySelectedBodyPreview(item: LockerCatalogItem?)
		local targetOutfitId: string?
		-- Nivel requerido solo cuando el body seleccionado está bloqueado: el preview
		-- lo marca con el contorno de bloqueo + el billboard LevelLock.
		local lockedLevel: number?
		if item and item.Category == LockerCategory.OUTFITS then
			targetOutfitId = item.id
			if getCurrentLevel() < item.LevelRequired then
				lockedLevel = item.LevelRequired
			end
		else
			targetOutfitId = getOptionalString(equippedLookup.Outfits) or getCurrentLoadout().Outfit
		end
		lobbyCharacter:applyOutfit(targetOutfitId, lockedLevel)
	end

	-- WeaponPreviewController se inicializa después de las funciones que necesita como dependencia.
	local weaponPreviewController: any = nil

	janitor:Add(function()
		actionPanel.activeTween = cancelTween(actionPanel.activeTween)
		activePurchaseButtonScaleTween = cancelTween(activePurchaseButtonScaleTween)
		activePurchaseButtonStrokeTween = cancelTween(activePurchaseButtonStrokeTween)
	end, true)

	local function rebuildOwnedLookup()
		local inventory = Fusion.peek(DataController.Inventory) :: InventoryData
		local nextLookup = {} :: { [string]: { [string]: boolean } }
		local nextWrapsByWeapon = {
			Main = {},
			Special = {},
		} :: { [WeaponCategory]: { [string]: { [string]: number } } }

		for category, items in inventory do
			if category == "WeaponWrapsByWeapon" then
				local wrapsByWeapon = items :: any
				for weaponCategory, weaponEntriesAny in wrapsByWeapon do
					if WeaponCategoryMod.isValid(weaponCategory) then
						local weaponEntries = weaponEntriesAny :: { [string]: { [string]: number | boolean } }
						local categoryWrapLookup = nextWrapsByWeapon[weaponCategory :: WeaponCategory]
						for weaponId, ownedWrapsAny in weaponEntries do
							if type(ownedWrapsAny) == "table" then
								local wrapLookup = {} :: { [string]: number }
								for wrapId, wrapOwned in ownedWrapsAny do
									if wrapOwned == true then
										wrapLookup[wrapId] = 1
									elseif type(wrapOwned) == "number" and wrapOwned > 0 then
										wrapLookup[wrapId] = math.max(1, math.floor(wrapOwned))
									end
								end
								categoryWrapLookup[weaponId] = wrapLookup
							end
						end
					end
				end
			elseif category ~= LockerCategory.WEAPON_WRAPS then
				local categoryLookup = {} :: { [string]: boolean }
				for itemId, owned in items do
					if owned == true then
						categoryLookup[itemId] = true
					end
				end
				nextLookup[category] = categoryLookup
			end
		end

		ownedLookup = nextLookup
		ownedWrapsByWeaponLookup = nextWrapsByWeapon
		if catalog then
			catalog:InvalidateSorted()
		end
	end

	local function getStoredWrapsTargetWeaponId(weaponCategory: WeaponCategory): string?
		return getOptionalString(wrapsTargetWeaponIdByCategory[weaponCategory])
	end

	local function setStoredWrapsTargetWeaponId(weaponCategory: WeaponCategory, weaponId: string?)
		wrapsTargetWeaponIdByCategory[weaponCategory] = getOptionalString(weaponId) or ""
	end

	local function resolveWeaponIdForCategory(weaponCategory: WeaponCategory, loadout: LoadoutData?): string
		local storedWeaponId = getStoredWrapsTargetWeaponId(weaponCategory)
		if storedWeaponId then
			return storedWeaponId
		end

		if loadout then
			local weaponSlot = CATEGORY_TO_LOADOUT_SLOT[weaponCategory]
			local weaponId = if weaponSlot then getOptionalString(loadout[weaponSlot]) else nil
			if weaponId then
				return weaponId
			end
		end

		return ItemDefaults.ITEM_ID
	end

	local function resolveWrapsTargetWeaponId(loadout: LoadoutData?): string
		return resolveWeaponIdForCategory(wrapsTargetWeaponCategory, loadout)
	end

	local function getWeaponWrapRequestContext(category: string): (string, string)
		if category ~= LockerCategory.WEAPON_WRAPS then
			return "", ""
		end

		return wrapsTargetWeaponCategory, resolveWrapsTargetWeaponId(getCurrentLoadout())
	end

	local getWrapAmountForWeapon: (weaponCategory: WeaponCategory, weaponId: string, wrapId: string) -> number

	local function isWrapOwnedForWeapon(weaponCategory: WeaponCategory, weaponId: string, wrapId: string): boolean
		return getWrapAmountForWeapon(weaponCategory, weaponId, wrapId) > 0
	end

	function getWrapAmountForWeapon(weaponCategory: WeaponCategory, weaponId: string, wrapId: string): number
		local categoryLookup = ownedWrapsByWeaponLookup[weaponCategory]
		if not categoryLookup then
			return 0
		end

		local weaponLookup = categoryLookup[weaponId]
		if not weaponLookup then
			return 0
		end

		return weaponLookup[wrapId] or 0
	end

	-- Cuenta los wraps poseídos para un arma, SIN contar el Default.
	local function countOwnedWrapsForWeapon(weaponCategory: WeaponCategory, weaponId: string): number
		local categoryLookup = ownedWrapsByWeaponLookup[weaponCategory]
		local weaponLookup = categoryLookup and categoryLookup[weaponId]
		if not weaponLookup then
			return 0
		end
		local count = 0
		for wrapId, amount in weaponLookup do
			if wrapId ~= ItemDefaults.ITEM_ID and (tonumber(amount) or 0) > 0 then
				count += 1
			end
		end
		return count
	end

	local function rebuildEquippedLookup()
		local loadout = getCurrentLoadout()
		local nextLookup = {} :: { [string]: string }

		for category, slot in CATEGORY_TO_LOADOUT_SLOT do
			local equippedItem = getOptionalString(loadout[slot])
			if equippedItem then
				nextLookup[category] = equippedItem
			end
		end

		equippedLookup = nextLookup
	end

	local function getEquippedItemByCategory(category: string): string?
		local equippedItem = getOptionalString(equippedLookup[category])
		if equippedItem then
			return equippedItem
		end

		local slot = CATEGORY_TO_LOADOUT_SLOT[category]
		if not slot then
			return nil
		end

		return getOptionalString(getCurrentLoadout()[slot])
	end

	local function getEquippedWeaponByCategory(category: WeaponCategory): string
		return getEquippedItemByCategory(category) or ItemDefaults.ITEM_ID
	end

	-- Mirror de LoadoutService._resolveWeaponWrapForLoadout y del preview controller:
	-- equip per-weapon; `wrapsTable.Default` es la slot del arma "Default", no un
	-- fallback. Un wrap global del BP da ownership a todas, pero se equipa por arma.
	local function resolveWeaponWrap(loadout: LoadoutData, weaponCategory: WeaponCategory, weaponId: string?): string
		local normalizedWeaponId = getOptionalString(weaponId) or ItemDefaults.ITEM_ID
		local wrapsTableKey = if weaponCategory == WeaponCategoryMod.MAIN then "MainWeaponWraps" else "SpecialWeaponWraps"
		local wrapsTableAny = loadout[wrapsTableKey]
		if type(wrapsTableAny) == "table" then
			local wrapsTable = wrapsTableAny :: { [string]: string }
			local resolvedByWeapon = getOptionalString(wrapsTable[normalizedWeaponId])
			if resolvedByWeapon and isWrapOwnedForWeapon(weaponCategory, normalizedWeaponId, resolvedByWeapon) then
				return resolvedByWeapon
			end
		end

		return ItemDefaults.ITEM_ID
	end

	local function isWeaponCategory(category: string): boolean
		return WeaponCategoryMod.isValid(category)
	end

	weaponPreviewController = WeaponPreviewController.new({
		tableSpawn = tableWeaponSpawn :: any,
		wallSpawn = wallWeaponSpawn :: any,
		sharedWeaponAssets = sharedWeaponAssets,
		itemsConfig = ItemsConfig,
		getCurrentLevel = getCurrentLevel,
		getCurrentLoadout = getCurrentLoadout,
		getEquippedItemByCategory = getEquippedItemByCategory,
		isOwned = function(category: string, itemId: string): boolean
			local categoryLookup = ownedLookup[category]
			return categoryLookup ~= nil and categoryLookup[itemId] == true
		end,
		ownsWeaponWrap = isWrapOwnedForWeapon,
		uiGui = uiGui,
	})
	janitor:Add(weaponPreviewController, "Destroy")

	local function updateWeaponFocusCategory()
		weaponPreviewController:updateFocusCategory(selectedMainCategory, selectedNavKey, wrapsTargetWeaponCategory)
	end

	local function applySelectedWeaponPreview(item: any)
		weaponPreviewController:applySelected(item)
	end

	local function restoreEquippedWeaponPreviews()
		weaponPreviewController:restoreEquipped()
	end

	local function restoreEquippedWeaponPreviewForCategory(category: string)
		weaponPreviewController:restoreEquippedFor(category)
	end

	-- Estado activo de Nav1: los botones son dinámicos y se registran en populateNav1.
	local nav1TabController = NavTabController.new()
	local navItemController = NavTabController.new()
	janitor:Add(nav1TabController, "Destroy")
	janitor:Add(navItemController, "Destroy")

	local function clearNavButtons()
		navItemsJanitor:Cleanup()
		table.clear(navButtons)
		navItemController:clear()

		for _, child in nav:GetChildren() do
			if child ~= navTemplate and child:IsA("GuiButton") then
				child:Destroy()
			end
		end
	end

	local function getButtonStroke(button: GuiButton): UIStroke?
		return button:FindFirstChildOfClass("UIStroke")
	end

	local function setSelectedNavButton(selectedButton: GuiButton)
		navItemController:setActive(selectedButton.Name)
	end

	local function setSelectedMainCategory(categoryKey: LockerCategoryKey)
		selectedMainCategory = categoryKey
		updateWeaponFocusCategory()
		nav1TabController:setActive(categoryKey)
	end

	local function bindStrokeHover(button: GuiButton, parentJanitor: any)
		if not canUseHoverAnimations then
			return
		end

		parentJanitor:Add(button.MouseEnter:Connect(function()
			local stroke = getButtonStroke(button)
			if stroke then
				stroke.Color = STROKE_WHITE
			end
		end), "Disconnect")

		parentJanitor:Add(button.MouseLeave:Connect(function()
			local stroke = getButtonStroke(button)
			if stroke then
				stroke.Color = STROKE_DEFAULT
			end
		end), "Disconnect")
	end

	type Nav1TabDefinition = {
		key: string,
		title: string,
		onActivated: () -> (),
	}

	-- Reconstruye los tabs de Nav1 clonando Nav1.Template (que solo tiene un hijo
	-- Title, sin Icon). `selectedKey` marca el tab activo (nil = ninguno).
	local function populateNav1(definitions: { Nav1TabDefinition }, selectedKey: string?)
		nav1ButtonsJanitor:Cleanup()
		nav1TabController:clear()
		for _, child in nav1:GetChildren() do
			if child:IsA("GuiButton") and child ~= nav1Template and child ~= closeBtn then
				child:Destroy()
			end
		end

		for layoutOrder, definition in ipairs(definitions) do
			local button = nav1Template:Clone()
			button.Name = definition.key
			button.Visible = true
			button.LayoutOrder = layoutOrder
			button.Size = defaultNav1ItemSize
			local titleNode = button:FindFirstChild("Title")
			if titleNode and titleNode:IsA("TextLabel") then
				titleNode.Text = definition.title
			end
			button.Parent = nav1
			nav1TabController:register(definition.key, button)

			local stroke = getButtonStroke(button)
			if stroke then
				stroke.Color = STROKE_DEFAULT
			end
			bindStrokeHover(button, nav1ButtonsJanitor)

			local onActivated = definition.onActivated
			nav1ButtonsJanitor:Add(button.Activated:Connect(onActivated), "Disconnect")
		end

		if selectedKey then
			nav1TabController:setActive(selectedKey)
		end
	end

	local function setNavButtonContent(button: GuiButton, definition: LockerNavItemDefinition)
		local iconNode = button:FindFirstChild("Icon")
		if iconNode and (iconNode:IsA("ImageLabel") or iconNode:IsA("ImageButton")) then
			iconNode.Image = definition.thumbnail
		end

		local titleNode = button:FindFirstChild("Title")
		if titleNode and titleNode:IsA("TextLabel") then
			titleNode.Text = definition.title
		end
	end

	local function tweenPanel(panel: ActionPanel, visible: boolean)
		if panel.activeTween then
			panel.activeTween:Cancel()
			panel.activeTween = nil
		end

		if visible then
			panel.frame.Visible = true
		end

		local target = if visible then panel.visiblePosition else panel.hiddenPosition
		local tween = TweenService:Create(panel.frame, ACTION_FRAME_TWEEN_INFO, { Position = target })
		panel.activeTween = tween
		tween.Completed:Once(function()
			if panel.activeTween == tween then
				panel.activeTween = nil
				if not visible then
					panel.frame.Visible = false
				end
			end
		end)
		tween:Play()
	end

	local function showActionFrameForItem(item: LockerCatalogItem)
		local panel = actionPanel
		local isLevelLocked = getCurrentLevel() < item.LevelRequired

		if isLevelLocked then
			panel.titleLabel.Text = "THIS ITEM IS LOCKED"
			panel.subtitleLabel.Text = string.format("Reach level %d to unlock this item.", item.LevelRequired)
			panel.icon.Image = ACTION_ICON_LOCKED
			setPanelButtonText(panel, "LOCKED")
			panel.button.BackgroundColor3 = ACTION_BTN_COLOR_LOCKED
		else
			panel.titleLabel.Text = item.Name
			panel.subtitleLabel.Text = item.Rarity
			panel.icon.Image = if CurrencyMod.resolve(item.Currency) == CurrencyMod.GEMS
				then ACTION_ICON_PURCHASE_GEMS
				else ACTION_ICON_PURCHASE
			setPanelButtonText(panel, UIUtils.formatCashAmount(item.Price))
			panel.button.BackgroundColor3 = ACTION_BTN_COLOR_PURCHASE
		end

		panel.button.Active = not isLevelLocked
		panel.button.Selectable = not isLevelLocked

		isActionFrameVisible = true
		tweenPanel(panel, true)
	end

	local function hideActionFrame()
		if isActionFrameVisible then
			isActionFrameVisible = false
			tweenPanel(actionPanel, false)
		end
	end

	local function isItemOwned(item: LockerCatalogItem): boolean
		if item.Category == LockerCategory.WEAPON_WRAPS then
			local targetWeaponId = resolveWrapsTargetWeaponId(getCurrentLoadout())
			return isWrapOwnedForWeapon(wrapsTargetWeaponCategory, targetWeaponId, item.id)
		end

		local categoryLookup = ownedLookup[item.Category]
		return categoryLookup ~= nil and categoryLookup[item.id] == true
	end

	local function getRarityRank(rarity: string): number
		return RARITY_RANK[rarity] or 0
	end

	local function isItemEquipped(item: LockerCatalogItem): boolean
		if pendingShopAction and pendingShopAction.kind == "equip" then
			if pendingShopAction.item.Category == item.Category then
				return pendingShopAction.item.qualifiedId == item.qualifiedId
			end
		end

		if item.Category == LockerCategory.WEAPON_WRAPS then
			local loadout = getCurrentLoadout()
			local targetWeaponId = resolveWrapsTargetWeaponId(loadout)
			local equippedWrap = resolveWeaponWrap(loadout, wrapsTargetWeaponCategory, targetWeaponId)
			return equippedWrap == item.id
		end

		local equippedItem = getEquippedItemByCategory(item.Category)
		return equippedItem == item.id
	end

	-- Stats del arma: se derivan en local de Shared (WeaponDisplayStats), sin red, y
	-- comparan la SELECCIONADA contra la EQUIPADA de su categoría.

	type WeaponBaseStats = WeaponDisplayStats.WeaponDisplayStats
	type DisplayStats = {
		damage: number,
		fireRate: number,
		reload: number,
		ammo: number,
		damageFill: number,
		fireRateFill: number,
		reloadFill: number,
		ammoFill: number,
	}
	-- Arma seleccionada ("" si ninguna).
	local statsSelectedCategory = ""
	local statsSelectedId = ""
	-- Token del debounce: invalida renders pendientes al cambiar de selección.
	local statsRenderToken = 0

	-- Fills 0..1 normalizados contra los rangos del arsenal. Reload invertido: más
	-- fill = recarga más rápida.
	local function displayStatsFor(base: WeaponBaseStats): DisplayStats
		local damage = base.damage
		local ammo = base.ammoCapacity
		local fireRate = base.fireRate
		local reload = base.reloadTime
		return {
			damage = damage,
			fireRate = fireRate,
			reload = reload,
			ammo = ammo,
			damageFill = if base.damageMax > 0 then damage / base.damageMax else 0,
			fireRateFill = if base.fireRateMax > 0 then fireRate / base.fireRateMax else 0,
			reloadFill = if reload > 0 then base.reloadMin / reload else 1,
			ammoFill = if base.ammoMax > 0 then ammo / base.ammoMax else 0,
		}
	end

	-- Los fills ya codifican dirección: más fill = mejor en todos los stats.
	local function dirFromFill(selFill: number, eqFill: number): string
		if selFill > eqFill + 1e-3 then
			return "up"
		elseif selFill < eqFill - 1e-3 then
			return "down"
		end
		return "equal"
	end

	local function buildStatsModel(sel: DisplayStats, eq: DisplayStats): WeaponStatsPanel.StatsModel
		return {
			Damage = {
				value = sel.damage,
				fill = sel.damageFill,
				compareFill = eq.damageFill,
				delta = sel.damage - eq.damage,
				dir = dirFromFill(sel.damageFill, eq.damageFill),
			},
			FireRate = {
				value = sel.fireRate,
				fill = sel.fireRateFill,
				compareFill = eq.fireRateFill,
				delta = sel.fireRate - eq.fireRate,
				dir = dirFromFill(sel.fireRateFill, eq.fireRateFill),
			},
			Reload = {
				value = sel.reload,
				fill = sel.reloadFill,
				compareFill = eq.reloadFill,
				delta = sel.reload - eq.reload,
				dir = dirFromFill(sel.reloadFill, eq.reloadFill),
			},
			Ammo = {
				value = sel.ammo,
				fill = sel.ammoFill,
				compareFill = eq.ammoFill,
				delta = sel.ammo - eq.ammo,
				dir = dirFromFill(sel.ammoFill, eq.ammoFill),
			},
		}
	end

	-- Solo en la cámara de armas (Arsenal); oculto en Character/Effects y en la vista
	-- de wraps (que zooma sobre la mesa).
	local function isWeaponPreviewContext(): boolean
		return isOpen and not isWrapsMode and selectedMainCategory == LockerMainCategory.ARSENAL
	end

	local function tryRenderStats()
		local category = statsSelectedCategory
		local selId = statsSelectedId
		if category == "" or selId == "" then
			return
		end

		if not isWeaponPreviewContext() then
			weaponStatsPanel:hide()
			return
		end

		local selBase = WeaponDisplayStats.Get(category, selId)
		local eqId = getEquippedWeaponByCategory(category :: WeaponCategory)
		local eqBase = WeaponDisplayStats.Get(category, eqId)

		weaponStatsPanel:setStats(buildStatsModel(displayStatsFor(selBase), displayStatsFor(eqBase)))
	end

	-- Debounce: al scrollear solo se renderiza el arma donde uno se detiene.
	local function requestWeaponStatsForItem(item: LockerCatalogItem?)
		if not item or not isWeaponCategory(item.Category) or not isWeaponPreviewContext() then
			statsSelectedCategory = ""
			statsSelectedId = ""
			weaponStatsPanel:hide()
			return
		end

		statsSelectedCategory = item.Category
		statsSelectedId = item.id

		statsRenderToken += 1
		local myToken = statsRenderToken
		task.delay(0.06, function()
			if myToken ~= statsRenderToken then
				return
			end
			tryRenderStats()
		end)
	end

	catalog = LockerCatalog.new(ItemsConfig, ITEMS_CONFIG_BY_NAV, DEFAULT_NAV_THUMBNAIL, getRarityRank, isItemOwned)
	local updateActionFrameForSelected: () -> ()
	local populateMainContentForNavItem: (LockerCategoryKey, string, string?, boolean?) -> ()
	local clearItemGrid: () -> ()
	local syncWeaponPreviewsFromLoadout: () -> ()
	local bannersView: any = nil

	-- Banner que se da por equipado: con un equip en vuelo ya es el pulsado (como
	-- la grid); un perfil sin Loadout.Banner lleva el Default.
	local function getShownBannerId(): string
		if pendingShopAction and pendingShopAction.kind == "equip" and pendingShopAction.item.Category == LockerCategory.BANNERS then
			return pendingShopAction.item.id
		end
		return getEquippedItemByCategory(LockerCategory.BANNERS) or ItemDefaults.ITEM_ID
	end

	local function refreshBanners()
		if not bannersView:IsVisible() then
			return
		end
		bannersView:Refresh()
		bannerPreview:setContent(player.Name, getCurrentLevel(), getShownBannerId())
	end

	local function refreshEquipVisuals()
		grid:RefreshVisibleState(false)
		refreshBanners()
	end

	local function requestEquip(item: LockerCatalogItem)
		local weaponCategoryForEquip, weaponIdForEquip = getWeaponWrapRequestContext(item.Category)

		local equipAction = {
			kind = "equip",
			item = item,
		}
		pendingShopAction = equipAction
		refreshEquipVisuals()
		task.delay(SHOP_REQUEST_TIMEOUT, function()
			if pendingShopAction == equipAction then
				pendingShopAction = nil
				refreshEquipVisuals()
			end
		end)
		Network.Shop.EquipItem.Send({
			category = item.Category,
			itemId = item.id,
			weaponCategory = weaponCategoryForEquip,
			weaponId = weaponIdForEquip,
		})
	end

	grid = LockerGrid.new(itemGrid, { default = itemGridTemplate, wraps = itemGridTemplate }, canUseHoverAnimations, {
		canInteract = function(): boolean
			return pendingShopAction == nil
		end,
		isItemOwned = isItemOwned,
		isItemEquipped = isItemEquipped,
		getCurrentLevel = getCurrentLevel,
		onSelectionChanged = function(item: LockerCatalogItem?)
			selectedCatalogItem = item
			if item and isWeaponCategory(item.Category) then
				local selectedWeaponCategory = item.Category :: WeaponCategory
				wrapsTargetWeaponCategory = selectedWeaponCategory
				setStoredWrapsTargetWeaponId(selectedWeaponCategory, item.id)
				updateWeaponFocusCategory()
			end
			applySelectedBodyPreview(item)
			applySelectedFacePreview(item)
			applySelectedHatPreview(item)
			applySelectedWeaponPreview(item)
			requestWeaponStatsForItem(item)
			if item and item.Category == LockerCategory.KILL_EFFECTS then
				if suppressNextKillEffectPreview then
					suppressNextKillEffectPreview = false
				else
					previewKillEffect(item.id)
				end
			elseif item and item.Category == LockerCategory.EMOTES then
				previewEmote(item.id)
			end
			updateActionFrameForSelected()
		end,
		onOwnedItemActivated = function(item: LockerCatalogItem)
			requestEquip(item)
		end,
	})
	janitor:Add(grid, "Destroy")

	bannersView = LockerBanners.new(bannersFrame, bannersTemplate, itemGrid, {
		canInteract = function(): boolean
			return pendingShopAction == nil
		end,
		isItemEquipped = function(item: LockerCatalogItem): boolean
			return getShownBannerId() == item.id
		end,
		onActivated = function(item: LockerCatalogItem)
			requestEquip(item)
		end,
	})
	janitor:Add(bannersView, "Destroy")

	-- Banners poseídos, Default primero y luego por rareza. Los del pase ya llegan
	-- filtrados por el catálogo; el filtro de posesión cubre los no comprables.
	local function getBannerItems(): { LockerCatalogItem }
		local items = {} :: { LockerCatalogItem }
		for _, item in catalog:GetItems(LockerMainCategory.EFFECTS, LockerCategory.BANNERS) do
			if item.id == ItemDefaults.ITEM_ID or isItemOwned(item) then
				table.insert(items, item)
			end
		end
		table.sort(items, function(a, b)
			local aDefault = a.id == ItemDefaults.ITEM_ID
			local bDefault = b.id == ItemDefaults.ITEM_ID
			if aDefault ~= bDefault then
				return aDefault
			end
			local rarityA = getRarityRank(a.Rarity)
			local rarityB = getRarityRank(b.Rarity)
			if rarityA ~= rarityB then
				return rarityA > rarityB
			end
			return a.Name < b.Name
		end)
		return items
	end

	-- La grid de ítems y la de banners ocupan el mismo hueco. Con la tarjeta de banner
	-- en escena el personaje del lobby se oculta, y solo se muestra al SALIR de
	-- banners (el preview de kill effects también lo oculta mientras corre su doble).
	local function setBannersViewActive(active: boolean, stagger: boolean?)
		itemGrid.Visible = not active
		if active then
			bannerPreview:setVisible(true)
			lobbyCharacter:setHiddenByOwner(true)
			bannersView:Show(getBannerItems(), stagger)
			refreshBanners()
		elseif bannersView:IsVisible() then
			bannersView:Hide()
			bannerPreview:setVisible(false)
			lobbyCharacter:setHiddenByOwner(false)
		end
	end

	local function getPreferredSelectedQualifiedId(categoryKey: LockerCategoryKey, navKey: string, selectedQualifiedId: string?): string?
		if selectedQualifiedId ~= nil then
			return selectedQualifiedId
		end

		-- El nav del body se llama "Body" pero su categoría es "Outfits" (única
		-- traducción no-identidad nav→categoría, ver LockerConfig.ItemsConfigByNav):
		-- hay que comparar contra el NAV key.
		if categoryKey == LockerMainCategory.STYLE and navKey == "Body" then
			local equippedOutfit = getOptionalString(equippedLookup.Outfits) or getOptionalString(getCurrentLoadout().Outfit)
			if equippedOutfit then
				return LockerConfig.makeQualifiedId(LockerCategory.OUTFITS, equippedOutfit)
			end
		end

		if categoryKey == LockerMainCategory.STYLE and navKey == LockerCategory.FACES then
			local equippedFace = getOptionalString(equippedLookup.Faces) or getOptionalString(getCurrentLoadout().Face)
			if equippedFace then
				return LockerConfig.makeQualifiedId(LockerCategory.FACES, equippedFace)
			end
		end

		if categoryKey == LockerMainCategory.EFFECTS and navKey == LockerCategory.EMOTES then
			local equippedEmote = getOptionalString(equippedLookup.Emotes) or getOptionalString(getCurrentLoadout().Emote)
			if equippedEmote then
				return LockerConfig.makeQualifiedId(LockerCategory.EMOTES, equippedEmote)
			end
		end

		if categoryKey == LockerMainCategory.ARSENAL and isWeaponCategory(navKey) then
			local weaponCategory = navKey :: WeaponCategory
			local equippedWeapon = getEquippedWeaponByCategory(weaponCategory)
			wrapsTargetWeaponCategory = weaponCategory
			setStoredWrapsTargetWeaponId(weaponCategory, equippedWeapon)
			updateWeaponFocusCategory()
			return LockerConfig.makeQualifiedId(weaponCategory, equippedWeapon)
		end

		if categoryKey == LockerMainCategory.ARSENAL and navKey == LockerCategory.WEAPON_WRAPS then
			local loadout = getCurrentLoadout()
			local weaponId = resolveWrapsTargetWeaponId(loadout)
			return LockerConfig.makeQualifiedId(LockerCategory.WEAPON_WRAPS, resolveWeaponWrap(loadout, wrapsTargetWeaponCategory, weaponId))
		end

		return nil
	end

	local function getKillProgressForWeaponWrap(weaponCategory: WeaponCategory, weaponId: string): number
		local weaponKills = Fusion.peek(DataController.WeaponKills) :: any
		if type(weaponKills) ~= "table" then
			return 0
		end
		local categoryKills = weaponKills[weaponCategory]
		if type(categoryKills) ~= "table" then
			return 0
		end
		local value = tonumber(categoryKills[weaponId])
		return if value and value > 0 then math.floor(value) else 0
	end

	local function getWrapItemsForCurrentWeapon(items: { LockerCatalogItem }): { LockerCatalogItem }
		local loadout = getCurrentLoadout()
		local targetWeaponId = resolveWrapsTargetWeaponId(loadout)
		local targetWeaponCategory = wrapsTargetWeaponCategory
		local targetCategoryConfig = ItemsConfig[targetWeaponCategory]
		local targetWeaponDefinition = if type(targetCategoryConfig) == "table"
			then targetCategoryConfig[targetWeaponId]
			else nil
		local targetWeaponDisplayName = if type(targetWeaponDefinition) == "table"
			and type(targetWeaponDefinition.Name) == "string"
			and targetWeaponDefinition.Name ~= ""
			then targetWeaponDefinition.Name
			else targetWeaponId
		local wrapItems = {} :: { LockerCatalogItem }

		for _, item in items do
			local isOwned = isWrapOwnedForWeapon(targetWeaponCategory, targetWeaponId, item.id)
			local isChallenge = item.KillGoal ~= nil and item.KillGoal > 0
			local include: boolean
			if wrapsView == "maestry" then
				include = isChallenge
			else -- "owned"
				include = isOwned
			end
			if include then
				local wrapItem = table.clone(item)
				wrapItem.PreviewWeaponCategory = targetWeaponCategory
				wrapItem.PreviewWeaponId = targetWeaponId
				wrapItem.PreviewWeaponDisplayName = targetWeaponDisplayName
				if isChallenge and not isOwned then
					wrapItem.KillProgress = getKillProgressForWeaponWrap(targetWeaponCategory, targetWeaponId)
				elseif isChallenge and isOwned then
					wrapItem.ChallengeUnlocked = true
				end
				table.insert(wrapItems, wrapItem)
			end
		end

		-- Orden dentro de la vista Wraps:
		--   1) Default (siempre primero; sólo aparece en Owned)
		--   2) Challenges de kill no desbloqueados (Maestry) por kills ascendente
		--   3) Resto (poseídos) por RAREZA descendente
		local function groupRank(it: LockerCatalogItem): number
			if it.id == ItemDefaults.ITEM_ID then
				return 1
			end
			local isOwned = isWrapOwnedForWeapon(targetWeaponCategory, targetWeaponId, it.id)
			local isChallenge = it.KillGoal ~= nil and it.KillGoal > 0
			if isChallenge and not isOwned then
				return 2
			end
			return 3
		end

		table.sort(wrapItems, function(a, b)
			local groupA = groupRank(a)
			local groupB = groupRank(b)
			if groupA ~= groupB then
				return groupA < groupB
			end

			if groupA == 3 then
				local rarityA = getRarityRank(a.Rarity)
				local rarityB = getRarityRank(b.Rarity)
				if rarityA ~= rarityB then
					return rarityA > rarityB
				end
			end

			if a.KillGoal ~= nil and b.KillGoal ~= nil and a.KillGoal ~= b.KillGoal then
				return a.KillGoal < b.KillGoal
			end

			return a.Name < b.Name
		end)

		return wrapItems
	end

	-- `stagger`: la repoblación viene de una interacción de usuario y las cards entran
	-- en orden. Los observers de inventario/loadout no lo pasan, para no re-animar al
	-- comprar/equipar.
	populateMainContentForNavItem = function(categoryKey: LockerCategoryKey, navKey: string, selectedQualifiedId: string?, stagger: boolean?)
		local previousNavKey = selectedNavKey
		selectedNavKey = navKey
		updateWeaponFocusCategory()
		if categoryKey ~= LockerMainCategory.ARSENAL or previousNavKey ~= navKey then
			restoreEquippedWeaponPreviews()
		end

		if categoryKey == LockerMainCategory.EFFECTS and navKey == LockerCategory.BANNERS then
			-- Sin selección en la grid: vuelven los previews de lo equipado y se
			-- ocultan ActionFrame y botón Wraps (onSelectionChanged(nil)).
			clearItemGrid()
			setBannersViewActive(true, stagger)
			return
		end
		-- Antes de crear el doble de emotes: salir de banners vuelve a mostrar el
		-- personaje del lobby, y si el doble ya estaba creado quedaban los dos.
		setBannersViewActive(false)

		if navKey == LockerCategory.KILL_EFFECTS and previousNavKey ~= LockerCategory.KILL_EFFECTS then
			-- En reposo el preview es el propio personaje del lobby: solo asegurar que
			-- no queda un doble de antes.
			destroyKillEffectDummy()
			suppressNextKillEffectPreview = true
		elseif navKey == LockerCategory.EMOTES and previousNavKey ~= LockerCategory.EMOTES then
			spawnKillEffectDummy()
		end

		local preferredSelectedQualifiedId = getPreferredSelectedQualifiedId(categoryKey, navKey, selectedQualifiedId)

		local items = catalog:GetItems(categoryKey, navKey)
		local isWrapsView = categoryKey == LockerMainCategory.ARSENAL and navKey == LockerCategory.WEAPON_WRAPS
		if isWrapsView then
			items = getWrapItemsForCurrentWeapon(items)
		end

		grid:Populate(items, preferredSelectedQualifiedId, if isWrapsView then "wraps" else "default")
		if stagger then
			grid:PlayStagger()
		end
	end

	updateActionFrameForSelected = function()
		local selectedItem = selectedCatalogItem
		if not selectedItem then
			wrapsButton.Visible = false
			hideActionFrame()
			return
		end

		if isItemOwned(selectedItem) then
			-- Arma poseída: sin ActionFrame, con botón Wraps. Otros items poseídos: nada.
			local showWraps = isWeaponCategory(selectedItem.Category) and not isWrapsMode
			wrapsButton.Visible = showWraps
			if showWraps then
				local ownedWrapsCount = countOwnedWrapsForWeapon(selectedItem.Category :: WeaponCategory, selectedItem.id)
				wrapsIndicator.Visible = ownedWrapsCount > 0
				if ownedWrapsCount > 0 then
					wrapsIndicator.Text = tostring(ownedWrapsCount)
				end
			end
			hideActionFrame()
		elseif (selectedItem.KillGoal ~= nil and selectedItem.KillGoal > 0)
			or (selectedItem.Category == LockerCategory.WEAPON_WRAPS
				and not (selectedItem.CanPurchase and selectedItem.Price > 0)) then
			-- No comprables con cash: wraps de desafío (se desbloquean por progreso) y
			-- wraps sin precio.
			wrapsButton.Visible = false
			hideActionFrame()
		else
			wrapsButton.Visible = false
			showActionFrameForItem(selectedItem)
		end
	end

	local function refreshGridSelectionState()
		grid:RefreshVisibleState()
		refreshBanners()
	end

	syncWeaponPreviewsFromLoadout = function()
		local selectedItem = selectedCatalogItem
		if not selectedItem or not isWeaponCategory(selectedItem.Category) then
			restoreEquippedWeaponPreviews()
			return
		end

		local selectedCategory = selectedItem.Category :: WeaponCategory
		local otherCategory = if selectedCategory == WeaponCategoryMod.MAIN then WeaponCategoryMod.SPECIAL else WeaponCategoryMod.MAIN
		restoreEquippedWeaponPreviewForCategory(otherCategory)

		if weaponPreviewController:isMotionActive(selectedCategory) then
			return
		end

		applySelectedWeaponPreview(selectedItem)
	end

	local function populateNavButtons(categoryKey: LockerCategoryKey)
		clearNavButtons()
		clearItemGrid()

		local itemDefinitions = LOCKER_NAV_ITEMS[categoryKey]
		for layoutOrder, definition in ipairs(itemDefinitions) do
			local navButton = navTemplate:Clone()
			navButton.Name = definition.key
			navButton.Visible = true
			navButton.LayoutOrder = layoutOrder
			navButton.Size = defaultNavItemSize
			setNavButtonContent(navButton, definition)
			navButton.Parent = nav
			table.insert(navButtons, navButton)
			navItemController:register(definition.key, navButton)

			local stroke = getButtonStroke(navButton)
			if stroke then
				stroke.Color = STROKE_DEFAULT
			end

			bindStrokeHover(navButton, navItemsJanitor)

			navItemsJanitor:Add(navButton.Activated:Connect(function()
				if selectedNavKey == definition.key then
					return
				end
				setSelectedNavButton(navButton)
				populateMainContentForNavItem(categoryKey, definition.key, nil, true)
			end), "Disconnect")
		end

		if #navButtons > 0 then
			setSelectedNavButton(navButtons[1])
			populateMainContentForNavItem(categoryKey, itemDefinitions[1].key, nil, true)
		end

		nav2Stagger:play()
	end

	clearItemGrid = function()
		grid:Clear()
		destroyKillEffectDummy()
	end

	-- `withoutFade` es para la apertura: la cámara la lleva el travelling de entrada
	-- justo después, y el cover (asíncrono) llegaría tarde y lo taparía.
	local function selectItem(selectedKey: LockerCategoryKey, withoutFade: boolean?)
		if selectedMainCategory == selectedKey and selectedNavKey ~= nil then
			return
		end

		local previousKey = selectedMainCategory
		setSelectedMainCategory(selectedKey)
		-- Fuera de Character el arrastre se apaga y el personaje vuelve girando al
		-- frente: la cámara de kill effects mira al mismo maniquí.
		characterRotate:setEnabled(selectedKey == LockerMainCategory.STYLE)
		local cameraTarget = CAMERA_TARGET_BY_MAIN_CATEGORY[selectedKey]
		-- Character ↔ Effects: cámaras cercanas, travelling en vez de negro. Con un
		-- fundido en vuelo la cámara aún no ha llegado a la pestaña anterior, así que
		-- ese caso sigue yendo a negro.
		local isCharacterEffectsSwap = not pendingCameraFade
			and (
				(previousKey == LockerMainCategory.STYLE and selectedKey == LockerMainCategory.EFFECTS)
				or (previousKey == LockerMainCategory.EFFECTS and selectedKey == LockerMainCategory.STYLE)
			)
		if withoutFade or isCharacterEffectsSwap then
			cameraController:setTargetPartName(cameraTarget)
		else
			pendingCameraFade = true
			fade:cover(function()
				pendingCameraFade = false
				-- El locker puede haberse cerrado o cambiado de pestaña antes del negro:
				-- entonces solo se descubre.
				if isOpen and selectedMainCategory == selectedKey then
					cameraController:setTargetPartName(cameraTarget, true)
				end
				fade:reveal()
			end)
		end
		if selectedKey ~= LockerMainCategory.ARSENAL then
			weaponStatsPanel:hide()
			restoreEquippedWeaponPreviews()
		end
		populateNavButtons(selectedKey)
	end

	local function handleMainCategoryButtonClick(selectedKey: LockerCategoryKey)
		if selectedMainCategory == selectedKey and selectedNavKey ~= nil then
			return
		end

		local now = os.clock()
		if now < nextAllowedMainCategorySwitchAt then
			return
		end

		nextAllowedMainCategorySwitchAt = now + MAIN_CATEGORY_SWITCH_COOLDOWN
		clearItemGrid()
		hideActionFrame()
		selectItem(selectedKey)
	end

	-- El tab activo lo marca `selectedMainCategory` (nil al abrir → lo fija selectItem).
	populateMainCategoryNav = function()
		local definitions = {} :: { Nav1TabDefinition }
		for _, item in NAV1_MAIN_CATEGORY_ITEMS do
			local categoryKey = item.key
			table.insert(definitions, {
				key = categoryKey,
				title = item.title,
				onActivated = function()
					handleMainCategoryButtonClick(categoryKey)
				end,
			})
		end
		populateNav1(definitions, selectedMainCategory)
	end

	navTemplate.Visible = false
	itemGridTemplate.Visible = false
	do
		-- Saldo del jugador en la moneda del ítem (Cash por defecto). El server
		-- cobra de este mismo stat (ShopService + Shared.constants.Currency).
		local function getBalanceFor(item: LockerCatalogItem): number
			local stats = getCurrentStats()
			if CurrencyMod.resolve(item.Currency) == CurrencyMod.GEMS then
				-- `or 0` cubre el perfil que aún no pasó por Reconcile.
				return stats.Gems or 0
			end
			return stats.Cash
		end

		local function promptBestFitPack(item: LockerCatalogItem)
			local isGems = CurrencyMod.resolve(item.Currency) == CurrencyMod.GEMS
			local deficit = item.Price - getBalanceFor(item)
			local packs: { any } = if isGems then StoreProducts.Gems.InOrder else StoreProducts.Cash.InOrder
			local function amountOf(pack: any): number
				return if isGems then pack.GemAmount else pack.CashAmount
			end

			local bestPack: any = nil

			for _, pack in packs do
				if amountOf(pack) >= deficit and pack.ProductId > 0 then
					bestPack = pack
					break
				end
			end

			if not bestPack then
				local largest = packs[#packs]
				if largest and largest.ProductId > 0 then
					bestPack = largest
				end
			end

			if bestPack then
				MarketplaceService:PromptProductPurchase(player, bestPack.ProductId)
			end
		end

		-- Si falta saldo se ofrece el pack que mejor encaja. Cada rechazo avisa por
		-- toast: el botón sigue visible con el ítem bloqueado y si no el clic no da feedback.
		local function canPurchase(item: LockerCatalogItem): boolean
			if pendingShopAction then
				return false
			end

			if getCurrentLevel() < item.LevelRequired then
				Notify.warning(`You need level {item.LevelRequired} to buy this item.`)
				return false
			end

			if isItemOwned(item) then
				Notify.warning("You already own this item.")
				return false
			end

			if item.KillGoal ~= nil and item.KillGoal > 0 then
				Notify.warning(`Unlock this wrap with {item.KillGoal} kills.`)
				return false
			end

			if getBalanceFor(item) < item.Price then
				local currencyName = if CurrencyMod.resolve(item.Currency) == CurrencyMod.GEMS then "Gems" else "Cash"
				Notify.warning(`Not enough {currencyName}. You need {UIUtils.formatCashAmount(item.Price)}.`)
				promptBestFitPack(item)
				return false
			end

			return true
		end

		local function executePurchase(item: LockerCatalogItem)
			if not canPurchase(item) then
				return
			end

			local buyAction = {
				kind = "buy",
				item = item,
			}
			pendingShopAction = buyAction
			-- Snapshot de categoría/nav: si el usuario navega durante el timeout, no se
			-- repuebla la vista nueva con un qualifiedId que no es suyo.
			local buyMainCategory = selectedMainCategory
			local buyNavKey = selectedNavKey
			task.delay(SHOP_REQUEST_TIMEOUT, function()
				if pendingShopAction == buyAction then
					pendingShopAction = nil
					if buyMainCategory and buyNavKey
						and selectedMainCategory == buyMainCategory and selectedNavKey == buyNavKey then
						populateMainContentForNavItem(buyMainCategory, buyNavKey, buyAction.item.qualifiedId)
					end
				end
			end)

			local weaponCategory, weaponId = getWeaponWrapRequestContext(item.Category)

			Network.Shop.BuyItem.Send({
				itemId = item.id,
				category = item.Category,
				weaponCategory = weaponCategory,
				weaponId = weaponId,
			})
		end

		local function onPurchaseActivated()
			local item = selectedCatalogItem
			if item then
				executePurchase(item)
			end
		end

		local function setupActionButton(button: GuiButton)
			button.Active = true
			button.Selectable = true
			button.AutoButtonColor = false

			local scaleNode = button:FindFirstChild("ButtonScale")
			if not (scaleNode and scaleNode:IsA("UIScale")) then
				scaleNode = Instance.new("UIScale")
				scaleNode.Name = "ButtonScale"
				scaleNode.Parent = button
			end
			scaleNode.Scale = PURCHASE_BUTTON_DEFAULT_SCALE

			local stroke = getButtonStroke(button)
			if stroke then
				stroke.Color = STROKE_DEFAULT
			end

			local function tweenScale(targetScale: number, tweenInfo: TweenInfo)
				if activePurchaseButtonScaleTween then
					activePurchaseButtonScaleTween:Cancel()
					activePurchaseButtonScaleTween = nil
				end
				activePurchaseButtonScaleTween = TweenService:Create(scaleNode :: UIScale, tweenInfo, { Scale = targetScale })
				activePurchaseButtonScaleTween:Play()
			end

			local function tweenStroke(targetColor: Color3, tweenInfo: TweenInfo)
				if not stroke then
					return
				end
				if activePurchaseButtonStrokeTween then
					activePurchaseButtonStrokeTween:Cancel()
					activePurchaseButtonStrokeTween = nil
				end
				activePurchaseButtonStrokeTween = TweenService:Create(stroke, tweenInfo, { Color = targetColor })
				activePurchaseButtonStrokeTween:Play()
			end

			if canUseHoverAnimations then
				janitor:Add(button.MouseEnter:Connect(function()
					purchaseButtonIsHovered = true
					tweenScale(PURCHASE_BUTTON_HOVER_SCALE, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
					tweenStroke(STROKE_WHITE, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
				end), "Disconnect")

				janitor:Add(button.MouseLeave:Connect(function()
					purchaseButtonIsHovered = false
					tweenScale(PURCHASE_BUTTON_DEFAULT_SCALE, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
					tweenStroke(STROKE_DEFAULT, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
				end), "Disconnect")
			end

			janitor:Add(button.MouseButton1Down:Connect(function()
				tweenScale(PURCHASE_BUTTON_CLICK_SCALE, PURCHASE_BUTTON_CLICK_TWEEN_INFO)
				tweenStroke(STROKE_WHITE, PURCHASE_BUTTON_CLICK_TWEEN_INFO)
			end), "Disconnect")

			janitor:Add(button.MouseButton1Up:Connect(function()
				local targetScale = if purchaseButtonIsHovered
					then PURCHASE_BUTTON_HOVER_SCALE
					else PURCHASE_BUTTON_DEFAULT_SCALE
				tweenScale(targetScale, PURCHASE_BUTTON_HOVER_TWEEN_INFO)

				local targetStrokeColor = if purchaseButtonIsHovered then STROKE_WHITE else STROKE_DEFAULT
				tweenStroke(targetStrokeColor, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
			end), "Disconnect")

			janitor:Add(button.Activated:Connect(onPurchaseActivated), "Disconnect")
		end

		setupActionButton(actionPanel.button)
	end

	local function showWrapsView(view: string)
		if not isWrapsMode or wrapsView == view then
			return
		end
		wrapsView = view
		nav1TabController:setActive(view)
		populateMainContentForNavItem(LockerMainCategory.ARSENAL, LockerCategory.WEAPON_WRAPS, nil, true)
	end

	-- Tabs de Nav1 en modo wraps. La key de cada tab ES el valor de `wrapsView`.
	populateWrapsViewNav = function()
		local definitions = {} :: { Nav1TabDefinition }
		for _, item in NAV1_WRAPS_VIEW_ITEMS do
			local viewKey = item.key
			table.insert(definitions, {
				key = viewKey,
				title = item.title,
				onActivated = function()
					showWrapsView(viewKey)
				end,
			})
		end
		populateNav1(definitions, wrapsView)
	end

	do
		janitor:Add(wrapsButton.Activated:Connect(function()
			local item = selectedCatalogItem
			if not item or pendingShopAction then
				return
			end

			if not isItemOwned(item) or not isWeaponCategory(item.Category) then
				return
			end

			local selectedWeaponCategory = item.Category :: WeaponCategory
			wrapsTargetWeaponCategory = selectedWeaponCategory
			setStoredWrapsTargetWeaponId(selectedWeaponCategory, item.id)
			updateWeaponFocusCategory()

			-- Arrancar en Owned ANTES de setWrapsMode: populateWrapsViewNav usa
			-- `wrapsView` como tab activo al reconstruir Nav1.
			wrapsView = "owned"
			setWrapsMode(true)
			-- updateWeaponFocusCategory (arriba) ya ha mandado el arma objetivo a
			-- la mesa, así que el zoom va siempre al ancla de la mesa.
			if tableWeaponSpawn and tableWeaponSpawn:IsA("BasePart") then
				cameraController:zoomOnPosition(tableWeaponSpawn.Position)
			end

			populateMainContentForNavItem(LockerMainCategory.ARSENAL, LockerCategory.WEAPON_WRAPS, nil, true)
		end), "Disconnect")
	end

	janitor:Add(Network.Shop.Response.Listen(function(response: { success: boolean, message: string })
		local resolvedAction = pendingShopAction
		pendingShopAction = nil

		if response.success then
			if resolvedAction and resolvedAction.kind == "buy" then
				GameSounds.play(GameSounds.Purchase)
				Confetti.Rain(lockerFrame)
			end
		else
			local message = if response.message ~= "" then response.message else "That purchase couldn't be completed."
			Notify.warning(message)

			task.defer(function()
				if resolvedAction and resolvedAction.kind == "buy" and selectedMainCategory and selectedNavKey then
					populateMainContentForNavItem(selectedMainCategory, selectedNavKey, resolvedAction.item.qualifiedId)
				else
					refreshGridSelectionState()
				end
			end)
		end
	end), true)

	DataController:WhenReady():andThen(function()
		rebuildOwnedLookup()
		rebuildEquippedLookup()
		-- El preview del personaje (outfit/cara/hat) lo mantiene LobbyFeature
		-- mientras el locker está cerrado; aquí solo preparamos las armas.
		restoreEquippedWeaponPreviews()

		local statsObserver = fusionScope:Observer(DataController.Stats)
		janitor:Add(statsObserver:onBind(function()
			if not isOpen then
				dirtyWhileClosed = true
				return
			end
			updateActionFrameForSelected()
			refreshBanners()
		end), true)

		local weaponKillsObserver = fusionScope:Observer(DataController.WeaponKills)
		janitor:Add(weaponKillsObserver:onBind(function()
			if not isOpen then
				dirtyWhileClosed = true
				return
			end
			if selectedMainCategory == LockerMainCategory.ARSENAL and selectedNavKey == LockerCategory.WEAPON_WRAPS then
				local selectedQualifiedId = if selectedCatalogItem then selectedCatalogItem.qualifiedId else nil
				populateMainContentForNavItem(selectedMainCategory, selectedNavKey, selectedQualifiedId)
			end
		end), true)

		local inventoryObserver = fusionScope:Observer(DataController.Inventory)
		janitor:Add(inventoryObserver:onBind(function()
			if not isOpen then
				dirtyWhileClosed = true
				return
			end
			rebuildOwnedLookup()
			if selectedMainCategory and selectedNavKey then
				local selectedQualifiedId = if selectedCatalogItem then selectedCatalogItem.qualifiedId else nil
				populateMainContentForNavItem(selectedMainCategory, selectedNavKey, selectedQualifiedId)
			end
		end), true)

		local loadoutObserver = fusionScope:Observer(DataController.Loadout)
		janitor:Add(loadoutObserver:onBind(function()
			if not isOpen then
				dirtyWhileClosed = true
				return
			end
			rebuildEquippedLookup()
			local previewingBody = selectedCatalogItem ~= nil
				and selectedCatalogItem.Category == LockerCategory.OUTFITS
			if not previewingBody then
				applyEquippedBodyPreview()
			end
			applyEquippedFacePreview()
			applyEquippedHatPreview()
			syncWeaponPreviewsFromLoadout()
			refreshGridSelectionState()
		end), true)
	end)

	local function setMenuVisibleInstant(visible: boolean)
		if visible then
			menuController:show()
		else
			menuController:hide()
		end
	end

	-- `animateCamera`: travelling al cerrar; en teardown del feature, al instante.
	local function restoreLockerSceneState(animateCamera: boolean?)
		weaponStatsPanel:hide()
		-- Antes de endPreview: devuelve el personaje del lobby si estaba oculto.
		setBannersViewActive(false)
		-- Todas las salidas pasan por aquí, incluidas las que no llaman a setWrapsMode:
		-- soltar el HUD compartido sin condiciones o se quedaría forzado en el lobby.
		menuController:setStatsHudOverride(nil)
		restoreEquippedWeaponPreviews()
		-- Soltar el preview del personaje del lobby: vuelve a mostrar lo equipado y
		-- LobbyFeature retoma el control de los cambios de loadout.
		characterRotate:reset()
		lobbyCharacter:endPreview()
		cameraController:restore(animateCamera)
		CameraLock.release("locker")
		setMenuVisibleInstant(true)
	end

	-- nav1 se re-anima al abrir y al alternar modo wraps; nav2 cada vez que se repuebla.
	nav1Stagger = NavStaggerController.new({
		{
			container = nav1,
			getSelectedKey = function()
				return if isWrapsMode then wrapsView else selectedMainCategory
			end,
			exclude = { nav1Template },
		},
	})
	nav2Stagger = NavStaggerController.new({
		{ container = nav, getSelectedKey = function() return selectedNavKey end, exclude = { navTemplate } },
	})
	janitor:Add(nav1Stagger, "Destroy")
	janitor:Add(nav2Stagger, "Destroy")

	-- Abrir desde el lobby NO pasa por negro: travelling hasta Workspace.Cameras.character
	-- (espejo del de vuelta). El fundido queda para los cambios de pestaña.
	local function openLockerGui()
		-- Durante el fundido de salida la escena sigue montada: reabrir pisaría el
		-- cierre a medias (en la práctica solo lo alcanzaría un autoOpen).
		if isOpen or closeFadePending then
			return
		end

		GameSounds.play(GameSounds.Open)
		isOpen = true
		CameraLock.acquire("locker")
		-- Desde aquí el locker controla lo que se muestra y LobbyFeature deja de
		-- sincronizarlo al loadout hasta el cierre.
		lobbyCharacter:beginPreview()
		if dirtyWhileClosed then
			dirtyWhileClosed = false
			rebuildOwnedLookup()
			rebuildEquippedLookup()
		end
		-- BODY primero: beginPreview no reconstruye el modelo y el preview del lobby pudo
		-- construirse antes de llegar el loadout. applyOutfit es no-op si ya coincide, y
		-- reconstruir el body recrea los appliers sobre los que se aplican cara/hat.
		applyEquippedBodyPreview()
		applyEquippedFacePreview()
		applyEquippedHatPreview()
		hideActionFrame()
		-- Antes de selectItem, para que nav1TabController pueda marcar la categoría.
		populateMainCategoryNav()
		-- Sin fundido: solo fija el target; la cámara la lleva el apply de abajo.
		selectItem(LockerMainCategory.STYLE, true)
		cameraController:apply()
		lockerFrame.Visible = true
		-- Antes de esconder el Menu: si no, el HUD compartido se iría con él
		-- durante un frame antes de que el Locker se lo quede.
		syncSharedStatsHud()
		setMenuVisibleInstant(false)
		ScenePresetController.applyFrom(lockerFolder)
		nav1Stagger:play()
		nav2Stagger:play()
	end

	local function finishClose(animateCamera: boolean)
		selectedMainCategory = nil
		selectedNavKey = nil
		selectedCatalogItem = nil
		hideActionFrame()
		restoreLockerSceneState(animateCamera)
		setWrapsMode(false)
		-- Liberar las cards (pooled) para que las texturas de wrap animadas dejen de
		-- actualizarse cada Heartbeat.
		clearItemGrid()
		lockerFrame.Visible = false
		ScenePresetController.applyLobbyOrRestore("[Locker]")
	end

	-- Desde Character y Effects se vuelve con travelling (cámaras cerca del lobby).
	-- Desde Weapons se va a negro y la cámara se restaura de golpe.
	local function closeLockerGui()
		if not isOpen then
			return
		end

		isOpen = false
		GameSounds.play(GameSounds.Close)

		-- Con un fundido de pestaña en vuelo la pantalla ya va camino del negro y la
		-- cámara aún no ha saltado: se aprovecha ese negro también.
		local useFade = pendingCameraFade
			or (selectedMainCategory ~= LockerMainCategory.STYLE and selectedMainCategory ~= LockerMainCategory.EFFECTS)
		if not useFade then
			finishClose(true)
			return
		end

		-- Este cover sustituye al de la pestaña (ScreenFade descarta el obsoleto).
		pendingCameraFade = false
		closeFadePending = true
		fade:cover(function()
			-- El teardown del feature ya limpió la escena mientras fundía.
			if not closeFadePending then
				fade:reveal()
				return
			end
			closeFadePending = false
			finishClose(false)
			fade:reveal()
		end)
	end

	if lockerBtn then
		janitor:Add(lockerBtn.MouseButton1Click:Connect(openLockerGui), "Disconnect")
	end
	janitor:Add(closeBtn.MouseButton1Click:Connect(function()
		if isWrapsMode then
			-- En modo wraps el CloseBtn vuelve a la lista de armas; suena como cierre
			-- porque UISoundsController no pone click a los CloseBtn.
			GameSounds.play(GameSounds.Close)
			setWrapsMode(false)
			local previousNavKey = wrapsTargetWeaponCategory

			cameraController:unzoom()

			for _, button in navButtons do
				if button.Name == previousNavKey then
					setSelectedNavButton(button)
					break
				end
			end

			populateMainContentForNavItem(LockerMainCategory.ARSENAL, previousNavKey, nil, true)
		else
			closeLockerGui()
		end
	end), "Disconnect")

	janitor:Add(lockerFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if not lockerFrame.Visible and isOpen then
			isOpen = false
			restoreLockerSceneState(true)
			ScenePresetController.applyLobbyOrRestore("[Locker]")
		end
	end), "Disconnect")

	janitor:Add(function()
		if isOpen or closeFadePending then
			closeFadePending = false
			restoreLockerSceneState()
			-- Igual que closeLockerGui: el preset del Locker no puede sobrevivir al
			-- feature, o el lobby se queda con su lighting (y su DoF).
			ScenePresetController.applyLobbyOrRestore("[Locker]")
		end
	end, true)

	-- `autoOpen` se lee AQUÍ y no al entrar: el arranque tarda (WaitForChild) y si el
	-- jugador pulsa Locker mientras tanto, ClientBootstrap marca la opción sobre esta
	-- misma tabla y el clic no se pierde.
	if options and options.autoOpen == true then
		task.defer(openLockerGui)
	end

	return janitor
end

return LockerFeature
