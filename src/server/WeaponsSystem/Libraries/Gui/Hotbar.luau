--!strict
-- Hotbar.luau (Client/Server Library)
-- Gestiona la interfaz del hotbar (PC y Touchscreen) del sistema de armas.
--
-- Estructura esperada por slot (Item1 / Item2), ambos idénticos:
--   Item.Image                    -> imagen del arma
--   Item.Footer.Value             -> munición "actual/cargador" en RichText
--   Item.UIAspectRatioConstraint  -> el slot seleccionado se ensancha
--   Item.UIStroke                 -> blanco si seleccionado, morado oscuro si no

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local ItemsConfig = require(Shared.constants.ItemsConfig)
local WeaponLevelConfig = require(Shared.constants.WeaponLevelConfig)
local WeaponsConfig = require(Shared.constants.WeaponsConfig)

local WeaponsSystemFolder = script.Parent.Parent.Parent
local WeaponData = WeaponsSystemFolder:WaitForChild("WeaponData")
local Libraries = WeaponsSystemFolder:WaitForChild("Libraries")

-- Selección de slot: el tamaño lo manda el UIAspectRatioConstraint (el
-- seleccionado se ensancha) y el UIStroke pasa a blanco. El Back del aspect da el
-- "pop"; el stroke va con Quad porque un overshoot sobre un Color3 se sale de
-- rango y pega un fogonazo.
local HOTBAR_ASPECT_SELECTED = 1.6
local HOTBAR_ASPECT_IDLE = 1
local HOTBAR_STROKE_SELECTED_COLOR = Color3.fromRGB(255, 255, 255)
local HOTBAR_STROKE_IDLE_COLOR = Color3.fromRGB(58, 52, 67)
local HOTBAR_ASPECT_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HOTBAR_STROKE_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Un único layout para todos los dispositivos, colocado por el UIListLayout del
-- root: en PC pegado a la derecha y en táctil centrado (entre los dos pulgares,
-- sin chocar con el joystick ni el botón de disparo).
local HOTBAR_ALIGNMENT_PC = Enum.HorizontalAlignment.Right
local HOTBAR_ALIGNMENT_TOUCH = Enum.HorizontalAlignment.Center

-- Texto de munición: color por munición baja y "..." animado al recargar.
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

local function toHexColor(color: Color3): string
	return string.format(
		"%02X%02X%02X",
		math.round(color.R * 255),
		math.round(color.G * 255),
		math.round(color.B * 255)
	)
end

local function getCategoryByToolName(toolName)
	if ItemsConfig.Main[toolName] ~= nil then
		return "Main"
	end
	if ItemsConfig.Special[toolName] ~= nil then
		return "Special"
	end
	return nil
end

-- Capacidad del cargador de un Tool: AmmoCapacity de su definición en
-- WeaponsConfig (o el default del esquema), escalada por su atributo WeaponLevel.
local function getToolAmmoCapacity(tool: Instance?): number
	if not tool then
		return 0
	end
	local base = tonumber(WeaponsConfig.GetValueForTool(tool, "AmmoCapacity"))
		or tonumber(WeaponsConfig.Schema.GetDefault("BulletWeapon", "AmmoCapacity"))
		or 0
	local level = tool:GetAttribute(WeaponLevelConfig.ATTRIBUTE)
	return tonumber(WeaponLevelConfig.ApplyScaling("AmmoCapacity", base, level)) or base
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
	local footerNode = itemFrame:FindFirstChild("Footer")
	local ammoValueNode = if footerNode then footerNode:FindFirstChild("Value") else nil

	return {
		frame = itemFrame,
		image = if isHotbarImageNode(imageNode) then imageNode else nil,
		aspect = itemFrame:FindFirstChildWhichIsA("UIAspectRatioConstraint"),
		stroke = itemFrame:FindFirstChildWhichIsA("UIStroke"),
		ammoValueNode = ammoValueNode,
		ammoValueLabel = if isHotbarTextNode(ammoValueNode) then ammoValueNode else nil,
		_selected = nil,
		_aspectTween = nil,
		_strokeTween = nil,
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

	local aspect = slotNode.aspect
	if aspect then
		if slotNode._aspectTween then
			slotNode._aspectTween:Cancel()
		end
		local tween = TweenService:Create(aspect, HOTBAR_ASPECT_TWEEN_INFO, {
			AspectRatio = if isSelected then HOTBAR_ASPECT_SELECTED else HOTBAR_ASPECT_IDLE,
		})
		slotNode._aspectTween = tween
		tween:Play()
	end

	local stroke = slotNode.stroke
	if stroke then
		if slotNode._strokeTween then
			slotNode._strokeTween:Cancel()
		end
		local tween = TweenService:Create(stroke, HOTBAR_STROKE_TWEEN_INFO, {
			Color = if isSelected then HOTBAR_STROKE_SELECTED_COLOR else HOTBAR_STROKE_IDLE_COLOR,
		})
		slotNode._strokeTween = tween
		tween:Play()
	end
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
				local category = getCategoryByToolName(child.Name)
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

-- ¿El Tool de este slot es el arma que se está recargando ahora mismo?
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

-- Pinta la munición de un slot: "..." blanco animado si su arma se recarga; si
-- no, "actual/cargador" con el número actual coloreado por munición baja
-- (blanco → naranja → rojo).
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
		-- Color por munición baja (% del cargador): naranja, luego rojo.
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

	-- Si ya estamos en ese slot (su arma ya está equipada), no hacemos nada:
	-- no re-equipamos (evita el toggle/desequipado de Roblox) y solo
	-- garantizamos el resaltado correcto.
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
			if slotNode._aspectTween then
				slotNode._aspectTween:Cancel()
				slotNode._aspectTween = nil
			end
			if slotNode._strokeTween then
				slotNode._strokeTween:Cancel()
				slotNode._strokeTween = nil
			end
		end
	end
end

return Hotbar
