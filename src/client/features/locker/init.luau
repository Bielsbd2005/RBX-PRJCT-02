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
local LockerUtils = require(script:WaitForChild("LockerUtils"))
local WeaponPreviewController = require(script:WaitForChild("WeaponPreviewController"))
local WeaponStatsPanel = require(script:WaitForChild("WeaponStatsPanel"))
local MenuHover = require(Client.core.ui.MenuHover)
local NavStaggerController = require(Client.core.ui.NavStaggerController)
local UIUtils = require(Client.core.ui.UIUtils)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local AssetIds = require(Shared.constants.AssetIds)
local WeaponLevelConfig = require(Shared.constants.WeaponLevelConfig)
local LockerConfig = require(Shared.constants.LockerConfig)
local WeaponCategoryMod = require(Shared.constants.WeaponCategory)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local LockerCategory = require(Shared.constants.LockerCategory)
local CurrencyMod = require(Shared.constants.Currency)
local LockerMainCategory = require(Shared.constants.LockerMainCategory)
local Network = require(Shared.networking.Network)
local KillEffectsRegistry = require(Shared.Locker.killEffects.KillEffectsRegistry)
local DataController = require(Client.core.data.DataController)
local StoreProducts = require(Shared.constants.StoreProducts)
local UITheme = require(Client.core.ui.UITheme)
local NavTabController = require(Client.core.ui.NavTabController)
local Confetti = require(Client.core.ui.Confetti)
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
-- Mismo icono de gema que pinta el grid (LockerGrid.STATUS_ICON_GEMS): el panel
-- de acción tiene que anunciar la moneda antes de que el jugador pulse comprar.
local ACTION_ICON_PURCHASE_GEMS = AssetIds.Images.LockerStatusGems
local ACTION_BTN_COLOR_PURCHASE = Color3.fromRGB(255, 0, 127)
local ACTION_BTN_COLOR_LOCKED = Color3.fromRGB(161, 161, 161)
local LOCKER_PREVIEW_IDLE_ANIMATION_ID = AssetIds.Animations.PreviewIdle
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

local CAMERA_TARGET_BY_MAIN_CATEGORY = {
	-- Character (Style) usa su propia cámara Workspace.Cameras.character.
	Style = "character",
	Arsenal = "weapons",
	Effects = "killEffects",
} :: { [LockerCategoryKey]: string }
local MAIN_CATEGORY_SWITCH_COOLDOWN = 0.2

