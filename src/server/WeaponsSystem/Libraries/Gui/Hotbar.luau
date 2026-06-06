--!strict
-- Hotbar.luau (Client/Server Library)
-- Gestiona la interfaz del hotbar (PC y Touchscreen) del sistema de armas.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local ItemsConfig = require(Shared.constants.ItemsConfig)

local WeaponsSystemFolder = script.Parent.Parent.Parent
local WeaponData = WeaponsSystemFolder:WaitForChild("WeaponData")
local Libraries = WeaponsSystemFolder:WaitForChild("Libraries")

local HOTBAR_SELECTED_SCALE = 1.25
local HOTBAR_DEFAULT_SCALE = 1
local HOTBAR_AMMO_CURRENT_COLOR = "#FFFFFF"
local HOTBAR_AMMO_TOTAL_COLOR = "#8FD6FF"

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

	local imageNode = itemFrame:FindFirstChild("Image")
	if not isHotbarImageNode(imageNode) then
		imageNode = itemFrame:FindFirstChildWhichIsA("ImageButton") or itemFrame:FindFirstChildWhichIsA("ImageLabel")
	end

	local strokeNode = itemFrame:FindFirstChildWhichIsA("UIStroke")
	local ammoRoot = itemFrame:FindFirstChild("Ammo")
	local ammoValueNode = if ammoRoot then ammoRoot:FindFirstChild("Value") else nil
	local ammoValueLabel = if ammoValueNode and (
		ammoValueNode:IsA("TextLabel")
		or ammoValueNode:IsA("TextButton")
		or ammoValueNode:IsA("TextBox")
	) then ammoValueNode else nil

	return {
		frame = itemFrame,
		image = imageNode,
		stroke = if strokeNode and strokeNode:IsA("UIStroke") then strokeNode else nil,
		ammoValueNode = ammoValueNode,
		ammoValueLabel = ammoValueLabel,
		baseSize = itemFrame.Size,
	}
end

function Hotbar:_setSlotStrokeVisible(slotNode, isVisible)
	local stroke = slotNode and slotNode.stroke
	if stroke then
		stroke.Enabled = isVisible
	end
end

function Hotbar:_setSlotScale(slotNode, scale)
	if not slotNode or not slotNode.frame or not slotNode.baseSize then return end
	local baseSize = slotNode.baseSize
	slotNode.frame.Size = UDim2.new(
		baseSize.X.Scale * scale,
		math.floor(baseSize.X.Offset * scale + 0.5),
		baseSize.Y.Scale * scale,
		math.floor(baseSize.Y.Offset * scale + 0.5)
	)
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
		self:_setSlotScale(layout.item1, if selectedSlot == 1 then HOTBAR_SELECTED_SCALE else HOTBAR_DEFAULT_SCALE)
		self:_setSlotScale(layout.item2, if selectedSlot == 2 then HOTBAR_SELECTED_SCALE else HOTBAR_DEFAULT_SCALE)
		self:_setSlotStrokeVisible(layout.item1, selectedSlot == 1)
		self:_setSlotStrokeVisible(layout.item2, selectedSlot == 2)
	end
end

function Hotbar:_resolveAmmoCapacityForTool(tool)
	if not tool then return nil end
	local currentWeapon = self.weaponsGui.weaponsSystem.currentWeapon
	if currentWeapon and currentWeapon.instance == tool and currentWeapon.getConfigValue then
		local capacity = currentWeapon:getConfigValue("AmmoCapacity", nil)
		if type(capacity) == "number" then
			return math.max(0, math.floor(capacity + 0.5))
		end
	end
	local configuration = tool:FindFirstChildOfClass("Configuration")
	if configuration then
		local ammoCapacityValue = configuration:FindFirstChild("AmmoCapacity")
		if ammoCapacityValue and ammoCapacityValue:IsA("ValueBase") then
			local rawValue = ammoCapacityValue.Value
			if type(rawValue) == "number" then
				return math.max(0, math.floor(rawValue + 0.5))
			end
		end
	end
	return nil
end

function Hotbar:_formatAmmoRichText(currentAmmo, totalAmmo)
	return string.format(
		"<font color=\"%s\">%d</font><font color=\"%s\">/%d</font>",
		HOTBAR_AMMO_CURRENT_COLOR,
		currentAmmo,
		HOTBAR_AMMO_TOTAL_COLOR,
		totalAmmo
	)
end

function Hotbar:_setSlotAmmoText(slotNode, currentAmmo, totalAmmo)
	if not slotNode then return end
	local ammoValueLabel = slotNode.ammoValueLabel
	local ammoValueNode = slotNode.ammoValueNode
	local hasAmmo = type(currentAmmo) == "number" and type(totalAmmo) == "number"
	local richText = if hasAmmo
		then self:_formatAmmoRichText(
			math.max(0, math.floor(currentAmmo + 0.5)),
			math.max(0, math.floor(totalAmmo + 0.5))
		)
		else ""

	if ammoValueLabel then
		ammoValueLabel.RichText = true
		ammoValueLabel.Text = richText
		return
	end
	if ammoValueNode and ammoValueNode:IsA("StringValue") then
		ammoValueNode.Value = richText
	elseif ammoValueNode and (ammoValueNode:IsA("IntValue") or ammoValueNode:IsA("NumberValue")) then
		ammoValueNode.Value = if hasAmmo then math.max(0, math.floor(currentAmmo + 0.5)) else 0
	end
end

function Hotbar:_updateAmmoDisplay(mainTool, specialTool)
	local mainCurrent = if mainTool then mainTool:GetAttribute("CurrentAmmo") else nil
	local specialCurrent = if specialTool then specialTool:GetAttribute("CurrentAmmo") else nil
	local mainTotal = self:_resolveAmmoCapacityForTool(mainTool)
	local specialTotal = self:_resolveAmmoCapacityForTool(specialTool)

	for _, layout in ipairs(self.layouts) do
		self:_setSlotAmmoText(layout.item1, mainCurrent, mainTotal)
		self:_setSlotAmmoText(layout.item2, specialCurrent, specialTotal)
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
	local currentWeapon = self.weaponsGui.weaponsSystem.currentWeapon
	if currentWeapon and currentWeapon.reloading and currentWeapon.cancelReload then
		currentWeapon:cancelReload()
	end

	if slot == 1 then
		self:_equipTool(self.mainTool)
		self:_applySelectedVisual(1)
		return
	end

	if slot == 2 then
		self:_equipTool(self.specialTool)
		self:_applySelectedVisual(2)
	end
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
end

return Hotbar
