--!strict
-- Gestiona la interfaz del hotbar (PC y Touchscreen) del sistema de armas.
-- Estructura esperada por slot (Item1 / Item2), ambos idénticos:
--   Item        (ImageButton) -> fondo del slot: imagen, ancho y degradado según selección
--   Item.Image                -> imagen del arma
--   Item.Value                -> munición "actual/cargador" en RichText

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local AssetIds = require(Shared.constants.AssetIds)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local WeaponsConfig = require(Shared.constants.WeaponsConfig)

local WeaponsSystemFolder = script.Parent.Parent.Parent
local WeaponData = WeaponsSystemFolder:WaitForChild("WeaponData")
local Libraries = WeaponsSystemFolder:WaitForChild("Libraries")

-- Selección de slot: el seleccionado se ensancha (el Back da el "pop") y cambia
-- de fondo.
local HOTBAR_SIZE_SELECTED = UDim2.new(0.104, 0, 1, 0)
local HOTBAR_SIZE_IDLE = UDim2.new(0.073, 0, 1, 0)
local HOTBAR_SIZE_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HOTBAR_TRANSPARENCY_SELECTED = 0
local HOTBAR_TRANSPARENCY_IDLE = 0.52
-- Degradados del fondo: si el root del Hotbar trae UIGradients "Selected"/"NotSelected"
-- en Studio se clonan esos; si no, se construyen con estos valores.
local HOTBAR_GRADIENT_SELECTED_NAME = "Selected"
local HOTBAR_GRADIENT_IDLE_NAME = "NotSelected"

-- Un único layout para todos los dispositivos, colocado por el UIListLayout del
-- root: en PC pegado a la derecha y en táctil centrado (entre los dos pulgares,
-- sin chocar con el joystick ni el botón de disparo).
local HOTBAR_ALIGNMENT_PC = Enum.HorizontalAlignment.Right
local HOTBAR_ALIGNMENT_TOUCH = Enum.HorizontalAlignment.Center

local AMMO_LOW_RATIO = 0.45 -- naranja por debajo de este % del cargador
local AMMO_CRITICAL_RATIO = 0.2 -- rojo por debajo de este %
local AMMO_COLOR_NORMAL = Color3.fromRGB(255, 255, 255)
local AMMO_COLOR_LOW = Color3.fromRGB(255, 150, 0)
local AMMO_COLOR_CRITICAL = Color3.fromRGB(230, 55, 55)
local AMMO_COLOR_RELOAD = Color3.fromRGB(255, 255, 255)
local RELOAD_DOT_INTERVAL = 0.25 -- segundos por punto del "..." de recarga
-- "actual/cargador": el actual lleva el color de munición baja y el total va en
-- gris pequeño. El color va DENTRO del tag porque con RichText el TextColor3 del
-- label no afecta a los spans que traen su propio <font color>.
local AMMO_RICH_FORMAT = '<font color="#%s">%d</font><font color="#d6d6d6" size="10">/%d</font>'

local Hotbar = {}
Hotbar.__index = Hotbar

local function isHotbarImageNode(node)
	return node and (node:IsA("ImageLabel") or node:IsA("ImageButton"))
end

local function isHotbarTextNode(node)
	return node and (node:IsA("TextLabel") or node:IsA("TextButton"))
end

local function getSlotGradientTemplate(hotbarRoot: Instance, name: string): UIGradient
	local template = hotbarRoot:FindFirstChild(name)
	if template and template:IsA("UIGradient") then
		-- En el root también degradaría el propio frame del Hotbar.
		template.Enabled = false
		return template
	end

	local gradient = Instance.new("UIGradient")
	gradient.Name = name
	if name == HOTBAR_GRADIENT_SELECTED_NAME then
		gradient.Rotation = 270
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
	else
		gradient.Rotation = 90
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.813131, 1),
			NumberSequenceKeypoint.new(1, 1),
		})
	end
	return gradient
end

local function cloneGradient(template: UIGradient): UIGradient
	local gradient = template:Clone()
	gradient.Enabled = true
	return gradient
end

local function toHexColor(color: Color3): string
	return string.format(
		"%02X%02X%02X",
		math.round(color.R * 255),
		math.round(color.G * 255),
		math.round(color.B * 255)
	)
