--!strict
--[[
	Sin blur: salta a su propia cámara (Workspace.Cameras.<CAMERA_TARGET>) tras un
	fundido a negro y aplica el LightingPreset de esa parte (su DoF desenfoca el fondo).

	GUI (PlayerGui.UserInterface.BattlePass). Cada nodo se busca primero bajo el frame
	intermedio OPCIONAL `Content` (o `Main`) y luego en la raíz.
	Todo con FindFirstChild: un nodo que falte no rompe el feature.
	  CloseBtn (root; fallback Header.CloseBtn)
	  Nav.Back (.Indicator) / Nav.Next (.Indicator) / Nav.Info ("1/8")
	  SkipLevel / SkipLevel5 (Robux, .Price opcional)
	  Banner.PurchaseBtn (Gems, premium; .Value = precio en Gems de la season)
	  ImagePreview (preview grande; un wrap usa su `Image` de ItemsConfig)
	  PathContainer."1".."8" (GuiButton; también `Path`, o PathContainer.Path.1..8):
	    Container.Level                    ("Lvl. 5"; oculto en el slot del nivel actual)
	    Container.Type / Container.Claim   (OPCIONALES)
	    Container.LevelReward
	      .ViewportReward (wraps) / .ImageReward (resto) / .Value (tipo de recompensa)
	      .Glow / .Check                   (OPCIONALES)
	      .Footer.Status.Locked
	  CurrentLevel (OPCIONAL; .Fill, .Level): plantilla clonada UNA vez y reparentada
	    al Container del nivel actual en cada render, para no crear CanvasGroups por tick.
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
local LockerCameraController = require(Client.core.camera.LockerCameraController)
local CameraLock = require(Client.core.camera.CameraLock)
local ScenePresetController = require(Client.core.lighting.ScenePresetController)
local ScreenFade = require(Client.core.ui.ScreenFade)
local DataController = require(Client.core.data.DataController)
local UIUtils = require(Client.core.ui.UIUtils)
local Network = require(Shared.networking.Network)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)
local ScenePreview = require(script.ScenePreview)
local BattlePassRewards = require(script.BattlePassRewards)
local BattlePassSlots = require(script.BattlePassSlots)
local BattlePassPurchases = require(script.BattlePassPurchases)

local SLOTS_PER_PAGE = BattlePassSlots.SLOTS_PER_PAGE

-- Nombre de la parte en Workspace.Cameras; el look sale de su atributo LightingPreset.
local CAMERA_TARGET = "battlepass"
local CAMERA_LOCK_OWNER = "battlepass"



local PREVIEW_LIFT_PIXELS = 24
local PREVIEW_TWEEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local BattlePassFeature = {}

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
	-- Sin WaitForChild a propósito: el frame intermedio es opcional y esperarlo colgaría.
	local mainNode = frame:FindFirstChild("Content") or frame:FindFirstChild("Main")
	local main: Instance = if mainNode then mainNode else frame

	local function findPanelChild(name: string): Instance?
		local found = main:FindFirstChild(name)
		if found then
			return found
		end
		return if main ~= frame then frame:FindFirstChild(name) else nil
	end

	local container = menuGui:FindFirstChild("Container")
	local btnInstance = container and container:FindFirstChild("FamePass")
	local menuBtn: GuiButton? = if btnInstance and btnInstance:IsA("GuiButton")
		then btnInstance
		else (btnInstance and btnInstance:FindFirstChildWhichIsA("GuiButton"))

	local navIconValueNode = btnInstance and btnInstance:FindFirstChild("Icon")
	local navValueNode = navIconValueNode and navIconValueNode:FindFirstChild("Value")
	local navIconValue: TextLabel? = if navValueNode and navValueNode:IsA("TextLabel") then navValueNode else nil
	local navIndicatorNode = btnInstance and btnInstance:FindFirstChild("Indicator")
	local navIndicator: GuiObject? = if navIndicatorNode and navIndicatorNode:IsA("GuiObject") then navIndicatorNode else nil

	local header = findPanelChild("Header")
	local closeNode = frame:FindFirstChild("CloseBtn") or (header and header:FindFirstChild("CloseBtn"))
	local closeBtn: GuiButton? = if closeNode and closeNode:IsA("GuiButton") then closeNode else nil

	local navFolder = findPanelChild("Nav")
	local backBtn = navFolder and navFolder:FindFirstChild("Back")
	local nextBtn = navFolder and navFolder:FindFirstChild("Next")
	local pageLabelNode = navFolder and navFolder:FindFirstChild("Info")
	local pageLabel: TextLabel? = if pageLabelNode and pageLabelNode:IsA("TextLabel") then pageLabelNode else nil
	local backIndicator = if backBtn then backBtn:FindFirstChild("Indicator") else nil
	local nextIndicator = if nextBtn then nextBtn:FindFirstChild("Indicator") else nil

	local banner = findPanelChild("Banner")
	local purchaseBtn = banner and banner:FindFirstChild("PurchaseBtn")
	local purchasePriceNode = purchaseBtn and purchaseBtn:FindFirstChild("Value")
	local purchasePrice: TextLabel? = if purchasePriceNode and purchasePriceNode:IsA("TextLabel")
		then purchasePriceNode
		else nil

	local pathFolder = findPanelChild("PathContainer") or findPanelChild("Path")
	if pathFolder and not pathFolder:FindFirstChild("1") then
		pathFolder = pathFolder:FindFirstChild("Path") or pathFolder
	end
	-- Asignado más abajo, cuando existen el preview y la lógica de reclamar.
	local onSlotClick: (index: number) -> ()
	local slots = BattlePassSlots.new({
		frame = frame,
		pathFolder = pathFolder,
		currentLevelTemplate = findPanelChild("CurrentLevel"),
		janitor = janitor,
		canHover = UserInputService.MouseEnabled and not UserInputService.TouchEnabled,
		onSlotClick = function(index)
			onSlotClick(index)
		end,
	})

	local imagePreviewNode = findPanelChild("ImagePreview")
	local imagePreview: (ImageLabel | ImageButton)? = if imagePreviewNode
			and (imagePreviewNode:IsA("ImageLabel") or imagePreviewNode:IsA("ImageButton"))
		then imagePreviewNode :: any
		else nil

	local season = BattlePassConfig.GetActiveSeason()
	local maxTier = BattlePassConfig.GetMaxTier(season)
	local pageCount = math.max(1, math.ceil(maxTier / SLOTS_PER_PAGE))
	local currentPage = 0
	local isOpen = false
	-- Lo fija `onOpen` y lo lee `onClose` para deshacer exactamente lo que se hizo.
	local cameraActive = false

	-- La cámara se resuelve en cada apertura (en el bootstrap Workspace.Cameras puede
	-- no haber replicado) y con FindFirstChild antes de LockerCameraController.new,
	-- que hace WaitForChild sin timeout y colgaría si la parte no existe.
	local cameraController: any = nil
	local fade: any = nil
	local warnedMissingCamera = false

	local function findCameraPart(): BasePart?
		local camerasFolder = Workspace:FindFirstChild("Cameras")
		local part = if camerasFolder then camerasFolder:FindFirstChild(CAMERA_TARGET) else nil
		return if part and part:IsA("BasePart") then part :: BasePart else nil
	end

	-- nil → el panel se abre sin cámara.
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
		-- Singleton compartido vía playerGui: no va al janitor.
		fade = ScreenFade.new(playerGui)
		return cameraController
	end

	-- Atributo LightingPreset de la parte de cámara; si no lo lleva, el de Workspace.Locker.
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

	-- Peanas de Workspace.BattlePass; si faltan las anclas no hace nada.
	local scenePreview = ScenePreview.new()
	janitor:Add(scenePreview, "Destroy")

	-- El perfil puede traer el SeasonId de la season anterior hasta que el servidor
	-- lo resetee: se relee al abrir y cuando `state.SeasonId` no coincide.
	local function refreshSeason()
		season = BattlePassConfig.GetActiveSeason()
		maxTier = BattlePassConfig.GetMaxTier(season)
		pageCount = math.max(1, math.ceil(maxTier / SLOTS_PER_PAGE))
		currentPage = 0
		slots:resetSelection()
	end

	local imagePreviewRest: UDim2? = nil

	-- El observer de Loadout la reenvía para recolocar un wrap global sobre el arma nueva.
	local lastSceneReward: BattlePassConfig.Reward? = nil

	local function pushScenePreview(reward: BattlePassConfig.Reward)
		lastSceneReward = reward
		local weaponCategory, weaponId, weaponName = BattlePassRewards.wrapPreviewWeapon(reward)
		scenePreview:setReward(reward, {
			weaponCategory = weaponCategory,
			weaponId = weaponId,
			weaponName = weaponName,
			wrapId = if BattlePassRewards.isWrap(reward) then reward.ItemId else nil,
		})
	end

	local function showRewardPreview(reward: BattlePassConfig.Reward)
		pushScenePreview(reward)
		if not imagePreview then return end
		local image = BattlePassRewards.image(reward)
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

	local function showPageDefaultPreview()
		local level = currentPage * SLOTS_PER_PAGE + SLOTS_PER_PAGE
		local tierDef = BattlePassConfig.GetTier(season, level)
		if tierDef then
			showRewardPreview(tierDef.Reward)
		end
	end

	local function applyDefaultSelection()
		local state = Fusion.peek(DataController.BattlePass)
		local currentTier = if type(state) == "table" then math.floor(state.CurrentTier or 1) else 1
		if currentTier >= 1 and currentTier <= maxTier then
			local pageStart = currentPage * SLOTS_PER_PAGE
			if currentTier > pageStart and currentTier <= pageStart + SLOTS_PER_PAGE then
				local tierDef = BattlePassConfig.GetTier(season, currentTier)
				if tierDef and slots:select(currentTier - pageStart) then
					showRewardPreview(tierDef.Reward)
					return
				end
			end
		end
		showPageDefaultPreview()
	end

	local function isClaimable(level: number, state: any): boolean
		local tierDef = BattlePassConfig.GetTier(season, level)
		if not tierDef then return false end
		local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
		if level >= currentTier then return false end
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

	-- Menu.Container.FamePass se actualiza aunque el panel esté cerrado (render no).
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

	local function render()
		if not isOpen then return end
		local state = Fusion.peek(DataController.BattlePass)
		if type(state) ~= "table" then return end

		local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
		local currentXP = math.max(0, math.floor(state.XP or 0))
		local complete = currentTier > maxTier

		local activeTier = BattlePassConfig.GetTier(season, math.min(currentTier, maxTier))
		local needed = if activeTier then activeTier.XPRequired else 100
		local ratio = if complete then 1 else math.clamp(currentXP / math.max(1, needed), 0, 1)

		if pageLabel then
			pageLabel.Text = tostring(currentPage + 1) .. "/" .. tostring(pageCount)
		end
		if purchaseBtn and purchaseBtn:IsA("GuiObject") then
			purchaseBtn.Visible = state.PremiumOwned ~= true
		end
		if purchasePrice then
			purchasePrice.Text = UIUtils.formatCashAmount(season.PremiumGemPrice)
		end

		slots:beginRender()
		local displayTier = math.clamp(currentTier, 1, maxTier)
		local claimedMap = if type(state.Claimed) == "table" then state.Claimed else {}
		for i = 1, SLOTS_PER_PAGE do
			local realLevel = currentPage * SLOTS_PER_PAGE + i
			local tierDef = BattlePassConfig.GetTier(season, realLevel)
			if tierDef then
				slots:paint(i, tierDef, {
					realLevel = realLevel,
					isClaimed = claimedMap[tostring(realLevel)] == true,
					claimable = isClaimable(realLevel, state),
					currentTier = displayTier,
					ratio = ratio,
				})
			else
				slots:hide(i)
			end
		end

		if backIndicator and backIndicator:IsA("GuiObject") then
			backIndicator.Visible = anyClaimableInRange(1, currentPage * SLOTS_PER_PAGE, state)
		end
		if nextIndicator and nextIndicator:IsA("GuiObject") then
			nextIndicator.Visible = anyClaimableInRange((currentPage + 1) * SLOTS_PER_PAGE + 1, maxTier, state)
		end
	end

	onSlotClick = function(index)
		local realLevel = currentPage * SLOTS_PER_PAGE + index
		local tierDef = BattlePassConfig.GetTier(season, realLevel)
		if not tierDef then
			return
		end
		if slots:select(index) then
			showRewardPreview(tierDef.Reward)
		end
		if isClaimable(realLevel, Fusion.peek(DataController.BattlePass)) then
			Network.BattlePass.ClaimTier.Send({ tier = realLevel })
		end
	end

	local function pageForCurrentTier(): number
		local state = Fusion.peek(DataController.BattlePass)
		if type(state) ~= "table" then return 0 end
		local tier = math.clamp(math.floor(state.CurrentTier or 1), 1, maxTier)
		return math.clamp(math.floor((tier - 1) / SLOTS_PER_PAGE), 0, pageCount - 1)
	end

	local panel = PanelController.new(menuController, frame, menuBtn, closeBtn, {
		onOpen = function()
			isOpen = true

			local function presentPanel()
				refreshSeason()
				currentPage = pageForCurrentTier()
				slots:resetSelection()
				render()
				slots:playStagger()
				scenePreview:show()
				applyDefaultSelection()
			end

			-- onClose mira este flag y no el controller: un panel abierto sin cámara se
			-- cierra sin fundido aunque la parte replique mientras está abierto.
			cameraActive = ensureCameraController() ~= nil
			if cameraActive then
				CameraLock.acquire(CAMERA_LOCK_OWNER)
				-- El animator ya hizo Visible=true: se oculta hasta que la pantalla esté negra
				-- para no ver el panel con la cámara vieja detrás.
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
			-- El decorado se retira detrás del negro, no antes.
			if cameraActive then
				-- PanelController ya remostró el menú; se re-oculta en el mismo frame (sin
				-- parpadeo) para que no se vea sobre la cámara del pase durante el fundido.
				menuController:hide()
				fade:cover(function()
					ScenePresetController.applyLobbyOrRestore("[BattlePassFeature]")
					cameraController:restore()
					CameraLock.release(CAMERA_LOCK_OWNER)
					scenePreview:hide()
					-- Mismo guard que PanelController: otro panel pudo abrirse durante el fundido.
					if not menuController:hasOpenPanel() then
						menuController:show()
					end
					fade:reveal()
				end)
			else
				scenePreview:hide()
			end
			slots:clearWraps()
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

	if nextBtn and nextBtn:IsA("GuiButton") then
		janitor:Add((nextBtn :: GuiButton).MouseButton1Click:Connect(function()
			if currentPage < pageCount - 1 then
				currentPage += 1
				slots:resetSelection()
				render()
				slots:playStagger()
				applyDefaultSelection()
			end
		end), "Disconnect")
	end
	if backBtn and backBtn:IsA("GuiButton") then
		janitor:Add((backBtn :: GuiButton).MouseButton1Click:Connect(function()
			if currentPage > 0 then
				currentPage -= 1
				slots:resetSelection()
				render()
				slots:playStagger()
				applyDefaultSelection()
			end
		end), "Disconnect")
	end
	BattlePassPurchases.bind({
		janitor = janitor,
		skipButton = findPanelChild("SkipLevel"),
		skip5Button = findPanelChild("SkipLevel5"),
		purchaseButton = purchaseBtn,
		getSeason = function()
			return season
		end,
		getMaxTier = function()
			return maxTier
		end,
	})

	DataController:WhenReady():andThen(function()
		currentPage = pageForCurrentTier()
		render()
		updateNavButton()
		local scope = Fusion.scoped(Fusion)
		janitor:Add(function()
			Fusion.doCleanup(scope)
		end, true)
		local obs = scope:Observer(DataController.BattlePass :: any)
		janitor:Add(obs:onBind(function()
			local state = Fusion.peek(DataController.BattlePass)
			if type(state) == "table" and type(state.SeasonId) == "string" and state.SeasonId ~= season.Id then
				refreshSeason()
			end
			render()
			updateNavButton()
		end), true)
		-- Los wraps globales van sobre el arma equipada: la previewKey detecta el cambio
		-- pero hace falta repintar para que se relea.
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
