--!strict
--[[
	BattlePassFeature (Client)

	Panel del Battle Pass (una recompensa por nivel, FREE o PASS). A diferencia de
	los paneles con blur, este salta a su propia cámara (Workspace.Cameras.<CAMERA_TARGET>)
	tapando el corte con un fundido a negro liso (ScreenFade), y aplica el preset
	de iluminación autorado en esa parte — de ahí sale el DepthOfField que
	desenfoca el fondo, igual que en el Locker.

	GUI (PlayerGui.UserInterface.BattlePass, con `Main` intermedio OPCIONAL: si
	ese frame existe se usa como raíz y si no se leen los hijos del panel):
	  CloseBtn (root)                 -- fallback opcional: Header.CloseBtn
	  Nav.Back (.Indicator) / Nav.Next (.Indicator) / Nav.Info  ("1/8")
	  SkipLevelBtn                     (compra con Gems: +1 nivel)
	  PurchaseBtn                      (compra con Gems: premium / PASS)
	  Path."1".."8" (cada item, GuiButton):
	    Container.Level                 -- nivel del slot ("Lvl. 5"); se oculta en
	                                       el slot del nivel actual, que lo pinta
	                                       CurrentLevel
	    Container.LevelReward
	      .ViewportReward               -- recompensa wrap (ViewportFrame 3D)
	      .ImageReward                  -- resto de recompensas (ImageLabel)
	      .Value                        -- tipo de recompensa ("Cash", "Gems",
	                                       "Hat", "Body"…)
	      .Glow                         -- OPCIONAL: resplandor teñido con el color
	                                       de rareza de la recompensa (oscuro si
	                                       ya está reclamada)
	      .Footer.Status.Locked         -- visible mientras el nivel no se pueda
	                                       reclamar (ni reclamado ni reclamable)
	    Container.Type                  -- OPCIONAL: FREE/PASS, o CLAIMED (fondo
	                                       oscuro) si ya se reclamó
	    Container.Claim                 -- OPCIONAL: visible solo mientras la
	                                       recompensa se pueda reclamar
	    …LevelReward.Check              -- OPCIONAL: visible si está reclamado
	  CurrentLevel                      -- OPCIONAL: plantilla del slot del nivel
	                                       actual (.Fill = progreso del nivel,
	                                       .Level = "Lvl. 5"). Se clona UNA vez al
	                                       arrancar y el clon se reparenta al
	                                       Container que toque en cada render: un
	                                       único CanvasGroup vivo en vez de uno
	                                       por slot, y cero instancias creadas
	                                       mientras el panel está abierto.

	Todos los nodos se resuelven con FindFirstChild y se pintan solo si existen:
	la GUI se edita en Studio y este feature no debe romperse porque falte uno.

	El preview grande de la derecha es hoy solo `ImagePreview` (ImageLabel): el
	ViewportPreview 3D se quitó de la GUI, así que un wrap seleccionado se
	previsualiza con su `Image` de ItemsConfig (si no tiene, no hay preview).
	Los slots SÍ siguen renderizando wraps en 3D en su propio ViewportReward.

	Además, la recompensa seleccionada se enseña en el decorado de la escena
	(ScenePreview), cada clase en su peana de Workspace.BattlePass: hats y faces en
	HeadSpawn, wraps en WrapSpawn, bodies y kill effects en DummySpawn, y lo que no
	tiene modelo 3D (cash, gems) en la carta de CardSpawn. Solo se ve la peana de lo
	seleccionado, y el relevo entre ellas va animado.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any
local PanelController = require(Client.core.ui.PanelController)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local LockerCameraController = require(Client.core.camera.LockerCameraController)
local CameraLock = require(Client.core.camera.CameraLock)
local ScenePresetController = require(Client.core.lighting.ScenePresetController)
local ScreenFade = require(Client.core.ui.ScreenFade)
local DataController = require(Client.core.data.DataController)
local Notify = require(Client.core.ui.NotificationController)
local UITheme = require(Client.core.ui.UITheme)
local Network = require(Shared.networking.Network)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local LockerConfig = require(Shared.constants.LockerConfig)
local WeaponCategoryMod = require(Shared.constants.WeaponCategory)
local WeaponWrapPreviewer = require(Client.features.locker.Previewers.WeaponWrapPreviewer)
local ScenePreview = require(script.ScenePreview)

local SLOTS_PER_PAGE = 8

-- Cámara del panel: la parte de Workspace.Cameras a la que viaja la cámara al
-- abrir el pase. El look (DoF incluido) sale del atributo LightingPreset de esa
-- misma parte, igual que Workspace.Cameras.lobby lleva el del menú: ningún
-- nombre de preset vive en código.
local CAMERA_TARGET = "battlepass"
local CAMERA_LOCK_OWNER = "battlepass"

-- Texto oscuro sobre los fondos claros del slot (Type y Level).
local UI_DARK_TEXT = Color3.fromRGB(34, 34, 34)

-- Type (FREE/PASS/CLAIMED): fondo plano y opaco. Sin gradients y sin
-- transparencia — el color es el color. CLAIMED invierte el esquema: fondo
-- oscuro con texto claro.
local TYPE_PREMIUM_BG = Color3.fromRGB(255, 196, 0)
local TYPE_FREE_BG = Color3.fromRGB(255, 255, 255)
local TYPE_CLAIMED_BG = Color3.fromRGB(34, 34, 34)
local TYPE_CLAIMED_TEXT = Color3.fromRGB(255, 255, 255)

-- LevelReward.Glow: oscuro (apagado) una vez reclamado, y el color de rareza de
-- la recompensa mientras no lo esté. La paleta es la misma que la de los cards
-- del locker (UITheme.LockerRarityGlow), para que un mismo item no brille de dos
-- colores distintos según el panel donde lo mires.
local GLOW_CLAIMED_COLOR = Color3.fromRGB(34, 34, 34)
local RARITY_GLOW = UITheme.LockerRarityGlow
local RARITY_FALLBACK = "Common"

-- Nivel del slot en Container.Level (y en CurrentLevel.Level para el actual).
local STATUS_LEVEL_FORMAT = "Lvl. %d"

-- Container.Level: el FONDO va dorado en los niveles ya superados y blanco en
-- los que aún no se han alcanzado; el texto se queda oscuro en ambos. El nivel
-- actual no usa este label (lo pinta CurrentLevel).
local LEVEL_PASSED_BG = Color3.fromRGB(255, 196, 0)
local LEVEL_LOCKED_BG = Color3.fromRGB(255, 255, 255)

-- Arma por defecto del preview de un wrap GLOBAL (no va atado a ningún arma):
-- se enseña sobre la principal del jugador, que es la que más mira.
local WRAP_PREVIEW_CATEGORY = WeaponCategoryMod.MAIN
local LOADOUT_SLOT_BY_WEAPON = LockerConfig.CategoryToLoadoutSlot :: { [string]: string }

-- Imagen/viewport de la recompensa cuando ya está reclamada.
local CLAIMED_IMG_COLOR = Color3.fromRGB(89, 89, 89)
local CLAIMED_IMG_TRANSPARENCY = 0.3

-- Repoblar páginas: cada slot (su Container) entra deslizándose desde abajo.
local SLOT_STAGGER_DELAY = 0.04
local SLOT_STAGGER_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local STAGGER_ENTER_OFFSET = 30

-- Selección: el slot elegido se queda subido SELECTED_LIFT_PIXELS px (marcado).
local SELECTED_LIFT_PIXELS = 12
local SELECT_MOVE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Hover del slot: un pelín más marcado que en los slots de MapVote (1.02) porque
-- estas cards son más pequeñas —ocho por página— y ahí un 2% no se lee.
local SLOT_HOVER_SCALE = 1.05
local SLOT_CLICK_SCALE = 0.97

-- Preview grande del item seleccionado (entra deslizándose desde abajo).
local PREVIEW_LIFT_PIXELS = 24
local PREVIEW_TWEEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Etiqueta de tipo para LevelReward.Value (categoría → singular). "Body" en vez
-- de "Outfit" para hablar el mismo idioma que el nav del locker, donde la
-- categoría Outfits se llama Body (LockerConfig.ITEMS_CONFIG_BY_NAV).
local CATEGORY_LABEL: { [string]: string } = {
	Outfits = "Body",
	Faces = "Face",
	Hats = "Hat",
	KillEffects = "Kill Effect",
	WeaponWraps = "Wrap",
	Main = "Weapon",
	Special = "Weapon",
}

local BattlePassFeature = {}

local function _isWrapReward(reward: BattlePassConfig.Reward): boolean
	return reward.Kind == "Item" and reward.Category == "WeaponWraps" and reward.ItemId ~= nil
end

-- Imagen para recompensas que NO son wraps (cash → icono cash; item → ItemsConfig).
local function _rewardImage(reward: BattlePassConfig.Reward): string
	if reward.Kind == "Cash" then
		return reward.Icon or BattlePassConfig.RewardIcons.Cash or ""
	end
	if reward.Kind == "Gems" then
		-- Sin icono propio se devuelve "" (no el de Cash): un tier de Gems
		-- mostrando la moneda equivocada es peor que uno sin imagen.
		return reward.Icon or BattlePassConfig.RewardIcons.Gems or ""
	end
	local catalog = ItemsConfig[reward.Category]
	local def = if type(catalog) == "table" then catalog[reward.ItemId] else nil
	return reward.Icon or (if def and type(def.Image) == "string" then def.Image else "")
end

-- Rareza de la recompensa para teñir el Glow. Cash/Gems no son items del
-- catálogo y no tienen rareza: caen al fallback.
local function _rewardRarity(reward: BattlePassConfig.Reward): string
	if reward.Kind ~= "Item" then
		return RARITY_FALLBACK
	end
	local catalog = ItemsConfig[reward.Category]
	local def = if type(catalog) == "table" then catalog[reward.ItemId] else nil
	if type(def) == "table" and type(def.Rarity) == "string" then
		return def.Rarity
	end
	return RARITY_FALLBACK
end

-- Texto de LevelReward.Value: el TIPO de recompensa ("Cash", "Gems", "Hat",
-- "Body"…), no su cantidad. `Reward.Label` lo sobrescribe si el tier trae uno.
local function _rewardValueText(reward: BattlePassConfig.Reward): string
	if reward.Label then
		return reward.Label
	end
	if reward.Kind == "Cash" or reward.Kind == "Gems" then
		return reward.Kind
	end
	local category = reward.Category or ""
	return CATEGORY_LABEL[category] or category
end

-- Arma sobre la que se pinta el wrap en el viewport del slot:
--   · wrap de un arma concreta (WeaponCategory/WeaponId) → ESA arma.
--   · wrap global → el arma que el jugador lleve equipada en WRAP_PREVIEW_CATEGORY,
--     para que lo vea sobre la suya; sin loadout devuelve id nil y el previewer
--     cae solo al modelo "Default" de esa categoría.
-- El nombre visible se devuelve además del id porque los modelos de
-- Shared.Locker.weapons.* pueden estar nombrados por uno o por el otro.
local function _wrapPreviewWeapon(reward: BattlePassConfig.Reward): (string, string?, string?)
	local category: string
	local weaponId: string?

	if WeaponCategoryMod.isValid(reward.WeaponCategory) then
		category = reward.WeaponCategory :: string
		weaponId = if type(reward.WeaponId) == "string" and reward.WeaponId ~= "" then reward.WeaponId else nil
	else
		category = WRAP_PREVIEW_CATEGORY
		local loadout = Fusion.peek(DataController.Loadout)
		local slot = LOADOUT_SLOT_BY_WEAPON[category]
		local equipped = if type(loadout) == "table" and slot then loadout[slot] else nil
		weaponId = if type(equipped) == "string" and equipped ~= "" then equipped else nil
	end

	local catalog = ItemsConfig[category]
	local def = if type(catalog) == "table" and weaponId then catalog[weaponId] else nil
	local displayName = if type(def) == "table" and type(def.Name) == "string" and def.Name ~= ""
		then def.Name
		else nil

	return category, weaponId, displayName
end

-- ────────────────────────────────────────────────────────────

type SlotRefs = {
	frame: GuiObject,
	container: GuiObject,
	-- LevelReward.ImageReward / .ViewportReward: la recompensa se pinta en uno u
	-- otro (wrap → viewport 3D, resto → imagen) y el que no se usa se oculta.
	image: ImageLabel?,
	viewport: ViewportFrame?,
	-- LevelReward.Value: cantidad de una recompensa de moneda.
	value: TextLabel?,
	rewardGradient: UIGradient?,
	-- LevelReward.Glow: resplandor teñido por rareza (verde si está reclamado).
	glow: GuiObject?,
	-- Container.Level: nivel del slot ("Lvl. 5"). Se oculta en el slot del nivel
	-- actual: ahí lo pinta el clon de CurrentLevel, que trae su propio label.
	levelLabel: TextLabel?,
	-- Footer.Status.Locked: candado mientras el nivel no se pueda reclamar.
	locked: GuiObject?,
	-- Claim: visible solo mientras la recompensa esté lista para reclamar.
	claim: GuiObject?,
	typeLabel: TextLabel?,
	-- Check: visible solo si el item del tier está reclamado.
	check: ImageLabel?,
}

local function _resolveSlot(pathFolder: Instance, index: number): SlotRefs?
	local frame = pathFolder:FindFirstChild(tostring(index))
	if not (frame and frame:IsA("GuiObject")) then
		return nil
	end

	-- Container: hijo que se anima (raise/scale); el slot queda fijo en el layout.
	local containerNode = frame:FindFirstChild("Container")
	local container: GuiObject = if containerNode and containerNode:IsA("GuiObject") then containerNode else frame

	local reward = container:FindFirstChild("LevelReward")
	local imageNode = reward and reward:FindFirstChild("ImageReward")
	local viewportNode = reward and reward:FindFirstChild("ViewportReward")
	local valueNode = reward and reward:FindFirstChild("Value")
	local rewardGradientNode = if reward then reward:FindFirstChildOfClass("UIGradient") else nil
	local glowNode = reward and reward:FindFirstChild("Glow")
	local checkNode = reward and reward:FindFirstChild("Check")

	local footer = reward and reward:FindFirstChild("Footer")
	local status = footer and footer:FindFirstChild("Status")
	local lockedNode = status and status:FindFirstChild("Locked")

	-- Level cuelga del Container; fallback al viejo Footer.Status.Value por si la
	-- GUI todavía no está migrada.
	local levelNode = container:FindFirstChild("Level") or (status and status:FindFirstChild("Value"))

	-- Type y Claim son opcionales y pueden colgar del Container o del propio
	-- LevelReward.
	local typeNode = container:FindFirstChild("Type") or (reward and reward:FindFirstChild("Type"))
	local claimNode = container:FindFirstChild("Claim") or (reward and reward:FindFirstChild("Claim"))

	return {
		frame = frame,
		container = container,
		image = if imageNode and imageNode:IsA("ImageLabel") then imageNode else nil,
		viewport = if viewportNode and viewportNode:IsA("ViewportFrame") then viewportNode else nil,
		value = if valueNode and valueNode:IsA("TextLabel") then valueNode else nil,
		rewardGradient = rewardGradientNode,
		glow = if glowNode and glowNode:IsA("GuiObject") then glowNode else nil,
		levelLabel = if levelNode and levelNode:IsA("TextLabel") then levelNode else nil,
		locked = if lockedNode and lockedNode:IsA("GuiObject") then lockedNode else nil,
		claim = if claimNode and claimNode:IsA("GuiObject") then claimNode else nil,
		typeLabel = if typeNode and typeNode:IsA("TextLabel") then typeNode else nil,
		check = if checkNode and checkNode:IsA("ImageLabel") then checkNode else nil,
	}
end

-- UIScale escala alrededor del AnchorPoint del nodo: con el (0,0) por defecto de
-- Studio la card crece hacia abajo y a la derecha en vez de desde su centro. Se
-- recentra el AnchorPoint compensando la Position con medio tamaño PROPIO, así
-- que la card se queda exactamente donde estaba y lo único que cambia es desde
-- dónde crece. Devuelve false si no se puede tocar sin descolocarla.
--
-- La compensación se hace con la Size (no con AbsoluteSize) para que siga siendo
-- independiente de la resolución; a cambio, deja de ser exacta si un constraint
-- decide el tamaño real. En ese caso —y si la Position la manda un layout— se
-- deja el nodo como está: una card medio desplazada es mucho peor que una card
-- que crece desde la esquina.
local function _centerScaleAnchor(node: GuiObject): boolean
	local anchor = node.AnchorPoint
	if anchor.X == 0.5 and anchor.Y == 0.5 then
		return true
	end

	local parent = node.Parent
	if parent and parent:IsA("GuiObject") and parent:FindFirstChildWhichIsA("UILayout") then
		return false
	end
	if node:FindFirstChildWhichIsA("UIAspectRatioConstraint") or node:FindFirstChildWhichIsA("UISizeConstraint") then
		return false
	end

	local dx = 0.5 - anchor.X
	local dy = 0.5 - anchor.Y
	local size = node.Size
	local pos = node.Position
	node.Position = UDim2.new(
		pos.X.Scale + size.X.Scale * dx,
		pos.X.Offset + size.X.Offset * dx,
		pos.Y.Scale + size.Y.Scale * dy,
		pos.Y.Offset + size.Y.Offset * dy
	)
	node.AnchorPoint = Vector2.new(0.5, 0.5)
	return true
end

-- ────────────────────────────────────────────────────────────

function BattlePassFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()

	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local frameNode = uiGui:WaitForChild("BattlePass")
	if not frameNode:IsA("GuiObject") then
		warn("[BattlePassFeature] UserInterface.BattlePass no es un GuiObject")
		return janitor
	end
	local frame = frameNode :: GuiObject
	-- `Main` es opcional: la GUI puede colgar Header/Nav/Path
	-- directamente del panel. Sin WaitForChild a propósito — esperar un frame
	-- que ya no existe dejaría el feature colgado para siempre.
	local mainNode = frame:FindFirstChild("Main")
	local main: Instance = if mainNode then mainNode else frame

	-- Botón de apertura en Menu.Container.FamePass
	local container = menuGui:FindFirstChild("Container")
	local btnInstance = container and container:FindFirstChild("FamePass")
	local menuBtn: GuiButton? = if btnInstance and btnInstance:IsA("GuiButton")
		then btnInstance
		else (btnInstance and btnInstance:FindFirstChildWhichIsA("GuiButton"))

	local navTarget = btnInstance or menuBtn
	local navIconValueNode = navTarget and navTarget:FindFirstChild("Icon")
	local navValueNode = navIconValueNode and navIconValueNode:FindFirstChild("Value")
	local navIconValue: TextLabel? = if navValueNode and navValueNode:IsA("TextLabel") then navValueNode else nil
	local navIndicatorNode = navTarget and navTarget:FindFirstChild("Indicator")
	local navIndicator: GuiObject? = if navIndicatorNode and navIndicatorNode:IsA("GuiObject") then navIndicatorNode else nil

	-- Header. CloseBtn cuelga hoy directo de BattlePass (root), no de Header;
	-- fallback a Header.CloseBtn por si la GUI aún no está migrada.
	local header = main:FindFirstChild("Header")
	local closeNode = frame:FindFirstChild("CloseBtn") or (header and header:FindFirstChild("CloseBtn"))
	local closeBtn: GuiButton? = if closeNode and closeNode:IsA("GuiButton") then closeNode else nil

	-- Nav (Back / Next / Info).
	local navFolder = main:FindFirstChild("Nav")
	local backBtn = navFolder and navFolder:FindFirstChild("Back")
	local nextBtn = navFolder and navFolder:FindFirstChild("Next")
	local pageLabelNode = navFolder and navFolder:FindFirstChild("Info")
	local pageLabel: TextLabel? = if pageLabelNode and pageLabelNode:IsA("TextLabel") then pageLabelNode else nil
	local backIndicator = if backBtn then backBtn:FindFirstChild("Indicator") else nil
	local nextIndicator = if nextBtn then nextBtn:FindFirstChild("Indicator") else nil

	-- Skip + Purchase (Premium) opcional.
	local skipBtn = main:FindFirstChild("SkipLevelBtn")
	local purchaseBtn = main:FindFirstChild("PurchaseBtn")

	-- Path slots 1..8.
	local pathFolder = main:FindFirstChild("Path")
	local slots: { SlotRefs? } = {}
	if pathFolder then
		for i = 1, SLOTS_PER_PAGE do
			slots[i] = _resolveSlot(pathFolder, i)
		end
	else
		warn("[BattlePassFeature] BattlePass.Path no existe")
	end

	-- Hover/click de los niveles. Se escala el Container (nodo "InteractiveScale"),
	-- NO su Position: la posición del Container ya la mueven el stagger de entrada
	-- y el lift de selección, y escala y posición son propiedades distintas, así
	-- que el hover convive con ambos sin pelearse por el mismo tween.
	--
	-- El AnchorPoint se recentra ANTES de nada: aquí, y no al abrir, porque el
	-- stagger cachea la Position de reposo la primera vez que anima y debe cachear
	-- ya la compensada.
	--
	-- Se enlaza UNA vez aquí y no en render(): el hover no depende del nivel que
	-- muestre el slot, y render() corre con cada cambio de estado.
	local canHover = UserInputService.MouseEnabled and not UserInputService.TouchEnabled
	local anchorFixFailed = false
	for i = 1, SLOTS_PER_PAGE do
		local refs = slots[i]
		if refs and refs.frame:IsA("GuiButton") then
			if not _centerScaleAnchor(refs.container) then
				anchorFixFailed = true
			end
			InteractiveScaleTween.bindButton(refs.frame :: GuiButton, janitor, {
				scaleTarget = refs.container,
				enableHover = canHover,
				hoverScale = SLOT_HOVER_SCALE,
				clickScale = SLOT_CLICK_SCALE,
			})
		end
	end
	if anchorFixFailed then
		warn(
			"[BattlePassFeature] Algún Container de Path no se puede recentrar por código (lo posiciona un layout o su tamaño lo decide un constraint): el hover crecerá desde la esquina. Ponle AnchorPoint 0.5,0.5 en Studio."
		)
	end

	-- CurrentLevel: plantilla del slot del nivel actual. Se clona UNA vez y el
	-- clon se reparenta al Container que toque en cada render — mover un hijo de
	-- padre es una asignación, mientras que clonar por página crearía y
	-- destruiría un CanvasGroup en cada tick de XP (render() corre con cada
	-- cambio de estado, no solo al paginar).
	local currentLevelTemplate = main:FindFirstChild("CurrentLevel") or frame:FindFirstChild("CurrentLevel")
	local currentLevel: GuiObject? = nil
	local currentFill: GuiObject? = nil
	local currentLevelLabel: TextLabel? = nil
	if currentLevelTemplate and currentLevelTemplate:IsA("GuiObject") then
		-- La plantilla no se renderiza nunca: solo se clona.
		(currentLevelTemplate :: GuiObject).Visible = false
		local clone = (currentLevelTemplate :: GuiObject):Clone()
		clone.Visible = false
		clone.Parent = frame
		janitor:Add(clone, "Destroy")
		currentLevel = clone
		local fillNode = clone:FindFirstChild("Fill")
		currentFill = if fillNode and fillNode:IsA("GuiObject") then fillNode else nil
		local levelNode = clone:FindFirstChild("Level")
		currentLevelLabel = if levelNode and levelNode:IsA("TextLabel") then levelNode else nil
	end

	-- Preview grande del item seleccionado. Solo imagen: el ViewportPreview 3D
	-- ya no está en la GUI, así que un wrap se previsualiza con su `Image`.
	local imagePreviewNode = main:FindFirstChild("ImagePreview")
	local imagePreview: (ImageLabel | ImageButton)? = if imagePreviewNode
			and (imagePreviewNode:IsA("ImageLabel") or imagePreviewNode:IsA("ImageButton"))
		then imagePreviewNode :: any
		else nil

	-- ── Estado / season ──────────────────────────────────────
	local season = BattlePassConfig.GetActiveSeason()
	local maxTier = BattlePassConfig.GetMaxTier(season)
	local pageCount = math.max(1, math.ceil(maxTier / SLOTS_PER_PAGE))
	local currentPage = 0
	local isOpen = false
	-- Si la apertura en curso saltó a la cámara del pase: lo decide `onOpen` y lo
	-- lee `onClose` para deshacer exactamente lo que se hizo.
	local cameraActive = false

	-- ── Cámara + iluminación ─────────────────────────────────
	-- Sin blur a propósito: el desenfoque del fondo lo da el DepthOfField del
	-- preset de la cámara, no el BlurController.
	--
	-- La cámara se resuelve PEREZOSAMENTE, en cada apertura, y con FindFirstChild:
	--   · Perezosamente porque `start` corre durante el bootstrap del cliente,
	--     cuando el mapa puede no haber replicado todavía y Workspace.Cameras no
	--     existir aún. Resolverla ahí de una vez dejaba el panel sin cámara para
	--     el resto de la sesión si el jugador entraba y abría el pase rápido.
	--   · Con FindFirstChild y no WaitForChild porque LockerCameraController.new
	--     hace WaitForChild sin timeout: un nombre que no exista dejaría el
	--     feature colgado para siempre en vez de abrir el panel sin cámara.
	local cameraController: any = nil
	local fade: any = nil
	local warnedMissingCamera = false

	local function findCameraPart(): BasePart?
		local camerasFolder = Workspace:FindFirstChild("Cameras")
		local part = if camerasFolder then camerasFolder:FindFirstChild(CAMERA_TARGET) else nil
		return if part and part:IsA("BasePart") then part :: BasePart else nil
	end

	-- Devuelve el controller si la cámara ya ha replicado, o nil (y el panel se
	-- abre sin cámara, como hasta ahora). El aviso sale UNA sola vez: si la parte
	-- falta de verdad, cada apertura repetiría el mismo warn.
	local function ensureCameraController(): any
		if cameraController then
			return cameraController
		end
		if not findCameraPart() then
			if not warnedMissingCamera then
				warnedMissingCamera = true
				warn(`[BattlePassFeature] Falta Workspace.Cameras.{CAMERA_TARGET} (o no es un BasePart); el panel se abre sin cámara`)
			end
			return nil
		end
		cameraController = LockerCameraController.new(CAMERA_TARGET)
		janitor:Add(cameraController, "Destroy")
		-- El salto de cámara va tapado por un fundido a negro liso, así que se
		-- hace de golpe (apply/restore instantáneos): un travelling detrás del
		-- negro solo sería una espera. Singleton compartido vía playerGui — igual
		-- que IrisTransition, no se suma al janitor.
		fade = ScreenFade.new(playerGui)
		return cameraController
	end

	-- Look de la escena. Preferimos el preset autorado en la propia parte de
	-- cámara (atributo LightingPreset, como Workspace.Cameras.lobby); si no lo
	-- lleva, caemos al de Workspace.Locker, que es de donde sale el DepthOfField
	-- del locker. Así el pase tiene el DoF del locker sin tocar Studio, y el día
	-- que quieras un look propio basta con ponerle el atributo a la cámara.
	local function applyPassPreset()
		local cameraPart = findCameraPart()
		if cameraPart and ScenePresetController.applyFrom(cameraPart) then
			return
		end
		local lockerNode = Workspace:FindFirstChild("Locker")
		if lockerNode and ScenePresetController.applyFrom(lockerNode) then
			return
		end
		warn(`[BattlePassFeature] Sin preset de iluminación: ni Workspace.Cameras.{CAMERA_TARGET} ni Workspace.Locker llevan atributo LightingPreset`)
	end

	-- ── Decorado 3D ──────────────────────────────────────────
	-- Prueba la recompensa seleccionada en las peanas de Workspace.BattlePass:
	-- hats y faces en HeadSpawn, wraps en WrapSpawn. Se construye solo en la
	-- primera apertura, y si al place le faltan las anclas no hace nada: el panel
	-- funciona igual, solo sin decorado.
	local scenePreview = ScenePreview.new()
	janitor:Add(scenePreview, "Destroy")

	-- ── Wrap previews por slot ───────────────────────────────
	-- previewKey = wrap + arma sobre la que se pinta: si cambia cualquiera de los
	-- dos hay que rehacer el viewport.
	type WrapEntry = { previewKey: string, janitor: any, viewport: ViewportFrame }
	local wrapBySlot: { [GuiObject]: WrapEntry } = {}
	local function clearWrap(slotFrame: GuiObject)
		local entry = wrapBySlot[slotFrame]
		if not entry then return end
		entry.janitor:Destroy()
		wrapBySlot[slotFrame] = nil
	end
	janitor:Add(function()
		for slotFrame in wrapBySlot do
			clearWrap(slotFrame)
		end
	end, true)

	-- ── Animación de slots (todo por Position del Container) ──
	-- Un único tween activo por Container (se cancela al reemplazarse), compartido
	-- por el stagger de entrada y el raise de selección.
	-- Selección persistente: el slot elegido se queda subido; el anterior baja.
	local slotRestPos: { [GuiObject]: UDim2 } = {}
	local selectMoveTween: { [GuiObject]: Tween } = {}
	local selectedFrame: GuiObject? = nil
	local function restPosOf(slotFrame: GuiObject): UDim2
		local cached = slotRestPos[slotFrame]
		if cached == nil then
			cached = slotFrame.Position
			slotRestPos[slotFrame] = cached
		end
		return cached
	end
	local function moveSlot(slotFrame: GuiObject, lifted: boolean)
		local rest = restPosOf(slotFrame)
		local target = if lifted
			then UDim2.new(rest.X.Scale, rest.X.Offset, rest.Y.Scale, rest.Y.Offset - SELECTED_LIFT_PIXELS)
			else rest
		local existing = selectMoveTween[slotFrame]
		if existing then
			existing:Cancel()
		end
		local tween = TweenService:Create(slotFrame, SELECT_MOVE_INFO, { Position = target })
		selectMoveTween[slotFrame] = tween
		tween:Play()
	end
	-- Devuelve true si la selección cambió (false si ya estaba seleccionado).
	local function selectSlot(slotFrame: GuiObject): boolean
		if selectedFrame == slotFrame then
			return false
		end
		if selectedFrame then
			moveSlot(selectedFrame, false)
		end
		moveSlot(slotFrame, true)
		selectedFrame = slotFrame
		return true
	end
	-- Al cambiar de página los slots cambian de nivel: limpia la selección.
	local function resetSelection()
		for slotFrame, tween in selectMoveTween do
			tween:Cancel()
			local rest = slotRestPos[slotFrame]
			if rest and slotFrame.Parent then
				slotFrame.Position = rest
			end
		end
		table.clear(selectMoveTween)
		selectedFrame = nil
	end

	-- Aparición escalonada: cada Container entra deslizándose desde abajo.
	local function playPageStagger()
		local order = 0
		for i = 1, SLOTS_PER_PAGE do
			local refs = slots[i]
			if not (refs and refs.frame.Visible) then
				continue
			end
			local container = refs.container
			local rest = restPosOf(container)
			local existing = selectMoveTween[container]
			if existing then
				existing:Cancel()
			end
			container.Position = UDim2.new(rest.X.Scale, rest.X.Offset, rest.Y.Scale, rest.Y.Offset + STAGGER_ENTER_OFFSET)
			local tween = TweenService:Create(container, SLOT_STAGGER_INFO, { Position = rest })
			selectMoveTween[container] = tween
			task.delay(order * SLOT_STAGGER_DELAY, function()
				if selectMoveTween[container] == tween then
					tween:Play()
				end
			end)
			order += 1
		end
	end

	janitor:Add(function()
		for slotFrame, tween in selectMoveTween do
			tween:Cancel()
			local rest = slotRestPos[slotFrame]
			if rest and slotFrame.Parent then
				slotFrame.Position = rest
			end
		end
		table.clear(selectMoveTween)
	end, true)

	-- ── Preview del item seleccionado ────────────────────────
	-- Entra deslizándose desde abajo. Una recompensa sin imagen (p. ej. un wrap
	-- sin `Image` en ItemsConfig, que antes se veía en el ViewportPreview 3D)
	-- oculta el preview en vez de dejar puesta la del item anterior.
	local imagePreviewRest: UDim2? = nil

	-- Última recompensa empujada a la escena 3D: el observer de Loadout la reenvía
	-- cuando cambia el arma equipada, para que un wrap global seleccionado se
	-- recoloque sobre el arma nueva sin esperar a otro clic.
	local lastSceneReward: BattlePassConfig.Reward? = nil

	-- Decorado de la escena: qué peana sale con cada clase de recompensa lo decide
	-- ScenePreview. Aquí solo se le pasa lo que él no puede deducir — el arma sobre
	-- la que va un wrap (sale del loadout) y la imagen del premio para la carta.
	local function pushScenePreview(reward: BattlePassConfig.Reward)
		lastSceneReward = reward
		local weaponCategory, weaponId, weaponName = _wrapPreviewWeapon(reward)
		scenePreview:setReward(reward, {
			weaponCategory = weaponCategory,
			weaponId = weaponId,
			weaponName = weaponName,
			wrapId = if _isWrapReward(reward) then reward.ItemId else nil,
			image = _rewardImage(reward),
		})
	end

	local function showRewardPreview(reward: BattlePassConfig.Reward)
		pushScenePreview(reward)
		if not imagePreview then return end
		local image = _rewardImage(reward)
		if image == "" then
			imagePreview.Visible = false
			return
		end
		if imagePreviewRest == nil then
			imagePreviewRest = imagePreview.Position
		end
		local rest = imagePreviewRest :: UDim2
		imagePreview.Image = image
		imagePreview.Visible = true
		imagePreview.Position = UDim2.new(rest.X.Scale, rest.X.Offset, rest.Y.Scale, rest.Y.Offset + PREVIEW_LIFT_PIXELS)
		TweenService:Create(imagePreview, PREVIEW_TWEEN_INFO, { Position = rest }):Play()
	end

	-- Sin selección: el preview muestra el item 8 (último) de la página actual.
	local function showPageDefaultPreview()
		local level = currentPage * SLOTS_PER_PAGE + SLOTS_PER_PAGE
		local tierDef = BattlePassConfig.GetTier(season, level)
		if tierDef then
			showRewardPreview(tierDef.Reward)
		end
	end

	-- Por defecto al (re)mostrar una página: si el tier en el que está el jugador
	-- cae en esta página, lo selecciona (levantado) y lo previsualiza; si no,
	-- previsualiza el item 8.
	local function applyDefaultSelection()
		local state = Fusion.peek(DataController.BattlePass)
		local currentTier = if type(state) == "table" then math.floor(state.CurrentTier or 1) else 1
		if currentTier >= 1 and currentTier <= maxTier then
			local pageStart = currentPage * SLOTS_PER_PAGE
			if currentTier > pageStart and currentTier <= pageStart + SLOTS_PER_PAGE then
				local refs = slots[currentTier - pageStart]
				local tierDef = BattlePassConfig.GetTier(season, currentTier)
				if refs and tierDef then
					selectSlot(refs.container)
					showRewardPreview(tierDef.Reward)
					return
				end
			end
		end
		showPageDefaultPreview()
	end

	-- ── Claim helpers ────────────────────────────────────────
	local function isClaimable(level: number, state: any): boolean
		local tierDef = BattlePassConfig.GetTier(season, level)
		if not tierDef then return false end
		local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
		if level >= currentTier then return false end -- no completado
		local claimed = if type(state.Claimed) == "table" then state.Claimed else {}
		if claimed[tostring(level)] == true then return false end
		if tierDef.Premium and state.PremiumOwned ~= true then return false end
		return true
	end

	local function anyClaimableInRange(fromLevel: number, toLevel: number, state: any): boolean
		for level = math.max(1, fromLevel), math.min(maxTier, toLevel) do
			if isClaimable(level, state) then
				return true
			end
		end
		return false
	end

	-- Estado del botón Menu.Nav.BattlePass. Independiente de `render` (que solo pinta
	-- con el panel abierto): esto debe reflejar nivel + indicador aunque esté cerrado.
	local function updateNavButton()
		if not (navIconValue or navIndicator) then
			return
		end
		local state = Fusion.peek(DataController.BattlePass)
		if type(state) ~= "table" then
			return
		end
		local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
		if navIconValue then
			navIconValue.Text = tostring(math.clamp(currentTier, 1, maxTier))
		end
		if navIndicator then
			navIndicator.Visible = anyClaimableInRange(1, maxTier, state)
		end
	end

	-- ── Render ───────────────────────────────────────────────
	local slotConnections: { RBXScriptConnection } = {}
	local function clearSlotConnections()
		for _, conn in slotConnections do
			conn:Disconnect()
		end
		table.clear(slotConnections)
	end
	janitor:Add(clearSlotConnections, true)

	local function paintType(refs: SlotRefs, isPremium: boolean, isClaimed: boolean)
		local typeLabel = refs.typeLabel
		if not typeLabel then return end

		typeLabel.Visible = true

		if isClaimed then
			typeLabel.Text = "CLAIMED"
			typeLabel.TextColor3 = TYPE_CLAIMED_TEXT
			typeLabel.BackgroundColor3 = TYPE_CLAIMED_BG
		else
			typeLabel.Text = if isPremium then "PASS" else "FREE"
			typeLabel.TextColor3 = UI_DARK_TEXT
			typeLabel.BackgroundColor3 = if isPremium then TYPE_PREMIUM_BG else TYPE_FREE_BG
		end
	end

	local function paintContent(refs: SlotRefs, reward: BattlePassConfig.Reward, isClaimed: boolean)
		-- Visual: wrap → viewport (3D), resto → image.
		if _isWrapReward(reward) and refs.viewport then
			if refs.image then
				refs.image.Visible = false
			end
			refs.viewport.Visible = true
			local wrapId = reward.ItemId :: string
			-- El arma va en la clave: un wrap global se enseña sobre el arma
			-- equipada, y esa puede cambiar con el panel abierto.
			local weaponCategory, weaponId, weaponName = _wrapPreviewWeapon(reward)
			local previewKey = `{wrapId}|{weaponCategory}|{weaponId or ""}`
			local existing = wrapBySlot[refs.frame]
			if not existing or existing.previewKey ~= previewKey or existing.viewport ~= refs.viewport then
				clearWrap(refs.frame)
				local wrapsCatalog = ItemsConfig.WeaponWraps
				local wrapDef = if type(wrapsCatalog) == "table" then wrapsCatalog[wrapId] else nil
				if type(wrapDef) == "table" then
					local previewJanitor = Janitor.new()
					local ok, usedWeapon = WeaponWrapPreviewer.Render(refs.viewport, {
						TextureID = wrapDef.TextureID,
						BaseColor = wrapDef.BaseColor,
						Material = wrapDef.Material,
						isAnimated = wrapDef.isAnimated,
						StudsPerTile = wrapDef.StudsPerTile,
						PreviewWeaponCategory = weaponCategory,
						PreviewWeaponId = weaponId,
						PreviewWeaponDisplayName = weaponName,
					}, previewJanitor)
					if ok then
						-- Render ya deja el arma encuadrada como en las cards de arma
						-- del locker; recentrar solo hace falta si no se encontró el
						-- modelo y se pintó el bloque genérico.
						if not usedWeapon then
							WeaponWrapPreviewer.reframeCentered(refs.viewport)
						end
						wrapBySlot[refs.frame] = { previewKey = previewKey, janitor = previewJanitor, viewport = refs.viewport }
					else
						previewJanitor:Destroy()
					end
				end
			end
		else
			clearWrap(refs.frame)
			if refs.viewport then
				refs.viewport.Visible = false
			end
			if refs.image then
				refs.image.Image = _rewardImage(reward)
				refs.image.Visible = true
			end
		end

		-- Value: el tipo de recompensa. Vacío solo si la categoría no se reconoce.
		if refs.value then
			local text = _rewardValueText(reward)
			refs.value.Text = text
			refs.value.Visible = text ~= ""
		end

		-- Reclamada → imagen/viewport gris semitransparente.
		local tintColor = if isClaimed then CLAIMED_IMG_COLOR else Color3.fromRGB(255, 255, 255)
		local tintTransp = if isClaimed then CLAIMED_IMG_TRANSPARENCY else 0
		if refs.image then
			refs.image.ImageColor3 = tintColor
			refs.image.ImageTransparency = tintTransp
		end
		if refs.viewport then
			refs.viewport.ImageColor3 = tintColor
			refs.viewport.ImageTransparency = tintTransp
		end
		-- Check: visible solo si el item del tier está reclamado.
		if refs.check then
			refs.check.Visible = isClaimed
		end

		-- Glow: se apaga al reclamar, rareza de la recompensa en el resto de casos.
		local glow = refs.glow
		if glow then
			local color = if isClaimed
				then GLOW_CLAIMED_COLOR
				else (RARITY_GLOW[_rewardRarity(reward)] or RARITY_GLOW[RARITY_FALLBACK])
			if color then
				if glow:IsA("ImageLabel") or glow:IsA("ImageButton") then
					glow.ImageColor3 = color
				else
					glow.BackgroundColor3 = color
				end
			end
		end
	end

	-- Footer.Status.Locked: el candado se va en cuanto el nivel deja de estar
	-- bloqueado, sea porque ya se reclamó o porque está listo para reclamar.
	-- Claim: solo en la ventana entre ambas cosas (isClaimable ya excluye lo
	-- reclamado, lo bloqueado y el PASS sin comprar).
	local function paintFooter(refs: SlotRefs, isClaimed: boolean, isClaimable_: boolean)
		if refs.locked then
			refs.locked.Visible = not isClaimed and not isClaimable_
		end
		if refs.claim then
			refs.claim.Visible = isClaimable_
		end
	end

	-- Nivel del slot. El slot del nivel actual cede su Container.Level al clon de
	-- CurrentLevel, que trae su propio label y una barra `Fill` con el progreso
	-- dentro del nivel. El clon ya lleva el LayoutOrder de la plantilla, así que
	-- cae en el hueco del Level que sustituye.
	local function paintLevel(refs: SlotRefs, realLevel: number, currentLevelTier: number, ratio: number)
		local isCurrent = realLevel == currentLevelTier
		-- El label propio solo se cede si el clon de CurrentLevel existe y va a
		-- sustituirlo: la plantilla es OPCIONAL, y sin ella ocultarlo dejaría al
		-- tier actual como el único slot sin indicador de nivel.
		local replacedByCurrent = isCurrent and currentLevel ~= nil
		if refs.levelLabel then
			refs.levelLabel.Text = STATUS_LEVEL_FORMAT:format(realLevel)
			refs.levelLabel.Visible = not replacedByCurrent
			refs.levelLabel.TextColor3 = UI_DARK_TEXT
			refs.levelLabel.BackgroundColor3 = if realLevel < currentLevelTier
				then LEVEL_PASSED_BG
				else LEVEL_LOCKED_BG
		end
		if not (isCurrent and currentLevel) then return end
		local node = currentLevel :: GuiObject
		node.Parent = refs.container
		node.Visible = true
		if currentLevelLabel then
			currentLevelLabel.Text = STATUS_LEVEL_FORMAT:format(realLevel)
		end
		if currentFill then
			local size = currentFill.Size
			currentFill.Size = UDim2.new(ratio, 0, size.Y.Scale, size.Y.Offset)
		end
	end

	local function render()
		if not isOpen then return end
		local state = Fusion.peek(DataController.BattlePass)
		if type(state) ~= "table" then return end

		local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
		local currentXP = math.max(0, math.floor(state.XP or 0))
		local complete = currentTier > maxTier

		-- Progreso dentro del nivel actual: solo alimenta CurrentLevel.Fill (el
		-- Progress global de arriba se quitó de la GUI).
		local activeTier = BattlePassConfig.GetTier(season, math.min(currentTier, maxTier))
		local needed = if activeTier then activeTier.XPRequired else 100
		local ratio = if complete then 1 else math.clamp(currentXP / math.max(1, needed), 0, 1)

		if pageLabel then
			pageLabel.Text = tostring(currentPage + 1) .. "/" .. tostring(pageCount)
		end
		if purchaseBtn and purchaseBtn:IsA("GuiObject") then
			purchaseBtn.Visible = state.PremiumOwned ~= true
		end

		clearSlotConnections()

		-- El nivel actual puede no caer en esta página: se oculta de entrada y
		-- solo el slot que le corresponda lo reparenta y lo vuelve a mostrar.
		if currentLevel then
			(currentLevel :: GuiObject).Visible = false
		end
		local displayTier = math.clamp(currentTier, 1, maxTier)

		for i = 1, SLOTS_PER_PAGE do
			local refs = slots[i]
			if not refs then continue end

			local realLevel = currentPage * SLOTS_PER_PAGE + i
			local tierDef = BattlePassConfig.GetTier(season, realLevel)
			if not tierDef then
				refs.frame.Visible = false
				clearWrap(refs.frame)
				continue
			end

			refs.frame.Visible = true
			local claimedMap = if type(state.Claimed) == "table" then state.Claimed else {}
			local isClaimed = claimedMap[tostring(realLevel)] == true
			local claimable = isClaimable(realLevel, state)

			paintContent(refs, tierDef.Reward, isClaimed)
			paintType(refs, tierDef.Premium, isClaimed)
			paintFooter(refs, isClaimed, claimable)
			paintLevel(refs, realLevel, displayTier, ratio)

			-- LevelReward.UIGradient: habilitado en niveles PASS.
			if refs.rewardGradient then
				refs.rewardGradient.Enabled = tierDef.Premium
			end

			-- Click → marca seleccionado (preview) + claim si reclamable.
			local slotReward = tierDef.Reward
			local function onSlotClick()
				-- Solo recarga el preview si la selección realmente cambió.
				if selectSlot(refs.container) then
					showRewardPreview(slotReward)
				end
				if isClaimable(realLevel, Fusion.peek(DataController.BattlePass)) then
					Network.BattlePass.ClaimTier.Send({ tier = realLevel })
				end
			end
			-- Path."1".."8" es un GuiButton en Studio: Activated cubre ratón y táctil.
			if refs.frame:IsA("GuiButton") then
				table.insert(slotConnections, (refs.frame :: GuiButton).Activated:Connect(onSlotClick))
			end
		end

		-- Indicadores de Back/Next: reclamables fuera de la página actual.
		if backIndicator and backIndicator:IsA("GuiObject") then
			backIndicator.Visible = anyClaimableInRange(1, currentPage * SLOTS_PER_PAGE, state)
		end
		if nextIndicator and nextIndicator:IsA("GuiObject") then
			nextIndicator.Visible = anyClaimableInRange((currentPage + 1) * SLOTS_PER_PAGE + 1, maxTier, state)
		end
	end

	local function pageForCurrentTier(): number
		local state = Fusion.peek(DataController.BattlePass)
		if type(state) ~= "table" then return 0 end
		local tier = math.clamp(math.floor(state.CurrentTier or 1), 1, maxTier)
		return math.clamp(math.floor((tier - 1) / SLOTS_PER_PAGE), 0, pageCount - 1)
	end

	-- ── Panel (cámara propia + preset de iluminación, sin blur) ─
	local panel = PanelController.new(menuController, frame, menuBtn, closeBtn, {
		onOpen = function()
			isOpen = true

			local function presentPanel()
				currentPage = pageForCurrentTier()
				resetSelection()
				render()
				playPageStagger()
				scenePreview:show()
				-- Viste la cabeza: applyDefaultSelection acaba en showRewardPreview.
				applyDefaultSelection()
			end

			-- La apertura manda: si la cámara ya replicó, se usa aunque no
			-- estuviera al arrancar el feature. El cierre mira este flag y no el
			-- controller, para que un panel abierto sin cámara se cierre sin
			-- fundido aunque la parte haya llegado mientras estaba abierto.
			cameraActive = ensureCameraController() ~= nil
			if cameraActive then
				CameraLock.acquire(CAMERA_LOCK_OWNER)
				-- El animator ya dejó `frame` Visible=true (y arrancó su propio
				-- tween de apertura) antes de llegar aquí: lo tapamos hasta que la
				-- pantalla esté completamente negra, para que el jugador no vea el
				-- panel —ni su stagger de entrada— con la cámara vieja detrás.
				frame.Visible = false
				fade:cover(function()
					cameraController:apply(true)
					applyPassPreset()
					frame.Visible = true
					presentPanel()
					fade:reveal()
				end)
			else
				presentPanel()
			end
		end,
		onClose = function()
			isOpen = false
			-- La cabeza se retira detrás del negro (o al momento si no hay cámara):
			-- quitarla antes del fundido se vería desaparecer en plena escena.
			if cameraActive then
				-- PanelController ya remostró el menú del lobby antes de llegar aquí
				-- (su animator de cierre es instantáneo). Lo volvemos a ocultar en
				-- el mismo frame —sin parpadeo, ambas cosas son `gui.Enabled`— para
				-- que no se vea sobre la cámara del pase mientras funde a negro.
				menuController:hide()
				fade:cover(function()
					ScenePresetController.applyLobbyOrRestore("[BattlePassFeature]")
					cameraController:restore()
					CameraLock.release(CAMERA_LOCK_OWNER)
					scenePreview:hide()
					-- Mismo guard que PanelController: si en medio de la transición
					-- se abrió otro panel, el menú no debe reaparecer debajo.
					if not menuController:hasOpenPanel() then
						menuController:show()
					end
					fade:reveal()
				end)
			else
				scenePreview:hide()
			end
			-- Liberar los wraps animados para que sus texturas dejen de
			-- actualizarse cada Heartbeat mientras el panel está cerrado.
			for slotFrame in wrapBySlot do
				clearWrap(slotFrame)
			end
		end,
	})
	janitor:Add(panel, "Destroy")

	if btnInstance and not menuBtn and btnInstance:IsA("GuiObject") then
		janitor:Add(btnInstance.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				panel:open()
			end
		end), "Disconnect")
	end

	-- ── Navegación / Skip / Purchase ──────────────────────────
	if nextBtn and nextBtn:IsA("GuiButton") then
		janitor:Add((nextBtn :: GuiButton).MouseButton1Click:Connect(function()
			if currentPage < pageCount - 1 then
				currentPage += 1
				resetSelection()
				render()
				playPageStagger()
				applyDefaultSelection()
			end
		end), "Disconnect")
	end
	if backBtn and backBtn:IsA("GuiButton") then
		janitor:Add((backBtn :: GuiButton).MouseButton1Click:Connect(function()
			if currentPage > 0 then
				currentPage -= 1
				resetSelection()
				render()
				playPageStagger()
				applyDefaultSelection()
			end
		end), "Disconnect")
	end
	if skipBtn and skipBtn:IsA("GuiButton") then
		janitor:Add((skipBtn :: GuiButton).MouseButton1Click:Connect(function()
			Network.BattlePass.BuySkip.Send({})
		end), "Disconnect")
	end
	if purchaseBtn and purchaseBtn:IsA("GuiButton") then
		janitor:Add((purchaseBtn :: GuiButton).MouseButton1Click:Connect(function()
			Network.BattlePass.BuyPremium.Send({})
		end), "Disconnect")
	end

	-- ── Feedback del servidor ─────────────────────────────────
	janitor:Add(Network.BattlePass.Response.Listen(function(data: any)
		if type(data) ~= "table" then return end
		if data.success then
			if data.message == "OK" then
				Notify.success("Reward claimed!")
			elseif data.message == "PremiumGranted" then
				Notify.success("Premium unlocked!")
			elseif data.message == "SkipGranted" then
				Notify.success("Tier skipped!")
			end
		else
			-- Fallos accionables por el jugador → notificación; el resto, log.
			-- "GemsInsufficient" es el momento clave del embudo: el jugador quiso
			-- comprar (premium o skip) y le faltan Gems — el copy apunta a la
			-- tienda, donde viven los packs.
			if data.message == "GemsInsufficient" then
				Notify.warning("Not enough Gems. Get more in the store.")
			elseif data.message == "AlreadyOwned" then
				Notify.warning("You already own the Premium pass.")
			elseif data.message == "SeasonCompleted" then
				Notify.warning("You already completed the season.")
			end
			warn(("[BattlePassFeature] Response: %s (tier=%s)"):format(tostring(data.message), tostring(data.tier)))
		end
	end), true)

	-- ── Render reactivo ───────────────────────────────────────
	DataController:WhenReady():andThen(function()
		currentPage = pageForCurrentTier()
		render()
		updateNavButton()
		local scope = Fusion.scoped(Fusion)
		janitor:Add(function()
			Fusion.doCleanup(scope)
		end, true)
		local obs = scope:Observer(DataController.BattlePass :: any)
		-- El panel solo se repinta abierto (render), pero el botón del menú debe
		-- reflejar nivel/indicador en cada cambio de estado aunque esté cerrado.
		janitor:Add(obs:onBind(function()
			render()
			updateNavButton()
		end), true)
		-- Los previews de wraps GLOBALES van sobre el arma equipada, así que un
		-- cambio de loadout con el panel abierto tiene que repintar slots y escena
		-- — la previewKey por sí sola detecta el arma nueva pero nadie la relee.
		local loadoutObs = scope:Observer(DataController.Loadout :: any)
		janitor:Add(loadoutObs:onBind(function()
			if not isOpen then
				return
			end
			render()
			if lastSceneReward then
				pushScenePreview(lastSceneReward)
			end
		end), true)
	end)

	return janitor
end

return BattlePassFeature
