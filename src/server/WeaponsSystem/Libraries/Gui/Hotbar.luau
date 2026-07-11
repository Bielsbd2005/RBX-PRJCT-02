--!strict
-- Hotbar.luau (Client/Server Library)
-- Gestiona la interfaz del hotbar (PC y Touchscreen) del sistema de armas.
--
-- Estructura esperada por slot (Item1 / Item2), ambos idénticos:
--   Item.Ammo.Value            -> balas restantes (solo el número actual)
--   Item.Container             -> ImageColor3 cyan si está equipado, gris si no
--   Item.Container.Thumbnail   -> imagen del arma; ImageColor3 blanco si seleccionado, gris si no

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local ItemsConfig = require(Shared.constants.ItemsConfig)
local WeaponLevelConfig = require(Shared.constants.WeaponLevelConfig)

local WeaponsSystemFolder = script.Parent.Parent.Parent
local WeaponData = WeaponsSystemFolder:WaitForChild("WeaponData")
local Libraries = WeaponsSystemFolder:WaitForChild("Libraries")

-- Container: borde/fondo del slot
local HOTBAR_CONTAINER_EQUIPPED_COLOR = Color3.fromRGB(0, 222, 248)
local HOTBAR_CONTAINER_IDLE_COLOR = Color3.fromRGB(84, 84, 84)
-- Thumbnail: imagen del arma
local HOTBAR_THUMBNAIL_SELECTED_COLOR = Color3.fromRGB(255, 255, 255)
local HOTBAR_THUMBNAIL_IDLE_COLOR = Color3.fromRGB(190, 190, 190)
-- Tween de tamaño del slot seleccionado
local HOTBAR_SELECTED_SCALE = 1.18
local HOTBAR_DEFAULT_SCALE = 1
local HOTBAR_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Texto de munición: color por munición baja y "..." animado al recargar.
local AMMO_LOW_RATIO = 0.45 -- naranja por debajo de este % del cargador
local AMMO_CRITICAL_RATIO = 0.2 -- rojo por debajo de este %
local AMMO_COLOR_LOW = Color3.fromRGB(255, 150, 0)
local AMMO_COLOR_CRITICAL = Color3.fromRGB(230, 55, 55)
local AMMO_COLOR_RELOAD = Color3.fromRGB(255, 255, 255)
local RELOAD_DOT_INTERVAL = 0.25 -- segundos por punto del "..." de recarga

local Hotbar = {}
Hotbar.__index = Hotbar

local function isHotbarImageNode(node)
	return node and (node:IsA("ImageLabel") or node:IsA("ImageButton"))
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

-- Capacidad del cargador de un Tool: Configuration.AmmoCapacity (replicado a
-- cliente) escalada por su atributo WeaponLevel.
local function getToolAmmoCapacity(tool: Instance?): number
	if not tool then
		return 0
	end
	local base = 30
	local config = tool:FindFirstChildOfClass("Configuration")
	local val = if config then config:FindFirstChild("AmmoCapacity") else nil
	if val and val:IsA("ValueBase") then
		base = tonumber((val :: any).Value) or base
	end
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

	local itemsFolder = hotbarRoot:FindFirstChild("Items")
	local searchRoot = if itemsFolder then itemsFolder else hotbarRoot

	local itemFrame = searchRoot:FindFirstChild(itemName)
	if not itemFrame then
		local lowercaseName = string.lower(itemName)
		for _, child in ipairs(searchRoot:GetChildren()) do
			if string.lower(child.Name) == lowercaseName then
				itemFrame = child
				break
			end
		end
	end
	if not itemFrame or not itemFrame:IsA("GuiObject") then
		return nil
	end

	local containerNode = itemFrame:FindFirstChild("Container")
	local thumbnailNode = if containerNode then containerNode:FindFirstChild("Thumbnail") else nil
	if not isHotbarImageNode(thumbnailNode) and containerNode then
		thumbnailNode = containerNode:FindFirstChildWhichIsA("ImageButton")
			or containerNode:FindFirstChildWhichIsA("ImageLabel")
	end

	local ammoRoot = itemFrame:FindFirstChild("Ammo")
	local ammoValueNode = if ammoRoot then ammoRoot:FindFirstChild("Value") else nil
	local ammoValueLabel = if ammoValueNode and (
		ammoValueNode:IsA("TextLabel")
		or ammoValueNode:IsA("TextButton")
		or ammoValueNode:IsA("TextBox")
	) then ammoValueNode else nil

	return {
		frame = itemFrame,
		container = if containerNode and isHotbarImageNode(containerNode) then containerNode else nil,
		thumbnail = if isHotbarImageNode(thumbnailNode) then thumbnailNode else nil,
		ammoValueNode = ammoValueNode,
		ammoValueLabel = ammoValueLabel,
		ammoDefaultColor = if ammoValueLabel then ammoValueLabel.TextColor3 else Color3.fromRGB(255, 255, 255),
		baseSize = itemFrame.Size,
		_selected = nil,
		_tween = nil,
	}