end

-- Categoría de un Tool: primero la identidad estampada por LoadoutService
-- (atributo WeaponCategory), que desambigua ids repetidos en los dos catálogos
-- ("Default"); si no la lleva, por nombre.
local function getToolCategory(tool: Tool): string?
	local category = WeaponsConfig.ResolveToolIdentity(tool)
	if category then
		return category
	end
	if ItemsConfig.Main[tool.Name] ~= nil then
		return "Main"
	end
	if ItemsConfig.Special[tool.Name] ~= nil then
		return "Special"
	end
	return nil
end

local function getToolAmmoCapacity(tool: Instance?): number
	if not tool then
		return 0
	end
	return tonumber(WeaponsConfig.GetValueForTool(tool, "AmmoCapacity"))
		or tonumber(WeaponsConfig.Schema.GetDefault("BulletWeapon", "AmmoCapacity"))
		or 0
end

function Hotbar.new(weaponsGui: any)
	local self = setmetatable({}, Hotbar)
	self.weaponsGui = weaponsGui

	self.layouts = {}
	self.mainTool = nil
	self.specialTool = nil
	self.selectedSlot = 1

	self._conns = {}
	self._lifetimeConns = {}
	self._charConns = {}
	self._ammoConns = {}
	self._lastMainTool = nil
	self._lastSpecialTool = nil

	return self
end

function Hotbar:_disconnectConns()
	for _, conn in ipairs(self._conns) do
		conn:Disconnect()
	end
	table.clear(self._conns)
end

function Hotbar:_captureSlot(hotbarRoot, itemName)
	if not hotbarRoot then return nil end

	local itemFrame = hotbarRoot:FindFirstChild(itemName)
	if not itemFrame or not itemFrame:IsA("GuiObject") then
		return nil
	end

	local imageNode = itemFrame:FindFirstChild("Image")
	local ammoValueNode = itemFrame:FindFirstChild("Value")

	-- Solo un degradado a la vez sobre el fondo: los que vengan de Studio se sustituyen.
	for _, child in itemFrame:GetChildren() do
		if child:IsA("UIGradient") then
			child:Destroy()
		end
	end

	return {
		frame = itemFrame,
		gradientSelected = cloneGradient(getSlotGradientTemplate(hotbarRoot, HOTBAR_GRADIENT_SELECTED_NAME)),
		gradientIdle = cloneGradient(getSlotGradientTemplate(hotbarRoot, HOTBAR_GRADIENT_IDLE_NAME)),
		image = if isHotbarImageNode(imageNode) then imageNode else nil,
		ammoValueNode = ammoValueNode,
		ammoValueLabel = if isHotbarTextNode(ammoValueNode) then ammoValueNode else nil,
		_selected = nil,
		_sizeTween = nil,
	}
end

function Hotbar:_getWeaponImageByTool(tool, category)
	if not tool then return "" end
	local config = ItemsConfig[category] and ItemsConfig[category][tool.Name]
	return if config and type(config.Image) == "string" then config.Image else ""
end

function Hotbar:_setSlotImage(slotNode, image)
	local imageNode = slotNode and slotNode.image
	if isHotbarImageNode(imageNode) then
		imageNode.Image = image
		imageNode.ImageTransparency = if image == "" then 1 else 0
	end
end

function Hotbar:_setSlotSelected(slotNode, isSelected)
	if not slotNode then return end
	-- Solo animamos cuando el estado de selección cambia, para no reiniciar los
	-- tweens en cada refresh() (que se llama muy a menudo).
	if slotNode._selected == isSelected then
		return
	end
	slotNode._selected = isSelected

	local frame = slotNode.frame
	if isHotbarImageNode(frame) then
		frame.Image = if isSelected then AssetIds.Images.HotbarSlotSelected else AssetIds.Images.HotbarSlotIdle
		frame.ScaleType = if isSelected then Enum.ScaleType.Stretch else Enum.ScaleType.Fit
		frame.ImageTransparency = if isSelected then HOTBAR_TRANSPARENCY_SELECTED else HOTBAR_TRANSPARENCY_IDLE
	end
	slotNode.gradientSelected.Parent = if isSelected then frame else nil
	slotNode.gradientIdle.Parent = if isSelected then nil else frame

	if slotNode._sizeTween then
		slotNode._sizeTween:Cancel()
	end
	local tween = TweenService:Create(frame, HOTBAR_SIZE_TWEEN_INFO, {
		Size = if isSelected then HOTBAR_SIZE_SELECTED else HOTBAR_SIZE_IDLE,
	})
	slotNode._sizeTween = tween
	tween:Play()
