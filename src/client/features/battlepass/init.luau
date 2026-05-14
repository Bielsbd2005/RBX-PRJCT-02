--!strict
--[[
	BattlePassFeature (Client)

	Controller completo del Battle Pass:
	  • Open/Close del panel vía PanelController + Blur.
	  • Reactivo a DataController.BattlePass (Fusion 0.3 Observer).
	  • Paginación de 6 slots (Next/Back) sobre los tiers de la season activa.
	  • Click-to-claim por slot (free/premium); el servidor valida.
	  • Premium purchase via Robux developer product (botón Purchase).
	  • Listener de Network.BattlePass.Response para feedback básico.

	Convenciones de UI (autoradas en PlayerGui.UserInterface.BattlePass):
	  Main."1".."6"          -- slots visibles
	    .free.Icon, .free.Value         -- recompensa free
	    .premium.Icon, .premium.Value   -- recompensa premium
	  Main.Premium.Purchase   -- botón compra Premium (Robux)
	  LevelIndicators."1".."6"
	    .Value, .Indicator              -- número y color del tier
	  LevelContainer
	    .Bar.Fill                       -- progreso XP del tier actual
	    .Level                          -- número del tier actual ("MAX" si completo)
	  Next, Back                        -- paginación
	  CloseBtn                          -- cerrar panel

	Convención de estado por slot/row (atributo "BPState"):
	  "Locked"    — tier todavía no completado por el jugador.
	  "Claimable" — completado y aún no reclamado.
	  "Claimed"   — recompensa ya entregada.
	  "PremiumLocked" — premium row, completado, pero el jugador no posee Premium.

	El UI author puede pintar estos estados con UIStroke/UIGradient bindeado a
	atributos. Si no lo hace, la UI sigue siendo funcional sin penalty visual.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any
local PanelController = require(Client.core.ui.PanelController)
local UIUtils = require(Client.core.ui.UIUtils)
local BlurController = require(Client.core.ui.BlurController)
local CameraFovEffect = require(Client.core.ui.CameraFovEffect)
local Confetti = require(Client.core.ui.Confetti)
local DataController = require(Client.core.data.DataController)
local Network = require(Shared.networking.Network)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any

local BLUR_KEY = "BattlePass"
local SLOTS_PER_PAGE = 6
local INDICATOR_DONE = Color3.fromRGB(136, 75, 246)
local INDICATOR_TODO = Color3.fromRGB(255, 255, 255)

-- Hover: el icon sube `HOVER_LIFT_PIXELS` en Y al pasar el mouse.
local HOVER_LIFT_PIXELS = 14
local HOVER_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Selected preview: al clicar un item, el ImageLabel de BattlePass.Selected
-- cambia su Image y entra desde un poco más abajo hasta su Position autorada.
local SELECTED_LIFT_PIXELS = 24
local SELECTED_TWEEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Estilos de Next/Back según si el jugador puede avanzar/retroceder.
local NAV_ENABLED_BG_COLOR  = Color3.fromRGB(255, 255, 255)
local NAV_ENABLED_IMG_COLOR = Color3.fromRGB(0, 0, 0)
local NAV_DISABLED_BG_COLOR  = Color3.fromRGB(0, 0, 0)
local NAV_DISABLED_IMG_COLOR = Color3.fromRGB(255, 255, 255)
local NAV_DISABLED_BG_TRANSPARENCY  = 0.65
local NAV_DISABLED_IMG_TRANSPARENCY = 0.77

-- Estilo de un slot ya reclamado (Claimed). Para todos los demás estados
-- (Locked / Claimable / PremiumLocked) se restauran los colores autorados
-- capturados la primera vez que vimos cada row.
local CLAIMED_BG_COLOR    = Color3.fromRGB(0, 0, 0)
local CLAIMED_ICON_COLOR  = Color3.fromRGB(72, 73, 73)
local CLAIMED_VALUE_COLOR = Color3.fromRGB(106, 106, 106)

-- Notification toast en claim exitoso: cae desde arriba (Y.Scale = -1) hasta
-- la Position autorada, sostiene NOTIFICATION_HOLD_SECONDS y se va por arriba.
-- Mismo patrón que MatchHud:playLevelUpAnimation.
local NOTIFICATION_TWEEN_IN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local NOTIFICATION_TWEEN_OUT_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local NOTIFICATION_HOLD_SECONDS = 3.0
local NOTIFICATION_CONFETTI_COLORS = {
	Color3.fromRGB(60, 200, 100),
	Color3.fromRGB(40, 220, 80),
	Color3.fromRGB(100, 230, 130),
	Color3.fromRGB(20, 160, 60),
	Color3.fromRGB(140, 240, 160),
}

local BattlePassFeature = {}

-- ────────────────────────────────────────────────────────────
-- Helpers de resolución de UI
-- ────────────────────────────────────────────────────────────

local function _resolveCloseButton(battlepassFrame: GuiObject): GuiButton?
	local closeBtn = battlepassFrame:FindFirstChild("CloseBtn")
	if closeBtn and closeBtn:IsA("GuiButton") then
		return closeBtn
	end
	return nil
end

local function _resolveSlotRow(slot: Instance, rowName: string): { frame: GuiObject, icon: ImageLabel?, valueLabel: TextLabel? }?
	local row = slot:FindFirstChild(rowName)
	if not row or not row:IsA("GuiObject") then
		return nil
	end
	local icon = row:FindFirstChild("Icon")
	local valueLabel = row:FindFirstChild("Value")
	return {
		frame = row,
		icon = if icon and icon:IsA("ImageLabel") then icon else nil,
		valueLabel = if valueLabel and valueLabel:IsA("TextLabel") then valueLabel else nil,
	}
end

-- Formatea segundos restantes como "Ends in 6 weeks, 2 days" (dos unidades
-- como máximo, omitiendo la segunda si es 0). Devuelve "" si ya terminó.
-- Granularidad escalonada: weeks/days → days/hours → hours/minutes → minutes.
local function _formatTimeLeft(seconds: number): string
	if seconds <= 0 then return "" end

	local function unit(n: number, singular: string): string
		return tostring(n) .. " " .. (if n == 1 then singular else singular .. "s")
	end

	local minutes = math.floor(seconds / 60)
	local hours = math.floor(minutes / 60)
	local days = math.floor(hours / 24)
	local weeks = math.floor(days / 7)

	if weeks >= 1 then
		local remDays = days - weeks * 7
		if remDays > 0 then
			return ("Ends in %s, %s"):format(unit(weeks, "week"), unit(remDays, "day"))
		end
		return ("Ends in %s"):format(unit(weeks, "week"))
	end
	if days >= 1 then
		local remHours = hours - days * 24
		if remHours > 0 then
			return ("Ends in %s, %s"):format(unit(days, "day"), unit(remHours, "hour"))
		end
		return ("Ends in %s"):format(unit(days, "day"))
	end
	if hours >= 1 then
		local remMinutes = minutes - hours * 60
		if remMinutes > 0 then
			return ("Ends in %s, %s"):format(unit(hours, "hour"), unit(remMinutes, "minute"))
		end
		return ("Ends in %s"):format(unit(hours, "hour"))
	end
	if minutes >= 1 then
		return ("Ends in %s"):format(unit(minutes, "minute"))
	end
	return "Ending soon"
end

-- Construye la representación visual de una Reward.
-- Devuelve image (asset id o "") y label (texto).
local function _resolveRewardVisual(reward: BattlePassConfig.Reward): (string, string)
	if not reward then return "", "" end

	if reward.Kind == "Cash" then
		return reward.Icon or BattlePassConfig.RewardIcons.Cash or "",
			reward.Label or ("+" .. UIUtils.formatCashAmount(reward.Amount or 0))
	elseif reward.Kind == "Item" then
		local catalogCategory = ItemsConfig[reward.Category]
		local itemDef = if type(catalogCategory) == "table" then catalogCategory[reward.ItemId] else nil
		local image = reward.Icon or (if itemDef and type(itemDef.Image) == "string" then itemDef.Image else "")
		local name = reward.Label or (if itemDef and type(itemDef.Name) == "string" then itemDef.Name else (reward.ItemId or "?"))
		return image, name
	end
	return reward.Icon or "", reward.Label or ""
end

-- ────────────────────────────────────────────────────────────
-- Start
-- ────────────────────────────────────────────────────────────

function BattlePassFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()

	local battlepassButton = UIUtils.findBottomButton(menuGui, "BattlePass")
	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local battlepassFrameNode = uiGui:WaitForChild("BattlePass")

	if not battlepassButton then
		warn("[BattlePassFeature] No se encontró el botón 'BattlePass' en Menu.Bottom")
		return janitor
	end
	if not battlepassFrameNode:IsA("GuiObject") then
		warn("[BattlePassFeature] PlayerGui.UserInterface.BattlePass no es un GuiObject")
		return janitor
	end
	local battlepassFrame = battlepassFrameNode :: GuiObject

	-- Bottom bar UI (Menu.Bottom.BattlePass.*): mirror compacto del estado del
	-- pass. Todos los nodos son opcionales — si el UI author no los pone, se
	-- ignoran silenciosamente. Driven por el mismo Fusion observer que el panel.
	local bottomNotification: TextLabel? = nil
	local bottomBarFill: GuiObject? = nil
	local bottomNextLevel: TextLabel? = nil
	local bottomTimeLeft: TextLabel? = nil
	do
		local notif = battlepassButton:FindFirstChild("Notification")
		if notif and notif:IsA("TextLabel") then
			bottomNotification = notif
		end
		local bar = battlepassButton:FindFirstChild("Bar")
		local fill = if bar then bar:FindFirstChild("Fill") else nil
		if fill and fill:IsA("GuiObject") then
			bottomBarFill = fill
		end
		local nextLevelNode = battlepassButton:FindFirstChild("NextLevel")
		if nextLevelNode and nextLevelNode:IsA("TextLabel") then
			bottomNextLevel = nextLevelNode
		end
		local tlNode = battlepassButton:FindFirstChild("TimeLeft")
		if tlNode and tlNode:IsA("TextLabel") then
			bottomTimeLeft = tlNode
		end
	end

	-- Resolver nodos. Faltantes solo warn; el panel sigue abriéndose.
	-- "Main" here is a Frame name in the BattlePass UI, unrelated to WeaponCategory.
	local mainFolder = battlepassFrame:FindFirstChild("Main")
	local indicatorsFolder = battlepassFrame:FindFirstChild("LevelIndicators")
	local levelContainer = battlepassFrame:FindFirstChild("LevelContainer")
	local nextBtn = battlepassFrame:FindFirstChild("Next")
	local backBtn = battlepassFrame:FindFirstChild("Back")
	local backIndicatorNode = if backBtn then backBtn:FindFirstChild("Indicator") else nil
	local backIndicator: GuiObject? = if backIndicatorNode and backIndicatorNode:IsA("GuiObject") then backIndicatorNode else nil
	local premiumFolder = if mainFolder then mainFolder:FindFirstChild("Premium") else nil
	local purchaseBtn = if premiumFolder then premiumFolder:FindFirstChild("Purchase") else nil
	local skipBtn = battlepassFrame:FindFirstChild("Skip")
	local timeLeftNode = battlepassFrame:FindFirstChild("TimeLeft")
	local timeLeftLabel: TextLabel? = if timeLeftNode and timeLeftNode:IsA("TextLabel") then timeLeftNode else nil
	local notificationNode = battlepassFrame:FindFirstChild("Notification")
	local notificationFrame: GuiObject? = if notificationNode and notificationNode:IsA("GuiObject") then notificationNode else nil

	if not mainFolder then warn("[BattlePassFeature] BattlePass.Main no existe") end
	if not indicatorsFolder then warn("[BattlePassFeature] BattlePass.LevelIndicators no existe") end
	if not levelContainer then warn("[BattlePassFeature] BattlePass.LevelContainer no existe") end

	-- Resolver slots 1..6 y indicators 1..6.
	local mainSlots: { GuiObject } = {}
	local indicatorSlots: { { value: TextLabel?, indicator: GuiObject? } } = {}
	for i = 1, SLOTS_PER_PAGE do
		if mainFolder then
			local slot = mainFolder:FindFirstChild(tostring(i))
			if slot and slot:IsA("GuiObject") then
				mainSlots[i] = slot
			end
		end
		if indicatorsFolder then
			local entry = indicatorsFolder:FindFirstChild(tostring(i))
			if entry and entry:IsA("GuiObject") then
				local valueLabel = entry:FindFirstChild("Value")
				local indicatorObj = entry:FindFirstChild("Indicator")
				indicatorSlots[i] = {
					value = if valueLabel and valueLabel:IsA("TextLabel") then valueLabel else nil,
					indicator = if indicatorObj and indicatorObj:IsA("GuiObject") then indicatorObj else nil,
				}
			else
				indicatorSlots[i] = { value = nil, indicator = nil }
			end
		else
			indicatorSlots[i] = { value = nil, indicator = nil }
		end
	end

	-- Selected puede ser el propio ImageLabel/ImageButton, o un contenedor cuyo
	-- primer hijo Image* es el preview. Soportamos ambas formas para no atar la
	-- implementación a un layout exacto del UI.
	local selectedImage: (ImageLabel | ImageButton)? = nil
	do
		local selectedNode = battlepassFrame:FindFirstChild("Selected")
		if selectedNode then
			if selectedNode:IsA("ImageLabel") or selectedNode:IsA("ImageButton") then
				selectedImage = selectedNode :: any
			else
				for _, child in selectedNode:GetChildren() do
					if child:IsA("ImageLabel") or child:IsA("ImageButton") then
						selectedImage = child :: any
						break
					end
				end
			end
		end
	end

	local barFill: GuiObject? = nil
	local levelLabel: TextLabel? = nil
	if levelContainer then
		local bar = levelContainer:FindFirstChild("Bar")
		local fill = bar and bar:FindFirstChild("Fill")
		if fill and fill:IsA("GuiObject") then
			barFill = fill
		end
		local levelTextNode = levelContainer:FindFirstChild("Level")
		if levelTextNode and levelTextNode:IsA("TextLabel") then
			levelLabel = levelTextNode
		end
	end

	-- ────────────────────────────────────────────────────────
	-- Estado local de UI
	-- ────────────────────────────────────────────────────────

	local season = BattlePassConfig.GetActiveSeason()
	local maxTier = BattlePassConfig.GetMaxTier(season)
	local pageCount = math.max(1, math.ceil(maxTier / SLOTS_PER_PAGE))

	-- TimeLeft: actualiza el label con el tiempo restante hasta season.EndsAt.
	-- El intervalo de tick es adaptativo: arriba de 1h el display más fino que
	-- mostramos es "hours, minutes" → tickear cada hora basta. Solo en la
	-- última hora caemos a 60s para que el contador de minutos sea fresco.
	-- Si EndsAt no está configurado (=0) o ya pasó, oculta el label.
	local timeLeftRunning = true
	local function updateTimeLeft(): number
		if not timeLeftLabel and not bottomTimeLeft then return 3600 end
		if season.EndsAt <= 0 then
			if timeLeftLabel then timeLeftLabel.Visible = false end
			if bottomTimeLeft then bottomTimeLeft.Visible = false end
			return 3600
		end
		local remaining = season.EndsAt - os.time()
		local text = _formatTimeLeft(remaining)
		if text == "" then
			if timeLeftLabel then timeLeftLabel.Visible = false end
			if bottomTimeLeft then bottomTimeLeft.Visible = false end
			return 3600
		end
		if timeLeftLabel then
			timeLeftLabel.Visible = true
			timeLeftLabel.Text = text
		end
		if bottomTimeLeft then
			bottomTimeLeft.Visible = true
			bottomTimeLeft.Text = text
		end
		return if remaining > 3600 then 3600 else 60
	end
	updateTimeLeft()
	if (timeLeftLabel or bottomTimeLeft) and season.EndsAt > 0 then
		task.spawn(function()
			while timeLeftRunning do
				local nextWait = updateTimeLeft()
				task.wait(nextWait)
			end
		end)
	end
	janitor:Add(function() timeLeftRunning = false end, true)
	local currentPage = 0

	-- Forward decl: render lo definimos más abajo, pero `onOpen` necesita
	-- llamarlo (Lua captura el upvalue, así que se resuelve al invocarse).
	local render: (() -> ())? = nil

	-- Devuelve la página 0-indexed que contiene el tier hacia el que está
	-- progresando el jugador. Capeada a [0, pageCount-1] para que en MAX
	-- aterrice en la última página y no fuera de rango.
	local function pageForCurrentTier(): number
		local state = Fusion.peek(DataController.BattlePass)
		if type(state) ~= "table" then return 0 end
		local tier = math.max(1, math.floor(state.CurrentTier or 1))
		tier = math.min(tier, maxTier)
		local pageIdx = math.floor((tier - 1) / SLOTS_PER_PAGE)
		return math.clamp(pageIdx, 0, pageCount - 1)
	end

	-- ────────────────────────────────────────────────────────
	-- Panel open/close
	-- ────────────────────────────────────────────────────────

	local closeButton = _resolveCloseButton(battlepassFrame)
	if not closeButton then
		warn("[BattlePassFeature] No se encontró CloseBtn en BattlePass")
		return janitor
	end

	local fovEffect = CameraFovEffect.new()
	janitor:Add(fovEffect, "Destroy")

	local panel = PanelController.new(menuController, battlepassFrame, battlepassButton, closeButton, {
		animationMode = "fade",
		onOpen = function()
			BlurController.acquire(BLUR_KEY)
			fovEffect:expand()
			-- Cada vez que se abre el panel, snapeamos a la página del
			-- progreso actual del jugador. Reabrir el panel reinicia la
			-- paginación al estado "primera vez" sin perder el resto del
			-- estado replicado.
			currentPage = pageForCurrentTier()
			if render then render() end
		end,
		onClose = function()
			BlurController.release(BLUR_KEY)
			fovEffect:restore()
		end,
	})
	janitor:Add(panel, "Destroy")

	-- Conexiones de click/hover por slot que se reinstalan cada render. Son
	-- baratas (6 slots × 2 rows × 3 conexiones máx) y evitan diff bookkeeping.
	local rowConnections: { RBXScriptConnection } = {}
	local function clearRowConnections()
		for _, conn in rowConnections do
			conn:Disconnect()
		end
		table.clear(rowConnections)
	end
	janitor:Add(clearRowConnections, true)

	-- Cache de la Position autorada de cada icon. Capturada la primera vez que
	-- vemos el icon (antes de que cualquier tween la mueva) y reutilizada para
	-- tweenear de vuelta al estado neutro al salir el cursor.
	local originalIconPositions: { [ImageLabel]: UDim2 } = {}
	local function getOriginalIconPos(icon: ImageLabel): UDim2
		local cached = originalIconPositions[icon]
		if cached == nil then
			cached = icon.Position
			originalIconPositions[icon] = cached
		end
		return cached
	end

	-- Cache de defaults visuales por row. La primera vez que vemos un row,
	-- guardamos sus colores autorados para poder restaurarlos cuando el
	-- estado deje de ser "Claimed". Sin esto, no sabríamos a qué color volver
	-- — el UI author elige la paleta y nosotros la respetamos.
	type RowDefaults = {
		rowBg: Color3,
		rowBgTransparency: number,
		iconColor: Color3?,
		valueColor: Color3?,
		checkImage: GuiObject?,
		indicator: GuiObject?,
	}
	local rowDefaultsCache: { [GuiObject]: RowDefaults } = {}
	local function getRowDefaults(row: { frame: GuiObject, icon: ImageLabel?, valueLabel: TextLabel? }): RowDefaults
		local cached = rowDefaultsCache[row.frame]
		if cached then return cached end

		local checkChild = row.frame:FindFirstChild("Check", true)
		local indicatorChild = row.frame:FindFirstChild("Indicator")
		cached = {
			rowBg = row.frame.BackgroundColor3,
			rowBgTransparency = row.frame.BackgroundTransparency,
			iconColor = if row.icon then row.icon.ImageColor3 else nil,
			valueColor = if row.valueLabel then row.valueLabel.TextColor3 else nil,
			checkImage = if checkChild and checkChild:IsA("GuiObject") then checkChild else nil,
			indicator = if indicatorChild and indicatorChild:IsA("GuiObject") then indicatorChild else nil,
		}
		rowDefaultsCache[row.frame] = cached
		return cached
	end

	-- Wire input → callback solo en MouseButton1 / Touch (funciona en Frame
	-- normal sin requerir GuiButton).
	local function bindRowClick(rowFrame: GuiObject, callback: () -> ())
		local conn = rowFrame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				callback()
			end
		end)
		table.insert(rowConnections, conn)
	end

	-- Pinta Next/Back según si el botón puede usarse en este momento.
	-- Acepta cualquier GuiObject; solo aplica ImageColor/Transparency si el
	-- botón es ImageButton/ImageLabel. Desactiva AutoButtonColor para evitar
	-- que el tint del engine pelee con nuestro color manual.
	local function paintNavButton(btn: Instance?, enabled: boolean)
		if not btn or not btn:IsA("GuiObject") then return end
		btn.Active = enabled
		if btn:IsA("GuiButton") then
			btn.AutoButtonColor = false
		end
		if enabled then
			btn.BackgroundColor3 = NAV_ENABLED_BG_COLOR
			btn.BackgroundTransparency = 0
		else
			btn.BackgroundColor3 = NAV_DISABLED_BG_COLOR
			btn.BackgroundTransparency = NAV_DISABLED_BG_TRANSPARENCY
		end
		if btn:IsA("ImageButton") or btn:IsA("ImageLabel") then
			if enabled then
				btn.ImageColor3 = NAV_ENABLED_IMG_COLOR
				btn.ImageTransparency = 0
			else
				btn.ImageColor3 = NAV_DISABLED_IMG_COLOR
				btn.ImageTransparency = NAV_DISABLED_IMG_TRANSPARENCY
			end
		end
	end

	-- Preview animado del item seleccionado. Capturamos la Position autorada
	-- la primera vez (antes de que ningún tween la mueva) y reutilizamos esa
	-- como destino del tween en cada click.
	local selectedImageOriginalPos: UDim2? = nil
	local function playSelectedAnimation(image: string)
		if not selectedImage then return end
		if selectedImageOriginalPos == nil then
			selectedImageOriginalPos = selectedImage.Position
		end
		local origPos = selectedImageOriginalPos :: UDim2

		selectedImage.Image = image
		-- Snap a un poco más abajo y tweenea de vuelta a la Position original.
		selectedImage.Position = UDim2.new(
			origPos.X.Scale, origPos.X.Offset,
			origPos.Y.Scale, origPos.Y.Offset + SELECTED_LIFT_PIXELS
		)
		TweenService:Create(selectedImage, SELECTED_TWEEN_INFO, {
			Position = origPos,
		}):Play()
	end

	-- Notification toast: cae desde Y.Scale=-1 hasta la Position autorada,
	-- sostiene NOTIFICATION_HOLD_SECONDS y se va por arriba. Se dispara en cada
	-- claim exitoso. Si llega un nuevo trigger mientras un toast está vivo,
	-- la generación se incrementa: la corrutina vieja se autocancela en el
	-- próximo checkpoint y la nueva snapea al estado inicial y reinicia.
	local notificationOriginalPos: UDim2? = nil
	local notificationGeneration = 0
	local notificationCurrentTween: Tween? = nil
	local function showClaimNotification()
		if not notificationFrame then return end
		local frame = notificationFrame :: GuiObject

		if notificationOriginalPos == nil then
			notificationOriginalPos = frame.Position
		end
		local origPos = notificationOriginalPos :: UDim2
		local abovePos = UDim2.new(origPos.X.Scale, origPos.X.Offset, -1, origPos.Y.Offset)

		notificationGeneration += 1
		local myGen = notificationGeneration

		if notificationCurrentTween then
			notificationCurrentTween:Cancel()
			notificationCurrentTween = nil
		end

		frame.Position = abovePos
		frame.Visible = true

		Confetti.Rain(battlepassFrame, {
			colors = NOTIFICATION_CONFETTI_COLORS,
			count = 60,
			minLifetime = 0.9,
			maxLifetime = 1.5,
			spawnDuration = 1.2,
		})

		local tweenIn = TweenService:Create(frame, NOTIFICATION_TWEEN_IN_INFO, { Position = origPos })
		notificationCurrentTween = tweenIn
		tweenIn:Play()

		task.spawn(function()
			tweenIn.Completed:Wait()
			if notificationGeneration ~= myGen then return end
			task.wait(NOTIFICATION_HOLD_SECONDS)
			if notificationGeneration ~= myGen then return end

			local tweenOut = TweenService:Create(frame, NOTIFICATION_TWEEN_OUT_INFO, { Position = abovePos })
			notificationCurrentTween = tweenOut
			tweenOut:Play()
			tweenOut.Completed:Wait()
			if notificationGeneration ~= myGen then return end

			frame.Visible = false
			notificationCurrentTween = nil
		end)
	end

	-- Si la feature se destruye mid-animación (panel close + janitor cleanup),
	-- bumpeamos la generación para que la corrutina activa salga sin tocar el
	-- frame ya destruido.
	janitor:Add(function()
		notificationGeneration += 1
		if notificationCurrentTween then
			notificationCurrentTween:Cancel()
			notificationCurrentTween = nil
		end
	end, true)

	-- Estado inicial: oculto. El UI author puede dejarlo visible en Studio
	-- para posicionarlo, pero al runtime siempre arranca fuera de pantalla.
	if notificationFrame then
		notificationFrame.Visible = false
	end

	-- Hover: tweenea el icon hacia arriba al entrar el mouse y de vuelta al salir.
	local function bindIconHover(rowFrame: GuiObject, icon: ImageLabel)
		local originalPos = getOriginalIconPos(icon)
		local liftedPos = UDim2.new(
			originalPos.X.Scale, originalPos.X.Offset,
			originalPos.Y.Scale, originalPos.Y.Offset - HOVER_LIFT_PIXELS
		)
		local enterConn = rowFrame.MouseEnter:Connect(function()
			TweenService:Create(icon, HOVER_TWEEN_INFO, { Position = liftedPos }):Play()
		end)
		local leaveConn = rowFrame.MouseLeave:Connect(function()
			TweenService:Create(icon, HOVER_TWEEN_INFO, { Position = originalPos }):Play()
		end)
		table.insert(rowConnections, enterConn)
		table.insert(rowConnections, leaveConn)
	end

	local function applyRow(
		row: { frame: GuiObject, icon: ImageLabel?, valueLabel: TextLabel? }?,
		reward: BattlePassConfig.Reward?,
		track: string,
		level: number,
		state: any,
		stateName: string
	)
		if not row then return end
		row.frame:SetAttribute("BPState", stateName)
		row.frame:SetAttribute("BPTier", level)
		row.frame:SetAttribute("BPTrack", track)
		row.frame.Visible = reward ~= nil

		if not reward then
			return
		end

		local image, label = _resolveRewardVisual(reward)
		-- Siempre reescribimos el Image, incluso si está vacío. Si no, al
		-- paginar Back un slot que ahora tiene reward Cash sin icon mantendría
		-- el icon de Item del tier que ocupaba antes ese mismo slot visual.
		if row.icon then
			row.icon.Image = image
		end
		if row.valueLabel then
			row.valueLabel.Text = label
		end

		-- Estilo según estado: Claimed pinta el row de negro y muestra Check;
		-- el resto restaura los defaults autorados.
		local defaults = getRowDefaults(row)
		local isClaimed = stateName == "Claimed"

		if isClaimed then
			-- Solo el row claimado (premium o free) cambia su background. El
			-- Frame interno y el UIGradient se respetan — los rows se claiman
			-- por separado y el gradient autorado sigue tintando.
			row.frame.BackgroundColor3 = CLAIMED_BG_COLOR
			row.frame.BackgroundTransparency = 0
			if row.icon then
				row.icon.ImageColor3 = CLAIMED_ICON_COLOR
			end
			if row.valueLabel then
				row.valueLabel.TextColor3 = CLAIMED_VALUE_COLOR
			end
		else
			row.frame.BackgroundColor3 = defaults.rowBg
			row.frame.BackgroundTransparency = defaults.rowBgTransparency
			if row.icon and defaults.iconColor then
				row.icon.ImageColor3 = defaults.iconColor
			end
			if row.valueLabel and defaults.valueColor then
				row.valueLabel.TextColor3 = defaults.valueColor
			end
		end
		if defaults.checkImage then
			defaults.checkImage.Visible = isClaimed
		end
		if defaults.indicator then
			defaults.indicator.Visible = stateName == "Claimable"
		end

		-- Hover en cualquier estado visible (feedback al cursor).
		if row.icon then
			bindIconHover(row.frame, row.icon)
		end

		-- Click siempre actualiza el preview de BattlePass.Selected. Si además
		-- el slot está Claimable, enviamos el claim al servidor.
		bindRowClick(row.frame, function()
			playSelectedAnimation(image)
			if stateName == "Claimable" then
				-- Coerción defensiva: si por algún motivo level llegase aquí
				-- como string/nil, ByteNet codificaría 0 y el server respondería
				-- "InvalidTier". Garantizamos que siempre se envíe un entero.
				local tierInt = tonumber(level) or 0
				Network.BattlePass.ClaimTier.Send({
					tier = tierInt,
					track = track,
				})
			end
		end)
	end

	render = function()
		clearRowConnections()

		local state = Fusion.peek(DataController.BattlePass)
		if type(state) ~= "table" then
			return
		end

		local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
		local xp = math.max(0, math.floor(state.XP or 0))
		local premiumOwned = state.PremiumOwned == true
		local claimedFree = state.ClaimedFree or {}
		local claimedPremium = state.ClaimedPremium or {}

		-- Level + Bar.
		-- En el modelo interno `currentTier` = "el tier hacia el que se está
		-- progresando". El jugador percibe "Lvl. N" como el último tier que
		-- ha desbloqueado, así que mostramos `currentTier - 1`. Capeado en
		-- [0, maxTier].
		if levelLabel then
			local displayedLevel = math.clamp(currentTier - 1, 0, maxTier)
			levelLabel.Text = "Lvl. " .. tostring(displayedLevel)
		end
		-- Cache de progreso del tier actual: lo usan tanto el barFill del panel
		-- como el bottom bar (Menu.Bottom.BattlePass.Bar.Fill). Mismo cálculo —
		-- si difieren, es solo el destino del Size.X.
		local progressScale: number
		do
			local activeTier = BattlePassConfig.GetTier(season, math.min(currentTier, maxTier))
			local needed = if activeTier then activeTier.XPRequired else 100
			if currentTier > maxTier then
				progressScale = 1
			else
				progressScale = math.clamp(xp / math.max(1, needed), 0, 1)
			end
		end
		if barFill then
			barFill.Size = UDim2.new(progressScale, 0, barFill.Size.Y.Scale, barFill.Size.Y.Offset)
		end

		-- Bottom bar (Menu.Bottom.BattlePass.*) ────────────────────
		if bottomBarFill then
			bottomBarFill.Size = UDim2.new(progressScale, 0, bottomBarFill.Size.Y.Scale, bottomBarFill.Size.Y.Offset)
		end
		if bottomNextLevel then
			-- `currentTier` en el modelo = tier hacia el que se progresa, que es
			-- exactamente el "siguiente nivel" desde la perspectiva del jugador.
			-- Si ya está MAX (currentTier > maxTier), no hay next → "MAX".
			if currentTier > maxTier then
				bottomNextLevel.Text = "MAX"
			else
				bottomNextLevel.Text = "Lvl " .. tostring(currentTier)
			end
		end
		if bottomNotification then
			-- Recuento de claims pendientes: por cada tier ya completado
			-- (level < currentTier), suma free no-reclamado y premium no-reclamado
			-- (este último solo si el jugador posee Premium). Igual criterio que
			-- el backIndicator del panel (ver más abajo) pero global, no por página.
			local pending = 0
			local lastCompletedTier = math.min(currentTier - 1, maxTier)
			for level = 1, lastCompletedTier do
				local tierDef = BattlePassConfig.GetTier(season, level)
				if not tierDef then continue end
				local key = tostring(level)
				if tierDef.Free and claimedFree[key] ~= true then
					pending += 1
				end
				if premiumOwned and tierDef.Premium and claimedPremium[key] ~= true then
					pending += 1
				end
			end
			if pending > 0 then
				bottomNotification.Visible = true
				bottomNotification.Text = tostring(pending)
			else
				bottomNotification.Visible = false
			end
		end

		-- Slots de la página actual
		for i = 1, SLOTS_PER_PAGE do
			local realLevel = currentPage * SLOTS_PER_PAGE + i
			local tierDef = BattlePassConfig.GetTier(season, realLevel)
			local slot = mainSlots[i]
			local indicatorEntry = indicatorSlots[i]

			-- Indicator: Value + color
			if indicatorEntry then
				if indicatorEntry.value then
					indicatorEntry.value.Text = if tierDef then tostring(realLevel) else ""
				end
				if indicatorEntry.indicator then
					indicatorEntry.indicator.Visible = tierDef ~= nil
					indicatorEntry.indicator.BackgroundColor3 =
						if tierDef and realLevel < currentTier then INDICATOR_DONE else INDICATOR_TODO
				end
			end

			-- Slot rows
			if slot then
				slot.Visible = tierDef ~= nil
				if tierDef then
					local isCompleted = realLevel < currentTier
					local levelKey = tostring(realLevel)

					local freeRow = _resolveSlotRow(slot, "free")
					local freeStateName = if claimedFree[levelKey] == true
						then "Claimed"
						elseif isCompleted then "Claimable"
						else "Locked"
					applyRow(freeRow, tierDef.Free, "Free", realLevel, state, freeStateName)

					local premiumRow = _resolveSlotRow(slot, "premium")
					local premiumStateName: string
					if claimedPremium[levelKey] == true then
						premiumStateName = "Claimed"
					elseif not isCompleted then
						premiumStateName = "Locked"
					elseif not premiumOwned then
						premiumStateName = "PremiumLocked"
					else
						premiumStateName = "Claimable"
					end
					applyRow(premiumRow, tierDef.Premium, "Premium", realLevel, state, premiumStateName)
				end
			end
		end

		-- Botones de paginación: pintados según si el jugador puede avanzar.
		paintNavButton(backBtn, currentPage > 0)
		paintNavButton(nextBtn, currentPage < pageCount - 1)

		-- Indicator del Back: visible si la página inmediatamente anterior tiene
		-- algún reward "Claimable" sin reclamar (free siempre cuenta; premium
		-- solo si el jugador posee Premium — sin pase no son claimables y no
		-- deberían pintar pendiente). Si ya estamos en la primera página, oculto.
		if backIndicator then
			local hasPending = false
			if currentPage > 0 then
				local prevPage = currentPage - 1
				local startLevel = prevPage * SLOTS_PER_PAGE + 1
				local endLevel = math.min(startLevel + SLOTS_PER_PAGE - 1, maxTier)
				for level = startLevel, endLevel do
					if level >= currentTier then
						break -- los siguientes tiers tampoco están completados
					end
					local tierDef = BattlePassConfig.GetTier(season, level)
					if not tierDef then continue end
					local key = tostring(level)
					if tierDef.Free and claimedFree[key] ~= true then
						hasPending = true
						break
					end
					if premiumOwned and tierDef.Premium and claimedPremium[key] ~= true then
						hasPending = true
						break
					end
				end
			end
			backIndicator.Visible = hasPending
		end
	end

	-- ────────────────────────────────────────────────────────
	-- Listeners de UI
	-- ────────────────────────────────────────────────────────

	if nextBtn and nextBtn:IsA("GuiButton") then
		janitor:Add(nextBtn.MouseButton1Click:Connect(function()
			if currentPage < pageCount - 1 then
				currentPage += 1
				render()
			end
		end), "Disconnect")
	end
	if backBtn and backBtn:IsA("GuiButton") then
		janitor:Add(backBtn.MouseButton1Click:Connect(function()
			if currentPage > 0 then
				currentPage -= 1
				render()
			end
		end), "Disconnect")
	end

	if purchaseBtn and purchaseBtn:IsA("GuiButton") then
		janitor:Add(purchaseBtn.MouseButton1Click:Connect(function()
			Network.BattlePass.BuyPremium.Send({})
		end), "Disconnect")
	end

	if skipBtn and skipBtn:IsA("GuiButton") then
		janitor:Add(skipBtn.MouseButton1Click:Connect(function()
			Network.BattlePass.BuySkip.Send({})
		end), "Disconnect")
	end

	-- ────────────────────────────────────────────────────────
	-- Network feedback (basico v1: warns para errores)
	-- ────────────────────────────────────────────────────────

	janitor:Add(Network.BattlePass.Response.Listen(function(data: any)
		if type(data) ~= "table" then return end
		if data.success then
			-- Éxito: el observer re-renderea solo al replicarse el cambio.
			-- Toast + confeti solo para claims (track Free/Premium); el receipt
			-- de Premium tiene su propio mensaje "PremiumGranted" sin tier.
			if data.message == "OK" then
				showClaimNotification()
			end
			return
		end
		warn(("[BattlePassFeature] Response: %s (tier=%s track=%s)"):format(
			tostring(data.message),
			tostring(data.tier),
			tostring(data.track)
		))
	end), true)

	-- ────────────────────────────────────────────────────────
	-- Render reactivo: bind al Value de Fusion
	-- ────────────────────────────────────────────────────────

	DataController:WhenReady():andThen(function()
		-- Primer render con datos reales: snapea a la página del tier actual
		-- para que la "primera vez" coincida con el progreso del jugador.
		currentPage = pageForCurrentTier()
		if render then render() end
		local scope = Fusion.scoped(Fusion)
		janitor:Add(function()
			Fusion.doCleanup(scope)
		end, true)
		local obs = scope:Observer(DataController.BattlePass :: any)
		janitor:Add(obs:onBind(render :: () -> ()), true)
	end)

	return janitor
end

return BattlePassFeature