end

function Hotbar:_getWeaponImageByTool(tool, category)
	if not tool then return "" end
	local config = ItemsConfig[category] and ItemsConfig[category][tool.Name]
	return if config and type(config.Image) == "string" then config.Image else ""
end

function Hotbar:_setSlotImage(slotNode, image)
	local thumbnail = slotNode and slotNode.thumbnail
	if isHotbarImageNode(thumbnail) then
		thumbnail.Image = image
		thumbnail.ImageTransparency = if image == "" then 1 else 0
	end
end

function Hotbar:_tweenSlotScale(slotNode, scale)
	local frame = slotNode.frame
	local baseSize = slotNode.baseSize
	if not frame or not baseSize then return end
	if slotNode._tween then
		slotNode._tween:Cancel()
		slotNode._tween = nil
	end
	local targetSize = UDim2.new(
		baseSize.X.Scale * scale,
		math.floor(baseSize.X.Offset * scale + 0.5),
		baseSize.Y.Scale * scale,
		math.floor(baseSize.Y.Offset * scale + 0.5)
	)
	local tween = TweenService:Create(frame, HOTBAR_TWEEN_INFO, { Size = targetSize })
	slotNode._tween = tween
	tween:Play()
end

function Hotbar:_setSlotSelected(slotNode, isSelected)
	if not slotNode then return end
	if slotNode.container then
		slotNode.container.ImageColor3 = if isSelected
			then HOTBAR_CONTAINER_EQUIPPED_COLOR
			else HOTBAR_CONTAINER_IDLE_COLOR
	end
	if slotNode.thumbnail then
		slotNode.thumbnail.ImageColor3 = if isSelected
			then HOTBAR_THUMBNAIL_SELECTED_COLOR
			else HOTBAR_THUMBNAIL_IDLE_COLOR
	end
	-- Solo animamos cuando el estado de selección cambia, para no reiniciar
	-- el tween en cada refresh() (que se llama muy a menudo).
	if slotNode._selected ~= isSelected then
		slotNode._selected = isSelected
		self:_tweenSlotScale(slotNode, if isSelected then HOTBAR_SELECTED_SCALE else HOTBAR_DEFAULT_SCALE)
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
-- no, el número con color por munición baja (naranja → rojo).
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
	local text = if hasAmmo then tostring(roundedAmmo) else ""

	if ammoValueLabel then
		ammoValueLabel.RichText = false
		-- Color por munición baja (% del cargador): naranja, luego rojo.
		local color = slotNode.ammoDefaultColor or AMMO_COLOR_RELOAD
		if hasAmmo then
			local capacity = getToolAmmoCapacity(tool)
			if capacity > 0 then
				local ratio = roundedAmmo / capacity
				if ratio <= AMMO_CRITICAL_RATIO then
					color = AMMO_COLOR_CRITICAL
				elseif ratio <= AMMO_LOW_RATIO then
					color = AMMO_COLOR_LOW
				end
			end
		end
		ammoValueLabel.TextColor3 = color
		ammoValueLabel.Text = text
		return
	end
	if ammoValueNode and ammoValueNode:IsA("StringValue") then
		ammoValueNode.Value = text
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

function Hotbar:setupLayout(hotbarRoot)
	if not hotbarRoot then return end
	local layout = {
		root = hotbarRoot,
		item1 = self:_captureSlot(hotbarRoot, "Item1"),
		item2 = self:_captureSlot(hotbarRoot, "Item2"),
	}
	table.insert(self.layouts, layout)

	local item1Button = (layout.item1 and layout.item1.frame and layout.item1.frame:IsA("GuiButton") and layout.item1.frame)
		or (layout.item1 and layout.item1.thumbnail)
	local item2Button = (layout.item2 and layout.item2.frame and layout.item2.frame:IsA("GuiButton") and layout.item2.frame)
		or (layout.item2 and layout.item2.thumbnail)
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
			if slotNode and slotNode._tween then
				slotNode._tween:Cancel()
				slotNode._tween = nil
			end
		end
	end
end

return Hotbar