end

function Hotbar:_findMainSpecialTools()
	local mainTool = nil
	local specialTool = nil
	local localPlayer = Players.LocalPlayer
	if not localPlayer then return nil, nil end

	local character = localPlayer.Character
	local backpack = localPlayer:FindFirstChildOfClass("Backpack")
	local containers = { character, backpack }

	for _, container in ipairs(containers) do
		if not container then continue end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") then
				local category = getToolCategory(child)
				if category == "Main" then
					if not mainTool or (character and child:IsDescendantOf(character)) then
						mainTool = child
					end
				elseif category == "Special" then
					if not specialTool or (character and child:IsDescendantOf(character)) then
						specialTool = child
					end
				end
			end
		end
	end
	return mainTool, specialTool
end

function Hotbar:_getSelectedSlotByCurrentWeapon(mainTool, specialTool)
	local currentWeapon = self.weaponsGui.weaponsSystem.currentWeapon
	local currentTool = if currentWeapon then currentWeapon.instance else nil

	if currentTool and currentTool == specialTool then
		return 2
	end
	if currentTool and currentTool == mainTool then
		return 1
	end
	return self.selectedSlot
end

function Hotbar:_applySelectedVisual(selectedSlot)
	self.selectedSlot = selectedSlot
	for _, layout in ipairs(self.layouts) do
		self:_setSlotSelected(layout.item1, selectedSlot == 1)
		self:_setSlotSelected(layout.item2, selectedSlot == 2)
	end
end

function Hotbar:_isToolReloading(tool): boolean
	if not tool then
		return false
	end
	if not self.weaponsGui._isReloadProgressAnimating then
		return false
	end
	local currentWeapon = self.weaponsGui.weaponsSystem.currentWeapon
	return currentWeapon ~= nil and currentWeapon.instance == tool
end

function Hotbar:_renderSlotAmmo(slotNode, tool)
	if not slotNode then return end
	local ammoValueLabel = slotNode.ammoValueLabel
	local ammoValueNode = slotNode.ammoValueNode

	if self:_isToolReloading(tool) then
		if ammoValueLabel then
			local dots = 1 + math.floor(os.clock() / RELOAD_DOT_INTERVAL) % 3
			ammoValueLabel.RichText = false
			ammoValueLabel.TextColor3 = AMMO_COLOR_RELOAD
			ammoValueLabel.Text = string.rep(".", dots)
		end
		return
	end

	local currentAmmo = if tool then tool:GetAttribute("CurrentAmmo") else nil
	local hasAmmo = type(currentAmmo) == "number"
	local roundedAmmo = if hasAmmo then math.max(0, math.floor(currentAmmo + 0.5)) else 0

	if ammoValueLabel then
		if not hasAmmo then
			ammoValueLabel.RichText = false
			ammoValueLabel.Text = ""
			return
		end
		local capacity = math.max(0, math.floor(getToolAmmoCapacity(tool)))
		local color = AMMO_COLOR_NORMAL
		if capacity > 0 then
			local ratio = roundedAmmo / capacity
			if ratio <= AMMO_CRITICAL_RATIO then
				color = AMMO_COLOR_CRITICAL
			elseif ratio <= AMMO_LOW_RATIO then
				color = AMMO_COLOR_LOW
			end
		end
		ammoValueLabel.RichText = true
		ammoValueLabel.Text = string.format(AMMO_RICH_FORMAT, toHexColor(color), roundedAmmo, capacity)
		return
	end
	if ammoValueNode and ammoValueNode:IsA("StringValue") then
		ammoValueNode.Value = if hasAmmo then tostring(roundedAmmo) else ""
	elseif ammoValueNode and (ammoValueNode:IsA("IntValue") or ammoValueNode:IsA("NumberValue")) then
		ammoValueNode.Value = roundedAmmo
	end
