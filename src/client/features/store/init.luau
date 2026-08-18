--!strict

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any
local DataController = require(Client.core.data.DataController)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local StaggerReveal = require(Client.core.ui.animators.StaggerReveal)
local PanelController = require(Client.core.ui.PanelController)
local NavTabController = require(Client.core.ui.NavTabController)
local NavStaggerController = require(Client.core.ui.NavStaggerController)
local UIUtils = require(Client.core.ui.UIUtils)
local UITheme = require(Client.core.ui.UITheme)
local BlurController = require(Client.core.ui.BlurController)
local ScenePresetController = require(Client.core.lighting.ScenePresetController)
local CameraFovEffect = require(Client.core.ui.CameraFovEffect)
local StoreProducts = require(Shared.constants.StoreProducts)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local WrapCasesConfig = require(Shared.constants.WrapCasesConfig)
local LockerCategory = require(Shared.constants.LockerCategory)
local Network = require(Shared.networking.Network)
local Notify = require(Client.core.ui.NotificationController)
local GiftFlow = require(script.GiftFlow)
local CaseContentPanel = require(script.CaseContentPanel)
local CaseUnboxing = require(script.CaseUnboxing)

local BLUR_KEY = "Store"
-- Supresor de blur mientras CaseContent está abierto: su vista es una escena de
-- cámara (Workspace.Cameras.cases), no debe ir borrosa aunque el Store siga abierto.
local CASE_BLUR_SUPPRESS_KEY = "CaseContent"
-- ── Cámara cinemática del unboxing ───────────────────────────────────────────
-- Al comprar, la cámara hace un travelling de Workspace.Cameras.cases a
-- Workspace.Cameras.unboxing y SE QUEDA ahí (el reveal ocurre en esa misma toma).
-- Carácter buscado: AGRESIVO y LIMPIO — golpes duros y precisos, sin bamboleo. El
-- movimiento se compone de tres capas:
--   1. SLAM: travelling corto con ease Exponential Out — cubre casi toda la distancia
--      de golpe y frena en seco en la pose exacta (agresivo, pero sin rebote sucio);
--   2. KICK + PUSH de FOV: al clavar la pose, un golpe corto de apertura (como un
--      retroceso) y acto seguido el push-in del 20% con Quint In, que repta y se
--      abalanza al final — la tensión sube justo cuando el reel frena hacia el ganador;
--   3. un hilo de sway (ruido Perlin) casi imperceptible: lo justo para que la toma no
--      se vea muerta, sin llegar a "cámara en mano" (eso ensuciaría el plano).
local UNBOXING_TRAVEL_TIME = 0.45
local UNBOXING_TRAVEL_INFO =
	TweenInfo.new(UNBOXING_TRAVEL_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
local UNBOXING_ZOOM_FACTOR = 0.80 -- push-in final (FOV 20% más estrecho)
local UNBOXING_ZOOM_ANTICIPATION = 1.08 -- golpe de apertura al llegar (retroceso)
local UNBOXING_ZOOM_ANTICIPATION_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Quad In (no Quint): con Quint el push-in era invisible los primeros segundos y la
-- cámara parecía parada. Quad reparte mejor el recorrido y se percibe movimiento.
local UNBOXING_ZOOM_IN_INFO = TweenInfo.new(1.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local UNBOXING_SWAY_POS = 0.1 -- studs de deriva del sway (un hilo, no cámara en mano)
local UNBOXING_SWAY_ROT = 0.3 -- grados de balanceo del sway
local UNBOXING_SWAY_SPEED = 0.18 -- velocidad del ruido (bajo = deriva lenta)
local UNBOXING_SWAY_RAMP = 0.5 -- s de entrada/salida de la intensidad del sway

-- ── Explosión de cámara del reveal ───────────────────────────────────────────
-- Al revelarse el resultado, la cámara "encaja" una onda expansiva: sacudida seca de
-- alta frecuencia que se amortigua sola + un golpe de FOV hacia fuera que vuelve al
-- valor zoomeado. La sacudida se compone sobre la pose base igual que el sway.
local UNBOXING_SHAKE_POS = 1.1 -- studs de sacudida en el pico
local UNBOXING_SHAKE_ROT = 3.2 -- grados de sacudida en el pico
local UNBOXING_SHAKE_FREQ = 34 -- frecuencia del ruido (alto = temblor seco, no vaivén)
local UNBOXING_SHAKE_DECAY = 6.5 -- rapidez del amortiguado (mayor = se apaga antes)
local UNBOXING_SHAKE_FOV_PUNCH = 1.12 -- apertura de FOV de la onda expansiva
local UNBOXING_SHAKE_FOV_OUT_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local UNBOXING_SHAKE_FOV_BACK_INFO = TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

-- ── Kicks de cámara ACOPLADOS al reel ────────────────────────────────────────
-- El reel emite un beat por item que cruza el centro (onReelTick, strength ∝ lo
-- lento que va) y otro al clavar el ganador (onReelLand). Se mapean a la MISMA
-- sacudida de la explosión (caseShakeIntensity), pero por MÁXIMO (no acumulan): un
-- rumble bajo y constante mientras el reel vuela → jolts secos y espaciados al
-- frenar → golpe al land → boom del reveal. Sin FOV en los ticks: el push-in del
-- zoom sigue su curva sin que lo pisemos.
local UNBOXING_TICK_SHAKE_BASE = 0.015 -- sacudida mínima por tick (rumble casi inexistente)
local UNBOXING_TICK_SHAKE_RANGE = 0.15 -- extra por lentitud del tick (0→1) → jolt suave del final
local UNBOXING_LAND_SHAKE = 0.32 -- golpe al clavar el ganador (antes del boom del reveal)

local StoreFeature = {}

type StoreProductDefinition = StoreProducts.StoreProductDefinition

function StoreFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()

	-- Botón de apertura en Menu.Container.Store
	local container = menuGui:FindFirstChild("Container")
	local storeButtonInstance = container and container:FindFirstChild("Store")
	local storeButton: GuiButton? = if storeButtonInstance and storeButtonInstance:IsA("GuiButton")
		then storeButtonInstance
		else nil

	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local storeFrame = uiGui:WaitForChild("Store") :: Frame

	-- Nav y CloseBtn son opcionales: durante la migración de la GUI el Store puede
	-- no tener barra de tabs todavía. Sin Nav, el panel se configura igual (solo se
	-- omite el sistema de pestañas) y se cierra vía CloseBtn si existe.
	local nav = storeFrame:FindFirstChild("Nav")
	local closeButton: GuiButton? = nil
	if nav then
		local closeNode = nav:FindFirstChild("CloseBtn")
		if closeNode and closeNode:IsA("GuiButton") then
			closeButton = closeNode
		end
	end

	-- Página de packs de Cash, estructurada en filas: Store.CashPage.Row1/Row2/…,
	-- cada fila con sus botones (Cash1…). Resolvemos el frame CashPage; si la GUI
	-- aún no migró, caemos al contenedor plano "Cash" (con Cash1… directo dentro),
	-- que tratamos como una fila implícita. Lo identificamos por contener Cash1
	-- para no confundir un tab de Nav ni el label de saldo "Cash".
	local function resolveCashPage(): GuiObject?
		local page = storeFrame:FindFirstChild("CashPage")
		if page and page:IsA("GuiObject") then
			return page
		end
		local direct = storeFrame:FindFirstChild("Cash")
		if direct and direct:IsA("GuiObject") and direct:FindFirstChild("Cash1") then
			return direct
		end
		for _, descendant in storeFrame:GetDescendants() do
			if descendant.Name == "Cash" and descendant:IsA("GuiObject") and descendant:FindFirstChild("Cash1") then
				return descendant :: GuiObject
			end
		end
		return nil
	end
	local cashPage = resolveCashPage()

	-- Localiza un botón de producto dentro de la CashPage: primero en su fila
	-- (CashPage.<Row>.<ButtonName>), luego suelto en la CashPage (fallback para la
	-- estructura plana previa a las filas).
	local function findProductButton(page: GuiObject, product: StoreProductDefinition): GuiButton?
		local rowContainer = page:FindFirstChild(product.Row)
		if rowContainer and rowContainer:IsA("GuiObject") then
			local inRow = rowContainer:FindFirstChild(product.ButtonName)
			if inRow and inRow:IsA("GuiButton") then
				return inRow
			end
		end
		local flat = page:FindFirstChild(product.ButtonName)
		if flat and flat:IsA("GuiButton") then
			return flat
		end
		return nil
	end

	-- ── Regalo (estado; el wiring vive más abajo) ────────────
	-- Cada pack de Robux regalable tiene un botón hijo "Gift" (Store.CashPage.
	-- <Row>.<Pack>.Gift) que abre el flujo de regalo (UserInterface.Gifting) para
	-- ESE pack. Declarado antes de bindCashButtons para que el click handler lo
	-- capture como upvalue (se instancia más abajo).
	local giftFlow: any = nil

	-- Reveal escalonado (pop stagger) de los items de cada página del Store:
	-- Store.<Page>.Row1/Row2/…, mismo criterio que antes solo aplicaba a
	-- CashPage.Row1. Una instancia de StaggerReveal por página (se rellenan
	-- tras registrar la Nav, tabla de tab-name → GuiObject).
	local pageReveals = {} :: { [string]: any }
	-- Tab que contiene la CashPage (se resuelve tras registrar la Nav): es la
	-- página por defecto al abrir el Store si existe.
	local cashTabName: string? = nil

	-- Items a revelar de una página: todos los GuiObject hijos directos de sus
	-- Row1, Row2, … (en ese orden, y por LayoutOrder dentro de cada fila).
	local function collectRowItems(pageFrame: GuiObject): { GuiObject }
		local items = {} :: { GuiObject }
		local rowIndex = 1
		while true do
			local row = pageFrame:FindFirstChild("Row" .. rowIndex)
			if not (row and row:IsA("GuiObject")) then
				break
			end
			local rowItems = {} :: { GuiObject }
			for _, child in row:GetChildren() do
				if child:IsA("GuiObject") then
					table.insert(rowItems, child)
				end
			end
			table.sort(rowItems, function(a, b)
				return a.LayoutOrder < b.LayoutOrder
			end)
			for _, item in rowItems do
				table.insert(items, item)
			end
			rowIndex += 1
		end
		return items
	end

	local function ensurePageReveal(name: string, pageFrame: GuiObject): any
		local existing = pageReveals[name]
		if existing then
			return existing
		end
		local reveal = StaggerReveal.new()
		janitor:Add(reveal, "Destroy")
		reveal:setItems(collectRowItems(pageFrame))
		pageReveals[name] = reveal
		return reveal
	end

	local fovEffect = CameraFovEffect.new()
	janitor:Add(fovEffect, "Destroy")
	local canUseHoverAnimations = UserInputService.MouseEnabled and not UserInputService.TouchEnabled

	local function applyProductToButton(button: GuiButton, product: StoreProductDefinition)
		local priceLabel = button:WaitForChild("Price") :: TextLabel
		local amountLabel = button:WaitForChild("Amount") :: TextLabel
		priceLabel.Text = product.PriceText
		amountLabel.Text = UIUtils.formatCashAmount(product.CashAmount)

		button.Active = product.ProductId > 0
		button.Selectable = product.ProductId > 0
		button.AutoButtonColor = false
	end

	local function bindCashButtons()
		if not cashPage then
			warn("[StoreFeature] No se encontró la CashPage (ni el contenedor plano 'Cash'); packs no cableados.")
			return
		end
		-- Recorremos el layout por filas (StoreProducts.RowLayout): Row1, Row2, …
		-- en orden, y dentro de cada fila los productos en orden.
		for _, row in StoreProducts.RowLayout do
			for _, product in row.Products do
				local button = findProductButton(cashPage, product)
				if button then
					applyProductToButton(button, product)
					InteractiveScaleTween.bindButton(button, janitor, {
						enableHover = canUseHoverAnimations,
						hoverScale = UITheme.ButtonHoverScale,
						clickScale = UITheme.ButtonClickScale,
					})
					janitor:Add(button.Activated:Connect(function()
						if product.ProductId <= 0 then
							-- Sin developer product no hay compra posible.
							warn("[StoreFeature] ProductId no configurado para", product.ButtonName)
							return
						end
						MarketplaceService:PromptProductPurchase(player, product.ProductId)
					end), "Disconnect")

					-- Botón "Gift" del pack (opcional): abre el flujo de regalo para
					-- ESTE producto. Solo los packs regalables lo llevan en la GUI.
					local giftNode = button:FindFirstChild("Gift")
					if giftNode and giftNode:IsA("GuiButton") then
						local giftBtn = giftNode :: GuiButton
						InteractiveScaleTween.bindButton(giftBtn, janitor, {
							enableHover = canUseHoverAnimations,
							hoverScale = UITheme.ButtonHoverScale,
							clickScale = UITheme.ButtonClickScale,
						})
						janitor:Add(giftBtn.Activated:Connect(function()
							if product.ProductId <= 0 then
								Notify.warning("That item can't be gifted.")
								return
							end
							if giftFlow then
								giftFlow:openForProduct(product)
							end
						end), "Disconnect")
					end
				end
			end
		end
	end

	bindCashButtons()

	-- ── Wrap cases (Store.Home.Row1.WrapCase1/2 → CaseContent → unboxing) ──
	-- El contenido/pesos/precios viven en WrapCasesConfig. Al pulsar un botón
	-- de case se abre UserInterface.CaseContent; Purchase envía WrapCases.Open
	-- y el Result del server dispara el reel de CaseUnboxing.
	local caseUnboxing = CaseUnboxing.new(uiGui, janitor)
	local pendingCaseOpen = false
	-- Estado lógico del panel Store (lo mantienen los hooks onOpen/onClose del
	-- PanelController). Mientras CaseContent está abierto, el frame del Store se
	-- oculta (Visible=false) SIN cerrar el panel: el blur sigue activo y este
	-- flag decide si hay que re-mostrar el Store al cerrar el CaseContent.
	local storePanelOpen = storeFrame.Visible

	-- Cámara de la vista de contenido de una case: al abrir CaseContent la cámara
	-- salta INSTANTÁNEAMENTE a Workspace.Cameras.cases (sin travelling) y al cerrarlo
	-- vuelve, instantáneo, a su estado previo. El salto se hace SIEMPRE con la
	-- pantalla en negro (ver runCaseTransition), así el corte de cámara no se ve.
	-- Degradamos sin mover la cámara si falta el nodo o no es BasePart.
	local caseCameraApplied = false
	local caseSavedCameraType: Enum.CameraType? = nil
	local caseSavedCameraCFrame: CFrame? = nil
	local caseSavedCameraSubject: Instance? = nil
	local caseSavedCameraFOV: number? = nil
	-- Travelling en vuelo (unboxing). Se cancela antes de cualquier salto instantáneo
	-- o restauración, si no seguiría moviendo la cámara por encima.
	local caseCameraTween: Tween? = nil
	local function cancelCaseCameraTween()
		if caseCameraTween then
			caseCameraTween:Cancel()
			caseCameraTween = nil
		end
	end
	-- Zoom (FOV) en vuelo, independiente del travelling: uno mueve CFrame y el otro
	-- FieldOfView, así que pueden solaparse sin pelearse.
	local caseCameraZoomTween: Tween? = nil
	local function cancelCaseCameraZoom()
		if caseCameraZoomTween then
			caseCameraZoomTween:Cancel()
			caseCameraZoomTween = nil
		end
	end
	-- Lanza un tween de FOV hacia `targetFOV`. Sin FOV base guardado (cámara de case
	-- no aplicada) no hacemos nada: no queremos tocar el FOV fuera de esta vista.
	local function tweenCameraFOV(targetFOV: number, info: TweenInfo)
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		cancelCaseCameraZoom()
		local tween = TweenService:Create(camera, info, { FieldOfView = targetFOV })
		caseCameraZoomTween = tween
		tween:Play()
	end

	-- Marcador de cámara bajo Workspace.Cameras (debe ser BasePart).
	local function resolveCameraNode(name: string): BasePart?
		local camerasFolder = Workspace:FindFirstChild("Cameras")
		local node = if camerasFolder then camerasFolder:FindFirstChild(name) else nil
		if node and node:IsA("BasePart") then
			return node :: BasePart
		end
		return nil
	end

	-- Pose BASE de la cámara cinemática (lo que se tweenea) separada del sway (lo que
	-- se compone encima cada frame). Sin esta separación, travelling y balanceo se
	-- pisarían el CFrame el uno al otro.
	local caseCameraBaseValue = Instance.new("CFrameValue")
	janitor:Add(caseCameraBaseValue, "Destroy")
	local caseSwayConn: RBXScriptConnection? = nil
	local caseSwayIntensity = 0 -- 0..1 actual (rampa)
	local caseSwayTarget = 0 -- 0..1 objetivo
	local caseSwaySeed = math.random() * 1000
	local caseShakeIntensity = 0 -- 0..1, impulso de la explosión; se amortigua solo

	local function stopCinematicCamera()
		if caseSwayConn then
			caseSwayConn:Disconnect()
			caseSwayConn = nil
		end
		caseSwayIntensity = 0
		caseSwayTarget = 0
		caseShakeIntensity = 0
	end
	janitor:Add(stopCinematicCamera, true)

	local function setCameraSway(enabled: boolean)
		caseSwayTarget = if enabled then 1 else 0
	end

	-- Render loop de la cámara cinemática: pose base tweeneada + sway de cámara en
	-- mano (ruido Perlin en deriva y balanceo, con rampa de intensidad para que
	-- entre y salga sin saltos).
	local function startCinematicCamera()
		if caseSwayConn then
			return
		end
		caseSwayConn = RunService.RenderStepped:Connect(function(dt)
			local camera = Workspace.CurrentCamera
			if not camera then
				return
			end
			caseSwayIntensity += (caseSwayTarget - caseSwayIntensity) * math.min(dt / UNBOXING_SWAY_RAMP, 1)
			local k = caseSwayIntensity
			local t = os.clock() * UNBOXING_SWAY_SPEED
			local nx = math.noise(t, caseSwaySeed, 0)
			local ny = math.noise(caseSwaySeed, t, 0)
			local nz = math.noise(t, 0, caseSwaySeed)
			local sway = CFrame.new(nx * UNBOXING_SWAY_POS * k, ny * UNBOXING_SWAY_POS * k, 0)
				* CFrame.Angles(
					ny * math.rad(UNBOXING_SWAY_ROT) * k,
					nx * math.rad(UNBOXING_SWAY_ROT) * k,
					nz * math.rad(UNBOXING_SWAY_ROT) * k
				)

			-- Onda expansiva del reveal: ruido de alta frecuencia amortiguado. Se
			-- compone encima del sway, así que ambos conviven sin pisarse.
			local shake = CFrame.identity
			if caseShakeIntensity > 0.001 then
				caseShakeIntensity *= math.exp(-UNBOXING_SHAKE_DECAY * dt)
				local s = caseShakeIntensity
				local st = os.clock() * UNBOXING_SHAKE_FREQ
				local sx = math.noise(st, caseSwaySeed + 11, 0)
				local sy = math.noise(caseSwaySeed + 11, st, 0)
				local sz = math.noise(st, 0, caseSwaySeed + 11)
				shake = CFrame.new(
					sx * UNBOXING_SHAKE_POS * s,
					sy * UNBOXING_SHAKE_POS * s,
					sz * UNBOXING_SHAKE_POS * s * 0.5
				) * CFrame.Angles(
					sy * math.rad(UNBOXING_SHAKE_ROT) * s,
					sx * math.rad(UNBOXING_SHAKE_ROT) * s,
					sz * math.rad(UNBOXING_SHAKE_ROT) * s
				)
			end

			camera.CFrame = caseCameraBaseValue.Value * sway * shake
		end)
	end

	-- Travelling SUAVE hasta Workspace.Cameras.<name>: tweenea la POSE BASE (el loop
	-- la aplica con el sway encima). Al contrario que el salto instantáneo de
	-- applyCaseCamera, aquí el movimiento se ve.
	local function tweenCameraTo(name: string): Tween?
		local node = resolveCameraNode(name)
		local camera = Workspace.CurrentCamera
		if not node then
			warn("[StoreFeature] Falta Workspace.Cameras." .. name .. " (BasePart); la cámara no viajará.")
			return nil
		end
		if not camera then
			return nil
		end
		cancelCaseCameraTween()
		camera.CameraType = Enum.CameraType.Scriptable
		-- Arrancar la base donde está la cámara AHORA para no dar un salto. Solo si el
		-- loop no corría ya: si corre, la base ya es la buena (y camera.CFrame lleva
		-- sway sumado, que no queremos hornear dentro de la base).
		if not caseSwayConn then
			caseCameraBaseValue.Value = camera.CFrame
		end
		startCinematicCamera()
		local tween = TweenService:Create(caseCameraBaseValue, UNBOXING_TRAVEL_INFO, { Value = node.CFrame })
		caseCameraTween = tween
		tween:Play()
		return tween
	end

	-- Entrada al unboxing: travelling hasta Cameras.unboxing y, AL LLEGAR, la
	-- respiración de FOV (apertura corta de anticipación → push-in lento del 5%). Si
	-- el travelling se cancela (panel cerrado a media animación) el zoom no arranca.
	-- Sin marcador de cámara, hacemos solo el zoom sobre la vista actual.
	local function enterUnboxingCamera()
		local baseFOV = caseSavedCameraFOV
		setCameraSway(true)
		local function startZoom()
			if not baseFOV then
				return
			end
			tweenCameraFOV(baseFOV * UNBOXING_ZOOM_ANTICIPATION, UNBOXING_ZOOM_ANTICIPATION_INFO)
			local breath = caseCameraZoomTween
			if breath then
				breath.Completed:Once(function(state)
					if state == Enum.PlaybackState.Completed then
						tweenCameraFOV(baseFOV * UNBOXING_ZOOM_FACTOR, UNBOXING_ZOOM_IN_INFO)
					end
				end)
			end
		end
		local travel = tweenCameraTo("unboxing")
		if not travel then
			startZoom()
			return
		end
		travel.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				startZoom()
			end
		end)
	end

	-- Explosión del reveal: impulso de sacudida (lo amortigua el render loop) + golpe
	-- seco de FOV hacia fuera que vuelve al valor zoomeado. La cámara NO se mueve de
	-- sitio: la onda expansiva se compone sobre la pose base.
	local function explodeCamera()
		caseShakeIntensity = 1
		local baseFOV = caseSavedCameraFOV
		if not baseFOV then
			return
		end
		local zoomedFOV = baseFOV * UNBOXING_ZOOM_FACTOR
		tweenCameraFOV(zoomedFOV * UNBOXING_SHAKE_FOV_PUNCH, UNBOXING_SHAKE_FOV_OUT_INFO)
		local punch = caseCameraZoomTween
		if punch then
			punch.Completed:Once(function(state)
				if state == Enum.PlaybackState.Completed then
					tweenCameraFOV(zoomedFOV, UNBOXING_SHAKE_FOV_BACK_INFO)
				end
			end)
		end
	end

	-- Beat de cámara por item que cruza el centro del reel (lo dispara CaseUnboxing
	-- vía onReelTick). Sube la sacudida por MÁXIMO, no acumula: rápido = base pequeña
	-- (rumble constante del barrido); al frenar strength→1 y los ticks se espacian →
	-- cada uno pega un jolt seco que se amortigua antes del siguiente. Sin FOV: el
	-- push-in del zoom sigue su curva sin que lo pisemos.
	local function kickCamera(strength: number)
		local kick = UNBOXING_TICK_SHAKE_BASE + UNBOXING_TICK_SHAKE_RANGE * math.clamp(strength, 0, 1)
		if kick > caseShakeIntensity then
			caseShakeIntensity = kick
		end
	end

	-- Golpe al clavar el ganador (onReelLand): sacudida fuerte sincronizada con el
	-- impacto del cofre, un beat antes de la onda expansiva del reveal. El FOV se
	-- reserva para ese boom (explodeCamera), así el land pega solo con sacudida.
	local function landCamera()
		if UNBOXING_LAND_SHAKE > caseShakeIntensity then
			caseShakeIntensity = UNBOXING_LAND_SHAKE
		end
	end

	-- Deshace la entrada al unboxing (solo hace falta si la animación no llegó a
	-- arrancar): vuelve a 'cases', suelta el zoom y apaga el sway.
	local function exitUnboxingCamera()
		tweenCameraTo("cases")
		setCameraSway(false)
		if caseSavedCameraFOV then
			tweenCameraFOV(caseSavedCameraFOV, UNBOXING_TRAVEL_INFO)
		end
	end

	local function applyCaseCamera()
		local camerasFolder = Workspace:FindFirstChild("Cameras")
		local casesNode = if camerasFolder then camerasFolder:FindFirstChild("cases") else nil
		if not casesNode then
			warn("[StoreFeature] Falta Workspace.Cameras.cases; la cámara no se moverá al abrir CaseContent.")
			return
		end
		if not casesNode:IsA("BasePart") then
			warn("[StoreFeature] Workspace.Cameras.cases debe ser un BasePart (es " .. casesNode.ClassName .. "); la cámara no se moverá.")
			return
		end
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		cancelCaseCameraTween()
		stopCinematicCamera()
		if not caseCameraApplied then
			caseSavedCameraType = camera.CameraType
			caseSavedCameraCFrame = camera.CFrame
			caseSavedCameraSubject = camera.CameraSubject
			-- FOV base de la vista de la case: el zoom del unboxing parte de aquí y
			-- vuelve aquí (y se repone al cerrar el detalle).
			caseSavedCameraFOV = camera.FieldOfView
			caseCameraApplied = true
		end
		-- Salto instantáneo: fijar tipo Scriptable y el CFrame de la parte `cases`.
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = casesNode.CFrame
	end
	local function restoreCaseCamera()
		cancelCaseCameraTween()
		cancelCaseCameraZoom()
		stopCinematicCamera()
		if not caseCameraApplied then
			return
		end
		caseCameraApplied = false
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		-- Reponer el FOV base (el zoom del unboxing pudo dejarlo a medias).
		if caseSavedCameraFOV then
			camera.FieldOfView = caseSavedCameraFOV
		end
		-- Restauración instantánea del estado previo (tipo/subject/CFrame).
		if caseSavedCameraType ~= nil then
			camera.CameraType = caseSavedCameraType
		end
		if caseSavedCameraSubject and caseSavedCameraSubject.Parent then
			camera.CameraSubject = caseSavedCameraSubject
		end
		if caseSavedCameraCFrame then
			camera.CFrame = caseSavedCameraCFrame
		end
		caseSavedCameraType = nil
		caseSavedCameraCFrame = nil
		caseSavedCameraSubject = nil
		caseSavedCameraFOV = nil
	end

	-- Lighting de la vista de la case, dirigido por atributo: si la parte
	-- Workspace.Cameras.cases lleva `LightingPreset = "<Nombre>"`, se aplica ese
	-- preset de ReplicatedStorage.LightingPresets al entrar y se restaura al salir.
	-- Sin atributo (o sin librería) degrada sin tocar la Lighting.
	local caseLightingApplied = false
	local function applyCaseLighting()
		local camerasFolder = Workspace:FindFirstChild("Cameras")
		local casesNode = if camerasFolder then camerasFolder:FindFirstChild("cases") else nil
		if casesNode and ScenePresetController.applyFrom(casesNode) then
			caseLightingApplied = true
		end
	end
	local function restoreCaseLighting()
		if caseLightingApplied then
			ScenePresetController.restore()
			caseLightingApplied = false
		end
	end
	-- Si el feature se destruye (hot reload) con la case abierta, no dejamos la
	-- Lighting del preset colgada.
	janitor:Add(function()
		restoreCaseLighting()
	end, true)

	-- Fade a negro full-screen que tapa el corte de cámara al entrar/salir de
	-- CaseContent. Overlay propio del Store (hermano del resto de la UI, por encima
	-- de todo). runCaseTransition ejecuta el cambio de estado con la pantalla en
	-- negro: fade in → (cámara/blur/visibilidad instantáneos) → fade out.
	local CASE_FADE_DURATION = 0.22
	local CASE_FADE_INFO = TweenInfo.new(CASE_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local caseFadeOverlay = Instance.new("Frame")
	caseFadeOverlay.Name = "CaseContentFade"
	caseFadeOverlay.Size = UDim2.fromScale(1, 1)
	caseFadeOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	caseFadeOverlay.BackgroundTransparency = 1
	caseFadeOverlay.BorderSizePixel = 0
	caseFadeOverlay.ZIndex = 1000
	caseFadeOverlay.Visible = false
	caseFadeOverlay.Parent = uiGui
	janitor:Add(caseFadeOverlay, "Destroy")

	local caseFadeTween: Tween? = nil
	local function caseFadeTo(opaque: boolean)
		if caseFadeTween then
			caseFadeTween:Cancel()
		end
		caseFadeOverlay.Visible = true
		local tween = TweenService:Create(caseFadeOverlay, CASE_FADE_INFO, {
			BackgroundTransparency = if opaque then 0 else 1,
		})
		caseFadeTween = tween
		tween:Play()
		task.wait(CASE_FADE_DURATION)
		if not opaque and caseFadeTween == tween then
			caseFadeOverlay.Visible = false
		end
	end

	-- Corre `midBlack` (cambios de cámara/blur/visibilidad) con la pantalla en
	-- negro: fade a negro → midBlack → fade desde negro. Bloqueante (yields).
	-- `caseTransitioning` evita solapar transiciones (clicks rápidos).
	local caseTransitioning = false
	local function runCaseTransition(midBlack: () -> ())
		caseTransitioning = true
		caseFadeTo(true)
		midBlack()
		caseFadeTo(false)
		caseTransitioning = false
	end

	-- Mirror cliente de InventoryRepository.ownsWeaponWrap sobre el estado
	-- replicado (soporta true y counts numéricos).
	local function ownsWrapForWeapon(inventory: any, category: string, weaponId: string, wrapId: string): boolean
		local wrapsByWeapon = if type(inventory) == "table" then inventory.WeaponWrapsByWeapon else nil
		local categoryWraps = if type(wrapsByWeapon) == "table" then wrapsByWeapon[category] else nil
		local weaponWraps = if type(categoryWraps) == "table" then categoryWraps[weaponId] else nil
		if type(weaponWraps) ~= "table" then
			return false
		end
		local owned = weaponWraps[wrapId]
		return owned == true or (type(owned) == "number" and owned > 0)
	end

	-- Armas del inventario que existen en ItemsConfig (mismo criterio que el
	-- server: Default solo si está definida en el catálogo de su categoría).
	local function getOwnedWeaponRefs(): { CaseUnboxing.OwnedWeaponRef }
		local inventory = Fusion.peek(DataController.Inventory)
		local refs = {} :: { CaseUnboxing.OwnedWeaponRef }
		for _, category in { "Main", "Special" } do
			local categoryConfig = (ItemsConfig :: any)[category]
			if type(categoryConfig) ~= "table" then
				continue
			end
			local inventoryCategory = if type(inventory) == "table" then inventory[category] else nil
			for weaponId, definition in categoryConfig do
				local id = tostring(weaponId)
				local isOwned = id == ItemDefaults.ITEM_ID
					or (type(inventoryCategory) == "table" and inventoryCategory[id] == true)
				if isOwned then
					table.insert(refs, {
						category = category,
						weaponId = id,
						image = tostring((definition :: any).Image or ""),
					})
				end
			end
		end
		return refs
	end

	-- ¿Queda alguna combinación wrap×arma por obtener en la case?
	local function caseHasRemainingCombos(caseDefinition: WrapCasesConfig.WrapCaseDefinition): boolean
		local inventory = Fusion.peek(DataController.Inventory)
		local ownedWeapons = getOwnedWeaponRefs()
		for _, caseItem in caseDefinition.Items do
			if caseItem.Weight > 0 and type(ItemsConfig.WeaponWraps[caseItem.WrapId]) == "table" then
				for _, weapon in ownedWeapons do
					if not ownsWrapForWeapon(inventory, weapon.category, weapon.weaponId, caseItem.WrapId) then
						return true
					end
				end
			end
		end
		return false
	end

	local caseContent: any = nil
	local function refreshCasePurchaseState()
		if not caseContent then
			return
		end
		local activeCase = caseContent:getActiveCase()
		if not activeCase then
			return
		end
		if pendingCaseOpen or (caseUnboxing and caseUnboxing:isPlaying()) then
			caseContent:setPurchaseState("pending")
		elseif not caseHasRemainingCombos(activeCase) then
			caseContent:setPurchaseState("completed")
		else
			caseContent:setPurchaseState("price")
		end
	end

	caseContent = CaseContentPanel.new(uiGui, janitor, {
		canUseHoverAnimations = canUseHoverAnimations,
		onPurchase = function(caseDefinition)
			if pendingCaseOpen or (caseUnboxing and caseUnboxing:isPlaying()) then
				return
			end
			pendingCaseOpen = true
			refreshCasePurchaseState()
			Network.WrapCases.Open.Send({ caseId = caseDefinition.Id })
		end,
		onClosed = function()
			-- Si el cierre devuelve al Store visible (CloseBtn de CaseContent o fin
			-- del unboxing), la transición va con la pantalla en negro: fade → salto
			-- instantáneo de cámara de vuelta + blur restaurado + Store visible →
			-- fade. Si el cierre vino del teardown del Store (panel cerrándose),
			-- storePanelOpen es false: restauramos estado SIN fade (no hay Store al
			-- que volver y un flash negro sobraría).
			-- El cofre idle vive mientras el detalle está abierto: se destruye aquí.
			if caseUnboxing then
				caseUnboxing:hideIdleChest()
			end
			if storePanelOpen then
				task.spawn(function()
					runCaseTransition(function()
						restoreCaseCamera()
						restoreCaseLighting()
						BlurController.unsuppress(CASE_BLUR_SUPPRESS_KEY)
						storeFrame.Visible = true
					end)
				end)
			else
				restoreCaseCamera()
				restoreCaseLighting()
				BlurController.unsuppress(CASE_BLUR_SUPPRESS_KEY)
			end
		end,
	})

	if caseContent then
		janitor:Add(Network.WrapCases.Result.Listen(function(response: any)
			pendingCaseOpen = false

			if not response.success then
				Notify.warning(response.message)
				refreshCasePurchaseState()
				return
			end

			local caseDefinition = WrapCasesConfig.GetCaseById(response.caseId)
			local wrapDefinition = ItemsConfig.WeaponWraps[response.wrapId]
			local weaponCategoryConfig = (ItemsConfig :: any)[response.weaponCategory]
			local weaponDefinition = if type(weaponCategoryConfig) == "table"
				then weaponCategoryConfig[response.weaponId]
				else nil
			local wrapName = tostring(if type(wrapDefinition) == "table" then wrapDefinition.Name or response.wrapId else response.wrapId)
			local weaponName = tostring(if type(weaponDefinition) == "table" then weaponDefinition.Name or response.weaponId else response.weaponId)

			local function announceResult()
				Notify.success(("Unboxed %s for %s!"):format(wrapName, weaponName))
				refreshCasePurchaseState()
			end

			if caseDefinition and caseUnboxing then
				-- Durante el cofre+reel la escena es 3D: ocultamos Main y la cámara viaja
				-- (travelling, no corte) hasta Workspace.Cameras.unboxing; al llegar entra
				-- el zoom dramático. En el reveal vuelve a 'cases' —que encuadra el
				-- RevealSpawn—, suelta el zoom y showReveal devuelve Main con la Nav en
				-- Equip/Collect.
				caseContent:setMainHidden(true)
				enterUnboxingCamera()
				local wrapRarity = tostring(if type(wrapDefinition) == "table"
					then wrapDefinition.Rarity or "Common"
					else "Common")
				-- El reveal se descarta con Equip o Collect (flag monótono que
				-- awaitDismiss poll-ea desde la corrutina del unboxing).
				local dismissed = false
				local started = caseUnboxing:play({
					caseDefinition = caseDefinition,
					resultWrapId = response.wrapId,
					resultWeaponCategory = response.weaponCategory,
					resultWeaponId = response.weaponId,
					ownedWeapons = getOwnedWeaponRefs(),
					-- Beats del reel → kicks de cámara: rumble mientras vuela, jolts
					-- secos al frenar (onReelTick) y un golpe al clavar el ganador
					-- (onReelLand), un beat antes del boom del reveal (explodeCamera).
					onReelTick = kickCamera,
					onReelLand = landCamera,
					onRevealShown = function()
						-- La cámara NO cambia de sitio: el reveal ocurre en la misma toma de
						-- 'unboxing', donde ya está el arma ganadora. Lo que sí encaja es la
						-- onda expansiva (sacudida + golpe de FOV), y aparece el frame
						-- CaseContent.Reveal con Equip/Collect.
						explodeCamera()
						caseContent:showReveal({
							wrapName = wrapName,
							rarity = wrapRarity,
							onEquip = function()
								Network.Shop.EquipItem.Send({
									category = LockerCategory.WEAPON_WRAPS,
									itemId = response.wrapId,
									weaponCategory = response.weaponCategory,
									weaponId = response.weaponId,
								})
								dismissed = true
							end,
							onCollect = function()
								dismissed = true
							end,
						})
					end,
					awaitDismiss = function()
						while not dismissed do
							task.wait()
						end
					end,
					onFinished = function()
						-- El jugador ya descartó el reveal (Equip/Collect): se cierra
						-- el detalle de la case y se vuelve a la Store (onClosed
						-- re-muestra el Store) refrescando el estado de compra.
						caseContent:close()
						refreshCasePurchaseState()
					end,
				})
				if not started then
					-- Ya había un unboxing en curso: deshacer el ocultado/viaje de cámara
					-- que acabamos de aplicar y limitarnos a anunciar.
					caseContent:setMainHidden(false)
					exitUnboxingCamera()
					announceResult()
				end
			else
				-- Sin frame de Unboxing en la GUI: el grant ya ocurrió; anunciar directo.
				announceResult()
			end
		end), true)

		-- Botones Store.Home.Row1.<ButtonName> — uno por case de WrapCasesConfig.
		local homeNode = storeFrame:FindFirstChild("Home")
		local row1Node = if homeNode then homeNode:FindFirstChild("Row1") else nil
		if row1Node then
			for _, caseDefinition in WrapCasesConfig.CasesInOrder do
				local buttonNode = row1Node:FindFirstChild(caseDefinition.ButtonName)
				if buttonNode and buttonNode:IsA("GuiButton") then
					local caseButton = buttonNode :: GuiButton
					-- Label opcional del botón: pinta el nombre de la case si existe.
					for _, labelName in { "Title", "Name" } do
						local labelNode = caseButton:FindFirstChild(labelName)
						if labelNode and labelNode:IsA("TextLabel") then
							labelNode.Text = caseDefinition.Name
							break
						end
					end
					InteractiveScaleTween.bindButton(caseButton, janitor, {
						enableHover = canUseHoverAnimations,
						hoverScale = UITheme.ButtonHoverScale,
						clickScale = UITheme.ButtonClickScale,
					})
					janitor:Add(caseButton.Activated:Connect(function()
						if caseUnboxing and caseUnboxing:isPlaying() then
							return
						end
						if caseTransitioning then
							return
						end
						-- CaseContent reemplaza al Store en pantalla (el panel
						-- sigue abierto; onClosed del CaseContent lo re-muestra). Con
						-- la pantalla en negro: salto instantáneo de cámara a
						-- Workspace.Cameras.cases, se suprime el blur del Store (la
						-- vista de la case es una escena de cámara, no debe ir
						-- borrosa) y se oculta el Store.
						runCaseTransition(function()
							caseContent:open(caseDefinition)
							applyCaseCamera()
							applyCaseLighting()
							-- Cofre idle quieto en FallPosition, visible ya al abrir el
							-- detalle (antes de comprar); el unboxing lo reutiliza.
							if caseUnboxing then
								caseUnboxing:showIdleChest()
							end
							BlurController.suppress(CASE_BLUR_SUPPRESS_KEY)
							storeFrame.Visible = false
							refreshCasePurchaseState()
						end)
					end), "Disconnect")
				else
					warn("[StoreFeature] Falta Store.Home.Row1." .. caseDefinition.ButtonName .. " para la case " .. caseDefinition.Name)
				end
			end
		else
			warn("[StoreFeature] Falta Store.Home.Row1; botones de wrap cases no cableados.")
		end
	end

	-- ── Nav tabs ─────────────────────────────────────────────
	local navFrames = {} :: { [string]: GuiObject }
	local activeNavTab: string? = nil
	local navTabController = NavTabController.new()
	janitor:Add(navTabController, "Destroy")

	local strokeTweens = {} :: { [GuiButton]: Tween }
	local function tweenStroke(button: GuiButton, stroke: UIStroke, color: Color3)
		local existing = strokeTweens[button]
		if existing then
			existing:Cancel()
		end
		local tween = TweenService:Create(stroke, UITheme.NavTweenInfo, { Color = color })
		strokeTweens[button] = tween
		tween:Play()
	end
	janitor:Add(function()
		for _, tween in strokeTweens do
			tween:Cancel()
		end
		table.clear(strokeTweens)
	end, true)

	-- Escala de los tabs consciente de la selección: el tab activo se mantiene en
	-- NavSelectedScale (más grande que el resto) y NO se encoge ni cambia con el
	-- hover/click; los inactivos hacen un pop sutil al pasar/clicar. Opera sobre la
	-- misma UIScale que usa NavTabController (un único nodo por botón), por eso no
	-- usamos InteractiveScaleTween aquí (metería una segunda UIScale en conflicto).
	local navScaleTweens = {} :: { [GuiButton]: Tween }
	local function getNavScaleNode(button: GuiButton): UIScale
		local existing = button:FindFirstChildOfClass("UIScale")
		if existing then
			return existing
		end
		local created = Instance.new("UIScale")
		created.Name = "NavScale"
		created.Parent = button
		return created
	end
	local function tweenNavScale(button: GuiButton, target: number)
		local node = getNavScaleNode(button)
		local existing = navScaleTweens[button]
		if existing then
			existing:Cancel()
		end
		local tween = TweenService:Create(node, UITheme.HoverTweenInfo, { Scale = target })
		navScaleTweens[button] = tween
		tween:Play()
	end
	janitor:Add(function()
		for _, tween in navScaleTweens do
			tween:Cancel()
		end
		table.clear(navScaleTweens)
	end, true)

	-- Forward decl: setActiveTab necesita llamar al tween de aparición del
	-- frame seleccionado, que se define más abajo con sus dependencias listas.
	-- `kind` controla la intensidad: "open" (entrada desde menú, pop grande)
	-- vs "switch" (cambio de tab, pop sutil).
	local playActiveNavFrameTween: (kind: "open" | "switch") -> ()
	-- Reveal escalonado de los items de la página activa; se asigna más abajo
	-- cuando la Nav ya está registrada (los pageReveals se construyen por tab).
	local playPageRevealIfActive: () -> ()

	local function setActiveTab(name: string)
		if activeNavTab == name then return end
		activeNavTab = name
		for tabName, frame in navFrames do
			frame.Visible = (tabName == name)
		end
		navTabController:setActive(name)
		if playActiveNavFrameTween then
			playActiveNavFrameTween("switch")
		end
		if playPageRevealIfActive then
			playPageRevealIfActive()
		end
	end

	for _, child in (if nav then nav:GetChildren() else {}) do
		if child:IsA("GuiButton") and child.Name ~= "CloseBtn" and child.Name ~= "Close" then
			local btn = child :: GuiButton
			local targetFrame = storeFrame:FindFirstChild(btn.Name)

			if targetFrame and targetFrame:IsA("GuiObject") then
				navFrames[btn.Name] = targetFrame
				navTabController:register(btn.Name, btn)

				local function isActiveTab()
					return activeNavTab == btn.Name
				end
				local hovered = false

				local stroke = btn:FindFirstChildOfClass("UIStroke")
				local defaultStrokeColor = if stroke then stroke.Color else nil

				janitor:Add(btn.MouseEnter:Connect(function()
					hovered = true
					if not canUseHoverAnimations then
						return
					end
					if stroke then
						tweenStroke(btn, stroke, UITheme.StrokeHover)
					end
					if not isActiveTab() then
						tweenNavScale(btn, UITheme.ButtonHoverScale)
					end
				end), "Disconnect")

				janitor:Add(btn.MouseLeave:Connect(function()
					hovered = false
					if stroke and defaultStrokeColor then
						tweenStroke(btn, stroke, defaultStrokeColor)
					end
					if not isActiveTab() then
						tweenNavScale(btn, UITheme.NavUnselectedScale)
					end
				end), "Disconnect")

				-- El tab activo no reacciona al click (se queda en NavSelectedScale);
				-- los inactivos sí hacen el pop de presión.
				janitor:Add(btn.MouseButton1Down:Connect(function()
					if not isActiveTab() then
						tweenNavScale(btn, UITheme.ButtonClickScale)
					end
				end), "Disconnect")

				janitor:Add(btn.MouseButton1Up:Connect(function()
					if isActiveTab() then
						return
					end
					local target = if hovered and canUseHoverAnimations
						then UITheme.ButtonHoverScale
						else UITheme.NavUnselectedScale
					tweenNavScale(btn, target)
				end), "Disconnect")

				janitor:Add(btn.Activated:Connect(function()
					setActiveTab(btn.Name)
				end), "Disconnect")
			end
		end
	end

	-- Tab por defecto: preferimos la página de packs (CashPage, o "Cash" legacy);
	-- si no existe, el primer tab registrado.
	cashTabName = if navFrames["CashPage"] then "CashPage"
		elseif navFrames["Cash"] then "Cash"
		else nil
	local hasSetDefault = false
	for name, frame in navFrames do
		if name == cashTabName or (not hasSetDefault and not cashTabName) then
			frame.Visible = true
			activeNavTab = name
			hasSetDefault = true
		else
			frame.Visible = false
		end
	end
	if activeNavTab then
		navTabController:setActive(activeNavTab)
	end

	-- Reveal por página: cada tab registrado en Nav consigue su propio
	-- StaggerReveal (Row1/Row2 de ese tab); sin barra de tabs (estructura plana),
	-- el propio Store hace de única página implícita.
	for name, frame in navFrames do
		ensurePageReveal(name, frame)
	end
	local flatPageReveal = if next(navFrames) == nil then ensurePageReveal("__store__", storeFrame) else nil

	playPageRevealIfActive = function()
		if flatPageReveal then
			flatPageReveal:play()
			return
		end
		local reveal = if activeNavTab then pageReveals[activeNavTab] else nil
		if reveal then
			reveal:play()
		end
	end

	-- ── Stagger de aparición de los items de Nav ─────────────
	-- Solo si hay Nav; sin barra de tabs no hay items que escalonar.
	local navStagger: any = nil
	if nav then
		navStagger = NavStaggerController.new({
			{ container = nav, getSelectedKey = function() return activeNavTab end },
		})
		janitor:Add(navStagger, "Destroy")
	end

	-- ── Tween de aparición del frame activo ──────────────────
	-- Dos perfiles:
	--   "open"   → entrada desde el menú (pop grande, Back.Out con overshoot).
	--   "switch" → cambio de tab dentro del store (pop sutil, Quad.Out).
	local NAV_FRAME_OPEN_START_SCALE = 0
	local NAV_FRAME_OPEN_TWEEN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local NAV_FRAME_SWITCH_START_SCALE = 0.94
	local NAV_FRAME_SWITCH_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local navFrameScales: { [GuiObject]: UIScale } = {}
	local activeNavFrameTween: Tween? = nil

	local function ensureNavFrameScale(frame: GuiObject): UIScale
		local cached = navFrameScales[frame]
		if cached then return cached end
		local existing = frame:FindFirstChild("NavFrameScale")
		local scale: UIScale
		if existing and existing:IsA("UIScale") then
			scale = existing
		else
			scale = Instance.new("UIScale")
			scale.Name = "NavFrameScale"
			scale.Parent = frame
		end
		navFrameScales[frame] = scale
		return scale
	end

	playActiveNavFrameTween = function(kind: "open" | "switch")
		if activeNavFrameTween then
			activeNavFrameTween:Cancel()
			activeNavFrameTween = nil
		end
		local name = activeNavTab
		if not name then return end
		local frame = navFrames[name]
		if not frame then return end
		local startScale = if kind == "open" then NAV_FRAME_OPEN_START_SCALE else NAV_FRAME_SWITCH_START_SCALE
		local tweenInfo = if kind == "open" then NAV_FRAME_OPEN_TWEEN_INFO else NAV_FRAME_SWITCH_TWEEN_INFO
		local scale = ensureNavFrameScale(frame)
		scale.Scale = startScale
		local tween = TweenService:Create(scale, tweenInfo, { Scale = 1 })
		activeNavFrameTween = tween
		tween:Play()
	end

	janitor:Add(function()
		if activeNavFrameTween then
			activeNavFrameTween:Cancel()
			activeNavFrameTween = nil
		end
		for _, scale in navFrameScales do
			if scale.Parent ~= nil then
				scale.Scale = 1
			end
		end
		table.clear(navFrameScales)
	end, true)

	-- ── Saldo de Cash en vivo ─────────────────────────────────
	-- Store.Cash.Value muestra el efectivo actual del jugador, observando el estado
	-- reactivo de DataController.Stats (mismo patrón que el HUD del menú). Si el
	-- label no existe, se omite sin afectar al resto del panel.
	local cashBalanceNode = storeFrame:FindFirstChild("Cash")
	local cashValueNode = cashBalanceNode and cashBalanceNode:FindFirstChild("Value")
	if cashValueNode and cashValueNode:IsA("TextLabel") then
		local cashValueLabel = cashValueNode :: TextLabel
		local fusionScope = Fusion.scoped(Fusion)
		janitor:Add(function()
			Fusion.doCleanup(fusionScope)
		end, true)

		DataController:WhenReady():andThen(function()
			local function updateCashBalance()
				local stats = Fusion.peek(DataController.Stats)
				if stats then
					cashValueLabel.Text = UIUtils.formatCashAmount(stats.Cash)
				end
			end
			local statsObserver = fusionScope:Observer(DataController.Stats)
			janitor:Add(statsObserver:onBind(updateCashBalance), true)
		end)
	end

	-- ── Gifting ──────────────────────────────────────────────
	-- El flujo de regalo (UserInterface.Gifting) lo abre el botón "Gift" de cada
	-- pack regalable (cableado en bindCashButtons). No hay ya un modo regalo
	-- global ni botón toggle en el Store.
	giftFlow = GiftFlow.new({
		menuController = menuController,
		storeFrame = storeFrame,
	}, janitor)

	-- ── Panel controller ──────────────────────────────────────
	local panel = PanelController.new(menuController, storeFrame, storeButton, closeButton, {
		animationMode = "none",
		onOpen = function()
			storePanelOpen = true
			BlurController.acquire(BLUR_KEY)
			fovEffect:expand()
			if navStagger then
				navStagger:play()
			end
			playActiveNavFrameTween("open")
			playPageRevealIfActive()
		end,
		onClose = function()
			-- Flag primero: el close() del CaseContent de abajo dispara su
			-- onClosed, que solo re-muestra el Store si el panel sigue abierto.
			storePanelOpen = false
			BlurController.release(BLUR_KEY)
			fovEffect:restore()
			-- Cerrar el panel (CloseBtn) descarta cualquier flujo de regalo colgado.
			if giftFlow then
				giftFlow:reset()
			end
			-- El panel de case es hijo lógico del Store: se cierra con él.
			if caseContent then
				caseContent:close()
			end
		end,
	})
	janitor:Add(panel, "Destroy")

	return janitor
end

return StoreFeature
