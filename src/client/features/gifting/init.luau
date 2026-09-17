--!strict
--[[
	Recepción de regalos: muestra UserInterface.GiftAlert (el más antiguo de
	PendingGifts) solo en lobby limpio: carga terminada, sin partida y sin panel
	abierto. Mientras se muestra, OCULTA el menú.

	Shade y blur los pone ShadeController si GiftAlert tiene el atributo
	`ShadowCenter` (o el alias `ShadeColor`) en Studio; este feature no los toca.

	"En lobby" se decide con MatchState y no con menuController:isHidden()/
	Menu.Enabled: como este feature oculta el menú, esas señales se realimentarían.

	Estructura en Studio: GiftAlert.Container.Content.{ClaimBtn, Title.Text.Subtitle}.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Fusion = require(Packages.fusion) :: any
local Janitor = require(Packages.janitor) :: any
local Network = require(Shared.networking.Network)
local StoreProducts = require(Shared.constants.StoreProducts)
local DataController = require(Client.core.data.DataController)
local Notify = require(Client.core.ui.NotificationController)
local UIUtils = require(Client.core.ui.UIUtils)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local UITheme = require(Client.core.ui.UITheme)
local MatchState = require(Client.features.match.MatchState)

local SENDER_COLOR_HEX = "#FF3A54"
local GIFT_COLOR_HEX = "#FFC850"
local SUBTITLE_FORMAT = `<font color="{SENDER_COLOR_HEX}">@%s</font> just gifted you <font color="{GIFT_COLOR_HEX}">%s</font>!`

local SHOW_TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLAIM_TIMEOUT = 5
local CLAIM_CLICK_GUARD = 0.4

local GiftingFeature = {}

local function escapeRichText(text: string): string
	local escaped = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
	return escaped
end

function GiftingFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui

	local alertFrame = uiGui:WaitForChild("GiftAlert") :: GuiObject
	local content = alertFrame:WaitForChild("Container"):WaitForChild("Content") :: Frame

	local claimBtn = content:WaitForChild("ClaimBtn") :: GuiButton
	local subtitleLabel = content:WaitForChild("Title"):WaitForChild("Text"):WaitForChild("Subtitle") :: TextLabel

	subtitleLabel.RichText = true

	alertFrame.Visible = false

	local menuGui = menuController:getGui() :: ScreenGui
	local dataReady = false
	local presenting = false
	local currentGiftId: string? = nil
	local claiming = false
	local claimingGiftId: string? = nil
	local claimToken = 0
	local lastShownAt = 0
	local claimedIds: { [string]: boolean } = {}
	local loadingDone = false

	local showTween: Tween? = nil

	local function getAlertScale(): UIScale
		local existing = alertFrame:FindFirstChild("AlertScale")
		if existing and existing:IsA("UIScale") then
			return existing
		end
		local scale = Instance.new("UIScale")
		scale.Name = "AlertScale"
		scale.Parent = alertFrame
		return scale
	end

	local function stopAnimations()
		if showTween then
			showTween:Cancel()
			showTween = nil
		end
	end
	janitor:Add(stopAnimations, true)

	local function show(giftId: string, gift: any)
		if currentGiftId == giftId and alertFrame.Visible then
			return
		end
		currentGiftId = giftId

		local cashAmount = tonumber(gift.CashAmount) or 0
		if cashAmount <= 0 then
			local product = StoreProducts.Cash.ByProductId[tonumber(gift.ProductId) or 0]
			if product then
				cashAmount = product.CashAmount
			end
		end

		subtitleLabel.Text = string.format(
			SUBTITLE_FORMAT,
			escapeRichText(tostring(gift.SenderName or "???")),
			UIUtils.formatCashAmount(cashAmount)
		)

		stopAnimations()

		local scale = getAlertScale()
		scale.Scale = 0
		alertFrame.Visible = true
		lastShownAt = os.clock()
		showTween = TweenService:Create(scale, SHOW_TWEEN_INFO, { Scale = 1 })
		showTween:Play()
	end

	local function hide()
		if not alertFrame.Visible then
			return
		end
		stopAnimations()
		alertFrame.Visible = false
		currentGiftId = nil
	end

	local function present(giftId: string, gift: any)
		show(giftId, gift)
		if not presenting then
			presenting = true
			menuController:hide()
		end
	end

	-- Solo restaura el menú en lobby limpio: si una partida o un panel lo tomó, ese
	-- dueño se lo queda.
	local function releaseMenu()
		if presenting then
			presenting = false
			if not MatchState.shouldKeepMenuHidden() and not menuController:hasOpenPanel() then
				menuController:show()
			end
		end
	end

	local function retract()
		hide()
		releaseMenu()
	end

	local function evaluate()
		if not dataReady then
			return
		end

		-- Fuera de lobby se retrae SIEMPRE, incluso con un claim en vuelo (su
		-- respuesta se procesa igual), o el alert queda encima al entrar en partida.
		local blocked = (not loadingDone)
			or MatchState.shouldKeepMenuHidden()
			or menuController:hasOpenPanel()

		if blocked then
			retract()
			return
		end

		if claiming then
			return
		end

		local oldestId: string? = nil
		local oldestGift: any = nil
		local pending = Fusion.peek(DataController.PendingGifts)
		if type(pending) == "table" then
			for giftId, gift in pending do
				if claimedIds[giftId] then
					continue
				end
				local sentAt = tonumber(gift.SentAt) or 0
				local oldestSentAt = if oldestGift then (tonumber(oldestGift.SentAt) or 0) else math.huge
				-- Desempate por giftId: SentAt va en segundos y la iteración del mapa no es
				-- determinista; sin orden estable dos regalos del mismo segundo se alternan.
				if oldestId == nil
					or sentAt < oldestSentAt
					or (sentAt == oldestSentAt and giftId < (oldestId :: string))
				then
					oldestId = giftId
					oldestGift = gift
				end
			end
		end

		if not oldestId then
			retract()
			return
		end

		-- Antes de tomar el menú se exige que esté REALMENTE visible (evita microhuecos
		-- entre transiciones). Una vez presentando no se re-chequea: lo ocultamos nosotros.
		if not presenting and (menuController:isHidden() or not menuGui.Enabled) then
			return
		end

		present(oldestId, oldestGift)
	end

	InteractiveScaleTween.bindButton(claimBtn, janitor, {
		hoverScale = UITheme.ButtonHoverScale,
		clickScale = UITheme.ButtonClickScale,
	})

	janitor:Add(claimBtn.Activated:Connect(function()
		local giftId = currentGiftId
		if not giftId or claiming then
			return
		end
		-- Anti doble-tap: el server descarta SIN responder los claims demasiado
		-- seguidos, y la UI quedaría bloqueada hasta CLAIM_TIMEOUT.
		if os.clock() - lastShownAt < CLAIM_CLICK_GUARD then
			return
		end
		claiming = true
		claimingGiftId = giftId
		claimToken += 1
		local token = claimToken
		task.delay(CLAIM_TIMEOUT, function()
			-- Respuesta perdida: no se marca como reclamado; si el server concedió,
			-- la réplica lo borrará.
			if claiming and claimToken == token then
				claiming = false
				claimingGiftId = nil
				Notify.warning("No response from the server. Try again.")
				evaluate()
			end
		end)
		Network.Gifting.ClaimGift.Send({ giftId = giftId })
	end), "Disconnect")

	janitor:Add(Network.Gifting.ClaimResponse.Listen(function(data: any)
		-- Registrar SIEMPRE los éxitos, aunque sean de un intento viejo: el regalo no
		-- debe re-mostrarse mientras la réplica de PendingGifts se pone al día.
		if data.success then
			claimedIds[data.giftId] = true
		end
		-- Una respuesta tardía de otro gift no debe liberar el claim en vuelo.
		if claiming and data.giftId == claimingGiftId then
			claiming = false
			claimingGiftId = nil
			if data.success then
				Notify.success(`+{UIUtils.formatCashAmount(data.cashAmount)} Cash`)
			else
				local message = if data.message ~= "" then data.message else "That gift couldn't be claimed."
				Notify.warning(message)
			end
		end
		-- No ocultamos aquí: evaluate() encadena el siguiente sin parpadeo del menú.
		evaluate()
	end), true)

	-- ReplicatedFirst destruye PlayerGui.LoadingScreen al terminar. El orden de
	-- replicación en PlayerGui no está garantizado: si aún no existe se asume
	-- terminada, pero ChildAdded re-arma el gate si aparece después.
	local function watchLoadingScreen(gui: Instance)
		loadingDone = false
		janitor:Add(gui.Destroying:Connect(function()
			loadingDone = true
			evaluate()
		end), "Disconnect")
	end

	local loadingScreen = playerGui:FindFirstChild("LoadingScreen")
	if loadingScreen then
		watchLoadingScreen(loadingScreen)
	else
		loadingDone = true
		janitor:Add(playerGui.ChildAdded:Connect(function(child: Instance)
			if child.Name == "LoadingScreen" then
				watchLoadingScreen(child)
				evaluate()
			end
		end), "Disconnect")
	end

	janitor:Add(menuController:onStateChanged(evaluate), true)

	-- La fase "Joining" (MatchMenu:enforceHidden) apaga Menu.Enabled sin pasar
	-- por MenuController.
	janitor:Add(menuGui:GetPropertyChangedSignal("Enabled"):Connect(evaluate), "Disconnect")

	local fusionScope = Fusion.scoped(Fusion)
	janitor:Add(function()
		Fusion.doCleanup(fusionScope)
	end, true)

	DataController:WhenReady():andThen(function()
		dataReady = true
		local observer = fusionScope:Observer(DataController.PendingGifts)
		-- onBind dispara también inmediatamente.
		janitor:Add(observer:onBind(evaluate), true)
	end)

	-- Teardown (hot reload): no dejar al jugador sin menú.
	janitor:Add(releaseMenu, true)

	return janitor
end

return GiftingFeature