end

function Hotbar:_updateAmmoDisplay(mainTool, specialTool)
	for _, layout in ipairs(self.layouts) do
		self:_renderSlotAmmo(layout.item1, mainTool)
		self:_renderSlotAmmo(layout.item2, specialTool)
	end
end

-- Llamado por frame desde WeaponsGui: anima los "..." en el slot del arma que se
-- recarga; al terminar la recarga marca dirty para restaurar el número y su color.
function Hotbar:tickReloadDots()
	if not self.weaponsGui._isReloadProgressAnimating then
		if self._wasReloading then
			self._wasReloading = false
			self.weaponsGui._hotbarDirty = true
		end
		return
	end
	self._wasReloading = true

	local currentWeapon = self.weaponsGui.weaponsSystem.currentWeapon
	local tool = if currentWeapon then currentWeapon.instance else nil
	if not tool then return end

	local isSpecial = tool == self.specialTool
	for _, layout in ipairs(self.layouts) do
		self:_renderSlotAmmo(if isSpecial then layout.item2 else layout.item1, tool)
	end
end

function Hotbar:_disconnectAmmoConns()
	for _, c in self._ammoConns do
		c:Disconnect()
	end
	table.clear(self._ammoConns)
end

function Hotbar:_connectAmmoConns(mainTool, specialTool)
	if mainTool == self._lastMainTool and specialTool == self._lastSpecialTool then
		return
	end
	self._lastMainTool = mainTool
	self._lastSpecialTool = specialTool
	self:_disconnectAmmoConns()
	if mainTool then
		table.insert(
			self._ammoConns,
			mainTool:GetAttributeChangedSignal("CurrentAmmo"):Connect(function()
				self.weaponsGui._hotbarDirty = true
			end)
		)
	end
	if specialTool and specialTool ~= mainTool then
		table.insert(
			self._ammoConns,
			specialTool:GetAttributeChangedSignal("CurrentAmmo"):Connect(function()
				self.weaponsGui._hotbarDirty = true
			end)
		)
	end
end

function Hotbar:_connectCharacterEvents(character: Instance?)
	for _, c in self._charConns do
		c:Disconnect()
	end
	table.clear(self._charConns)
	if not character then return end
	table.insert(self._charConns, character.ChildAdded:Connect(function() self.weaponsGui._hotbarDirty = true end))
	table.insert(self._charConns, character.ChildRemoved:Connect(function() self.weaponsGui._hotbarDirty = true end))
end

function Hotbar:setupEvents()
	if self._eventsSetup then return end
	self._eventsSetup = true

	local localPlayer = Players.LocalPlayer
	if not localPlayer then return end

	table.insert(
		self._lifetimeConns,
		localPlayer.CharacterAdded:Connect(function(char)
			self.weaponsGui._hotbarDirty = true
			self:_connectCharacterEvents(char)
		end)
	)
	table.insert(
		self._lifetimeConns,
		localPlayer.CharacterRemoving:Connect(function()
			self.weaponsGui._hotbarDirty = true
		end)
	)
	self:_connectCharacterEvents(localPlayer.Character)

	local backpack = localPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		table.insert(self._lifetimeConns, backpack.ChildAdded:Connect(function() self.weaponsGui._hotbarDirty = true end))
		table.insert(self._lifetimeConns, backpack.ChildRemoved:Connect(function() self.weaponsGui._hotbarDirty = true end))
	else
		table.insert(
			self._lifetimeConns,
			localPlayer.ChildAdded:Connect(function(child)
				if child:IsA("Backpack") then
					table.insert(self._lifetimeConns, child.ChildAdded:Connect(function() self.weaponsGui._hotbarDirty = true end))
					table.insert(self._lifetimeConns, child.ChildRemoved:Connect(function() self.weaponsGui._hotbarDirty = true end))
					self.weaponsGui._hotbarDirty = true
				end
			end)
		)
	end
end