function LockerFeature.start(menuController: any, options: { autoOpen: boolean? }?): any
	local janitor = Janitor.new()
	local fusionScope = Fusion.scoped(Fusion)
	local navItemsJanitor = Janitor.new()
	local autoOpenOnStart = options and options.autoOpen == true
	janitor:Add(function()
		Fusion.doCleanup(fusionScope)
	end, true)
	janitor:Add(navItemsJanitor, "Destroy")
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()
	local bodiesFolder = Shared:WaitForChild("Bodies") :: Folder
	local killEffectDummyTemplate = bodiesFolder:WaitForChild("KillEffectDummy") :: Model

	-- El preview del personaje (outfit/cara/hat) ya no usa un maniquí propio en
	-- Workspace.Locker.CharacterSpawn: se previsualiza sobre el personaje del lobby
	-- (Workspace.Lobby.Spawners.P1) vía este singleton compartido con LobbyFeature.
	local lobbyCharacter = LobbyCharacterPreview.get()

	local lockerFolder = Workspace:WaitForChild("Locker")

	-- Lighting por atributo: el look del Locker lo lleva Workspace.Locker
	-- (LightingPreset="Locker") y la vuelta al lobby es la política compartida de
	-- ScenePresetController.applyLobbyOrRestore (misma que usa el BattlePass).
	local dummySpawn = lockerFolder:WaitForChild("DummySpawn")
	-- Anclas del preview de armas por ROL, no por arma: el arma de la categoría
	-- activa se va a la mesa y la otra a la pared (WeaponPreviewController las
	-- intercambia al cambiar de nav). Fallback a los nombres antiguos mientras el
	-- place no tenga los nuevos: el intercambio funciona igual, entre las posiciones
	-- de siempre.
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

	-- Botón de apertura en Menu.Container.Locker
	local container = menuGui:FindFirstChild("Container")
	local lockerBtnInstance = container and container:FindFirstChild("Locker")
	local lockerBtn: GuiButton? = if lockerBtnInstance and lockerBtnInstance:IsA("GuiButton")
		then lockerBtnInstance
		else nil
	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local lockerFrame = uiGui:WaitForChild("Locker") :: Frame

	-- Registrar el Locker como panel del MenuController para que hasOpenPanel()
	-- lo cuente — afecta a MapVote (auto-hide cuando hay panel encima) y al
	-- estado MUFFLED de la música del lobby. El Locker oculta el menú via
	-- :hide()/:show() pero antes no se registraba: la música caía en STOP
	-- creyendo que estábamos en match.
	menuController:registerPanel(lockerFrame)
	janitor:Add(function()
		menuController:unregisterPanel(lockerFrame)
	end, true)
	local nav = lockerFrame:WaitForChild("Nav2")
	local navTemplate = nav:WaitForChild("Template") :: GuiButton
	local defaultNavItemSize = navTemplate.Size
	local nav1 = lockerFrame:WaitForChild("Nav1")
	local closeBtn = nav1:WaitForChild("CloseBtn") :: GuiButton
	-- Nav1 pasó a ser template-driven: sus tabs se clonan de Nav1.Template según el
	-- modo. En el locker normal son Character/Effects/Weapons (categorías internas
	-- Style/Effects/Arsenal); en modo wraps son Maestry/Owned. El Name de
	-- cada botón clonado ES la key (nav1TabController y nav1Stagger indexan por Name).
	local nav1Template = nav1:WaitForChild("Template") :: GuiButton
	local defaultNav1ItemSize = nav1Template.Size
	local itemGrid = lockerFrame:WaitForChild("ScrollingFrame")
	-- ItemTemplate es ahora la única plantilla del grid: la vista de wraps la
	-- reutiliza (incluye ViewportFrame para el preview 3D; el progreso de los
	-- wraps de desafío se muestra como texto en Status.Value).
	local itemGridTemplate = itemGrid:WaitForChild("ItemTemplate") :: GuiObject
	-- El texto del ActionBtn puede vivir en el propio botón (TextButton) o en un hijo
	-- (Title/Label/Text). Resolvemos el destino una vez por botón.
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

	-- Panel de acción (compra / bloqueo). Hay DOS frames de idéntica estructura:
	-- ActionFrame (ítems normales) y WeaponActionFrame (armas, con su tamaño/posición
	-- propios). showActionFrameForItem enruta según la categoría del ítem.
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
		local title = frame:WaitForChild("Title")
		local textContainer = title:WaitForChild("Text")
		local button = frame:FindFirstChild("ActionBtn", true) :: GuiButton
		local visiblePosition = frame.Position
		return {
			frame = frame,
			titleLabel = textContainer:WaitForChild("Title") :: TextLabel,
			subtitleLabel = textContainer:WaitForChild("Subtitle") :: TextLabel,
			icon = title:WaitForChild("Icon") :: ImageLabel,
			button = button,
			buttonTextTarget = resolveActionButtonTextTarget(button),
			visiblePosition = visiblePosition,
			-- Oculto: deslizado bajo el borde inferior (mismo X, Y fuera de pantalla).
			hiddenPosition = UDim2.new(visiblePosition.X.Scale, visiblePosition.X.Offset, 1.15, visiblePosition.Y.Offset),
			activeTween = nil,
		}
	end

	local actionPanel = makeActionPanel(lockerFrame:WaitForChild("ActionFrame") :: GuiObject)
	-- WeaponActionFrame: misma estructura que ActionFrame, con su tamaño/posición
	-- propios (deja sitio al panel de stats). Geometría que pediste; ajústala aquí.
	local weaponActionFrame = lockerFrame:WaitForChild("WeaponActionFrame") :: GuiObject
	weaponActionFrame.Size = UDim2.new(0.229, 0, 0.143, 0)
	weaponActionFrame.Position = UDim2.new(0.137, 0, 0.804, 0)
	local weaponActionPanel = makeActionPanel(weaponActionFrame)
	-- Panel de acción actualmente visible (nil = ninguno).
	local activeActionPanel: ActionPanel? = nil
	-- Botón separado (fuera del ActionFrame) para personalizar los wraps de un arma poseída.
	-- El nav de armas (Locker.WeaponNav) agrupa las acciones específicas del arma y
	-- se muestra al seleccionar un arma poseída. El botón de wraps vive dentro; su
	-- visibilidad la controla la del contenedor.
	local wrapsButton = lockerFrame:WaitForChild("Wraps") :: GuiButton
	-- Indicator: nº de wraps poseídos para el arma seleccionada (sin contar Default).
	local wrapsIndicator = wrapsButton:WaitForChild("Indicator") :: TextLabel

	local function setPanelButtonText(panel: ActionPanel, text: string)
		if panel.buttonTextTarget then
			(panel.buttonTextTarget :: any).Text = text
		end
	end

	-- HUD de monedas: el Locker monta una copia del Stats del Menu
	-- (Stats.CoinsFrame.Value + Stats.GemsFrame.Value opcional). El panel de stats
	-- del arma vive aparte, en Locker.WeaponStats. Todo opcional: sin HUD montado el
	-- locker funciona igual, solo no pinta el cash.
	local statsHud = lockerFrame:FindFirstChild("Stats")
	local coinsFrame = if statsHud then statsHud:FindFirstChild("CoinsFrame") else nil
	local coinsValueNode = if coinsFrame then coinsFrame:FindFirstChild("Value") else nil
	local cashValueLabel = if coinsValueNode and coinsValueNode:IsA("TextLabel") then coinsValueNode else nil
	local statsHudNode = if statsHud and statsHud:IsA("GuiObject") then statsHud :: GuiObject else nil
	local gemsFrame = if statsHudNode then statsHudNode:FindFirstChild("GemsFrame") else nil
	local gemsValueNode = if gemsFrame then gemsFrame:FindFirstChild("Value") else nil
	local gemsValueLabel = if gemsValueNode and gemsValueNode:IsA("TextLabel") then gemsValueNode else nil
	if not cashValueLabel then
		warn("[Locker] HUD de cash no encontrado (Stats.CoinsFrame.Value) dentro de Locker")
	end
	local cameraController = LockerCameraController.new("weapons")
	janitor:Add(cameraController, "Destroy")
	lockerFrame.Visible = false

	MenuHover.bindButton(closeBtn, janitor)

	-- Los tabs de categoría de Nav1 (Character/Effects/Weapons) se clonan de
	-- Nav1.Template en populateMainCategoryNav; cada tab lleva su key de categoría.
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
	-- Janitor de los botones clonados de Nav1 (conexiones + hover). Se limpia en cada
	-- repoblación para no acumular listeners de tabs destruidos.
	local nav1ButtonsJanitor = Janitor.new()
	janitor:Add(nav1ButtonsJanitor, "Destroy")
	local activeNavSizeTweens = {} :: { [GuiButton]: Tween }
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
	-- Forward decl: los controladores del stagger de Nav1/Nav2 se construyen más
	-- abajo (cuando `navTemplate`/janitor están listos) pero se referencian antes:
	-- `populateNavButtons` re-tweenea Nav2 al cambiar de categoría, y `setWrapsMode`
	-- re-tweenea Nav1 al alternar entre el locker normal y el modo wraps.
	local nav1Stagger: NavStaggerController.NavStaggerController? = nil
	local nav2Stagger: NavStaggerController.NavStaggerController? = nil
	-- Forward decl de la repoblación de Nav1: setWrapsMode las invoca para reconstruir
	-- los tabs (Character/Effects/Weapons ↔ Maestry/Owned); se asignan más
	-- abajo, cuando sus dependencias (handleMainCategoryButtonClick / showWrapsView)
	-- ya existen.
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

	local function setWrapsMode(enabled: boolean)
		isWrapsMode = enabled
		if statsHudNode then
			statsHudNode.Visible = not enabled
		end
		if nav then nav.Visible = not enabled end
		-- Entrar al modo wraps oculta el WeaponNav; al salir, updateActionFrameForSelected
		-- lo vuelve a mostrar si toca.
		if enabled then wrapsButton.Visible = false end
		-- Reconstruir los tabs de Nav1 según el modo: wraps (Maestry/Owned)
		-- vs locker normal (Character/Effects/Weapons). Cada repoblación destruye los
		-- botones del modo anterior y clona los nuevos desde Nav1.Template.
		if enabled then
			populateWrapsViewNav()
		else
			populateMainCategoryNav()
		end
		if nav1Stagger then
			nav1Stagger:play()
		end
	end

	actionPanel.frame.Visible = false
	weaponActionPanel.frame.Visible = false
	wrapsButton.Visible = false
	nav1Template.Visible = false
	actionPanel.frame.Position = actionPanel.hiddenPosition
	weaponActionPanel.frame.Position = weaponActionPanel.hiddenPosition

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

	local function cancelTweenMap(tweenMap: { [any]: Tween })
		for _, tween in tweenMap do
			tween:Cancel()
		end

		table.clear(tweenMap)
	end


	-- La implementación vive en LockerUtils (la comparte ResultsView); aquí solo se
	-- fija la animación del locker y el janitor por defecto.
	local function playPreviewIdleAnimation(previewModel: Model, ownerJanitor: any?)
		LockerUtils.playPreviewIdleAnimation(previewModel, ownerJanitor or janitor, LOCKER_PREVIEW_IDLE_ANIMATION_ID)
	end

	local KILL_EFFECT_PREVIEW_COOLDOWN = 0.4

	local currentKillEffectDummy: Model? = nil
	local killEffectIdleJanitor: any = nil
	local killEffectRespawnTask: thread? = nil
	local currentlyPreviewingEffectId: string? = nil
	local nextAllowedPreviewAt = 0
	-- Al entrar a la nav KillEffects el grid auto-selecciona el primer item y
	-- dispara onSelectionChanged sin que el usuario haya clickeado. Esta flag
	-- consume esa primera notificación para que el preview solo arranque por clic.
	local suppressNextKillEffectPreview = false

	local function destroyKillEffectDummy()
		if killEffectRespawnTask then
			task.cancel(killEffectRespawnTask)
			killEffectRespawnTask = nil
		end
		if killEffectIdleJanitor then
			killEffectIdleJanitor:Destroy()
			killEffectIdleJanitor = nil
		end
		if currentKillEffectDummy and currentKillEffectDummy.Parent then
			currentKillEffectDummy:Destroy()
		end
		currentKillEffectDummy = nil
		currentlyPreviewingEffectId = nil
	end

	local function spawnKillEffectDummy()
		destroyKillEffectDummy()
		local clone = killEffectDummyTemplate:Clone()
		clone.Name = "KillEffectDummy"
		local humanoid = clone:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
		clone.Parent = lockerFolder
		LockerUtils.placePreviewCharacter(clone, dummySpawn)
		LockerUtils.snapPartsToCanonicalPose(clone)

		-- Anclar HRP para que el dummy no caiga por gravedad antes del clic.
		-- El killEffect desancla todo en su paso final (Utils.anchor false).
		local hrp = clone:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			hrp.Anchored = true
		end

		killEffectIdleJanitor = Janitor.new()
		playPreviewIdleAnimation(clone, killEffectIdleJanitor)
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
		-- Parar idle antes del apply: el effect destruye los Motor6Ds y la
		-- AnimationTrack quedaría apuntando a joints inexistentes.
		killEffectIdleJanitor:Destroy()
		killEffectIdleJanitor = nil
		currentlyPreviewingEffectId = effectId
		KillEffectsRegistry.apply(effectId, currentKillEffectDummy :: Model)
		killEffectRespawnTask = task.delay(2, function()
			killEffectRespawnTask = nil
			currentlyPreviewingEffectId = nil
			spawnKillEffectDummy()
		end)
	end

	janitor:Add(destroyKillEffectDummy, true)

	-- Todo el preview de outfit/cara/hat se aplica sobre el personaje del lobby
	-- (LobbyCharacterPreview), no sobre un maniquí del locker.
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
			-- Igual que el body: si el hat está bloqueado por nivel, el preview lo
			-- marca con el contorno de bloqueo (sin billboard, ese es solo del body).
			local lockedLevel: number? = if getCurrentLevel() < item.LevelRequired
				then item.LevelRequired
				else nil
			lobbyCharacter:applyHatItem(item, lockedLevel)
			return
		end

		applyEquippedHatPreview()
	end

	-- Body preview: a diferencia de face/hat reconstruye el modelo entero, por eso
	-- el controlador solo lo rehace si el outfit cambió. Tras reconstruir, los
	-- appliers se recrean dentro del controlador — los siguientes applySelectedFace/
	-- HatPreview del onSelectionChanged ven los nuevos.
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
		weaponActionPanel.activeTween = cancelTween(weaponActionPanel.activeTween)
		activePurchaseButtonScaleTween = cancelTween(activePurchaseButtonScaleTween)
		activePurchaseButtonStrokeTween = cancelTween(activePurchaseButtonStrokeTween)
		cancelTweenMap(activeNavSizeTweens)
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

	-- Mirror del server (LoadoutService._resolveWeaponWrapForLoadout) y del
	-- preview controller. Equip es per-weapon: la slot `wrapsTable.Default`
	-- es la del arma con id "Default", no un fallback que se propaga al resto.
	-- Un wrap global del BP otorga ownership a todas las armas, pero equiparlo
	-- sigue siendo manual per-arma desde el locker.
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

	-- Controlador de estado activo de Nav1 (tabs de categoría o de wraps, según el
	-- modo). Los botones se registran en cada populateNav1, ya que son dinámicos.
	local nav1TabController = NavTabController.new()
	local navItemController = NavTabController.new()
	janitor:Add(nav1TabController, "Destroy")
	janitor:Add(navItemController, "Destroy")

	local function clearNavButtons()
		navItemsJanitor:Cleanup()
		table.clear(navButtons)
		navItemController:clear()

		for _, tween in activeNavSizeTweens do
			tween:Cancel()
		end
		table.clear(activeNavSizeTweens)

		for _, child in nav:GetChildren() do
			if child ~= navTemplate and child:IsA("GuiButton") then
				child:Destroy()
			end
		end
	end

	local function getButtonStroke(button: GuiButton): UIStroke?
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke and stroke:IsA("UIStroke") then
			return stroke
		end

		return nil
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

	-- Reconstruye los tabs de Nav1 clonando Nav1.Template: destruye los del modo
	-- anterior, registra los nuevos en nav1TabController (estado activo) y engancha
	-- hover de stroke + click. El template sólo tiene un hijo Title (sin Icon).
	-- `selectedKey` marca el tab activo tras poblar (nil = ninguno; lo fija el caller).
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
		-- Armas → WeaponActionFrame; resto → ActionFrame (misma estructura).
		local panel = if isWeaponCategory(item.Category) then weaponActionPanel else actionPanel
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
			-- Item comprable: el botón muestra el precio (en lugar de "PURCHASE").
			setPanelButtonText(panel, UIUtils.formatCashAmount(item.Price))
			panel.button.BackgroundColor3 = ACTION_BTN_COLOR_PURCHASE
		end

		panel.button.Active = not isLevelLocked
		panel.button.Selectable = not isLevelLocked

		-- Si había otro panel visible (cambio arma↔no-arma), deslízalo fuera.
		if activeActionPanel and activeActionPanel ~= panel then
			tweenPanel(activeActionPanel, false)
		end
		activeActionPanel = panel
		tweenPanel(panel, true)
	end

	local function hideActionFrame()
		if activeActionPanel then
			tweenPanel(activeActionPanel, false)
			activeActionPanel = nil
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

		local slot = CATEGORY_TO_LOADOUT_SLOT[item.Category]
		if not slot then
			return false
		end

		local equippedItem = getEquippedItemByCategory(item.Category)
		return equippedItem == item.id
	end

	-- ── Panel de stats del arma (Locker.Stats) ───────────────────
	-- Los stats de combate viven en la Configuration del Tool (ServerStorage,
	-- no replicado), así que se piden al server (Network.WeaponStats). Los
	-- valores BASE se cachean por arma (estáticos) y el escalado por nivel se
	-- aplica aquí con las WeaponKills locales — así subir de nivel re-anima sin
	-- otro round-trip. El panel compara la SELECCIONADA contra la EQUIPADA
	-- (delta bar verde/rojo), así que se piden/cachean ambas armas.
	local weaponStatsPanel = WeaponStatsPanel.new(lockerFrame, janitor)

	type WeaponBaseStats = {
		damage: number,
		fireRate: number,
		reloadTime: number,
		ammoCapacity: number,
		damageMax: number,
		fireRateMax: number,
		reloadMin: number,
	}
	-- Valores escalados por nivel + sus fills 0..1 (para comparar y mostrar).
	type ScaledStats = {
		damage: number,
		fireRate: number,
		reload: number,
		ammo: number,
		damageFill: number,
		fireRateFill: number,
		reloadFill: number,
	}
	local weaponStatsCache = {} :: { [string]: WeaponBaseStats }
	-- Requests en vuelo (evita reenviar el mismo paquete mientras se espera).
	local pendingStatsRequests = {} :: { [string]: boolean }
	-- Arma seleccionada ahora (category/id, "" si ninguna). Se compara contra la
	-- equipada de su misma categoría.
	local statsSelectedCategory = ""
	local statsSelectedId = ""
	-- Token del debounce: invalida renders pendientes al cambiar de selección.
	local statsRenderToken = 0

	local function weaponStatsKey(category: string, weaponId: string): string
		return category .. "|" .. weaponId
	end

	local function getWeaponKillsFor(category: WeaponCategory, weaponId: string): number
		local weaponKills = Fusion.peek(DataController.WeaponKills) :: any
		if type(weaponKills) ~= "table" then
			return 0
		end
		local categoryKills = weaponKills[category]
		if type(categoryKills) ~= "table" then
			return 0
		end
		local value = tonumber(categoryKills[weaponId])
		return if value and value > 0 then math.floor(value) else 0
	end

	-- Pide los stats de un arma al server si no están cacheados ni en vuelo.
	local function requestStats(category: string, weaponId: string)
		local key = weaponStatsKey(category, weaponId)
		if weaponStatsCache[key] or pendingStatsRequests[key] then
			return
		end
		pendingStatsRequests[key] = true
		Network.WeaponStats.Request.Send({ weaponCategory = category, weaponId = weaponId })
	end

	-- Escala los stats base al nivel del arma y calcula sus fills 0..1 (las barras
	-- se normalizan contra los rangos del arsenal; reload invertido = menos mejor).
	local function scaledStatsFor(base: WeaponBaseStats, level: number): ScaledStats
		-- HitDamage y BlastDamage escalan con el mismo factor, así que aplicar la
		-- clave "HitDamage" al daño efectivo es correcto sea balístico o explosivo.
		local damage = WeaponLevelConfig.ApplyScaling("HitDamage", base.damage, level)
		local ammo = WeaponLevelConfig.ApplyScaling("AmmoCapacity", base.ammoCapacity, level)
		-- Cadencia y recarga NO escalan con nivel.
		local fireRate = base.fireRate
		local reload = base.reloadTime
		return {
			damage = damage,
			fireRate = fireRate,
			reload = reload,
			ammo = ammo,
			damageFill = if base.damageMax > 0 then damage / base.damageMax else 0,
			fireRateFill = if base.fireRateMax > 0 then fireRate / base.fireRateMax else 0,
			-- Recarga: menos es mejor → barra más llena = recarga más rápida.
			reloadFill = if reload > 0 then base.reloadMin / reload else 1,
		}
	end

	-- Bondad de la seleccionada vs la equipada en espacio de fill (los fills ya
	-- codifican dirección: más fill = mejor para todos los stats, reload incluido).
	local function dirFromFill(selFill: number, eqFill: number): string
		if selFill > eqFill + 1e-3 then
			return "up"
		elseif selFill < eqFill - 1e-3 then
			return "down"
		end
		return "equal"
	end

	local function buildStatsModel(sel: ScaledStats, eq: ScaledStats): WeaponStatsPanel.StatsModel
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
				fill = 0, -- Ammo no tiene barra
				compareFill = 0,
				delta = sel.ammo - eq.ammo,
				-- Más munición = mejor: el delta en fill equivale al signo del valor.
				dir = dirFromFill(sel.ammo, eq.ammo),
			},
		}
	end

	-- Renderiza la comparación seleccionada-vs-equipada. Pide las armas que falten
	-- (vuelve al llegar su respuesta); sólo anima cuando ambas están cacheadas.
	local function tryRenderStats()
		local category = statsSelectedCategory
		local selId = statsSelectedId
		if category == "" or selId == "" then
			return
		end

		local selBase = weaponStatsCache[weaponStatsKey(category, selId)]
		if not selBase then
			requestStats(category, selId)
			return
		end

		local eqId = getEquippedWeaponByCategory(category :: WeaponCategory)
		local eqBase = weaponStatsCache[weaponStatsKey(category, eqId)]
		if not eqBase then
			requestStats(category, eqId)
			return
		end

		local selLevel = WeaponLevelConfig.GetLevelForKills(getWeaponKillsFor(category :: WeaponCategory, selId))
		local eqLevel = WeaponLevelConfig.GetLevelForKills(getWeaponKillsFor(category :: WeaponCategory, eqId))
		weaponStatsPanel:setStats(buildStatsModel(scaledStatsFor(selBase, selLevel), scaledStatsFor(eqBase, eqLevel)))
	end

	-- Item seleccionado: no-arma ⇒ oculta el panel. Arma ⇒ debounce 0.06s y
	-- renderiza (evita ráfagas al scrollear: sólo el arma donde uno se detiene).
	local function requestWeaponStatsForItem(item: LockerCatalogItem?)
		if not item or not isWeaponCategory(item.Category) then
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
				return -- la selección cambió durante el debounce
			end
			tryRenderStats()
		end)
	end

	janitor:Add(Network.WeaponStats.Response.Listen(function(response: any)
		local key = weaponStatsKey(response.weaponCategory, response.weaponId)
		pendingStatsRequests[key] = nil
		if not response.success then
			return
		end
		weaponStatsCache[key] = {
			damage = response.damage,
			fireRate = response.fireRate,
			reloadTime = response.reloadTime,
			ammoCapacity = response.ammoCapacity,
			damageMax = response.damageMax,
			fireRateMax = response.fireRateMax,
			reloadMin = response.reloadMin,
		}
		-- Re-render sólo si el arma recibida es la seleccionada o su equipada
		-- (su baseline de comparación) — evita renders redundantes.
		if statsSelectedCategory ~= "" then
			local selKey = weaponStatsKey(statsSelectedCategory, statsSelectedId)
			local eqKey = weaponStatsKey(statsSelectedCategory, getEquippedWeaponByCategory(statsSelectedCategory :: WeaponCategory))
			if key == selKey or key == eqKey then
				tryRenderStats()
			end
		end
	end), true)

	catalog = LockerCatalog.new(ItemsConfig, ITEMS_CONFIG_BY_NAV, DEFAULT_NAV_THUMBNAIL, getRarityRank, isItemOwned)
	local updateActionFrameForSelected: () -> ()
	local populateMainContentForNavItem: (LockerCategoryKey, string, string?, boolean?) -> ()
	local clearItemGrid: () -> ()
	local syncWeaponPreviewsFromLoadout: () -> ()

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
			end
			updateActionFrameForSelected()
		end,
		onOwnedItemActivated = function(item: LockerCatalogItem)
			local weaponCategoryForEquip, weaponIdForEquip = getWeaponWrapRequestContext(item.Category)

			local equipAction = {
				kind = "equip",
				item = item,
			}
			pendingShopAction = equipAction
			grid:RefreshVisibleState(false)
			task.delay(SHOP_REQUEST_TIMEOUT, function()
				if pendingShopAction == equipAction then
					pendingShopAction = nil
					grid:RefreshVisibleState(false)
				end
			end)
			Network.Shop.EquipItem.Send({
				category = item.Category,
				itemId = item.id,
				weaponCategory = weaponCategoryForEquip,
				weaponId = weaponIdForEquip,
			})
		end,
	})
	janitor:Add(grid, "Destroy")

	local function getPreferredSelectedQualifiedId(categoryKey: LockerCategoryKey, navKey: string, selectedQualifiedId: string?): string?
		if selectedQualifiedId ~= nil then
			return selectedQualifiedId
		end

		-- El nav del body se llama "Body" pero su categoría es "Outfits" (única
		-- traducción no-identidad nav→categoría, ver LockerConfig.ItemsConfigByNav).
		-- Hay que comparar contra el NAV key "Body", no contra LockerCategory.OUTFITS
		-- ("Outfits") — por eso antes nunca preseleccionaba el body equipado y el
		-- grid caía al primer item (Default).
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

	local function getKillProgressForWeaponWrap(weaponCategory: WeaponCategory, weaponId: string, _wrapKey: string): number
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
			-- Filtro por sub-vista de Nav1:
			--   Maestry → desafíos de kills del arma (desbloqueados o no).
			--   Owned   → sólo lo que posees en el inventario.
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
					wrapItem.KillProgress = getKillProgressForWeaponWrap(targetWeaponCategory, targetWeaponId, item.id)
				elseif isChallenge and isOwned then
					-- Desafío ya desbloqueado (visible en Maestry/Owned): "UNLOCKED".
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

	-- `stagger` indica que la repoblación viene de una interacción de usuario
	-- (cambio de categoría/nav, abrir locker) — los cards entran en orden con
	-- UIScale 0→1. Las llamadas pasivas (observers de inventario/loadout) no
	-- pasan stagger para evitar re-animar al comprar/equipar.
	populateMainContentForNavItem = function(categoryKey: LockerCategoryKey, navKey: string, selectedQualifiedId: string?, stagger: boolean?)
		local previousNavKey = selectedNavKey
		selectedNavKey = navKey
		updateWeaponFocusCategory()
		if categoryKey ~= LockerMainCategory.ARSENAL or previousNavKey ~= navKey then
			restoreEquippedWeaponPreviews()
		end

		if navKey == LockerCategory.KILL_EFFECTS and previousNavKey ~= LockerCategory.KILL_EFFECTS then
			spawnKillEffectDummy()
			suppressNextKillEffectPreview = true
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
			-- Arma poseída: el ActionFrame se oculta y se muestra el botón Wraps para
			-- personalizar sus wraps. Otros items poseídos: nada.
			local showWraps = isWeaponCategory(selectedItem.Category) and not isWrapsMode
			wrapsButton.Visible = showWraps
			if showWraps then
				-- Indicator: oculto si no hay wraps (sin contar Default); si hay, su número.
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
			-- No comprables con cash → sin ActionFrame de compra:
			--   · wraps de desafío de kills → se desbloquean por progreso.
			--   · wraps sin precio (Price 0 / CanPurchase false).
			wrapsButton.Visible = false
			hideActionFrame()
		else
			wrapsButton.Visible = false
			showActionFrameForItem(selectedItem)
		end
	end

	local function refreshGridSelectionState()
		grid:RefreshVisibleState()
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
		hideActionFrame()

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
				-- Si ya estamos en esta nav, no repoblar (clic sobre la nav activa).
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

		if nav2Stagger then
			nav2Stagger:play()
		end
	end

	clearItemGrid = function()
		grid:Clear()
		restoreEquippedWeaponPreviews()
		destroyKillEffectDummy()
	end

	local function selectItem(selectedKey: LockerCategoryKey)
		if selectedMainCategory == selectedKey and selectedNavKey ~= nil then
			return
		end

		setSelectedMainCategory(selectedKey)
		cameraController:setTargetPartName(CAMERA_TARGET_BY_MAIN_CATEGORY[selectedKey])
		if selectedKey ~= LockerMainCategory.ARSENAL then
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

	-- Tabs de categoría del locker normal. Cada uno cambia la main-category; el tab
	-- activo lo marca `selectedMainCategory` (nil al abrir → lo fija selectItem).
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

	-- El nivel ya no se pinta aquí: el LevelContainer del Locker desapareció y el
	-- HUD copiado del Menu solo trae monedas.
	local function updateStatsUi()
		local stats = getCurrentStats()
		if cashValueLabel then
			cashValueLabel.Text = UIUtils.formatCashAmount(stats.Cash)
		end

		if gemsValueLabel then
			-- `or 0` cubre el perfil que aún no pasó por Reconcile (igual que MenuController).
			gemsValueLabel.Text = UIUtils.formatCashAmount(stats.Gems or 0)
		end
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
			-- Los dos catálogos tienen la misma forma salvo el campo de cantidad,
			-- así que solo cambia de dónde se lee el importe del pack.
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

		-- Condiciones de compra: nivel, inventario, wraps de desafío y saldo (si
		-- falta saldo se ofrece el pack que mejor encaja en vez de comprar).
		-- Cada rechazo avisa por toast: el botón de compra sigue visible cuando
		-- el ítem está bloqueado, así que sin notificación el click no da feedback.
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
				-- Los wraps de desafío de kills no se compran.
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
			-- Snapshot de la categoría/nav al momento de comprar: si el usuario
			-- navega a otra vista durante el timeout, repoblar la vista ACTUAL
			-- forzando un qualifiedId que probablemente no existe allí es incorrecto.
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

		-- Handler de compra: idéntico para el botón de ambos ActionFrame (actúa sobre
		-- selectedCatalogItem, no sobre el frame), así que se comparte.
		local function onPurchaseActivated()
			local item = selectedCatalogItem
			if item then
				executePurchase(item)
			end
		end

		-- Wiring de hover/escala/click + handler de compra de un botón de acción.
		-- Se aplica al ActionBtn de AMBOS frames (ActionFrame y WeaponActionFrame).
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
				local targetScale = if purchaseButtonIsHovered and canUseHoverAnimations
					then PURCHASE_BUTTON_HOVER_SCALE
					else PURCHASE_BUTTON_DEFAULT_SCALE
				tweenScale(targetScale, PURCHASE_BUTTON_HOVER_TWEEN_INFO)

				local targetStrokeColor = if purchaseButtonIsHovered and canUseHoverAnimations then STROKE_WHITE else STROKE_DEFAULT
				tweenStroke(targetStrokeColor, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
			end), "Disconnect")

			janitor:Add(button.Activated:Connect(onPurchaseActivated), "Disconnect")
		end

		setupActionButton(actionPanel.button)
		setupActionButton(weaponActionPanel.button)
	end

	-- Sub-pestañas dentro de wraps: Maestry (desafíos) / Owned.
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
				Confetti.Rain(lockerFrame)
			end
		else
			-- El server ya manda el motivo en inglés; el fallback cubre un payload
			-- sin mensaje (p.ej. un rechazo nuevo que no lo rellene).
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
			updateStatsUi()
			if not isOpen then
				dirtyWhileClosed = true
				return
			end
			updateActionFrameForSelected()
		end), true)

		local weaponKillsObserver = fusionScope:Observer(DataController.WeaponKills)
		janitor:Add(weaponKillsObserver:onBind(function()
			if not isOpen then
				dirtyWhileClosed = true
				return
			end
			-- Si el arma seleccionada (o su equipada de referencia) subió de nivel
			-- por kills, re-escalar y re-animar (los valores base están cacheados).
			tryRenderStats()
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

	-- Al cerrar, la cámara vuelve al lobby con un travelling; en teardown del feature
	-- se restaura al instante (animateCamera nil/false).
	local function restoreLockerSceneState(animateCamera: boolean?)
		restoreEquippedWeaponPreviews()
		-- Soltar el preview del personaje del lobby: vuelve a mostrar lo equipado y
		-- LobbyFeature retoma el control de los cambios de loadout.
		lobbyCharacter:endPreview()
		cameraController:restore(animateCamera)
		CameraLock.release("locker")
		setMenuVisibleInstant(true)
	end

	-- ── Stagger de aparición de los items de Nav ─────────────
	-- Dos controladores separados: nav1 se re-anima al abrir el locker y al alternar
	-- entre el locker normal y el modo wraps (setWrapsMode); nav2 se re-anima cada vez
	-- que se repuebla (cambio de categoría en nav1). El tab activo depende del modo:
	-- wrapsView en modo wraps, selectedMainCategory en el locker normal.
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

	local function openLockerGui()
		if isOpen then
			return
		end

		isOpen = true
		CameraLock.acquire("locker")
		-- Tomar el preview del personaje del lobby: a partir de aquí el locker
		-- controla lo que se muestra (selección sin equipar) y LobbyFeature deja
		-- de sincronizarlo al loadout hasta que se cierre.
		lobbyCharacter:beginPreview()
		if dirtyWhileClosed then
			dirtyWhileClosed = false
			rebuildOwnedLookup()
			rebuildEquippedLookup()
		end
		-- Reaplicar el BODY equipado primero (antes que cara/hat): beginPreview no
		-- reconstruye el modelo, así que si el preview del lobby se construyó antes
		-- de llegar el loadout (outfit nil → body por defecto), al abrir mostraría
		-- un body no equipado. applyOutfit es no-op si ya coincide. El orden importa:
		-- reconstruir el body recrea los appliers, y cara/hat se aplican sobre el
		-- modelo nuevo.
		applyEquippedBodyPreview()
		applyEquippedFacePreview()
		applyEquippedHatPreview()
		hideActionFrame()
		-- Construir los tabs de categoría de Nav1 (Character/Effects/Weapons) antes de
		-- seleccionar la primera categoría, para que nav1TabController pueda marcarla.
		populateMainCategoryNav()
		selectItem(LockerMainCategory.STYLE)
		-- Abrimos en Character: la cámara parte de la del lobby/menú y se desplaza
		-- (travelling) hasta Workspace.Cameras.character.
		cameraController:apply()
		lockerFrame.Visible = true
		setMenuVisibleInstant(false)
		ScenePresetController.applyFrom(lockerFolder)
		nav1Stagger:play()
		if nav2Stagger then nav2Stagger:play() end
	end

	local function closeLockerGui()
		if not isOpen then
			return
		end

		isOpen = false
		selectedMainCategory = nil
		selectedNavKey = nil
		selectedCatalogItem = nil
		statsSelectedCategory = ""
		statsSelectedId = ""
		weaponStatsPanel:hide()
		hideActionFrame()
		restoreLockerSceneState(true)
		setWrapsMode(false)
		-- Liberar las cards del grid (cards pooled, reabrir sigue siendo barato) para
		-- que las texturas de wrap animadas dejen de actualizarse cada Heartbeat.
		clearItemGrid()
		destroyKillEffectDummy()
		lockerFrame.Visible = false
		ScenePresetController.applyLobbyOrRestore("[Locker]")
	end

	if lockerBtn then
		janitor:Add(lockerBtn.MouseButton1Click:Connect(openLockerGui), "Disconnect")
	end
	janitor:Add(closeBtn.MouseButton1Click:Connect(function()
		if isWrapsMode then
			setWrapsMode(false)
			local previousNavKey = wrapsTargetWeaponCategory or WeaponCategoryMod.MAIN

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
	-- El click de los tabs de categoría de Nav1 lo engancha populateNav1 (botones
	-- dinámicos): ya no hay botones estáticos que conectar aquí.

	janitor:Add(lockerFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if not lockerFrame.Visible and isOpen then
			isOpen = false
			restoreLockerSceneState(true)
			ScenePresetController.applyLobbyOrRestore("[Locker]")
		end
	end), "Disconnect")

	janitor:Add(function()
		if isOpen then
			restoreLockerSceneState()
			-- Igual que closeLockerGui: el preset del Locker no puede sobrevivir al
			-- feature, o el lobby se queda con su lighting (y su DoF).
			ScenePresetController.applyLobbyOrRestore("[Locker]")
		end
	end, true)

	if autoOpenOnStart then
		task.defer(openLockerGui)
	end

	return janitor
end

return LockerFeature
