--!strict
--[[
	CaseUnboxing.luau
	Animación slot-machine del unboxing de wrap cases sobre
	UserInterface.Unboxing.Roll.WeaponLane/WrapLane (reel HORIZONTAL) +
	Unboxing.Roll.RollBtn (dispara el roll real). Unboxing.Reveal es el panel
	de resultado (Frame.Name/Rarity + Equip/Collect); Roll y Reveal son dos
	estados excluyentes del mismo Unboxing (uno visible, el otro oculto).

	Reel con REVEAL ESCALONADO + confetti, cronometrado para maximizar la
	anticipación (la dopamina pica en la espera, no en el premio):

	  0. Attract: ambos lanes hacen un drift lento en bucle hasta pulsar
	     RollBtn; al pulsar, una rampa de aceleración lleva el ciclo a
	     velocidad de crucero y arranca el roll real.
	  1. Crucero: ambas lanes giran rápido (blur = hype inicial).
	  2. El ARMA frena primero (deceleración geométrica → "casi para… casi para")
	     y se revela con un glow del color de su RAREZA. El WrapLane sigue
	     girando de fondo → el ojo salta a la lane sin resolver.
	  3. Hueco de anticipación (~0.55s): el wrap aún gira, "¿qué wrap le tocó?!".
	  4. El WRAP frena (clímax final): glow dorado, pulso mayor y CONFETTI.
	  5. Hold para leer el combo completo.

	El resultado viene ROLEADO DEL SERVER (nunca una combinación ya poseída);
	aquí solo se anima. Cada parada usa un schedule de ciclos conocido de
	antemano, así el item que recicla cuando quedan CENTER_STATE-1 ciclos
	aterriza en el centro — ahí se inyecta el resultado, invisible (entra por la
	izquierda con alpha 1), y el swap nunca se ve. La relación recycle→centro es
	válida desde cualquier estado de entrada, por eso el WrapLane puede crucear
	un tiempo indefinido de fondo y luego frenar amañado con su cola de decel.

	Los 5 items por lane ciclan 5 estados horizontales SIMÉTRICOS alrededor de
	X=0.5; el 3 es el centro (escala grande). Los bordes (1 y 5) van con alpha 1
	para entrar/salir en fundido.

	Cada item es un clon del ItemTemplate, que ES un CanvasGroup (dentro lleva un
	Container con UIGradient de rareza, ViewportFrame, Glow, Footer, Item,
	Pattern). El CanvasGroup permite mover/escalar la celda y fundir/oscurecer
	TODO de golpe con GroupTransparency/GroupColor3 — el ViewportFrame del wrap SÍ
	renderiza dentro de un CanvasGroup (soportado por Roblox), así que no hace
	falta sacarlo ni tratarlo aparte. El wrap se muestra en el ViewportFrame; el
	arma en el ImageLabel Item.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local ItemsConfig = require(Shared.constants.ItemsConfig)
local WrapCasesConfig = require(Shared.constants.WrapCasesConfig)
local LockerCategory = require(Shared.constants.LockerCategory)
local Network = require(Shared.networking.Network)
local UITheme = require(script.Parent.Parent.Parent.core.ui.UITheme)
local Confetti = require(script.Parent.Parent.Parent.core.ui.Confetti)
local BlurController = require(script.Parent.Parent.Parent.core.ui.BlurController)
local WeaponWrapPreviewer = require(script.Parent.Parent.locker.Previewers.WeaponWrapPreviewer)

export type OwnedWeaponRef = {
	category: string,
	weaponId: string,
	image: string,
}

export type PlayParams = {
	caseDefinition: WrapCasesConfig.WrapCaseDefinition,
	resultWrapId: string,
	resultWeaponCategory: string,
	resultWeaponId: string,
	ownedWeapons: { OwnedWeaponRef },
	onFinished: () -> (),
}

export type CaseUnboxing = {
	play: (self: CaseUnboxing, params: PlayParams) -> boolean,
	isPlaying: (self: CaseUnboxing) -> boolean,
}

-- ── Tuning del giro (perfil del prototipo original) ──────────
-- Antes de pulsar RollBtn ambos lanes hacen un drift lento en bucle (attract);
-- al pulsar, una rampa de aceleración lleva el ciclo de IDLE_SPEED a CRUISE_SPEED
-- y arranca el roll real.
local IDLE_SPEED = 0.7 -- duración de ciclo del drift lento (pre-RollBtn)
local ACCEL_MULT = 0.65 -- cada ciclo de la rampa dura *mult (0<mult<1 → acelera)
local CRUISE_SPEED = 0.09 -- duración de ciclo a velocidad de crucero (blur)
-- Deceleración: cada ciclo dura *mult más, hasta el umbral (ese último ciclo NO
-- se ejecuta, como en el original). Más ticks lentos = más anticipación.
-- Orden del roll: PRIMERO el arma (frena con schedule fijo), LUEGO el wrap
-- (crucea de fondo mientras el arma se resuelve y es el clímax final).
local FIRST_CRUISE_DURATION = 0.8 -- s de crucero del arma antes de frenar
local FIRST_DECEL_MULT = 1.1
local FIRST_STOP_THRESHOLD = 0.40
-- El WrapLane es el clímax: crucea de fondo mientras el arma se resuelve y
-- luego frena con su propia cola de decel (un pelín más larga → más agónica).
local CLIMAX_DECEL_MULT = 1.1
local CLIMAX_STOP_THRESHOLD = 0.50

-- ── Tuning de la revelación ──────────────────────────────────
-- Squash de anticipación del ganador antes del pop (fracción de su escala). El
-- agrandado pivota en 0.5,0.5 (AnchorPoint del container), sin mover el item.
local TEASE_SQUASH = 0.9
local COLOR_FLASH = Color3.fromRGB(255, 215, 0) -- glow dorado del clímax (wrap)
local COLOR_DARKEN = Color3.fromRGB(40, 40, 40) -- perdedores oscurecidos
-- ItemTemplate comparte estructura con el del locker (Glow + UIGradient
-- coloreados por rareza); mismo set de colores que LockerGrid._applyRarityVisuals.
local RARITY_GLOW = UITheme.LockerRarityGlow
local RARITY_GRADIENTS = UITheme.LockerRarityGradients
local RARITY_FALLBACK = "Common"
-- Hueco entre reveals: el arma ya está fijada y el wrap sigue girando. ~0.55s
-- basta para registrar el primer premio y disparar el "¿qué wrap le tocó?!".
local ANTICIPATION_GAP = 0.8
-- Tiempo que el combo final se mantiene en pantalla antes de cerrar.
local REVEAL_HOLD = 2.0

-- Fade a negro que tapa el corte CaseContent → Unboxing (in y out).
local BLACK_FADE_DURATION = 0.25

-- ── Motion del reveal final ──────────────────────────────────
-- El arma flota (bob) con dos senoides desfasadas para un vaivén orgánico (no
-- un sube-baja mecánico).
local REVEAL_BOB_SPEED = 1.9 -- rad/s de la senoide principal del bob
local REVEAL_BOB_AMPLITUDE = 0.35 -- studs de amplitud vertical del bob
-- Confetti continuo (bursts periódicos, no un solo Rain) mientras dura la
-- pantalla de reveal, para que se sienta como que sigue cayendo de fondo.
local REVEAL_CONFETTI_INTERVAL = 0.8 -- s entre bursts
local REVEAL_CONFETTI_BURST_COUNT = 36 -- piezas por burst (el Rain del climax usa 80)
local REVEAL_CONFETTI_SPAWN_DURATION = 0.3 -- escalonado del burst (menos "pop" que el climax)

-- Perfiles de reveal (tiempos + intensidad). El primero (arma) es más ágil; el
-- clímax final (wrap) tiene tease/pulso mayores y confetti.
type RevealProfile = { tease: number, hang: number, snapback: number, pulse: number, confetti: boolean }
local FIRST_REVEAL: RevealProfile = { tease = 0.4, hang = 0.3, snapback = 0.3, pulse = 1.15, confetti = false }
local CLIMAX_REVEAL: RevealProfile = { tease = 0.5, hang = 0.4, snapback = 0.4, pulse = 1.25, confetti = true }

-- Carrusel HORIZONTAL de 5 estados, SIMÉTRICO alrededor de X=0.5: 3 visibles
-- (2/3/4) + 2 bordes en fade (1 = entrando por la izquierda, 5 = saliendo por la
-- derecha). Nº impar de estados → el estado central (3) tiene los mismos vecinos
-- a cada lado, así el ganador aterriza CLAVADO en el centro (X=0.5) y el grupo
-- queda balanceado. El item avanza 1→5 (X creciente → derecha); el que llega al
-- estado 5 recicla fuera de pantalla por la izquierda (pre-estado 0 → 1).
local STATES = {
	{ X = 0.06, Scale = 0.85, Alpha = 1 },
	{ X = 0.28, Scale = 0.95, Alpha = 0.45 },
	{ X = 0.50, Scale = 1.15, Alpha = 0 },
	{ X = 0.72, Scale = 0.95, Alpha = 0.45 },
	{ X = 0.94, Scale = 0.85, Alpha = 1 },
}
local CENTER_STATE = 3
local ITEM_COUNT = #STATES
local RECYCLE_OFFSCREEN_X = -0.2

type LaneItem = {
	-- El ItemTemplate ES un CanvasGroup: se clona tal cual como celda. Se
	-- mueve/escala cada ciclo (Position + UIScale) y se funde entero (incluido el
	-- ViewportFrame, que SÍ renderiza dentro de un CanvasGroup) vía
	-- GroupTransparency/GroupColor3.
	container: CanvasGroup,
	scale: UIScale,
	-- ImageLabel (weapon) o ViewportFrame (wrap): la fuente de contenido visual.
	visual: GuiObject?,
	-- Nodos del ItemTemplate clonado (bajo Container); el lane usa uno u otro.
	slotImage: ImageLabel?,
	slotViewport: ViewportFrame?,
	-- Glow (resplandor) y UIGradient de rareza — misma estructura que el
	-- ItemTemplate del locker.
	glowNode: GuiObject?,
	rarityGradientNode: UIGradient?,
	appliedRarity: string?,
	state: number,
}

type Lane = {
	items: { LaneItem },
	-- Asigna contenido a un item (arma o wrap) según la key del pool.
	setContent: (item: LaneItem, key: any) -> (),
	randomKey: () -> any,
	targetKey: any,
}

-- Duración de cada ciclo de la cola de deceleración: *mult hasta el umbral (el
-- ciclo que cruza el umbral NO se incluye, como el `break` del prototipo).
local function buildDecelTail(startCycleTime: number, multiplier: number, threshold: number): { number }
	local schedule = {} :: { number }
	local cycleTime = startCycleTime
	while true do
		cycleTime *= multiplier
		if cycleTime >= threshold then
			break
		end
		table.insert(schedule, cycleTime)
	end
	return schedule
end

-- Schedule completo: crucero a velocidad constante durante `cruiseDuration`,
-- seguido de la cola de deceleración.
local function buildSpinSchedule(cruiseDuration: number, multiplier: number, threshold: number): { number }
	local schedule = {} :: { number }
	local constantCycles = math.max(1, math.floor(cruiseDuration / CRUISE_SPEED + 0.5))
	for _ = 1, constantCycles do
		table.insert(schedule, CRUISE_SPEED)
	end
	for _, cycleTime in buildDecelTail(CRUISE_SPEED, multiplier, threshold) do
		table.insert(schedule, cycleTime)
	end
	return schedule
end

-- Rampa de aceleración (attract → roll): cicla de fromTime hacia toTime
-- multiplicando por `mult` (<1) cada ciclo. El ciclo que baja del objetivo NO se
-- incluye (empalma con el crucero constante que viene después).
local function buildAccelRamp(fromTime: number, toTime: number, mult: number): { number }
	local schedule = {} :: { number }
	local cycleTime = fromTime * mult
	while cycleTime > toTime do
		table.insert(schedule, cycleTime)
		cycleTime *= mult
	end
	return schedule
end

local function setItemAlpha(item: LaneItem, alpha: number)
	-- Funde la celda entera (incluido el ViewportFrame) vía el CanvasGroup.
	item.container.GroupTransparency = alpha
end

local function findCenterItem(lane: Lane): LaneItem?
	for _, item in lane.items do
		if item.state == CENTER_STATE then
			return item
		end
	end
	return nil
end

local CaseUnboxing = {}
CaseUnboxing.__index = CaseUnboxing

-- Localiza el ItemTemplate (Frame plantilla con ViewportFrame + Item) dentro de
-- un lane. Se oculta al encontrarlo; los items del reel se clonan de él.
local function findLaneTemplate(laneNode: Instance): GuiObject?
	local template = laneNode:FindFirstChild("ItemTemplate")
	if template and template:IsA("GuiObject") then
		template.Visible = false
		return template
	end
	return nil
end

function CaseUnboxing.new(uiGui: ScreenGui, parentJanitor: any): CaseUnboxing?
	-- Estructura nueva: Unboxing.Roll agrupa el reel (WeaponLane/WrapLane +
	-- RollBtn) y ES el fondo (se tinta por rareza); Unboxing.Reveal agrupa el
	-- panel de resultado (Frame.Name/Rarity + Equip/Collect). Roll/Reveal se
	-- muestran/ocultan como dos estados excluyentes del mismo Unboxing.
	local frameNode = uiGui:FindFirstChild("Unboxing")
	local rollNode = if frameNode then frameNode:FindFirstChild("Roll") else nil
	local revealNode = if frameNode then frameNode:FindFirstChild("Reveal") else nil
	local weaponLaneNode = if rollNode then rollNode:FindFirstChild("WeaponLane") else nil
	local wrapLaneNode = if rollNode then rollNode:FindFirstChild("WrapLane") else nil
	local rollBtnNode = if rollNode then rollNode:FindFirstChild("RollBtn") else nil

	if not (frameNode and frameNode:IsA("GuiObject"))
		or not (rollNode and rollNode:IsA("GuiObject"))
		or not (weaponLaneNode and weaponLaneNode:IsA("GuiObject"))
		or not (wrapLaneNode and wrapLaneNode:IsA("GuiObject")) then
		warn("[CaseUnboxing] Falta UserInterface.Unboxing.Roll.WeaponLane/WrapLane; unboxing sin animación.")
		return nil
	end

	local weaponTemplate = findLaneTemplate(weaponLaneNode)
	local wrapTemplate = findLaneTemplate(wrapLaneNode)
	if not weaponTemplate or not wrapTemplate then
		warn("[CaseUnboxing] Falta ItemTemplate en WeaponLane/WrapLane; unboxing sin animación.")
		return nil
	end

	local revealCardNode = if revealNode then revealNode:FindFirstChild("Frame") else nil
	local revealNameNode = if revealCardNode then revealCardNode:FindFirstChild("Name") else nil
	local revealRarityNode = if revealCardNode then revealCardNode:FindFirstChild("Rarity") else nil
	local equipBtnNode = if revealNode then revealNode:FindFirstChild("Equip") else nil
	local collectBtnNode = if revealNode then revealNode:FindFirstChild("Collect") else nil

	local self = setmetatable({}, CaseUnboxing) :: any
	self._frame = frameNode :: GuiObject
	self._rollNode = rollNode :: GuiObject
	-- El propio Roll es el fondo: se tinta por rareza durante el giro.
	self._backgroundNode = rollNode :: GuiObject
	self._baseBackgroundColor = rollNode.BackgroundColor3
	self._weaponLaneFolder = weaponLaneNode :: GuiObject
	self._wrapLaneFolder = wrapLaneNode :: GuiObject
	self._weaponTemplate = weaponTemplate
	self._wrapTemplate = wrapTemplate
	self._rollBtn = if rollBtnNode and rollBtnNode:IsA("GuiButton") then rollBtnNode :: GuiButton else nil
	if not self._rollBtn then
		warn("[CaseUnboxing] Falta Unboxing.Roll.RollBtn; el roll arrancará automáticamente.")
	end

	self._revealNode = if revealNode and revealNode:IsA("GuiObject") then revealNode :: GuiObject else nil
	self._revealNameLabel = if revealNameNode and revealNameNode:IsA("TextLabel") then revealNameNode :: TextLabel else nil
	self._revealRarityLabel = if revealRarityNode and revealRarityNode:IsA("TextLabel") then revealRarityNode :: TextLabel else nil
	self._equipBtn = if equipBtnNode and equipBtnNode:IsA("GuiButton") then equipBtnNode :: GuiButton else nil
	self._collectBtn = if collectBtnNode and collectBtnNode:IsA("GuiButton") then collectBtnNode :: GuiButton else nil
	if not self._revealNode then
		warn("[CaseUnboxing] Falta Unboxing.Reveal; el reveal final no tendrá panel de resultado.")
	end

	-- Roll y Reveal son estados excluyentes: se arranca en Roll (Reveal oculto);
	-- el toggle real ocurre en _revealResult.
	self._rollNode.Visible = true
	if self._revealNode then
		self._revealNode.Visible = false
	end

	self._playing = false
	self._rng = Random.new()
	self._janitor = Janitor.new()
	parentJanitor:Add(self._janitor, "Destroy")
	-- Janitor por-play: items dinámicos, pool de viewports y tweens del run activo.
	self._playJanitor = Janitor.new()
	self._janitor:Add(self._playJanitor, "Destroy")

	self._frame.Visible = false

	-- Overlay negro full-screen que tapa el corte CaseContent → Unboxing.
	-- Hermano del frame de Unboxing en el mismo ScreenGui, por encima de todo.
	local fadeOverlay = Instance.new("Frame")
	fadeOverlay.Name = "UnboxingFade"
	fadeOverlay.Size = UDim2.fromScale(1, 1)
	fadeOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	fadeOverlay.BackgroundTransparency = 1
	fadeOverlay.BorderSizePixel = 0
	fadeOverlay.ZIndex = 1000
	fadeOverlay.Visible = false
	fadeOverlay.Parent = uiGui
	self._janitor:Add(fadeOverlay, "Destroy")
	self._fadeOverlay = fadeOverlay

	return self
end

-- Tapa la pantalla en negro (fade in) o la destapa (fade out). Bloqueante:
-- espera a que el tween termine antes de continuar la orquestación.
function CaseUnboxing:_fadeScreen(toOpaque: boolean)
	local overlay = self._fadeOverlay
	overlay.Visible = true
	local tween = self:_playTween(overlay, TweenInfo.new(BLACK_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = if toOpaque then 0 else 1,
	})
	task.wait(BLACK_FADE_DURATION)
	if not toOpaque then
		overlay.Visible = false
	end
	return tween
end

function CaseUnboxing:isPlaying(): boolean
	return self._playing
end

-- true si los items del run fueron destruidos (teardown del feature a mitad de
-- animación) — las corrutinas abortan sin tocar instancias muertas.
local function laneTornDown(lane: Lane): boolean
	return lane.items[1].container.Parent == nil
end

-- Registra un tween en el janitor del play (se cancela si el feature muere a
-- mitad de animación) y lo reproduce.
function CaseUnboxing:_playTween(instance: Instance, tweenInfo: TweenInfo, goals: { [string]: any }): Tween
	local tween = TweenService:Create(instance, tweenInfo, goals)
	self._playJanitor:Add(tween, "Cancel")
	tween:Play()
	return tween
end

-- ── Construcción de lanes ────────────────────────────────────

function CaseUnboxing:_createLaneItem(template: GuiObject, laneFolder: GuiObject, initialState: number): LaneItem
	-- El ItemTemplate ES un CanvasGroup: se clona tal cual como celda. Se posiciona
	-- horizontalmente por X y se funde entero (incluido el ViewportFrame, que SÍ
	-- renderiza dentro de un CanvasGroup) con GroupTransparency.
	local container = template:Clone() :: CanvasGroup
	container.Name = "ReelItem"
	container.Visible = true
	container.AnchorPoint = Vector2.new(0.5, 0.5)

	local existingScale = container:FindFirstChildOfClass("UIScale")
	local scale = existingScale or Instance.new("UIScale")
	if not existingScale then
		scale.Name = "ReelScale"
		scale.Parent = container
	end

	-- Contenido bajo ItemTemplate.Container (fallback al propio container legacy).
	local contentNode = container:FindFirstChild("Container") or container
	local slotImageNode = contentNode:FindFirstChild("Item")
	local slotViewportNode = contentNode:FindFirstChild("ViewportFrame")
	local glowNode = contentNode:FindFirstChild("Glow")
	-- UIGradient de rareza: el que cuelga directo de Container (el de Glow es nieto).
	local rarityGradient = contentNode:FindFirstChildOfClass("UIGradient")

	local state = STATES[initialState]
	container.Position = UDim2.fromScale(state.X, 0.5)
	scale.Scale = state.Scale
	container.GroupTransparency = state.Alpha
	container.Parent = laneFolder
	self._playJanitor:Add(container, "Destroy")

	return {
		container = container,
		scale = scale,
		visual = nil,
		slotImage = if slotImageNode and slotImageNode:IsA("ImageLabel") then slotImageNode else nil,
		slotViewport = if slotViewportNode and slotViewportNode:IsA("ViewportFrame") then slotViewportNode else nil,
		glowNode = if glowNode and glowNode:IsA("GuiObject") then glowNode else nil,
		rarityGradientNode = rarityGradient,
		state = initialState,
	}
end

-- Colorea Glow + UIGradient de la celda según rareza — igual que
-- LockerGrid._applyRarityVisuals. Cachea la última rareza aplicada para no
-- re-teñir en cada reciclo si el item mantiene la misma rareza.
local function applyRarityVisuals(item: LaneItem, rarity: string)
	if item.appliedRarity == rarity then
		return
	end
	item.appliedRarity = rarity

	local glowColor = RARITY_GLOW[rarity] or RARITY_GLOW[RARITY_FALLBACK]
	local glowNode = item.glowNode
	if glowNode and glowColor then
		if glowNode:IsA("ImageLabel") or glowNode:IsA("ImageButton") then
			glowNode.ImageColor3 = glowColor
		elseif glowNode:IsA("Frame") then
			glowNode.BackgroundColor3 = glowColor
		end
	end

	local gradient = RARITY_GRADIENTS[rarity] or RARITY_GRADIENTS[RARITY_FALLBACK]
	if item.rarityGradientNode and gradient then
		item.rarityGradientNode.Color = gradient
	end
end

-- WeaponLane: pool de armas poseídas → el ImageLabel `Item` del template.
function CaseUnboxing:_buildWeaponLane(ownedWeapons: { OwnedWeaponRef }, targetWeapon: OwnedWeaponRef): Lane
	local items = {} :: { LaneItem }
	for index = 1, ITEM_COUNT do
		local item = self:_createLaneItem(self._weaponTemplate, self._weaponLaneFolder, index)
		-- Arma: se muestra la imagen (Item); el ViewportFrame del template no se usa.
		if item.slotViewport then
			item.slotViewport.Visible = false
		end
		if item.slotImage then
			item.slotImage.Visible = true
			item.visual = item.slotImage
		end
		table.insert(items, item)
	end

	local rng = self._rng
	local lane: Lane = {
		items = items,
		setContent = function(item: LaneItem, key: any)
			local weapon = key :: OwnedWeaponRef
			local icon = item.slotImage
			if icon then
				icon.Image = weapon.image
				icon.ImageColor3 = Color3.fromRGB(255, 255, 255)
			end
			local categoryConfig = (ItemsConfig :: any)[weapon.category]
			local weaponDefinition = if type(categoryConfig) == "table" then categoryConfig[weapon.weaponId] else nil
			local rarity = tostring(if type(weaponDefinition) == "table" then weaponDefinition.Rarity or "Common" else "Common")
			applyRarityVisuals(item, rarity)
		end,
		randomKey = function()
			return ownedWeapons[rng:NextInteger(1, #ownedWeapons)]
		end,
		targetKey = targetWeapon,
	}
	return lane
end

function CaseUnboxing:_buildWrapLane(caseDefinition: WrapCasesConfig.WrapCaseDefinition, resultWrapId: string): Lane?
	-- IDs de wrap posibles (items de la case + el resultado), solo los que tienen
	-- definición válida en ItemsConfig.
	local wrapIdSet = {} :: { [string]: boolean }
	for _, caseItem in caseDefinition.Items do
		if type(ItemsConfig.WeaponWraps[caseItem.WrapId]) == "table" then
			wrapIdSet[caseItem.WrapId] = true
		end
	end
	if type(ItemsConfig.WeaponWraps[resultWrapId]) == "table" then
		wrapIdSet[resultWrapId] = true
	end
	if not wrapIdSet[resultWrapId] then
		-- Sin definición del wrap resultado no hay nada que animar.
		return nil
	end

	local wrapIds = {} :: { string }
	for wrapId in wrapIdSet do
		table.insert(wrapIds, wrapId)
	end
	table.sort(wrapIds) -- orden estable para el rng

	local items = {} :: { LaneItem }
	for index = 1, ITEM_COUNT do
		local item = self:_createLaneItem(self._wrapTemplate, self._wrapLaneFolder, index)
		-- Wrap: se muestra el ViewportFrame 3D; la imagen (Item) del template no se usa.
		if item.slotImage then
			item.slotImage.Visible = false
		end
		if item.slotViewport then
			item.slotViewport.Visible = true
			item.visual = item.slotViewport
		end
		table.insert(items, item)
	end

	-- Janitor por item: limpia el render 3D anterior antes de renderizar el
	-- siguiente wrap (cada reciclo cambia de wrap).
	local renderJanitors = {} :: { [LaneItem]: any }

	local rng = self._rng
	local lane: Lane = {
		items = items,
		setContent = function(item: LaneItem, key: any)
			local wrapId = key :: string
			local target = item.slotViewport
			local wrapDefinition = ItemsConfig.WeaponWraps[wrapId]
			if not target or type(wrapDefinition) ~= "table" then
				return
			end

			-- Render DIRECTO en el ViewportFrame del item, como el locker
			-- (WeaponWrapPreviewer.Render). El enfoque master+copy (clonar un
			-- WorldModel ya parenteado entre viewports) deja el viewport en blanco:
			-- Roblox no re-renderiza contenido 3D clonado entre ViewportFrames.
			local jan = renderJanitors[item]
			if jan then
				jan:Cleanup() -- destruye el WorldModel/Camera/texturas del wrap anterior
			else
				jan = Janitor.new()
				renderJanitors[item] = jan
				self._playJanitor:Add(jan, "Destroy")
			end

			local ok = WeaponWrapPreviewer.Render(target, {
				TextureID = wrapDefinition.TextureID,
				BaseColor = wrapDefinition.BaseColor,
				Material = wrapDefinition.Material,
				isAnimated = wrapDefinition.isAnimated,
				StudsPerTile = wrapDefinition.StudsPerTile,
			}, jan)
			if ok then
				WeaponWrapPreviewer.reframeCentered(target)
			end
			target.ImageColor3 = Color3.fromRGB(255, 255, 255)
			item.visual = target

			applyRarityVisuals(item, tostring(wrapDefinition.Rarity or "Common"))
		end,
		randomKey = function()
			return wrapIds[rng:NextInteger(1, #wrapIds)]
		end,
		targetKey = resultWrapId,
	}
	return lane
end

-- ── Giro ─────────────────────────────────────────────────────

function CaseUnboxing:_updateBackground(color: Color3, duration: number)
	if not self._backgroundNode then return end
	self:_playTween(self._backgroundNode, TweenInfo.new(duration, Enum.EasingStyle.Sine), { BackgroundColor3 = color })
end

-- Avanza una lane UN ciclo. El item que estaba en el último estado recicla por la
-- izquierda: recibe el resultado (targetKey) si `landTarget`, o contenido random.
function CaseUnboxing:_advanceLane(lane: Lane, duration: number, landTarget: boolean, driveBackground: boolean)
	local motionInfo = TweenInfo.new(duration, Enum.EasingStyle.Linear)
	local visualInfo = TweenInfo.new(duration * 1.5, Enum.EasingStyle.Sine)
	for _, item in lane.items do
		if item.state == ITEM_COUNT then
			item.state = 0
			item.container.Position = UDim2.fromScale(RECYCLE_OFFSCREEN_X, 0.5)
			item.scale.Scale = STATES[1].Scale
			lane.setContent(item, if landTarget then lane.targetKey else lane.randomKey())
			setItemAlpha(item, STATES[1].Alpha)
		end

		item.state += 1
		local target = STATES[item.state]
		self:_playTween(item.container, motionInfo, { Position = UDim2.fromScale(target.X, 0.5) })
		self:_playTween(item.scale, visualInfo, { Scale = target.Scale })
		-- Fade de entrada/salida de la celda entera (simétrico en ambos bordes).
		self:_playTween(item.container, visualInfo, { GroupTransparency = target.Alpha })
		
		if item.state == CENTER_STATE and driveBackground then
			local rarity = item.appliedRarity or RARITY_FALLBACK
			local glowColor = RARITY_GLOW[rarity] or RARITY_GLOW[RARITY_FALLBACK] or Color3.fromRGB(0,0,0)
			self:_updateBackground(glowColor, duration)
		end
	end
end

-- Recorre un schedule frenando la lane. El item que recicla cuando quedan
-- exactamente CENTER_STATE-1 ciclos aterriza en el centro → recibe el resultado
-- (tras reciclar necesita CENTER_STATE-1 avances para llegar al estado central).
function CaseUnboxing:_spinSchedule(lane: Lane, schedule: { number }, driveBackground: boolean)
	local totalCycles = #schedule
	for cycleIndex, duration in ipairs(schedule) do
		if laneTornDown(lane) then
			return
		end
		self:_advanceLane(lane, duration, (totalCycles - cycleIndex) == (CENTER_STATE - 1), driveBackground)
		task.wait(duration)
	end
end

-- ── Revelación (una lane; se llama escalonada por lane) ──────

function CaseUnboxing:_revealLane(lane: Lane, glowColor: Color3, profile: RevealProfile)
	if laneTornDown(lane) then
		return
	end

	-- Eleva el item ganador por encima de sus vecinos de lane durante el reveal.
	local center = findCenterItem(lane)
	if center then
		center.container.ZIndex = 10
		if center.visual then
			center.visual.ZIndex = 10
		end
	end

	-- Tease: anticipación de ESCALA del ganador (squash) sin desplazamiento — el
	-- item se queda centrado y el agrandado pivota en 0.5,0.5 (el reel es
	-- horizontal, un dip vertical se leía como que el ganador "baja").
	local teaseInfo = TweenInfo.new(profile.tease, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
	if center then
		self:_playTween(center.scale, teaseInfo, { Scale = STATES[center.state].Scale * TEASE_SQUASH })
	end
	task.wait(profile.tease)

	-- Hang: los no-ganadores se oscurecen (celda entera vía GroupColor3 del
	-- CanvasGroup — tiñe el compuesto ya renderizado, viewport incluido).
	local darkenInfo = TweenInfo.new(profile.hang, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, item in lane.items do
		if item ~= center then
			self:_playTween(item.container, darkenInfo, { GroupColor3 = COLOR_DARKEN })
		end
	end
	task.wait(profile.hang)

	-- Glow (clon del visual que se expande y disuelve) + pulso del ganador. El
	-- pulso escala el UIScale del container (AnchorPoint 0.5,0.5 → crece centrado).
	if center then
		local visual = center.visual
		if visual then
			local glow = visual:Clone()
			glow.Name = "GlowEffect"
			-- Clon de ViewportFrame: re-mapear su cámara al clon.
			if glow:IsA("ViewportFrame") then
				local camera = glow:FindFirstChildOfClass("Camera")
				if camera then
					glow.CurrentCamera = camera
				end
			end
			(glow :: any).ImageColor3 = glowColor
			glow.ZIndex = visual.ZIndex - 1
			-- Mismo padre que el visual para que el ZIndex compare contra sus hermanos.
			glow.Parent = visual.Parent
			self._playJanitor:Add(glow, "Destroy")

			self:_playTween(glow, TweenInfo.new(0.6, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), {
				Size = UDim2.fromScale(1.5, 1.5),
				Position = UDim2.fromScale(-0.25, -0.25),
				ImageTransparency = 1,
			})
		end

		local targetScale = STATES[center.state].Scale
		center.scale.Scale = targetScale * profile.pulse
		self:_playTween(center.scale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = targetScale })
	end

	if profile.confetti then
		Confetti.Rain(self._frame)
	end

	task.wait(profile.snapback)
end

-- ── Reveal final (arma+wrap en el mundo) ─────────────────────

-- CFrame de mundo de un marcador del reveal, que puede ser un Attachment (marcador
-- ligero sin render/colisión — lo preferido), un BasePart o un Model.
local function markerWorldCFrame(node: Instance): CFrame?
	if node:IsA("Attachment") then
		return node.WorldCFrame
	elseif node:IsA("BasePart") then
		return node.CFrame
	elseif node:IsA("Model") then
		return node:GetPivot()
	end
	return nil
end

-- Resuelve los nodos de mundo del reveal (cámara + spawn + cámara de vuelta al
-- Locker). FindFirstChild (no WaitForChild) para degradar con gracia si el mapa
-- no los tiene: sin ellos el reveal salta la parte 3D pero mantiene el swap del
-- botón para volver a la Store. cameraTarget/spawnTarget aceptan Attachment/
-- BasePart (el spawn además Model) — el diseñador puede marcarlos con
-- Attachments, más limpios que Parts invisibles. lockerCameraTarget es el mismo
-- Workspace.Cameras.locker que usa LockerCameraController.
function CaseUnboxing:_resolveRevealNodes(): (Instance?, Instance?, BasePart?)
	local camerasFolder = Workspace:FindFirstChild("Cameras")
	local lockerFolder = Workspace:FindFirstChild("Locker")
	local cameraNode = if camerasFolder then camerasFolder:FindFirstChild("reveal") else nil
	local spawnNode = if lockerFolder then lockerFolder:FindFirstChild("RevealSpawn") else nil
	local lockerCameraNode = if camerasFolder then camerasFolder:FindFirstChild("locker") else nil
	local cameraTarget = if cameraNode and (cameraNode:IsA("Attachment") or cameraNode:IsA("BasePart")) then cameraNode else nil
	local spawnTarget = if spawnNode and (spawnNode:IsA("Attachment") or spawnNode:IsA("BasePart") or spawnNode:IsA("Model")) then spawnNode else nil
	local lockerCameraTarget = if lockerCameraNode and lockerCameraNode:IsA("BasePart") then lockerCameraNode :: BasePart else nil
	return cameraTarget, spawnTarget, lockerCameraTarget
end

-- Entra a la escena del reveal (cámara + sin blur) DESDE el arranque del Roll,
-- no solo en el reveal final: todo el unboxing (giro + reveal) transcurre en
-- Workspace.Cameras.reveal, sin el blur del Store. Al terminar (Equip/Collect,
-- o teardown a mitad) volvemos SIEMPRE a Workspace.Cameras.locker (la misma
-- que usa LockerCameraController) — pase o no por la escena 3D de
-- Workspace.Cameras.reveal (que puede no existir aún en el mapa); sin esa
-- parte, degradamos al estado previo a abrir la Store.
function CaseUnboxing:_enterRevealCamera()
	local cameraTarget, _spawnTarget, lockerCameraTarget = self:_resolveRevealNodes()

	-- La escena 3D del reveal ocupa toda la pantalla: quitamos el blur del Store
	-- (queda tapado por el negro del fade) y lo restauramos en el cleanup del play.
	BlurController.suppress("Unboxing")
	self._playJanitor:Add(function()
		BlurController.unsuppress("Unboxing")
	end, true)

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local savedType = camera.CameraType
	local savedCFrame = camera.CFrame
	local savedSubject = camera.CameraSubject
	self._playJanitor:Add(function()
		-- Preferimos la cámara del Locker si existe; si no, volvemos al estado
		-- previo (la vista de donde se abrió la Store).
		if lockerCameraTarget then
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = lockerCameraTarget.CFrame
			return
		end
		camera.CameraType = savedType
		if savedSubject and savedSubject.Parent then
			camera.CameraSubject = savedSubject
		end
		-- Reponer SIEMPRE el CFrame guardado: en este juego la cámara del
		-- lobby/locker es Scriptable, así que sin esto la cámara se quedaría
		-- clavada en la posición del reveal (restaurar solo el CameraType es
		-- no-op si ya era Scriptable). En una cámara Custom el set es inocuo
		-- (se recalcula al siguiente frame).
		if savedCFrame then
			camera.CFrame = savedCFrame
		end
	end, true)

	-- Cámara → Workspace.Cameras.reveal, si el mapa la tiene. Fija, sin parallax.
	local cameraCFrame = if cameraTarget then markerWorldCFrame(cameraTarget) else nil
	if cameraCFrame then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = cameraCFrame
	end
end

-- Tras el hold del combo: arma+wrap aplicados en Workspace.Locker.RevealSpawn,
-- se oculta Roll (lanes + fondo + RollBtn) y se muestra Reveal con el
-- Name/Rarity del wrap resultado. Bloquea hasta que el jugador pulsa Equip o
-- Collect (o el feature se destruye) — al volver, el cleanup del play
-- restaura cámara/blur, Roll/Reveal, y `onFinished` devuelve a la Store.
function CaseUnboxing:_revealResult(params: PlayParams, teardownSentinel: Lane)
	local _cameraTarget, spawnTarget = self:_resolveRevealNodes()

	-- Fade a negro: tapa el corte reel → escena 3D del reveal final.
	self:_fadeScreen(true)

	-- Arma + wrap aplicados en Workspace.Locker.RevealSpawn.
	local revealModel: PVInstance? = nil
	local revealModelBase: CFrame? = nil
	local spawnCFrame = if spawnTarget then markerWorldCFrame(spawnTarget) else nil
	if spawnTarget and spawnCFrame then
		local wrapDefinition = ItemsConfig.WeaponWraps[params.resultWrapId]
		local validDef = type(wrapDefinition) == "table"
		local model = WeaponWrapPreviewer.buildWeaponModelWithWrap({
			TextureID = if validDef then wrapDefinition.TextureID else nil,
			BaseColor = if validDef then wrapDefinition.BaseColor else nil,
			Material = if validDef then wrapDefinition.Material else nil,
			isAnimated = if validDef then wrapDefinition.isAnimated else nil,
			StudsPerTile = if validDef then wrapDefinition.StudsPerTile else nil,
			PreviewWeaponCategory = params.resultWeaponCategory,
			PreviewWeaponId = params.resultWeaponId,
		}, self._playJanitor)
		if model and model:IsA("PVInstance") then
			model:PivotTo(spawnCFrame)
			-- Un Model no puede colgar de un Attachment: se parenta a la parte que
			-- lo contiene (Attachment.Parent), o al propio nodo si es Part/Model.
			model.Parent = if spawnTarget:IsA("Attachment") then spawnTarget.Parent else spawnTarget
			revealModel = model
			revealModelBase = spawnCFrame
		end
	end

	-- Motion loop: el arma flota (bob orgánico). La cámara del reveal se queda
	-- FIJA (los efectos de cámara van en el roll, no aquí). RenderStepped para que
	-- vaya suave; se limpia con el janitor del play.
	if revealModel then
		local elapsed = 0
		self._playJanitor:Add(RunService.RenderStepped:Connect(function(dt)
			elapsed += dt

			-- Bob orgánico: senoide principal + una armónica lenta desfasada.
			if (revealModel :: any).Parent and revealModelBase then
				local y = math.sin(elapsed * REVEAL_BOB_SPEED) * REVEAL_BOB_AMPLITUDE
					+ math.sin(elapsed * REVEAL_BOB_SPEED * 0.5 + 1.3) * REVEAL_BOB_AMPLITUDE * 0.3
				revealModel:PivotTo(revealModelBase * CFrame.new(0, y, 0))
			end
		end), "Disconnect")
	end

	-- Roll → Reveal: se ocultan lanes+fondo+RollBtn (todo cuelga de Roll) y se
	-- muestra el panel de resultado. Se restauran al limpiar el play para el
	-- siguiente open.
	self._rollNode.Visible = false
	self._playJanitor:Add(function()
		self._rollNode.Visible = true
	end, true)

	-- Rellena Name/Rarity del wrap resultado (coloreado por rareza, mismo
	-- patrón que CaseContentPanel).
	local wrapDefinition = ItemsConfig.WeaponWraps[params.resultWrapId]
	local validDef = type(wrapDefinition) == "table"
	local wrapRarity = tostring(if validDef then wrapDefinition.Rarity or RARITY_FALLBACK else RARITY_FALLBACK)
	if self._revealNameLabel then
		self._revealNameLabel.Text = tostring(if validDef then wrapDefinition.Name or params.resultWrapId else params.resultWrapId)
	end
	if self._revealRarityLabel then
		self._revealRarityLabel.Text = wrapRarity
		local rarityColor = UITheme.RarityColors[wrapRarity]
		if rarityColor then
			self._revealRarityLabel.TextColor3 = rarityColor
		end
	end

	if self._revealNode then
		self._revealNode.Visible = true
		self._playJanitor:Add(function()
			(self._revealNode :: GuiObject).Visible = false
		end, true)
	end

	-- Destapar la pantalla ya con la escena de reveal montada.
	self:_fadeScreen(false)

	-- Confetti continuo (bursts periódicos) mientras dura la pantalla de reveal.
	-- Se detiene con el flag al limpiar el play (COLLECT/EQUIP o teardown).
	local confettiStopped = false
	self._playJanitor:Add(function()
		confettiStopped = true
	end, true)
	task.spawn(function()
		while not confettiStopped do
			if laneTornDown(teardownSentinel) then
				return
			end
			Confetti.Rain(self._frame, {
				count = REVEAL_CONFETTI_BURST_COUNT,
				spawnDuration = REVEAL_CONFETTI_SPAWN_DURATION,
			})
			task.wait(REVEAL_CONFETTI_INTERVAL)
		end
	end)

	-- Esperar Equip o Collect (o teardown del feature → los items del reel se
	-- destruyen). Equip además dispara la red para equipar el wrap ganado.
	local equipBtn = self._equipBtn
	local collectBtn = self._collectBtn
	if equipBtn or collectBtn then
		local finished = false
		if equipBtn then
			equipBtn.Active = true
			self._playJanitor:Add(equipBtn.Activated:Connect(function()
				Network.Shop.EquipItem.Send({
					category = LockerCategory.WEAPON_WRAPS,
					itemId = params.resultWrapId,
					weaponCategory = params.resultWeaponCategory,
					weaponId = params.resultWeaponId,
				})
				finished = true
			end), "Disconnect")
		end
		if collectBtn then
			collectBtn.Active = true
			self._playJanitor:Add(collectBtn.Activated:Connect(function()
				finished = true
			end), "Disconnect")
		end
		while not finished do
			if laneTornDown(teardownSentinel) then
				return
			end
			task.wait()
		end
	else
		-- Sin botones: auto-collect tras un breve hold para leer el reveal.
		task.wait(1.5)
	end
end

-- ── Orquestación ─────────────────────────────────────────────

function CaseUnboxing:_run(params: PlayParams)
	local targetWeapon: OwnedWeaponRef? = nil
	for _, weapon in params.ownedWeapons do
		if weapon.category == params.resultWeaponCategory and weapon.weaponId == params.resultWeaponId then
			targetWeapon = weapon
			break
		end
	end

	-- Defensa: el server garantiza que el arma es del inventario; si el estado
	-- local aún no lo refleja, construimos la ref desde el catálogo.
	if not targetWeapon then
		local categoryConfig = (ItemsConfig :: any)[params.resultWeaponCategory]
		local weaponDefinition = if type(categoryConfig) == "table" then categoryConfig[params.resultWeaponId] else nil
		targetWeapon = {
			category = params.resultWeaponCategory,
			weaponId = params.resultWeaponId,
			image = tostring(if type(weaponDefinition) == "table" then weaponDefinition.Image or "" else ""),
		}
	end

	local weaponLane = self:_buildWeaponLane(params.ownedWeapons, targetWeapon :: OwnedWeaponRef)
	local wrapLane = self:_buildWrapLane(params.caseDefinition, params.resultWrapId)
	if not wrapLane then
		warn("[CaseUnboxing] No se pudo renderizar el wrap del resultado:", params.resultWrapId)
		return
	end

	-- Contenido inicial de los 5 items de cada lane (aleatorio del pool) con el
	-- alpha de su estado — sin esto, el primer frame mostraría items vacíos.
	for _, lane in { weaponLane, wrapLane :: Lane } do
		for _, item in lane.items do
			lane.setContent(item, lane.randomKey())
			setItemAlpha(item, STATES[item.state].Alpha)
		end
	end

	-- Fade a negro: tapa el corte CaseContent → Unboxing, el salto de cámara a
	-- Workspace.Cameras.reveal y la supresión del blur. El frame se activa
	-- mientras la pantalla está en negro y se destapa ya con el reel montado —
	-- el Roll (giro) transcurre en la misma cámara/sin blur que el reveal final.
	self:_fadeScreen(true)
	self:_enterRevealCamera()
	self._frame.Visible = true
	self:_fadeScreen(false)

	-- Attract: ambos lanes hacen un drift lento en bucle hasta que el jugador
	-- pulsa RollBtn; entonces una rampa los acelera hasta el crucero real.
	local rollStarted = false
	local rollBtn = self._rollBtn
	if rollBtn then
		rollBtn.Visible = true
		rollBtn.Active = true
		self._playJanitor:Add(rollBtn.Activated:Connect(function()
			rollStarted = true
		end), "Disconnect")
	else
		-- Sin botón: arranca solo tras un breve drift.
		task.delay(1.0, function()
			rollStarted = true
		end)
	end

	while not rollStarted do
		if laneTornDown(weaponLane) or laneTornDown(wrapLane) then
			return
		end
		self:_advanceLane(weaponLane, IDLE_SPEED, false, true)
		self:_advanceLane(wrapLane, IDLE_SPEED, false, false)
		task.wait(IDLE_SPEED)
	end

	-- Pulsado: ocultar el botón y acelerar (rampa IDLE_SPEED → CRUISE_SPEED).
	if rollBtn then
		rollBtn.Visible = false
		rollBtn.Active = false
	end
	for _, duration in buildAccelRamp(IDLE_SPEED, CRUISE_SPEED, ACCEL_MULT) do
		if laneTornDown(weaponLane) or laneTornDown(wrapLane) then
			return
		end
		self:_advanceLane(weaponLane, duration, false, true)
		self:_advanceLane(wrapLane, duration, false, false)
		task.wait(duration)
	end

	-- El WrapLane crucea de fondo (contenido aleatorio) hasta que le pedimos
	-- frenar; entonces recorre su cola de decel amañada. `finished` es monótono
	-- (sin race de BindableEvent): el flujo principal lo poll-ea.
	local wrapControl = { beginStop = false, finished = false, driveBackground = false }
	local wrapStopSchedule = buildDecelTail(CRUISE_SPEED, CLIMAX_DECEL_MULT, CLIMAX_STOP_THRESHOLD)
	task.spawn(function()
		pcall(function()
			while not wrapControl.beginStop do
				if laneTornDown(wrapLane) then
					return
				end
				self:_advanceLane(wrapLane, CRUISE_SPEED, false, wrapControl.driveBackground)
				task.wait(CRUISE_SPEED)
			end
			self:_spinSchedule(wrapLane, wrapStopSchedule, true)
		end)
		wrapControl.finished = true
	end)

	-- 1) El ARMA gira (crucero + decel) y se revela con el glow de su rareza.
	self:_spinSchedule(weaponLane, buildSpinSchedule(FIRST_CRUISE_DURATION, FIRST_DECEL_MULT, FIRST_STOP_THRESHOLD), true)
	local weaponCategoryConfig = (ItemsConfig :: any)[params.resultWeaponCategory]
	local weaponDefinition = if type(weaponCategoryConfig) == "table" then weaponCategoryConfig[params.resultWeaponId] else nil
	local weaponRarity = tostring(if type(weaponDefinition) == "table" then weaponDefinition.Rarity or "Common" else "Common")
	local weaponGlow = UITheme.RarityColors[weaponRarity] or COLOR_FLASH
	self:_revealLane(weaponLane, weaponGlow, FIRST_REVEAL)

	-- El arma ha terminado su roll. Ahora el Wrap toma el control del fondo.
	wrapControl.driveBackground = true

	-- 2) Hueco de anticipación: el arma ya está; el wrap sigue girando.
	task.wait(ANTICIPATION_GAP)

	-- 3) Frenar el wrap y esperar a que fije (polling del flag monótono).
	wrapControl.beginStop = true
	while not wrapControl.finished do
		if laneTornDown(wrapLane) then
			break
		end
		task.wait()
	end

	-- 4) Reveal del wrap: clímax (glow dorado + pulso mayor + confetti).
	self:_revealLane(wrapLane, COLOR_FLASH, CLIMAX_REVEAL)
	-- Opcional: el fondo final se puede forzar al COLOR_FLASH o la rareza final.
	self:_updateBackground(COLOR_FLASH, 0.5)

	-- 5) Hold (~2s) para leer el combo completo antes del reveal.
	task.wait(REVEAL_HOLD)

	-- 6) Reveal final: fade a negro, arma+wrap en Workspace.Locker.RevealSpawn,
	--    se oculta Roll y se muestra el panel Reveal (Equip/Collect) — al pulsar
	--    cualquiera se vuelve a la Store.
	self:_revealResult(params, weaponLane)
end

-- Lanza la animación (no bloquea). Devuelve false si ya hay una en curso.
function CaseUnboxing:play(params: PlayParams): boolean
	if self._playing then
		return false
	end
	if #params.ownedWeapons == 0 then
		-- Sin pool de armas no hay reel que girar; termina directo.
		params.onFinished()
		return true
	end

	self._playing = true
	task.spawn(function()
		local ok, err = pcall(function()
			self:_run(params)
		end)
		if not ok then
			warn("[CaseUnboxing] Animación abortada:", err)
		end
		-- Cleanup del run: items, pool de viewports, tweens.
		self._playJanitor:Cleanup()
		self._frame.Visible = false
		if self._backgroundNode and self._baseBackgroundColor then
			self._backgroundNode.BackgroundColor3 = self._baseBackgroundColor
		end
		self._playing = false
		params.onFinished()
	end)
	return true
end

return CaseUnboxing