function Hotbar:refresh()
	local mainTool, specialTool = self:_findMainSpecialTools()
	self.mainTool = mainTool
	self.specialTool = specialTool
	self.weaponsGui.hotbarMainTool = mainTool
	self.weaponsGui.hotbarSpecialTool = specialTool

	local mainImage = self:_getWeaponImageByTool(mainTool, "Main")
	local specialImage = self:_getWeaponImageByTool(specialTool, "Special")

	for _, layout in ipairs(self.layouts) do
		self:_setSlotImage(layout.item1, mainImage)
		self:_setSlotImage(layout.item2, specialImage)
	end

	self:_updateAmmoDisplay(mainTool, specialTool)

	local selectedSlot = self:_getSelectedSlotByCurrentWeapon(mainTool, specialTool)
	if selectedSlot ~= 1 and selectedSlot ~= 2 then
		selectedSlot = 1
	end
	self:_applySelectedVisual(selectedSlot)
	self:_connectAmmoConns(mainTool, specialTool)
	self.weaponsGui._hotbarDirty = false
end

function Hotbar:_equipTool(tool)
	if not tool then return end
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:EquipTool(tool)
	end
end

function Hotbar:equipSlot(slot)
	-- 1 => Main, 2 => Special, fijo. Si el slot no tiene arma, no hacemos nada
	-- (no movemos el resaltado a un slot vacío).
	local tool = if slot == 1 then self.mainTool elseif slot == 2 then self.specialTool else nil
	if not tool then return end

	local currentWeapon = self.weaponsGui.weaponsSystem.currentWeapon
	local currentTool = if currentWeapon then currentWeapon.instance else nil

	-- Ya equipada: no re-equipar (evita el toggle/desequipado de Roblox), solo
	-- garantizar el resaltado.
	if currentTool == tool then
		self:_applySelectedVisual(slot)
		return
	end

	if currentWeapon and currentWeapon.reloading and currentWeapon.cancelReload then
		currentWeapon:cancelReload()
	end

	self:_equipTool(tool)
	self:_applySelectedVisual(slot)
end

function Hotbar:_registerButton(button, slot)
	if not button or not button:IsA("GuiButton") then return end
	table.insert(self._conns, button.Activated:Connect(function()
		self:equipSlot(slot)
	end))
end

-- Alinea el UIListLayout del hotbar según el dispositivo. Se reaplica en cada
-- cambio de pantalla porque TouchEnabled puede pasar a true en caliente (una
-- tablet a la que se le conecta un teclado, o al revés).
function Hotbar:applyDeviceAlignment()
	local alignment = if UserInputService.TouchEnabled then HOTBAR_ALIGNMENT_TOUCH else HOTBAR_ALIGNMENT_PC
	for _, layout in ipairs(self.layouts) do
		local listLayout = layout.root and layout.root:FindFirstChildWhichIsA("UIListLayout")
		if listLayout then
			listLayout.HorizontalAlignment = alignment
		end
	end
end

function Hotbar:setupLayout(hotbarRoot)
	if not hotbarRoot then return end
	local layout = {
		root = hotbarRoot,
		item1 = self:_captureSlot(hotbarRoot, "Item1"),
		item2 = self:_captureSlot(hotbarRoot, "Item2"),
	}
	table.insert(self.layouts, layout)
	self:applyDeviceAlignment()

	local item1Button = (layout.item1 and layout.item1.frame and layout.item1.frame:IsA("GuiButton") and layout.item1.frame)
		or (layout.item1 and layout.item1.image)
	local item2Button = (layout.item2 and layout.item2.frame and layout.item2.frame:IsA("GuiButton") and layout.item2.frame)
		or (layout.item2 and layout.item2.image)
	self:_registerButton(item1Button, 1)
	self:_registerButton(item2Button, 2)
end

function Hotbar:Destroy()
	self:_disconnectConns()
	self:_disconnectAmmoConns()
	for _, c in self._lifetimeConns do c:Disconnect() end
	for _, c in self._charConns do c:Disconnect() end
	table.clear(self._lifetimeConns)
	table.clear(self._charConns)
	for _, layout in ipairs(self.layouts) do
		for _, slotNode in { layout.item1, layout.item2 } do
			if not slotNode then continue end
			if slotNode._sizeTween then
				slotNode._sizeTween:Cancel()
				slotNode._sizeTween = nil
			end
		end
	end
end

return Hotbar
