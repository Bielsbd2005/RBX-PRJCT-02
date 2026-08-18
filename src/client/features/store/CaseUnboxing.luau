--!strict
--[[
	CaseUnboxing.luau
	Unboxing LOCAL y físico. Al abrir el detalle de una case, `showIdleChest`
	clona ReplicatedStorage.ChestModel arriba y lo deja CAER (squash & stretch,
	motor de resortes) hasta asentarse sobre Workspace.Cases.FallPosition: un cofre
	que cae a la vista al destaparse la transición y luego queda idle esperando la
	compra. Ese MISMO cofre persiste entre plays y se destruye al cerrar el detalle
	(`hideIdleChest`).

	Al comprar, `play` reutiliza el cofre: enciende el BillboardGui
	ChestModel.Box.RollBillboard y el reel de rareza gira dentro de
	RollBillboard.RollFrame, clonando el Template que hay dentro
	(Template.Container.ViewportFrame = render 3D del wrap; Template.Container.Value =
	% de drop de ese wrap en la case). El "juice" va coreografiado: wind-up
	(anticipación + agachado) → barrido con la VIBRACIÓN DEL COFRE ACOPLADA al reel
	(intensidad ∝ velocidad, un "ka-chunk" por item que cruza el centro, impacto al
	clavar el ganador) → reveal. Al terminar, el cofre calma la vibración y vuelve
	a idle (billboard apagado, quieto en FallPosition).

	Además, el reel EMITE BEATS DE CÁMARA (onReelTick por item que cruza el centro,
	con strength ∝ lentitud; onReelLand al clavar el ganador) que el Store mapea a
	kicks de cámara: rumble mientras vuela → jolts secos al frenar → golpe al land →
	boom del reveal. Este módulo no toca la cámara; solo señala los beats.

	El resultado llega ROLEADO DEL SERVER (nunca un duplicado); aquí solo se anima.
	Ya NO hay cámara de reveal propia: la cámara se queda en la de 'cases' todo el
	rato (es la que encuadra el RevealSpawn). Tras el reel (reveal pop en el
	billboard), el cofre se OCULTA, el arma con el wrap ganador se planta en
	Workspace.Locker.RevealSpawn (con bob orgánico) y se avisa al Store, que resalta
	la card ganadora en CaseContent.Main y cambia la barra Nav a Equip/Collect;
	BLOQUEA hasta que el jugador lo descarta.

	El reel es un flujo INFINITO de wraps que se desplaza en horizontal y decelera
	con ease-out hasta dejar al ganador clavado en el centro. La escala y la
	opacidad de cada celda se calculan cada frame en función de su distancia al
	centro (una "lente" gaussiana): el item que pasa por el centro crece — ese es
	el gancho. Con object pooling: un puñado de celdas se reciclan generando wraps
	random a medida que entran por la derecha, salvo el índice final (targetIndex),
	que siempre lleva el resultado roleado por el server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local ItemsConfig = require(Shared.constants.ItemsConfig)
local WrapCasesConfig = require(Shared.constants.WrapCasesConfig)
local Notify = require(script.Parent.Parent.Parent.core.ui.NotificationController)
local UITheme = require(script.Parent.Parent.Parent.core.ui.UITheme)
local Confetti = require(script.Parent.Parent.Parent.core.ui.Confetti)
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
	-- Se dispara al entrar en el reveal (cofre ya oculto). El Store lo usa para
	-- cambiar la barra Nav de CaseContent a los botones Equip/Collect.
	onRevealShown: (() -> ())?,
	-- Bloqueante: el reveal espera aquí hasta que el jugador lo descarta
	-- (Equip/Collect). Sin él, el reveal se mantiene RESULT_HOLD s y sigue solo.
	awaitDismiss: (() -> ())?,
	-- Beats del reel para ACOPLAR la cámara (los conduce el Store). onReelTick se
	-- dispara una vez por item que cruza el centro durante la deceleración, con
	-- `strength` 0→1 según lo lento que vaya el tick (rápido≈0, casi parado≈1) →
	-- rumble de cámara que se vuelve jolts secos al frenar. onReelLand se dispara al
	-- clavar el ganador (golpe seco, un beat antes del boom del reveal). Opcionales:
	-- sin ellos el reel anima igual, solo que la cámara no reacciona al giro.
	onReelTick: ((strength: number) -> ())?,
	onReelLand: (() -> ())?,
	onFinished: () -> (),
}

export type CaseUnboxing = {
	play: (self: CaseUnboxing, params: PlayParams) -> boolean,
	isPlaying: (self: CaseUnboxing) -> boolean,
	showIdleChest: (self: CaseUnboxing) -> (),
	hideIdleChest: (self: CaseUnboxing) -> (),
}

--============================================================
-- SPRING: oscilador armónico amortiguado (motor del "juice").
-- Da continuidad de velocidad → movimiento mantequilla, sin los "cortes" de
-- encadenar tweens que frenan a 0 en cada paso.
--============================================================
local Spring = {}
Spring.__index = Spring

function Spring.new(frequency: number, damping: number, initial: number)
	return setmetatable({
		f = frequency,
		d = damping,
		p = initial,
		v = 0,
		target = initial,
	}, Spring)
end

function Spring:setInstant(value: number) -- coloca el resorte "cargado" para que rebote
	self.p = value
	self.v = 0
end

function Spring:impulse(force: number)
	self.v += force
end

function Spring:update(dt: number): number
	local w = self.f * 2 * math.pi
	local damper = 2 * self.d * w
	local k = w * w
	local a = k * (self.target - self.p) - damper * self.v
	self.v += a * dt
	self.p += self.v * dt
	return self.p
end

-- ── Tuning de la caída (drop-in al abrir el detalle) ─────────
local CHEST_FALL_HEIGHT = 38 -- studs por encima de FallPosition donde arranca
local CHEST_TILT_X, CHEST_TILT_Z = 20, -16 -- inclinación inicial (grados)

-- ── Tuning del "juice" del roll (vibración ACOPLADA al reel) ──
-- La vibración ya no es random e independiente del reel (se veía desincronizada):
-- ahora sale de la propia velocidad del reel y de cada item que cruza el centro,
-- así el temblor "tiene sentido" con lo que se ve girar.
local CHARGE_TIME = 0.5 -- s de anticipación (rumble creciente) antes de soltar el spin
local CHARGE_RUMBLE = 0.7 -- intensidad de vibración al final de la carga
local CHARGE_CROUCH = 0.28 -- pre-squash (agachado) al arrancar el spin → se libera hacia arriba
local SPIN_REF_SPEED = 11 -- units/s del reel que mapean a vibración máxima (1)
local SPIN_STRUGGLE_MIN = 0.12 -- vibración mínima mientras el reel rueda (nunca del todo quieto)
-- Ratchet: cada item que cruza el centro pega un "ka-chunk". Los ticks lentos
-- (al final del barrido) pegan MÁS fuerte → tensión de máquina tragaperras.
local TICK_SQUASH = 0.11 -- squash base por tick
local TICK_LUNGE_DEG = 20 -- tirón lateral base por tick (grados)
-- Impacto al clavar el ganador en el centro: el clímax, sincronizado con el land.
local LAND_SQUASH = 0.6
local LAND_LUNGE_DEG = 42

-- ── Tuning del reel (scroll continuo con lente de magnificación) ──
-- El reel es un flujo INFINITO de celdas que se desplaza horizontalmente y
-- decelera con ease-out hasta dejar al ganador clavado en el centro. La escala y
-- la opacidad de cada celda NO son estados discretos: se calculan cada frame en
-- función de su distancia al centro (una "lente" gaussiana) — eso es lo que hace
-- que el item que pasa por el centro crezca y sea adictivo.
local ITEM_SPACING = 0.14 -- separación entre celdas (fracción del ancho de RollFrame)
local VISIBLE_RADIUS = 3 -- celdas a cada lado del centro que se renderizan (pooling)
local SPIN_ITEMS = 28 -- nº de items que pasan por el centro antes de parar (más = más largo)
local SPIN_DURATION = 5.0 -- s del barrido; ease-out Quint → deceleración "casi para…"
local START_INDEX = VISIBLE_RADIUS + 1 -- arranque desde un índice >0 → reel lleno desde el frame 1

-- Lente: escala por distancia al centro (en "item units"). En el centro
-- SCALE_CENTER; hacia los lados cae suavemente hacia SCALE_EDGE (campana). Campana
-- estrecha + pico alto = el item del centro "bulge-ea" con fuerza y los vecinos se
-- encogen → el ojo se pega al centro (el gancho del reel).
local SCALE_CENTER = 1.24
local SCALE_EDGE = 0.78
local LENS_SIGMA = 0.82 -- ancho de la campana (item units)
-- Opacidad: totalmente visible en la banda central; se desvanece al acercarse a
-- los bordes del RollFrame (entradas/salidas en fundido).
local FADE_START = 1.6 -- dxUnits donde empieza a desvanecer
local FADE_END = 2.6 -- dxUnits donde ya es invisible

-- Squash de anticipación del ganador antes del pop (fracción de su escala).
local TEASE_SQUASH = 0.9

-- Reveal: tras el land, el ganador hace un tease (squash), un pop elástico y un
-- burst de glow (clon de su propio render, coloreado por rareza) — el toque AAA.
local REVEAL_TEASE = 0.4
local REVEAL_PULSE = 1.25
local REVEAL_SNAPBACK = 0.4
local REVEAL_GLOW_DURATION = 0.6
local REVEAL_GLOW_SCALE = 2.0 -- tamaño final del burst (múltiplo del tamaño del wrap)
local RARITY_FALLBACK = "Common"
local GLOW_FALLBACK_COLOR = Color3.fromRGB(255, 215, 0)
-- Confetti (fullscreen) solo en las rarezas altas: el drop se siente especial.
local CONFETTI_RARITIES = { Epic = true, Legendary = true }

-- ColorSequence para el Template.UIGradient de cada celda del reel, derivada del
-- color de rareza (bordes oscurecidos, centro brillante) para dar ese shimmer.
-- Memoizada por rareza: el render corre por cada celda reciclada, varias veces
-- por segundo durante el spin, y las ColorSequences son inmutables.
local rarityGradientCache = {} :: { [string]: ColorSequence }
local function gradientForRarity(rarity: string): ColorSequence
	local cached = rarityGradientCache[rarity]
	if cached then
		return cached
	end
	local base = UITheme.RarityColors[rarity] or UITheme.RarityColors[RARITY_FALLBACK]
	local dark = base:Lerp(Color3.new(0, 0, 0), 0.4)
	local bright = base:Lerp(Color3.new(1, 1, 1), 0.25)
	local seq = ColorSequence.new({
		ColorSequenceKeypoint.new(0, dark),
		ColorSequenceKeypoint.new(0.5, bright),
		ColorSequenceKeypoint.new(1, dark),
	})
	rarityGradientCache[rarity] = seq
	return seq
end

-- Tiempo que el cofre se queda con el resultado antes de ocultarse (fallback si
-- no se pasa awaitDismiss).
local RESULT_HOLD = 3.0

-- ── Motion del arma+wrap ganador plantado en RevealSpawn ─────
-- El arma flota (bob) con dos senoides desfasadas para un vaivén orgánico (no un
-- sube-baja mecánico).
local REVEAL_BOB_SPEED = 1.9 -- rad/s de la senoide principal del bob
local REVEAL_BOB_AMPLITUDE = 0.35 -- studs de amplitud vertical del bob
-- El arma del reveal va a 1.5× su tamaño de gameplay.
local REVEAL_MODEL_SCALE = 1.5

type Cell = {
	container: GuiObject, -- clon del Template (celda que se mueve/escala/funde)
	scale: UIScale,
	viewport: ViewportFrame?, -- Container.ViewportFrame: render 3D del wrap
	value: TextLabel?, -- Container.Value: % de drop del wrap
	gradient: UIGradient?, -- Template.UIGradient: teñido por la rareza del wrap
	appliedRarity: string?, -- rareza ya aplicada al gradiente (evita re-teñir)
	renderJanitor: any?, -- limpia el render 3D anterior al reasignar la celda
	index: number?, -- índice lógico asignado en el flujo (nil = libre en el pool)
}

type Reel = {
	cells: { Cell }, -- pool fijo de celdas (object pooling)
	free: { Cell }, -- celdas libres del pool
	active: { [number]: Cell }, -- índice del flujo → celda que lo muestra
	folder: GuiObject,
	render: (cell: Cell, wrapId: string) -> (),
	contentForIndex: (index: number) -> string, -- ganador en targetIndex, random el resto
	targetIndex: number, -- índice del flujo donde vive el ganador (final del scroll)
}

-- ── Helpers de reel ──────────────────────────────────────────

-- Funde la celda entera (incluido el ViewportFrame) si el Template es un
-- CanvasGroup; si no, la degradación es no fundir (el reel gira igual).
local function setCellAlpha(cell: GuiObject, alpha: number)
	if cell:IsA("CanvasGroup") then
		(cell :: CanvasGroup).GroupTransparency = alpha
	end
end

-- Lente de magnificación: campana gaussiana centrada en dxUnits=0.
local function lensScale(dxUnits: number): number
	local t = dxUnits / LENS_SIGMA
	return SCALE_EDGE + (SCALE_CENTER - SCALE_EDGE) * math.exp(-(t * t))
end

-- Opacidad (GroupTransparency): 0 en la banda central, 1 pasado el borde.
local function lensTransparency(dxUnits: number): number
	return math.clamp((dxUnits - FADE_START) / (FADE_END - FADE_START), 0, 1)
end

-- true si las celdas del reel fueron destruidas (teardown a mitad de animación):
-- las corrutinas abortan sin tocar instancias muertas.
local function reelTornDown(reel: Reel): boolean
	return reel.cells[1].container.Parent == nil
end

local CaseUnboxing = {}
CaseUnboxing.__index = CaseUnboxing

function CaseUnboxing.new(uiGui: ScreenGui, parentJanitor: any): CaseUnboxing?
	local chestTemplate = ReplicatedStorage:FindFirstChild("ChestModel")
	if not (chestTemplate and chestTemplate:IsA("Model")) then
		warn("[CaseUnboxing] Falta ReplicatedStorage.ChestModel (Model); unboxing sin animación.")
		return nil
	end

	local self = setmetatable({}, CaseUnboxing) :: any
	self._chestTemplate = chestTemplate :: Model
	self._uiGui = uiGui -- fullscreen host para el confetti del reveal (rarezas altas)
	self._playing = false
	self._rng = Random.new()
	self._janitor = Janitor.new()
	parentJanitor:Add(self._janitor, "Destroy")
	-- Janitor por-play: items del reel, renders 3D y tweens del run activo (NO el
	-- cofre: ese vive en _chestJanitor y persiste entre plays).
	self._playJanitor = Janitor.new()
	self._janitor:Add(self._playJanitor, "Destroy")
	-- Janitor del cofre idle: cofre + billboard (en PlayerGui) + motor de pose.
	-- Vive desde showIdleChest hasta hideIdleChest, cruzando varios plays.
	self._chestJanitor = Janitor.new()
	self._janitor:Add(self._chestJanitor, "Destroy")
	-- Estado del cofre idle (nil hasta showIdleChest).
	self._chest = nil :: Model?
	self._motion = nil :: any
	self._rollBillboard = nil :: BillboardGui?
	self._rollFrameGui = nil :: GuiObject?
	self._reelTemplate = nil :: GuiObject?
	return self
end

function CaseUnboxing:isPlaying(): boolean
	return self._playing
end

-- Registra un tween en el janitor del play (se cancela si el feature muere a
-- mitad de animación) y lo reproduce.
function CaseUnboxing:_playTween(instance: Instance, tweenInfo: TweenInfo, goals: { [string]: any }): Tween
	local tween = TweenService:Create(instance, tweenInfo, goals)
	self._playJanitor:Add(tween, "Cancel")
	tween:Play()
	return tween
end

-- Tween registrado en el janitor DEL COFRE (no del play): la caída de entrada y
-- el asentado del cofre viven en su propio ciclo de vida, no en el del play.
function CaseUnboxing:_chestTween(instance: Instance, tweenInfo: TweenInfo, goals: { [string]: any }): Tween
	local tween = TweenService:Create(instance, tweenInfo, goals)
	self._chestJanitor:Add(tween, "Cancel")
	tween:Play()
	return tween
end

-- Tween BLOQUEANTE de la trayectoria rígida del cofre (pathValue).
function CaseUnboxing:_tweenChestPath(motion: any, target: CFrame, time: number, style: Enum.EasingStyle, direction: Enum.EasingDirection)
	local tween = self:_chestTween(motion.pathValue, TweenInfo.new(time, style, direction), { Value = target })
	tween.Completed:Wait()
end

-- ── Cofre físico (idle en FallPosition + squash & stretch) ───

-- Resuelve el CFrame de mundo de FallPosition (Attachment o BasePart).
local function nodeWorldCFrame(node: Instance): CFrame?
	if node:IsA("Attachment") then
		return node.WorldCFrame
	elseif node:IsA("BasePart") then
		return node.CFrame
	end
	return nil
end

-- Igual que nodeWorldCFrame pero también acepta un Model: el marcador RevealSpawn
-- puede ser Attachment, BasePart o Model.
local function markerWorldCFrame(node: Instance): CFrame?
	if node:IsA("Model") then
		return node:GetPivot()
	end
	return nodeWorldCFrame(node)
end

-- Monta el motor de pose del cofre EN REPOSO sobre `endCFrame` (FallPosition):
-- captura piezas para squash & stretch no uniforme y arranca un Heartbeat que
-- compone stretch por velocidad + impacto (squash) + forcejeo (ruido Perlin).
-- Devuelve un `motion` con el pathValue (trayectoria rígida) y los resortes para
-- que `_run` lo coreografíe. En idle el forcejeo está apagado, así que el cofre
-- solo se asienta quieto en FallPosition.
-- `stablePart`, si se pasa (la parte que hostea el RollBillboard), se EXCLUYE
-- del squash/forcejeo: solo sigue la trayectoria limpia (`pathCF`, sin
-- `struggleCF` ni escala). Así el cofre puede forcejear todo el rato sin que
-- el billboard (y el reel dentro) tiemble o se desplace con él — el resto de
-- piezas sigue temblando normalmente (más vivo, más AAA).
-- El motor vive en `_chestJanitor` (ciclo de vida del cofre idle), no en el play.
-- El cofre NACE arriba (CHEST_FALL_HEIGHT + tilt) para caer con `_dropInChest`;
-- `endCFrame` es el reposo sobre FallPosition. `motion.settled` pasa a true
-- cuando termina la caída (play espera a que aterrice antes de rolar).
function CaseUnboxing:_buildChestMotion(chest: Model, endCFrame: CFrame, stablePart: BasePart?): any
	local startCFrame = endCFrame
		* CFrame.new(0, CHEST_FALL_HEIGHT, 0)
		* CFrame.Angles(math.rad(CHEST_TILT_X), 0, math.rad(CHEST_TILT_Z))
	chest:PivotTo(startCFrame)

	-- Captura de piezas: tamaño original + transform relativo al pivote para
	-- escalar (squash/stretch) alrededor del pivote sin deformar la jerarquía.
	-- `stablePart` se captura aparte (mismo cálculo de `rel`) y NO entra en
	-- `pieces`, así `applyPose` (squash/forcejeo) nunca la toca.
	local basePivot = chest:GetPivot()
	local pieces = {} :: { { part: BasePart, size: Vector3, rel: CFrame } }
	local stableRel: CFrame? = nil
	for _, d in chest:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true -- controlamos la pose manualmente
			local rel = basePivot:ToObjectSpace(d.CFrame)
			if stablePart and d == stablePart then
				stableRel = rel
			else
				table.insert(pieces, {
					part = d,
					size = d.Size,
					rel = rel,
				})
			end
		end
	end

	local function applyPose(pivotCF: CFrame, scale: Vector3)
		for _, info in pieces do
			local rel = info.rel
			local pos = rel.Position
			local scaledPos = Vector3.new(pos.X * scale.X, pos.Y * scale.Y, pos.Z * scale.Z)
			info.part.CFrame = pivotCF * (CFrame.new(scaledPos) * rel.Rotation)
			info.part.Size = info.size * scale
		end
	end

	local pathValue = Instance.new("CFrameValue")
	pathValue.Value = startCFrame
	self._chestJanitor:Add(pathValue, "Destroy")

	local motion = {
		pathValue = pathValue,
		startCFrame = startCFrame,
		endCFrame = endCFrame,
		applyPose = applyPose,
		squashSpring = Spring.new(10, 0.30, 0), -- subamortiguado → pop elástico
		lungeX = Spring.new(6, 0.40, 0), -- tirones internos (radianes)
		lungeZ = Spring.new(6, 0.40, 0),
		struggleIntensity = 0,
		settled = false, -- true cuando la caída de entrada termina
		seed = math.random() * 1000,
		lastY = startCFrame.Position.Y,
	}

	local connection = RunService.Heartbeat:Connect(function(dt)
		if not chest.Parent then
			return
		end
		dt = math.min(dt, 1 / 45) -- estabilidad del resorte ante lag spikes

		local pathCF = motion.pathValue.Value

		-- Stretch automático por velocidad vertical.
		local y = pathCF.Position.Y
		local vy = (y - motion.lastY) / math.max(dt, 1e-4)
		motion.lastY = y
		local speedStretch = math.clamp(math.abs(vy) * 0.006, 0, 0.55)
		if vy > 0 then
			speedStretch *= 0.6 -- estira menos al subir que al caer
		end

		-- Squash por impacto.
		local squash = motion.squashSpring:update(dt)

		-- Forcejeo orgánico (ruido Perlin + tirones), con rampa de intensidad.
		local lx = motion.lungeX:update(dt)
		local lz = motion.lungeZ:update(dt)
		local struggleCF = CFrame.identity
		if motion.struggleIntensity > 0.001 then
			local t = os.clock()
			local maxTilt = math.rad(9)
			local n1 = math.noise(t * 5.5, motion.seed, 0.0)
			local n2 = math.noise(motion.seed, t * 6.1, 0.0)
			local n3 = math.noise(t * 9.0, motion.seed, 5.0)
			local rx = (n1 * maxTilt + lx) * motion.struggleIntensity
			local rz = (n2 * maxTilt + lz) * motion.struggleIntensity
			local lift = math.abs(n3) * 0.35 * motion.struggleIntensity
			struggleCF = CFrame.new(0, lift, 0) * CFrame.Angles(rx, 0, rz)
		end

		-- Composición de escala (conserva volumen aprox.).
		local sy = math.max(1 + speedStretch - squash, 0.25)
		local sxz = math.max(1 - speedStretch * 0.42 + squash * 0.58, 0.25)

		applyPose(pathCF * struggleCF, Vector3.new(sxz, sy, sxz))

		-- La parte estable sigue SOLO el path limpio (sin forcejeo ni escala).
		if stablePart and stableRel then
			stablePart.CFrame = pathCF * stableRel
		end
	end)
	self._chestJanitor:Add(connection, "Disconnect")

	motion.dispose = function()
		connection:Disconnect()
		pcall(function()
			pathValue:Destroy()
		end)
	end

	return motion
end

-- Coreografía de la caída de entrada (al abrir el detalle): anticipación
-- (overshoot arriba) → caída acelerada → rebotes con squash decreciente. Corre en
-- su propia corrutina (no bloquea showIdleChest) y marca `motion.settled` al
-- terminar. Bloquea vía _tweenChestPath entre pasos.
function CaseUnboxing:_dropInChest(chest: Model, motion: any)
	-- 1. Anticipación (overshoot hacia arriba desde el punto de spawn).
	local anticipation = motion.startCFrame
		* CFrame.new(0, 2.5, 0)
		* CFrame.Angles(math.rad(-10), 0, math.rad(10))
	self:_tweenChestPath(motion, anticipation, 0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	if not chest.Parent then return end

	-- 2. Caída (acelerada como gravedad) → impacto (squash fuerte → rebote).
	self:_tweenChestPath(motion, motion.endCFrame, 0.32, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
	motion.squashSpring:setInstant(0.5)
	if not chest.Parent then return end

	-- 3. Rebotes con squash/stretch decreciente.
	local bounces = {
		{ height = 3.4, up = 0.18, down = 0.16, squash = 0.32 },
		{ height = 1.2, up = 0.13, down = 0.12, squash = 0.18 },
		{ height = 0.35, up = 0.09, down = 0.08, squash = 0.09 },
	}
	for _, b in bounces do
		if not chest.Parent then return end
		self:_tweenChestPath(motion, motion.endCFrame * CFrame.new(0, b.height, 0), b.up, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
		self:_tweenChestPath(motion, motion.endCFrame, b.down, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		motion.squashSpring:setInstant(b.squash)
	end
end

-- Genera el cofre en lo alto sobre Workspace.Cases.FallPosition y lo deja CAER
-- (drop-in) hasta asentarse; luego queda idle hasta que `play` lo reutiliza.
-- Idempotente: si ya hay un cofre vivo, no hace nada. Sin FallPosition/ChestModel/
-- estructura del billboard, degrada dejando el estado sin cofre (play hará el
-- reveal sin reel).
--
-- El BillboardGui se mueve YA a PlayerGui (apagado, con Adornee = Box) porque un
-- BillboardGui SOLO rasteriza el contenido 3D de un ViewportFrame si vive en
-- PlayerGui y apunta a la parte del mundo vía Adornee; colgado del cofre en
-- Workspace el viewport del reel saldría en blanco. Queda "pegado" al cofre (Box
-- va por la trayectoria limpia, sin forcejeo). Se registra en _chestJanitor: al
-- moverlo fuera del cofre ya no lo destruye chest:Destroy().
function CaseUnboxing:showIdleChest()
	if self._chest and (self._chest :: Model).Parent then
		return -- ya hay un cofre idle en escena
	end

	local casesFolder = Workspace:FindFirstChild("Cases")
	local fallNode = if casesFolder then casesFolder:FindFirstChild("FallPosition") else nil
	local endCFrame = if fallNode then nodeWorldCFrame(fallNode) else nil
	if not endCFrame then
		warn("[CaseUnboxing] Falta Workspace.Cases.FallPosition (Attachment/BasePart); sin cofre idle.")
		return
	end

	local chest = self._chestTemplate:Clone()
	self._chestJanitor:Add(chest, "Destroy")

	local box = chest:FindFirstChild("Box")
	local rollBillboard = if box then box:FindFirstChild("RollBillboard") else nil
	local rollFrame = if rollBillboard then rollBillboard:FindFirstChild("RollFrame") else nil
	local templateNode = if rollFrame then rollFrame:FindFirstChild("Template") else nil
	local rollFrameGui = if rollFrame and rollFrame:IsA("GuiObject") then rollFrame :: GuiObject else nil
	local template = if templateNode and templateNode:IsA("GuiObject") then templateNode :: GuiObject else nil

	-- Billboard apagado en idle; el Template es solo la plantilla del reel.
	if rollBillboard and rollBillboard:IsA("BillboardGui") then
		rollBillboard.Enabled = false
	end
	if template then
		template.Visible = false
	end

	-- Motor de pose. Nace arriba (para caer). `box` (si es BasePart) se excluye
	-- del squash/forcejeo → el billboard nunca tiembla con el cofre.
	local motion = self:_buildChestMotion(chest, endCFrame, if box and box:IsA("BasePart") then box :: BasePart else nil)
	chest.Parent = casesFolder or Workspace

	-- Billboard → PlayerGui (apagado, Adornee = Box) listo para renderizar el reel
	-- cuando se encienda en `play`.
	if rollBillboard and rollBillboard:IsA("BillboardGui") and box and box:IsA("BasePart") then
		local playerGui = if self._uiGui then self._uiGui.Parent else Players.LocalPlayer:FindFirstChild("PlayerGui")
		if playerGui then
			rollBillboard.Adornee = box :: BasePart
			rollBillboard.Parent = playerGui
			self._chestJanitor:Add(rollBillboard, "Destroy")
		end
	end

	self._chest = chest
	self._motion = motion
	self._rollBillboard = if rollBillboard and rollBillboard:IsA("BillboardGui") then rollBillboard :: BillboardGui else nil
	self._rollFrameGui = rollFrameGui
	self._reelTemplate = template

	-- Drop-in ASÍNCRONO: showIdleChest se llama con la pantalla en negro (fade de
	-- la transición del CaseContent); la caída corre en su corrutina para que la
	-- transición no se bloquee y el cofre caiga a la vista justo al destaparse.
	task.spawn(function()
		self:_dropInChest(chest, motion)
		motion.settled = true
	end)
end

-- Destruye el cofre idle (y su billboard/motor). Se llama al cerrar el detalle
-- de la case. Idempotente.
function CaseUnboxing:hideIdleChest()
	self._chestJanitor:Cleanup()
	self._chest = nil
	self._motion = nil
	self._rollBillboard = nil
	self._rollFrameGui = nil
	self._reelTemplate = nil
end

-- Anticipación antes de soltar el spin (BLOQUEANTE, ~CHARGE_TIME): la vibración
-- sube (rumble creciente) y termina con un pre-squash (agachado) que se libera
-- hacia arriba justo cuando arranca el reel — el "wind up" que le da sentido al
-- roll. La vibración del propio barrido la conduce _runReel (acoplada al reel),
-- así que aquí solo cargamos la tensión.
function CaseUnboxing:_chargeUpChest(chest: Model, motion: any)
	local t0 = os.clock()
	while os.clock() - t0 < CHARGE_TIME and chest.Parent do
		local a = (os.clock() - t0) / CHARGE_TIME
		-- Curva acelerada: el rumble crece más rápido al final (a²) → tensión.
		motion.struggleIntensity = a * a * CHARGE_RUMBLE
		-- Micro-golpes esporádicos que se aceleran al acercarse el disparo.
		if self._rng:NextNumber() < a * 0.35 then
			local dir = if self._rng:NextNumber() < 0.5 then 1 else -1
			motion.lungeZ:impulse(math.rad(self._rng:NextInteger(8, 18)) * dir)
		end
		RunService.Heartbeat:Wait()
	end
	-- Pre-squash (agachado) → al soltarse, el resorte lo lanza hacia arriba a la
	-- vez que el reel arranca a máxima velocidad.
	motion.squashSpring:setInstant(CHARGE_CROUCH)
end

-- ── Reel de wraps (dentro del BillboardGui) ──────────────────

-- El reel posiciona cada celda A MANO (Position por distancia al centro). Un
-- UIListLayout/UIGridLayout/UITableLayout en RollFrame (patrón habitual en
-- plantillas de "reel") pelearía con eso: reordena los hijos en fila por
-- LayoutOrder e IGNORA el Position que le pongamos, así que todo se ve
-- apilado a la izquierda y nunca "para" en el centro. Se desactiva (no se
-- destruye, por si el diseñador lo reutiliza) al montar el reel.
local function disableConflictingLayouts(folder: GuiObject)
	for _, child in folder:GetChildren() do
		if child:IsA("UIListLayout") or child:IsA("UIGridLayout") or child:IsA("UITableLayout") or child:IsA("UIPageLayout") then
			(child :: any).Enabled = false
		end
	end
end

function CaseUnboxing:_createCell(template: GuiObject, folder: GuiObject): Cell
	local container = template:Clone()
	container.Name = "ReelItem"
	container.Visible = false -- las celdas libres del pool quedan ocultas
	container.AnchorPoint = Vector2.new(0.5, 0.5)

	local existingScale = container:FindFirstChildOfClass("UIScale")
	local scale = existingScale or Instance.new("UIScale")
	if not existingScale then
		scale.Name = "ReelScale"
		scale.Parent = container
	end

	-- Contenido bajo Template.Container (fallback al propio container).
	local contentNode = container:FindFirstChild("Container") or container
	local viewportNode = contentNode:FindFirstChild("ViewportFrame")
	local valueNode = contentNode:FindFirstChild("Value")
	-- Template.UIGradient (directo en la celda): se tiñe por rareza en render.
	local gradientNode = container:FindFirstChildOfClass("UIGradient")

	container.Parent = folder
	self._playJanitor:Add(container, "Destroy")

	return {
		container = container,
		scale = scale,
		viewport = if viewportNode and viewportNode:IsA("ViewportFrame") then viewportNode else nil,
		value = if valueNode and valueNode:IsA("TextLabel") then valueNode else nil,
		gradient = gradientNode,
		appliedRarity = nil,
		renderJanitor = nil,
		index = nil,
	}
end

function CaseUnboxing:_buildContinuousReel(params: PlayParams, folder: GuiObject, template: GuiObject): Reel?
	local caseDefinition = params.caseDefinition
	local resultWrapId = params.resultWrapId

	-- IDs de wrap posibles (items de la case + el resultado) con definición válida.
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
		return nil -- sin definición del resultado no hay nada que animar
	end

	local wrapIds = {} :: { string }
	for wrapId in wrapIdSet do
		table.insert(wrapIds, wrapId)
	end
	table.sort(wrapIds) -- orden estable para el rng

	-- Pool fijo: basta con cubrir la ventana visible (VISIBLE_RADIUS a cada lado)
	-- más un colchón para las celdas que entran/salen por los bordes.
	local cellCount = VISIBLE_RADIUS * 2 + 3
	local cells = {} :: { Cell }
	local free = {} :: { Cell }
	for _ = 1, cellCount do
		local cell = self:_createCell(template, folder)
		table.insert(cells, cell)
		table.insert(free, cell)
	end

	local rng = self._rng
	local targetIndex = START_INDEX + SPIN_ITEMS

	-- Contenido por índice del flujo: cacheado (estable) — el ganador vive
	-- SIEMPRE en targetIndex; el resto es un wrap aleatorio del pool de la case.
	local contentCache = {} :: { [number]: string }
	local function contentForIndex(index: number): string
		if index == targetIndex then
			return resultWrapId
		end
		local cached = contentCache[index]
		if cached then
			return cached
		end
		local wrapId = wrapIds[rng:NextInteger(1, #wrapIds)]
		contentCache[index] = wrapId
		return wrapId
	end

	-- Solo avisamos UNA vez por motivo (evita spamear el Output: esto corre por
	-- cada celda reciclada, varias veces por segundo durante el spin).
	local warnedNoDefinition = false
	local warnedNoViewport = false
	local warnedRenderFailed = false

	local function render(cell: Cell, wrapId: string)
		local wrapDefinition = ItemsConfig.WeaponWraps[wrapId]
		if type(wrapDefinition) ~= "table" then
			if not warnedNoDefinition then
				warnedNoDefinition = true
				warn("[CaseUnboxing] wrapId sin definición en ItemsConfig.WeaponWraps:", wrapId)
			end
			return
		end

		-- % de drop de este wrap en la case → Container.Value.
		if cell.value then
			local chance = WrapCasesConfig.GetChancePercent(caseDefinition, wrapId)
			cell.value.Text = string.format("%d%%", math.floor(chance + 0.5))
		end

		-- Template.UIGradient teñido por la rareza del wrap. Guard por rareza ya
		-- aplicada: al reciclar la celda casi siempre repite rareza (evita reasignar
		-- la ColorSequence en cada frame del spin).
		if cell.gradient then
			local rarity = tostring(wrapDefinition.Rarity or RARITY_FALLBACK)
			if cell.appliedRarity ~= rarity then
				cell.appliedRarity = rarity
				cell.gradient.Color = gradientForRarity(rarity)
			end
		end

		local target = cell.viewport
		if not target then
			if not warnedNoViewport then
				warnedNoViewport = true
				warn("[CaseUnboxing] La celda clonada del reel no tiene Container.ViewportFrame; revisa la jerarquía de ChestModel.Box.RollBillboard.RollFrame.Template.")
			end
			return
		end

		-- Render DIRECTO en el ViewportFrame de la celda (como el locker). El
		-- janitor por celda destruye el WorldModel del wrap anterior al reasignar.
		local jan = cell.renderJanitor
		if jan then
			jan:Cleanup()
		else
			jan = Janitor.new()
			cell.renderJanitor = jan
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
		elseif not warnedRenderFailed then
			warnedRenderFailed = true
			warn("[CaseUnboxing] WeaponWrapPreviewer.Render no encontró primaryPart al renderizar", wrapId, "— revisa ReplicatedStorage.Wrap (o el modelo del arma).")
		end
		target.ImageColor3 = Color3.fromRGB(255, 255, 255)
	end

	local reel: Reel = {
		cells = cells,
		free = free,
		active = {},
		folder = folder,
		render = render,
		contentForIndex = contentForIndex,
		targetIndex = targetIndex,
	}
	return reel
end

-- Reposiciona el flujo para una posición de scroll dada (en "item units": el
-- índice que queda clavado en el centro es floor/frac de scrollPos). Recicla las
-- celdas fuera de la ventana (generación infinita) y aplica la lente de escala/
-- opacidad por distancia al centro. `applyLens` permite congelar la escala
-- durante el reveal (el pop del ganador la controla a mano).
function CaseUnboxing:_layoutReel(reel: Reel, scrollPos: number, applyLens: boolean)
	local base = math.floor(scrollPos)
	local lo = base - VISIBLE_RADIUS
	local hi = base + VISIBLE_RADIUS + 1

	-- Liberar celdas que salieron de la ventana → vuelven al pool (ocultas).
	for index, cell in reel.active do
		if index < lo or index > hi then
			cell.container.Visible = false
			cell.index = nil
			reel.active[index] = nil
			table.insert(reel.free, cell)
		end
	end

	-- Asignar celda a cada índice visible que aún no la tenga → render + mostrar.
	for index = lo, hi do
		if index >= 0 and not reel.active[index] then
			local cell = table.remove(reel.free)
			if cell then
				cell.index = index
				reel.active[index] = cell
				reel.render(cell, reel.contentForIndex(index))
				cell.container.Visible = true
			end
		end
	end

	-- Posición + lente de cada celda activa por su distancia al centro.
	for index, cell in reel.active do
		local dxUnits = index - scrollPos
		cell.container.Position = UDim2.fromScale(0.5 + dxUnits * ITEM_SPACING, 0.5)
		local adx = math.abs(dxUnits)
		-- El más cercano al centro pinta por encima de sus vecinos (solape natural).
		cell.container.ZIndex = math.max(1, math.floor(100 - adx * 10 + 0.5))
		if applyLens then
			cell.scale.Scale = lensScale(adx)
			setCellAlpha(cell.container, lensTransparency(adx))
		end
	end
end

-- Barrido con deceleración: scroll continuo de START_INDEX a targetIndex con
-- ease-out Quint (el clásico "casi para… casi para"). La lente se recalcula cada
-- frame → los items crecen al pasar por el centro. Bloqueante hasta parar; NO
-- dispara el reveal (eso lo hace `_run`, después de aquietar el cofre — ver nota
-- ahí sobre por qué el reveal no puede ir pegado al spin).
--
-- Si se pasa `motion`, la vibración del cofre se ACOPLA al reel en el mismo loop:
--   • intensidad de temblor ∝ velocidad del reel (rápido = tiembla fuerte; al
--     frenar, se calma) → nunca se ve desincronizado;
--   • cada item que cruza el centro dispara un "ka-chunk" (squash + tirón),
--     y los ticks lentos del final pegan más fuerte (tensión de tragaperras);
--   • al clavar el ganador, un IMPACTO fuerte sincronizado con el land.
function CaseUnboxing:_runReel(reel: Reel, motion: any?, onTick: ((strength: number) -> ())?, onLand: (() -> ())?)
	local scrollValue = Instance.new("NumberValue")
	scrollValue.Value = START_INDEX
	self._playJanitor:Add(scrollValue, "Destroy")

	local lastScroll = START_INDEX
	local lastTickIndex = math.floor(START_INDEX)

	-- Layout + vibración acoplada, dirigidos por el valor de scroll (cada frame).
	local layoutConn = RunService.RenderStepped:Connect(function(dt)
		if reelTornDown(reel) then
			return
		end
		local pos = scrollValue.Value
		self:_layoutReel(reel, pos, true)

		if motion then
			-- Velocidad del reel (item units/s) → intensidad de temblor.
			local speed = math.abs(pos - lastScroll) / math.max(dt, 1e-4)
			motion.struggleIntensity = math.clamp(speed / SPIN_REF_SPEED, SPIN_STRUGGLE_MIN, 1)

			-- Ratchet: un "ka-chunk" por cada item que cruza el centro. Cuanto más
			-- lento va (menor speed), más fuerte el chunk → los últimos ticks pegan.
			local idx = math.floor(pos)
			if idx ~= lastTickIndex then
				lastTickIndex = idx
				local slow = math.clamp(1.25 - speed / SPIN_REF_SPEED, 0.3, 1.25)
				motion.squashSpring:impulse(TICK_SQUASH * slow)
				local dir = if self._rng:NextNumber() < 0.5 then 1 else -1
				motion.lungeZ:impulse(math.rad(TICK_LUNGE_DEG) * slow * dir)
				-- Beat de cámara acoplado al mismo tick: strength ∝ lentitud (0.3→1.25
				-- normalizado a 0→1). Rápido = base pequeña (rumble del barrido); al
				-- frenar los ticks se espacian y pegan más → jolts secos de tensión.
				if onTick then
					onTick(math.clamp((slow - 0.3) / 0.95, 0, 1))
				end
			end
			lastScroll = pos
		end
	end)
	self._playJanitor:Add(layoutConn, "Disconnect")

	-- Frame inicial poblado antes del primer render.
	self:_layoutReel(reel, START_INDEX, true)

	local tween = self:_playTween(scrollValue, TweenInfo.new(SPIN_DURATION, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Value = reel.targetIndex,
	})
	tween.Completed:Wait()
	if reelTornDown(reel) then
		return
	end

	-- Fijar la parada exacta y congelar el layout: a partir de aquí el reveal
	-- controla la escala del ganador a mano (si no, este loop la sobrescribiría
	-- cada frame) y su posición ya no se toca — queda clavado en X=0.5.
	self:_layoutReel(reel, reel.targetIndex, true)
	layoutConn:Disconnect()

	-- IMPACTO del land: el clímax, sincronizado con el ganador clavado en el
	-- centro. Squash fuerte (el cofre "acusa" el golpe) + tirón + temblor a tope.
	if motion then
		motion.squashSpring:setInstant(LAND_SQUASH)
		local dir = if self._rng:NextNumber() < 0.5 then 1 else -1
		motion.lungeX:impulse(math.rad(LAND_LUNGE_DEG) * dir)
		motion.struggleIntensity = 1
	end
	-- Golpe de cámara sincronizado con el impacto del land (un beat antes del boom
	-- del reveal): el ganador se clava y la cámara lo acusa.
	if onLand then
		onLand()
	end
end

-- Reveal del ganador: tease (squash) + pop elástico centrado (AnchorPoint 0.5,0.5).
function CaseUnboxing:_revealReel(reel: Reel, glowColor: Color3, doConfetti: boolean)
	if reelTornDown(reel) then
		return
	end
	local center = reel.active[reel.targetIndex]
	if not center then
		return
	end

	center.container.ZIndex = 200

	local teaseInfo = TweenInfo.new(REVEAL_TEASE, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
	self:_playTween(center.scale, teaseInfo, { Scale = SCALE_CENTER * TEASE_SQUASH })
	task.wait(REVEAL_TEASE)

	-- Burst de glow: clon del propio render del wrap, coloreado por rareza, que
	-- se expande y disuelve por detrás del ganador — el "pop" de premio AAA.
	local visual = center.viewport
	if visual then
		local glow = visual:Clone()
		glow.Name = "GlowBurst"
		local camera = glow:FindFirstChildOfClass("Camera")
		if camera then
			glow.CurrentCamera = camera
		end
		(glow :: any).ImageColor3 = glowColor
		glow.ZIndex = math.max(1, visual.ZIndex - 1)
		glow.Parent = visual.Parent
		self._playJanitor:Add(glow, "Destroy")
		self:_playTween(glow, TweenInfo.new(REVEAL_GLOW_DURATION, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), {
			Size = UDim2.fromScale(REVEAL_GLOW_SCALE, REVEAL_GLOW_SCALE),
			Position = UDim2.fromScale(-(REVEAL_GLOW_SCALE - 1) / 2, -(REVEAL_GLOW_SCALE - 1) / 2),
			ImageTransparency = 1,
		})
	end

	center.scale.Scale = SCALE_CENTER * REVEAL_PULSE
	self:_playTween(center.scale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = SCALE_CENTER })

	if doConfetti and self._uiGui then
		Confetti.Rain(self._uiGui)
	end

	task.wait(REVEAL_SNAPBACK)
end

-- ── Resultado ────────────────────────────────────────────────

function CaseUnboxing:_notifyResult(params: PlayParams)
	local wrapDefinition = ItemsConfig.WeaponWraps[params.resultWrapId]
	local wrapName = tostring(if type(wrapDefinition) == "table" then wrapDefinition.Name or params.resultWrapId else params.resultWrapId)
	local weaponCategoryConfig = (ItemsConfig :: any)[params.resultWeaponCategory]
	local weaponDefinition = if type(weaponCategoryConfig) == "table" then weaponCategoryConfig[params.resultWeaponId] else nil
	local weaponName = tostring(if type(weaponDefinition) == "table" then weaponDefinition.Name or params.resultWeaponId else params.resultWeaponId)
	Notify.success(("Unboxed %s for %s!"):format(wrapName, weaponName))
end

-- Oculta el cofre (y apaga su billboard) al entrar en el reveal. Sacarlo del árbol
-- basta para que deje de renderizarse; el motor de pose (Heartbeat) se auto-frena
-- al ver chest.Parent == nil, y hideIdleChest lo destruye igual al cerrar el detalle.
function CaseUnboxing:_hideChest()
	if self._rollBillboard then
		self._rollBillboard.Enabled = false
	end
	local chest = self._chest
	if chest then
		chest.Parent = nil
	end
end

-- Resuelve el marcador de mundo donde se planta el arma+wrap ganador
-- (Workspace.Locker.RevealSpawn; Attachment/BasePart/Model). FindFirstChild (no
-- WaitForChild) para degradar con gracia si el mapa no lo tiene.
function CaseUnboxing:_resolveRevealSpawn(): Instance?
	local lockerFolder = Workspace:FindFirstChild("Locker")
	local spawnNode = if lockerFolder then lockerFolder:FindFirstChild("RevealSpawn") else nil
	if spawnNode and (spawnNode:IsA("Attachment") or spawnNode:IsA("BasePart") or spawnNode:IsA("Model")) then
		return spawnNode
	end
	return nil
end

-- Planta el arma con el wrap ganador en Workspace.Locker.RevealSpawn, con un bob
-- orgánico. NO toca la cámara: la vista sigue siendo la de 'cases' (que es la que
-- encuadra el RevealSpawn). El modelo vive en el janitor del play, así que se
-- destruye al terminar el unboxing. Degrada avisando si falta el marcador.
function CaseUnboxing:_buildRevealScene(params: PlayParams): boolean
	local spawnTarget = self:_resolveRevealSpawn()
	local spawnCFrame = if spawnTarget then markerWorldCFrame(spawnTarget) else nil
	if not (spawnTarget and spawnCFrame) then
		warn("[CaseUnboxing] Falta Workspace.Locker.RevealSpawn (Attachment/BasePart/Model); el arma ganadora no se planta.")
		return false
	end

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

	if not (model and model:IsA("PVInstance")) then
		warn("[CaseUnboxing] No se pudo construir el arma+wrap del reveal:", params.resultWeaponCategory, params.resultWeaponId, params.resultWrapId)
		return false
	end

	local pvModel = model :: PVInstance
	-- Escalado alrededor del pivote (ScaleTo lo conserva), ANTES de colocarlo: así el
	-- arma crece "desde su sitio" y sigue centrada en el RevealSpawn.
	if model:IsA("Model") then
		(model :: Model):ScaleTo(REVEAL_MODEL_SCALE)
	end
	pvModel:PivotTo(spawnCFrame :: CFrame)
	-- Un Model no puede colgar de un Attachment: se parenta a la parte que lo
	-- contiene (Attachment.Parent), o al propio nodo si es Part/Model.
	model.Parent = if spawnTarget:IsA("Attachment") then spawnTarget.Parent else spawnTarget

	-- Bob orgánico: senoide principal + una armónica lenta desfasada.
	local elapsed = 0
	self._playJanitor:Add(RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if model.Parent then
			local y = math.sin(elapsed * REVEAL_BOB_SPEED) * REVEAL_BOB_AMPLITUDE
				+ math.sin(elapsed * REVEAL_BOB_SPEED * 0.5 + 1.3) * REVEAL_BOB_AMPLITUDE * 0.3
			pvModel:PivotTo((spawnCFrame :: CFrame) * CFrame.new(0, y, 0))
		end
	end), "Disconnect")
	return true
end

-- Reveal final. La cámara se queda en la de 'cases': el reveal es el arma+wrap
-- ganador plantado en RevealSpawn + la card resaltada en CaseContent.Main + la barra
-- Nav (Equip/Collect), que el Store muestra en onRevealShown. Aquí ocultamos el
-- cofre, plantamos el arma, notificamos y BLOQUEAMOS hasta que el jugador descarta
-- (awaitDismiss); sin él, se mantiene RESULT_HOLD s y sigue solo.
function CaseUnboxing:_revealResult(params: PlayParams)
	self:_hideChest()
	self:_buildRevealScene(params)
	self:_notifyResult(params)

	if params.onRevealShown then
		params.onRevealShown()
	end

	if params.awaitDismiss then
		params.awaitDismiss()
	else
		task.wait(RESULT_HOLD)
	end
end

-- ── Orquestación ─────────────────────────────────────────────

function CaseUnboxing:_run(params: PlayParams)
	-- Reutiliza el cofre idle (lo genera en FallPosition si aún no está; p. ej. si
	-- el unboxing arranca sin haber abierto el detalle). El cofre NO se destruye
	-- al terminar: vuelve a idle y lo limpia hideIdleChest al cerrar el detalle.
	self:showIdleChest()
	local chest = self._chest :: Model?
	local motion = self._motion
	local rollBillboard = self._rollBillboard
	local rollFrameGui = self._rollFrameGui
	local template = self._reelTemplate

	if not (chest and motion) then
		-- Sin cofre (falta FallPosition/ChestModel/estructura): reveal sin reel.
		self:_revealResult(params)
		return
	end
	local chestModel = chest :: Model

	-- 1. Esperar a que el cofre aterrice (la caída de entrada puede seguir en curso
	-- si el jugador compró nada más abrir el detalle): no se rola en el aire.
	while not motion.settled and chestModel.Parent do
		task.wait()
	end
	if not chestModel.Parent then
		return
	end

	-- 2. Encender el billboard (ya vive en PlayerGui con Adornee = Box) y montar
	-- el reel dentro de RollFrame.
	if rollBillboard then
		rollBillboard.Enabled = true
	end

	local reel: Reel? = nil
	if rollFrameGui and template then
		-- ClipsDescendants: el flujo entra/sale por los bordes del RollFrame.
		rollFrameGui.ClipsDescendants = true
		disableConflictingLayouts(rollFrameGui)
		reel = self:_buildContinuousReel(params, rollFrameGui, template)
		if not reel then
			warn("[CaseUnboxing] No se pudo renderizar el wrap resultado:", params.resultWrapId)
		end
	else
		warn("[CaseUnboxing] Falta ChestModel.Box.RollBillboard.RollFrame.Template; roll sin reel.")
	end

	-- 3. Wind-up: anticipación (rumble creciente + agachado) → el cofre "carga"
	-- justo antes de soltar el barrido. Poblar el reel primero para que se vea el
	-- flujo quieto durante la carga.
	if reel then
		self:_layoutReel(reel, START_INDEX, true)
	end
	self:_chargeUpChest(chestModel, motion)

	-- 4. Barrido: el reel gira y la vibración del cofre va ACOPLADA a él (velocidad
	-- + ratchet por item + impacto al clavar) → el temblor "tiene sentido" con lo
	-- que se ve girar, en vez del forcejeo random y desincronizado de antes.
	if reel then
		self:_runReel(reel, motion, params.onReelTick, params.onReelLand)
	else
		task.wait(1.0)
	end

	-- 5. Reveal del ganador en el billboard (tease + pop elástico + glow por
	-- rareza; confetti en rarezas altas) — llega pegado al impacto del land.
	local wrapDefinition = ItemsConfig.WeaponWraps[params.resultWrapId]
	local wrapRarity = tostring(if type(wrapDefinition) == "table" then wrapDefinition.Rarity or RARITY_FALLBACK else RARITY_FALLBACK)
	local glowColor = UITheme.RarityColors[wrapRarity] or GLOW_FALLBACK_COLOR
	local doConfetti = CONFETTI_RARITIES[wrapRarity] == true
	if reel then
		self:_revealReel(reel, glowColor, doConfetti)
	end

	-- 6. Reveal final: la cámara se queda en 'cases'; se OCULTA el cofre, se planta
	-- el arma+wrap ganador en RevealSpawn y se avisa al Store para que resalte la
	-- card ganadora y muestre Equip/Collect en Nav. BLOQUEA hasta que el jugador lo
	-- descarta (o RESULT_HOLD s sin awaitDismiss). Tras descartar, onFinished cierra
	-- el detalle y hideIdleChest destruye el cofre.
	self:_revealResult(params)
end

-- Lanza la animación (no bloquea). Devuelve false si ya hay una en curso.
function CaseUnboxing:play(params: PlayParams): boolean
	if self._playing then
		return false
	end

	self._playing = true
	task.spawn(function()
		local ok, err = pcall(function()
			self:_run(params)
		end)
		if not ok then
			warn("[CaseUnboxing] Animación abortada:", err)
		end
		-- Cleanup del run: cofre, items del reel, renders 3D, tweens.
		self._playJanitor:Cleanup()
		self._playing = false
		params.onFinished()
	end)
	return true
end

return CaseUnboxing
