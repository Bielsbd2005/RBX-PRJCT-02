--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
local WeaponPreviewController = require(script:WaitForChild("WeaponPreviewController"))
local LockerWeaponStats = require(script:WaitForChild("LockerWeaponStats"))
local LockerWrapsView = require(script:WaitForChild("LockerWrapsView"))
local LockerNavStrip = require(script:WaitForChild("LockerNavStrip"))
local LockerWrapInfo = require(script:WaitForChild("LockerWrapInfo"))
local CharacterRotateController = require(script:WaitForChild("CharacterRotateController"))
local LockerInventoryState = require(script:WaitForChild("LockerInventoryState"))
local LockerShopRequests = require(script:WaitForChild("LockerShopRequests"))
local LockerActionPanel = require(script:WaitForChild("LockerActionPanel"))
local LockerKillEffectPreview = require(script:WaitForChild("LockerKillEffectPreview"))
local MenuHover = require(Client.core.ui.MenuHover)
local NavStaggerController = require(Client.core.ui.NavStaggerController)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local LockerConfig = require(Shared.constants.LockerConfig)
local WeaponCategoryMod = require(Shared.constants.WeaponCategory)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local LockerCategory = require(Shared.constants.LockerCategory)
local LockerMainCategory = require(Shared.constants.LockerMainCategory)
local DataController = require(Client.core.data.DataController)
local Confetti = require(Client.core.ui.Confetti)
local ScreenFade = require(Client.core.ui.ScreenFade)
local GameSounds = require(Client.core.ui.GameSounds)

local LockerFeature = {}

local DEFAULT_NAV_THUMBNAIL = "rbxasset://textures/ui/GuiImagePlaceholder.png"
type LockerCategoryKey = LockerMainCategory.LockerMainCategory

type LockerNavItemDefinition = {
	key: string,
	title: string,
	thumbnail: string,
}

type LockerCatalogItem = LockerCatalog.LockerCatalogItem

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
-- Entrar/salir de Arsenal con travelling de cámara; false = fundido a negro.
local ARSENAL_CAMERA_TRAVEL = true
-- Más largo que el travelling Character↔Effects: la cámara de armas queda lejos.
local ARSENAL_TRAVEL_TWEEN_INFO = TweenInfo.new(0.9, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut)
-- Margen para que replique un nodo de la GUI. Solo se consume si el nodo NO está
-- ya (búsqueda inmediata primero).
local GUI_NODE_TIMEOUT = 5

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

local function getRarityRank(rarity: string): number
	return RARITY_RANK[rarity] or 0
end

-- Con más de 200 locales vivos en esta función el locker no carga ("Out of local
-- registers"). Lo nuevo va en un módulo de features/locker; medir con
-- tools/luau/MeasureLocals.luau.
function LockerFeature.start(menuController: any, options: { autoOpen: boolean? }?): any
	local janitor = Janitor.new()
	local fusionScope = Fusion.scoped(Fusion)
	janitor:Add(function()
		Fusion.doCleanup(fusionScope)
	end, true)
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	-- El preview de outfit/cara/hat se hace sobre el personaje del lobby
	-- (Workspace.Lobby.Spawners.P1), singleton compartido con LobbyFeature.
	local lobbyCharacter = LobbyCharacterPreview.get()

	local lockerFolder = Workspace:WaitForChild("Locker")

	-- Lighting por atributo: el look lo lleva Workspace.Locker (LightingPreset="Locker")
	-- y la vuelta usa ScenePresetController.applyLobbyOrRestore (como el BattlePass).
	-- Ancla única del preview de armas (ver WeaponPreviewController).
	local weaponSpawn = lockerFolder:FindFirstChild("WeaponSpawn")
	if not weaponSpawn then
		warn("[Locker] Ancla de arma no encontrada: Workspace.Locker.WeaponSpawn")
	end
	-- Stats del arma: SurfaceGui del mundo bajo Workspace.Locker.Stats.
	local weaponStatsAnchor = lockerFolder:WaitForChild("Stats", 10)
	-- Tarjeta de banner en el mundo (Workspace.Locker.Banner.Part.Card): solo se
	-- enciende en Effects → Banners.
	local bannerPreview = BannerPreviewer.new(lockerFolder:WaitForChild("Banner", 10))
	janitor:Add(bannerPreview, "Destroy")
	if not weaponStatsAnchor then
		warn("[Locker] Panel de stats no encontrado: Workspace.Locker.Stats")
	end

	local container = menuController:getGui():FindFirstChild("Container")
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

	-- Los casts valen tras hasMissingNodes(): antes pueden ser nil (expectNode acepta raíz nil).
	local nav = expectNode(lockerFrame, "Nav2") :: Instance
	local navTemplate = expectNode(nav, "Template") :: GuiButton
	local nav1 = expectNode(lockerFrame, "Nav1") :: Instance
	local closeBtn = expectNode(nav1, "CloseBtn") :: GuiButton
	-- Los tabs de Nav1 se clonan de Nav1.Template según el modo: normal
	-- Character/Effects/Weapons (Style/Effects/Arsenal) o wraps Maestry/Owned. El Name
	-- de cada botón clonado ES la key (nav1TabController y nav1Stagger indexan por Name).
	local nav1Template = expectNode(nav1, "Template") :: GuiButton
	local itemGrid = expectNode(lockerFrame, "ScrollingFrame") :: ScrollingFrame
	-- Única plantilla del grid, también en la vista de wraps (trae ViewportFrame para
	-- el preview 3D; el progreso de desafío va como texto en Status.Value).
	local itemGridTemplate = expectNode(itemGrid, "ItemTemplate") :: GuiObject
	-- Vista de banners (Effects → Banners): ScrollingFrame hermano de la grid
	-- (Locker.Content.Banners) que la sustituye mientras esa nav está activa.
	local bannersFrame = expectNode(if itemGrid then itemGrid.Parent else nil, "Banners") :: ScrollingFrame
	local bannersTemplate = expectNode(bannersFrame, "Template") :: ImageButton
	local actionFrameNode = expectNode(lockerFrame, "ActionFrame")
	-- Botón separado del ActionFrame para personalizar los wraps del arma poseída.
	local wrapsButton = expectNode(lockerFrame, "Wraps") :: GuiButton
	-- Indicator: nº de wraps poseídos para el arma seleccionada (sin contar Default).
	local wrapsIndicator = expectNode(wrapsButton, "Indicator") :: TextLabel

	if hasMissingNodes() then
		return janitor
	end

	-- Asignado junto a la tienda, más abajo: el panel se monta antes para validar sus nodos.
	local onPurchaseActivated: () -> ()
	local actionPanel = LockerActionPanel.new({
		frame = actionFrameNode :: GuiObject,
		findNode = expectNode,
		janitor = janitor,
		canUseHoverAnimations = UserInputService.MouseEnabled and not UserInputService.TouchEnabled,
		onActivated = function()
			onPurchaseActivated()
		end,
	})
	if not actionPanel or hasMissingNodes() then
		return janitor
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
	-- Lo mismo para el arma en Arsenal; weaponPreviewController se crea más abajo.
	local weaponPreviewController: any = nil
	local weaponRotate = CharacterRotateController.new({
		name = "LockerWeaponRotate",
		playerGui = playerGui,
		uiGui = uiGui,
		onYawChanged = function(yaw: number)
			if weaponPreviewController then
				weaponPreviewController:setUserYaw(yaw)
			end
		end,
	})
	janitor:Add(weaponRotate, "Destroy")
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

	local selectedMainCategory: LockerCategoryKey? = nil
	local selectedCatalogItem: LockerCatalogItem? = nil
	local canUseHoverAnimations = UserInputService.MouseEnabled and not UserInputService.TouchEnabled
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
	local sharedWeaponAssets = Shared:WaitForChild("Locker"):WaitForChild("weapons")
	local catalog: any = nil
	local grid: any = nil

	local isWrapsMode = false
	-- Sub-vista de la pantalla de wraps (tabs de Nav1 en modo wraps):
	--   "maestry" → desafíos de maestría del arma (WrapMastery)
	--   "owned"   → wraps que posees en el inventario
	local wrapsView = "owned"

	local wrapInfo = janitor:Add(LockerWrapInfo.new(lockerFrame), "Destroy")

	-- El HUD de monedas (LobbyStats) es compartido y por defecto sigue al Menu, que
	-- el Locker esconde. Con el Locker abierto manda él: visible salvo en la vista de
	-- wraps. Al cerrarse devuelve el control al Menu (nil).
	local function syncSharedStatsHud()
		menuController:setStatsHudOverride(if isOpen then not isWrapsMode else nil)
	end

	local function setWrapsMode(enabled: boolean)
		isWrapsMode = enabled
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

	wrapsButton.Visible = false

	local inventory = LockerInventoryState.new(function()
		if catalog then
			catalog:InvalidateSorted()
		end
	end)
	local function getCurrentLevel(): number
		return inventory:getLevel()
	end

	local killEffectPreview = LockerKillEffectPreview.new({
		lobbyCharacter = lobbyCharacter,
		cameraController = cameraController,
		lockerFolder = lockerFolder,
		dummySpawn = lockerFolder:WaitForChild("DummySpawn"),
		dummyTemplate = Shared:WaitForChild("Bodies"):WaitForChild("KillEffectDummy") :: Model,
	})
	janitor:Add(killEffectPreview, "Destroy")

	local function applyEquippedFacePreview()
		lobbyCharacter:applyFaceId(inventory:getEquipped(LockerCategory.FACES))
	end

	local function applyEquippedHatPreview()
		lobbyCharacter:applyHatId(inventory:getEquipped(LockerCategory.HATS))
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
		lobbyCharacter:applyOutfit(inventory:getEquipped(LockerCategory.OUTFITS))
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
			targetOutfitId = inventory:getEquipped(LockerCategory.OUTFITS)
		end
		lobbyCharacter:applyOutfit(targetOutfitId, lockedLevel)
	end

	-- WeaponPreviewController se inicializa después de las funciones que necesita como dependencia.

	weaponPreviewController = WeaponPreviewController.new({
		weaponSpawn = weaponSpawn :: any,
		sharedWeaponAssets = sharedWeaponAssets,
		itemsConfig = ItemsConfig,
		getCurrentLevel = getCurrentLevel,
		getCurrentLoadout = function()
			return inventory:getLoadout()
		end,
		getEquippedItemByCategory = function(category: string): string?
			return inventory:getEquipped(category)
		end,
		isOwned = function(category: string, itemId: string): boolean
			return inventory:isOwned(category, itemId)
		end,
		ownsWeaponWrap = function(category: string, weaponId: string, wrapId: string): boolean
			return inventory:ownsWrap(category, weaponId, wrapId)
		end,
		uiGui = uiGui,
	})
	janitor:Add(weaponPreviewController, "Destroy")

	local function updateWeaponFocusCategory()
		weaponPreviewController:updateFocusCategory(selectedMainCategory, selectedNavKey, inventory:getWrapsTargetCategory())
	end

	local function applySelectedWeaponPreview(item: any, animate: boolean?)
		weaponPreviewController:applySelected(item, animate)
	end

	local function restoreEquippedWeaponPreviews()
		weaponPreviewController:restoreEquipped()
	end

	local function restoreEquippedWeaponPreviewForCategory(category: string)
		weaponPreviewController:restoreEquippedFor(category)
	end

	local nav1Strip = janitor:Add(LockerNavStrip.new({
		container = nav1,
		template = nav1Template,
		keep = { closeBtn },
		canUseHoverAnimations = canUseHoverAnimations,
	}), "Destroy")
	local nav2Strip = janitor:Add(LockerNavStrip.new({
		container = nav,
		template = navTemplate,
		canUseHoverAnimations = canUseHoverAnimations,
	}), "Destroy")

	local function setSelectedMainCategory(categoryKey: LockerCategoryKey)
		selectedMainCategory = categoryKey
		updateWeaponFocusCategory()
		nav1Strip:setActive(categoryKey)
	end

	local weaponStats = janitor:Add(LockerWeaponStats.new({
		anchor = weaponStatsAnchor,
		janitor = janitor,
		-- Oculto en Character/Effects y en la vista de wraps (que zooma sobre la mesa).
		isVisibleContext = function(): boolean
			return isOpen and not isWrapsMode and selectedMainCategory == LockerMainCategory.ARSENAL
		end,
		getEquippedWeapon = function(category: WeaponCategory): string
			return inventory:getEquippedWeapon(category)
		end,
	}), "Destroy")

	catalog = LockerCatalog.new(ItemsConfig, ITEMS_CONFIG_BY_NAV, DEFAULT_NAV_THUMBNAIL, getRarityRank, function(item)
		return inventory:isItemOwned(item)
	end)
	local updateActionFrameForSelected: () -> ()
	local populateMainContentForNavItem: (LockerCategoryKey, string, string?, boolean?) -> ()
	local clearItemGrid: () -> ()
	local syncWeaponPreviewsFromLoadout: () -> ()
	local bannersView: any = nil

	-- Un perfil sin Loadout.Banner lleva el Default.
	local function getShownBannerId(): string
		return inventory:getEquipped(LockerCategory.BANNERS) or ItemDefaults.ITEM_ID
	end

	local function refreshBanners()
		if not bannersView:IsVisible() then
			return
		end
		bannersView:Refresh()
		bannerPreview:setContent(player.Name, getCurrentLevel(), getShownBannerId())
	end

	local shopRequests = LockerShopRequests.new({
		inventory = inventory,
		getNav = function()
			return selectedMainCategory, selectedNavKey
		end,
		repopulate = function(category, navKey, qualifiedId)
			populateMainContentForNavItem(category :: LockerCategoryKey, navKey, qualifiedId)
		end,
		refreshSelection = function()
			grid:RefreshVisibleState()
			refreshBanners()
		end,
		onPurchased = function()
			GameSounds.play(GameSounds.Purchase)
			Confetti.Rain(lockerFrame)
		end,
	})
	janitor:Add(shopRequests, "Destroy")

	grid = LockerGrid.new(itemGrid, { default = itemGridTemplate, wraps = itemGridTemplate }, canUseHoverAnimations, {
		canInteract = function(): boolean
			return not shopRequests:isBusy()
		end,
		isItemOwned = function(item: LockerCatalogItem): boolean
			return inventory:isItemOwned(item)
		end,
		isItemEquipped = function(item: LockerCatalogItem): boolean
			return inventory:isItemEquipped(item)
		end,
		getCurrentLevel = getCurrentLevel,
		onSelectionChanged = function(item: LockerCatalogItem?, byUser: boolean?)
			selectedCatalogItem = item
			if item and WeaponCategoryMod.isValid(item.Category) then
				local selectedWeaponCategory = item.Category :: WeaponCategory
				inventory:setWrapsTarget(selectedWeaponCategory, item.id)
				updateWeaponFocusCategory()
			end
			applySelectedBodyPreview(item)
			applySelectedFacePreview(item)
			applySelectedHatPreview(item)
			applySelectedWeaponPreview(item, byUser)
			weaponStats:request(item)
			if item and item.Category == LockerCategory.KILL_EFFECTS then
				-- Solo por clic: no al auto-seleccionar al entrar ni al refrescar tras equipar.
				if byUser then
					killEffectPreview:previewKillEffect(item.id)
				end
			elseif item and item.Category == LockerCategory.EMOTES then
				killEffectPreview:previewEmote(item.id)
			end
			updateActionFrameForSelected()
		end,
		onOwnedItemActivated = function(item: LockerCatalogItem)
			shopRequests:requestEquip(item)
		end,
	})
	janitor:Add(grid, "Destroy")

	bannersView = LockerBanners.new(bannersFrame, bannersTemplate, itemGrid, {
		canInteract = function(): boolean
			return not shopRequests:isBusy()
		end,
		isItemEquipped = function(item: LockerCatalogItem): boolean
			return getShownBannerId() == item.id
		end,
		onActivated = function(item: LockerCatalogItem)
			shopRequests:requestEquip(item)
		end,
	})
	janitor:Add(bannersView, "Destroy")

	-- Banners poseídos, Default primero y luego por rareza. Los del pase ya llegan
	-- filtrados por el catálogo; el filtro de posesión cubre los no comprables.
	local function getBannerItems(): { LockerCatalogItem }
		local items = {} :: { LockerCatalogItem }
		for _, item in catalog:GetItems(LockerMainCategory.EFFECTS, LockerCategory.BANNERS) do
			if item.id == ItemDefaults.ITEM_ID or inventory:isItemOwned(item) then
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

		-- Nav→categoría vía ItemsConfigByNav: el nav "Body" es la categoría "Outfits".
		if categoryKey ~= LockerMainCategory.ARSENAL then
			local navCategory = (LockerConfig.ItemsConfigByNav :: any)[categoryKey][navKey] :: string?
			local loadoutSlot = if navCategory then CATEGORY_TO_LOADOUT_SLOT[navCategory] else nil
			if navCategory and loadoutSlot then
				local equippedId = inventory:getEquipped(navCategory)
				if equippedId then
					return LockerConfig.makeQualifiedId(navCategory, equippedId)
				end
			end
		end

		if categoryKey == LockerMainCategory.ARSENAL and WeaponCategoryMod.isValid(navKey) then
			local weaponCategory = navKey :: WeaponCategory
			local equippedWeapon = inventory:getEquippedWeapon(weaponCategory)
			inventory:setWrapsTarget(weaponCategory, equippedWeapon)
			updateWeaponFocusCategory()
			return LockerConfig.makeQualifiedId(weaponCategory, equippedWeapon)
		end

		if categoryKey == LockerMainCategory.ARSENAL and navKey == LockerCategory.WEAPON_WRAPS then
			local loadout = inventory:getLoadout()
			local weaponId = inventory:getWrapsTargetWeaponId(loadout)
			return LockerConfig.makeQualifiedId(LockerCategory.WEAPON_WRAPS, inventory:resolveEquippedWrap(loadout, inventory:getWrapsTargetCategory(), weaponId))
		end

		return nil
	end

	-- `stagger`: la repoblación viene de una interacción de usuario y las cards entran
	-- en orden. Los observers de inventario/loadout no lo pasan, para no re-animar al
	-- comprar/equipar.
	populateMainContentForNavItem = function(categoryKey: LockerCategoryKey, navKey: string, selectedQualifiedId: string?, stagger: boolean?)
		local previousNavKey = selectedNavKey
		if previousNavKey ~= navKey then
			shopRequests:flushEquips()
		end
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
			killEffectPreview:destroyDummy()
		elseif navKey == LockerCategory.EMOTES and previousNavKey ~= LockerCategory.EMOTES then
			killEffectPreview:spawnEmoteDummy()
		end

		local preferredSelectedQualifiedId = getPreferredSelectedQualifiedId(categoryKey, navKey, selectedQualifiedId)

		local items = catalog:GetItems(categoryKey, navKey)
		local isWrapsView = categoryKey == LockerMainCategory.ARSENAL and navKey == LockerCategory.WEAPON_WRAPS
		if isWrapsView then
			items = LockerWrapsView.build(items, inventory, wrapsView, getRarityRank)
		end

		-- Hat es el único slot opcional: sin hat equipado no se preselecciona ninguno,
		-- o se previsualizaría el primero de la grid como si estuviera puesto.
		local allowEmptySelection = navKey == LockerCategory.HATS
		grid:Populate(items, preferredSelectedQualifiedId, if isWrapsView then "wraps" else "default", allowEmptySelection)
		if stagger then
			grid:PlayStagger()
		end
	end

	updateActionFrameForSelected = function()
		local selectedItem = selectedCatalogItem
		wrapInfo:show(if isWrapsMode and wrapsView == "maestry" then selectedItem else nil, inventory:getWrapsTargetCategory())
		if not selectedItem then
			wrapsButton.Visible = false
			actionPanel:hide()
			return
		end

		if inventory:isItemOwned(selectedItem) then
			-- Arma poseída: sin ActionFrame, con botón Wraps. Otros items poseídos: nada.
			local showWraps = WeaponCategoryMod.isValid(selectedItem.Category) and not isWrapsMode
			wrapsButton.Visible = showWraps
			if showWraps then
				local ownedWrapsCount = inventory:countOwnedWraps(selectedItem.Category :: WeaponCategory, selectedItem.id)
				wrapsIndicator.Visible = ownedWrapsCount > 0
				if ownedWrapsCount > 0 then
					wrapsIndicator.Text = tostring(ownedWrapsCount)
				end
			end
			actionPanel:hide()
		elseif (selectedItem.KillGoal ~= nil and selectedItem.KillGoal > 0)
			or (selectedItem.Category == LockerCategory.WEAPON_WRAPS
				and not (selectedItem.CanPurchase and selectedItem.Price > 0)) then
			-- No comprables con cash: wraps de desafío (se desbloquean por progreso) y
			-- wraps sin precio.
			wrapsButton.Visible = false
			actionPanel:hide()
		else
			wrapsButton.Visible = false
			actionPanel:show(selectedItem, getCurrentLevel())
		end
	end

	local function refreshGridSelectionState()
		grid:RefreshVisibleState()
		refreshBanners()
	end

	syncWeaponPreviewsFromLoadout = function()
		local selectedItem = selectedCatalogItem
		if not selectedItem or not WeaponCategoryMod.isValid(selectedItem.Category) then
			restoreEquippedWeaponPreviews()
			return
		end

		local selectedCategory = selectedItem.Category :: WeaponCategory
		local otherCategory = if selectedCategory == WeaponCategoryMod.MAIN then WeaponCategoryMod.SPECIAL else WeaponCategoryMod.MAIN
		restoreEquippedWeaponPreviewForCategory(otherCategory)
		applySelectedWeaponPreview(selectedItem)
	end

	local function populateNavButtons(categoryKey: LockerCategoryKey)
		clearItemGrid()

		local definitions = {} :: { LockerNavStrip.TabDefinition }
		for _, item in LOCKER_NAV_ITEMS[categoryKey] do
			local navKey = item.key
			table.insert(definitions, {
				key = navKey,
				title = item.title,
				thumbnail = item.thumbnail,
				onActivated = function()
					if selectedNavKey == navKey then
						return
					end
					nav2Strip:setActive(navKey)
					populateMainContentForNavItem(categoryKey, navKey, nil, true)
				end,
			})
		end
		nav2Strip:populate(definitions)

		local first = definitions[1]
		if first then
			nav2Strip:setActive(first.key)
			populateMainContentForNavItem(categoryKey, first.key, nil, true)
		end

		nav2Stagger:play()
	end

	clearItemGrid = function()
		grid:Clear()
		killEffectPreview:destroyDummy()
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
		weaponRotate:setEnabled(selectedKey == LockerMainCategory.ARSENAL)
		local cameraTarget = CAMERA_TARGET_BY_MAIN_CATEGORY[selectedKey]
		-- Character ↔ Effects: cámaras cercanas, travelling en vez de negro. Con un
		-- fundido en vuelo la cámara aún no ha llegado a la pestaña anterior, así que
		-- ese caso sigue yendo a negro.
		local isCharacterEffectsSwap = not pendingCameraFade
			and (
				(previousKey == LockerMainCategory.STYLE and selectedKey == LockerMainCategory.EFFECTS)
				or (previousKey == LockerMainCategory.EFFECTS and selectedKey == LockerMainCategory.STYLE)
			)
		local isArsenalTravel = ARSENAL_CAMERA_TRAVEL
			and not pendingCameraFade
			and previousKey ~= nil
			and (previousKey == LockerMainCategory.ARSENAL or selectedKey == LockerMainCategory.ARSENAL)
		if isArsenalTravel then
			cameraController:setTargetPartName(cameraTarget, false, ARSENAL_TRAVEL_TWEEN_INFO)
		elseif withoutFade or isCharacterEffectsSwap then
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
		actionPanel:hide()
		selectItem(selectedKey)
	end

	-- El tab activo lo marca `selectedMainCategory` (nil al abrir → lo fija selectItem).
	populateMainCategoryNav = function()
		local definitions = {} :: { LockerNavStrip.TabDefinition }
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
		nav1Strip:populate(definitions, selectedMainCategory)
	end

	itemGridTemplate.Visible = false
	onPurchaseActivated = function()
		local item = selectedCatalogItem
		if item then
			shopRequests:purchase(item)
		end
	end

	local function showWrapsView(view: string)
		if not isWrapsMode or wrapsView == view then
			return
		end
		wrapsView = view
		nav1Strip:setActive(view)
		populateMainContentForNavItem(LockerMainCategory.ARSENAL, LockerCategory.WEAPON_WRAPS, nil, true)
	end

	-- Tabs de Nav1 en modo wraps. La key de cada tab ES el valor de `wrapsView`.
	populateWrapsViewNav = function()
		local definitions = {} :: { LockerNavStrip.TabDefinition }
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
		nav1Strip:populate(definitions, wrapsView)
	end

	do
		janitor:Add(wrapsButton.Activated:Connect(function()
			local item = selectedCatalogItem
			if not item or shopRequests:isBusy() then
				return
			end

			if not inventory:isItemOwned(item) or not WeaponCategoryMod.isValid(item.Category) then
				return
			end

			local selectedWeaponCategory = item.Category :: WeaponCategory
			inventory:setWrapsTarget(selectedWeaponCategory, item.id)
			updateWeaponFocusCategory()

			-- Arrancar en Owned ANTES de setWrapsMode: populateWrapsViewNav usa
			-- `wrapsView` como tab activo al reconstruir Nav1.
			wrapsView = "owned"
			setWrapsMode(true)
			if weaponSpawn and weaponSpawn:IsA("BasePart") then
				cameraController:zoomOnPosition(weaponSpawn.Position)
			end

			populateMainContentForNavItem(LockerMainCategory.ARSENAL, LockerCategory.WEAPON_WRAPS, nil, true)
		end), "Disconnect")
	end

	DataController:WhenReady():andThen(function()
		inventory:rebuildOwned()
		inventory:rebuildEquipped()
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
			inventory:rebuildOwned()
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
			inventory:rebuildEquipped()
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
	local function restoreLockerSceneState(animateCamera: boolean?, cameraTweenInfo: TweenInfo?)
		shopRequests:flushEquips()
		-- Antes de endPreview: devuelve el personaje del lobby si estaba oculto.
		setBannersViewActive(false)
		-- Todas las salidas pasan por aquí, incluidas las que no llaman a setWrapsMode:
		-- soltar el HUD compartido sin condiciones o se quedaría forzado en el lobby.
		menuController:setStatsHudOverride(nil)
		restoreEquippedWeaponPreviews()
		-- Soltar el preview del personaje del lobby: vuelve a mostrar lo equipado y
		-- LobbyFeature retoma el control de los cambios de loadout.
		characterRotate:reset()
		weaponRotate:reset()
		lobbyCharacter:endPreview()
		cameraController:restore(animateCamera, cameraTweenInfo)
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
			inventory:rebuildOwned()
			inventory:rebuildEquipped()
		end
		-- BODY primero: beginPreview no reconstruye el modelo y el preview del lobby pudo
		-- construirse antes de llegar el loadout. applyOutfit es no-op si ya coincide, y
		-- reconstruir el body recrea los appliers sobre los que se aplican cara/hat.
		applyEquippedBodyPreview()
		applyEquippedFacePreview()
		applyEquippedHatPreview()
		actionPanel:hide()
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

	local function finishClose(animateCamera: boolean, cameraTweenInfo: TweenInfo?)
		selectedMainCategory = nil
		selectedNavKey = nil
		selectedCatalogItem = nil
		actionPanel:hide()
		wrapInfo:hide()
		restoreLockerSceneState(animateCamera, cameraTweenInfo)
		setWrapsMode(false)
		-- Liberar las cards (pooled) para que las texturas de wrap animadas dejen de
		-- actualizarse cada Heartbeat.
		clearItemGrid()
		lockerFrame.Visible = false
		ScenePresetController.applyLobbyOrRestore("[Locker]")
	end

	-- Se vuelve al lobby con travelling (desde Arsenal, con el suyo si
	-- ARSENAL_CAMERA_TRAVEL); a negro solo si ya había un fundido en vuelo.
	local function closeLockerGui()
		if not isOpen then
			return
		end

		isOpen = false
		GameSounds.play(GameSounds.Close)

		-- Con un fundido de pestaña en vuelo la pantalla ya va camino del negro y la
		-- cámara aún no ha saltado: se aprovecha ese negro también.
		local fromArsenal = selectedMainCategory == LockerMainCategory.ARSENAL
		local useFade = pendingCameraFade or (fromArsenal and not ARSENAL_CAMERA_TRAVEL)
		if not useFade then
			finishClose(true, if fromArsenal then ARSENAL_TRAVEL_TWEEN_INFO else nil)
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
			local previousNavKey = inventory:getWrapsTargetCategory()

			cameraController:unzoom()

			if nav2Strip:has(previousNavKey) then
				nav2Strip:setActive(previousNavKey)
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
