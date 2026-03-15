--[[
    Locker
    Script principal de la Locker GUI.
    Orquesta todos los componentes y gestiona el estado de la tienda.

    Ruta: StarterPlayerScripts > Client > LockerUI
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
-- Fusion 0.3 imports
local Fusion = require(ReplicatedStorage.Packages.fusion)
local scoped = Fusion.scoped
local Children = Fusion.Children
local Value = Fusion.Value
local Computed = Fusion.Computed
local Spring = Fusion.Spring
local peek = Fusion.peek
local Observer = Fusion.Observer

-- Componentes
local NavButton = require(script.Parent.Components.NavButton)
local ItemCard = require(script.Parent.Components.ItemCard)
local CloseButton = require(script.Parent.Components.CloseButton)
local TabButton = require(script.Parent.Components.TabButton)
local ActionFrame = require(script.Parent.Components.ActionFrame)
local SkinCard = require(script.Parent.Components.SkinCard)
local OutfitCard = require(script.Parent.Components.OutfitCard)
local Constants = require(script.Parent.Components.StoreConstants)

-- Shared modules
local SkinApplier = require(ReplicatedStorage.Shared.Systems.Appearance.SkinApplier)
local ItemsDataUtils = require(ReplicatedStorage.Shared.Systems.Locker.Data.ItemsDataUtils)
local CasesUI = require(script.Parent.Parent.Cases.CasesUI)

-- Jugador local
local player = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Scope principal (gestiona la memoria de toda la UI)
--------------------------------------------------------------------------------
local scope = scoped(Fusion)

--------------------------------------------------------------------------------
-- Estado reactivo
--------------------------------------------------------------------------------
local isStoreOpen = Value(scope, false)
local isLockerVisible = Value(scope, true)

-- Remotes
local shopFolder = ReplicatedStorage:WaitForChild("Shop", 10)
local equipItemRF = shopFolder and shopFolder:WaitForChild("EquipItem", 10)
local buyItemRF = shopFolder and shopFolder:WaitForChild("BuyItem", 10)

-- Tab y opción seleccionados
local selectedTab = Value(scope, "Arsenal")
local selectedOption = Value(scope, "Weapons")
local selectedItem = Value(scope, nil)
local previewCharacter = Value(scope, nil)
local previewWeapon = Value(scope, nil)

-- Resolución de referencia
local REFERENCE_WIDTH = 1920
local REFERENCE_HEIGHT = 1080

-- Escala dinámica
local camera = workspace.CurrentCamera
local viewportSize = Value(scope, camera.ViewportSize)

-- FIX: Añadido al scope para limpieza automática
table.insert(scope, camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
    viewportSize:set(camera.ViewportSize)
end))

local uiScale = Computed(scope, function(use)
    local viewport = use(viewportSize)
    local scaleX = viewport.X / REFERENCE_WIDTH
    local scaleY = viewport.Y / REFERENCE_HEIGHT
    return math.min(scaleX, scaleY)
end)

-- Gestor de Cámaras
local CameraManager = require(ReplicatedStorage.Shared.Systems.Camera.CameraManager)
local EffectsManager = require(script.Parent.Modules.EffectsManager)
--------------------------------------------------------------------------------
-- Funciones
--------------------------------------------------------------------------------

local skinAnimationConnection: RBXScriptConnection? = nil

local previewKillEffectDummy = Value(scope, nil)
local killEffectToken = 0 -- Incremented to cancel in-flight previews
local killEffectLastTime = -math.huge -- Timestamp of last preview trigger (os.clock)
local KILL_EFFECT_COOLDOWN = 1 -- seconds

local function cleanupPreview()
	local char = peek(previewCharacter)
	if char then char:Destroy(); previewCharacter:set(nil) end

	if skinAnimationConnection then
		skinAnimationConnection:Disconnect()
		skinAnimationConnection = nil
	end

	local weap = peek(previewWeapon)
	if weap then weap:Destroy(); previewWeapon:set(nil) end

	local killDummy = peek(previewKillEffectDummy)
	if killDummy then killDummy:Destroy(); previewKillEffectDummy:set(nil) end
end

local function spawnCharacter()
	-- Si ya existe, no recrear (optimización), pero asegurar que es visible
	if peek(previewCharacter) then return peek(previewCharacter) end

	local template = ReplicatedStorage.Shared.Systems.Locker.Templates:WaitForChild("CharacterTemplate", 5)
	if not template then warn("CharacterTemplate no encontrado"); return end

	local lockerFolder = workspace:WaitForChild("Locker", 5)
	local spawnLocation = lockerFolder and lockerFolder:WaitForChild("CharacterSpawn", 5)
	if not spawnLocation then warn("CharacterSpawn no encontrado"); return end

	local char = template:Clone()
	char.Parent = spawnLocation
	char:PivotTo(spawnLocation.CFrame)

	-- Animación Idle
	local humanoid = char:WaitForChild("Humanoid", 5)
	local animator = humanoid and humanoid:WaitForChild("Animator", 5)
	if animator then
		local animation = Instance.new("Animation")
		animation.AnimationId = Constants.AnimationIds.Idle
		local track = animator:LoadAnimation(animation)
		track.Looped = true
		track:Play()
	end

	previewCharacter:set(char)
	return char
end

local function spawnKillEffectDummy(forceRespawn)
	if peek(previewKillEffectDummy) and not forceRespawn then return peek(previewKillEffectDummy) end

	-- Cleanup existing if forcing respawn
	local existing = peek(previewKillEffectDummy)
	if existing then existing:Destroy(); previewKillEffectDummy:set(nil) end

	local template = ReplicatedStorage.Shared.Systems.Locker.Templates:FindFirstChild("Dummy")
	if not template then warn("Dummy/CharacterTemplate not found for KillEffect"); return end

	local lockerFolder = workspace:WaitForChild("Locker", 5)
	local spawnLocation = lockerFolder and lockerFolder:FindFirstChild("KillEffectSpawn")

	if not spawnLocation then
		warn("KillEffectSpawn not found")
		-- Fallback to a position near Locker camera if spawn doesn't exist
		spawnLocation = { CFrame = CFrame.new(0, 5, 0) }
	end

	-- Aggressive orphan cleanup
    local parentFolder = lockerFolder or workspace
    for _, child in parentFolder:GetChildren() do
        if child.Name == "KillEffectDummy" and child ~= peek(previewKillEffectDummy) then
            child:Destroy()
        end
    end

	local char = template:Clone()
	char.Name = "KillEffectDummy"
	char.Parent = lockerFolder or workspace
	char:PivotTo(spawnLocation.CFrame)

	-- Animation Idle (reuse same id)
	local humanoid = char:WaitForChild("Humanoid", 5)
	local animator = humanoid and humanoid:WaitForChild("Animator", 5)
	if animator then
		local animation = Instance.new("Animation")
		animation.AnimationId = Constants.AnimationIds.Idle
		local track = animator:LoadAnimation(animation)
		track.Looped = true
		track:Play()
	end

	previewKillEffectDummy:set(char)
	return char
end

local function playKillEffectPreview(effectItem)
	-- 1-second cooldown to prevent spam
	local now = os.clock()
	if now - killEffectLastTime < KILL_EFFECT_COOLDOWN then return end
	killEffectLastTime = now

	-- Cancel any in-flight preview by incrementing the token
	killEffectToken += 1
	local myToken = killEffectToken

	-- Force-destroy the current dummy so we start clean immediately
	local existing = peek(previewKillEffectDummy)
	if existing then existing:Destroy(); previewKillEffectDummy:set(nil) end

	-- Spawn a fresh dummy
	local dummy = spawnKillEffectDummy(true)
	if not dummy then return end

	-- 1. Apply Effect Logic
    print("Playing Kill Effect:", effectItem.Name)

	-- Wait for character to be fully in workspace
	task.wait()
	if killEffectToken ~= myToken then return end -- cancelled

    local killEffectsFolder = ReplicatedStorage:FindFirstChild("Shared") and ReplicatedStorage.Shared:FindFirstChild("Systems") and ReplicatedStorage.Shared.Systems:FindFirstChild("Combat") and ReplicatedStorage.Shared.Systems.Combat:FindFirstChild("KillEffects")
    local effectTemplate = killEffectsFolder and killEffectsFolder:FindFirstChild(effectItem.Name)

    if effectTemplate then
	    local effectModule = require(effectTemplate)
		if effectModule.applyDefaultRagdoll then
			effectModule.applyDefaultRagdoll(dummy)
		end
    else
        warn("KillEffect module not found for:", effectItem.Name)
    end

    -- Trigger Death to activate the effect
	local humanoid = dummy:FindFirstChild("Humanoid")
	if humanoid then
		task.wait() -- Allow Died event to connect
		if killEffectToken ~= myToken then return end -- cancelled
		humanoid.Health = 0
	end

	-- 2. Wait
	task.wait(2)
	if killEffectToken ~= myToken then return end -- cancelled

	-- 3. Fade Out
	local tweenInfo = TweenInfo.new(1, Enum.EasingStyle.Linear)
	local parts = {}

    for _, part in dummy:GetDescendants() do
        if part:IsA("BasePart") or part:IsA("Decal") then
            table.insert(parts, part)
        end
    end

    for _, part in parts do
        TweenService:Create(part, tweenInfo, {Transparency = 1}):Play()
    end

    task.wait(1)
	if killEffectToken ~= myToken then return end -- cancelled

    -- 4. Cleanup and Respawn
    if dummy and dummy.Parent then dummy:Destroy() end
    previewKillEffectDummy:set(nil)

    -- Only respawn if the store is still OPEN and we are still the active preview
    if peek(isStoreOpen) and killEffectToken == myToken then
        spawnKillEffectDummy(true)
    end
end

local function applySkin(weapon: Model, skinData: { [string]: any })
	if not weapon or not skinData then return end

	-- Disconnect previous animation
	if skinAnimationConnection then
		skinAnimationConnection:Disconnect()
		skinAnimationConnection = nil
	end

	-- Apply skin using shared module (also cleans up previous textures)
	local textures = SkinApplier.apply(weapon, skinData)

	-- Start animation if needed (uses Heartbeat, not RenderStepped)
	skinAnimationConnection = SkinApplier.startAnimation(textures, skinData, weapon)
end

local function spawnWeapon(weaponName: string, skinData: { [string]: any }?)
	-- NO limpiar personaje aquí para permitir dual preview
	-- local char = peek(previewCharacter)
	-- if char then char:Destroy(); previewCharacter:set(nil) end

	-- Limpiar arma anterior
	-- Limpiar arma anterior
	local currentWeap = peek(previewWeapon)
	if currentWeap then currentWeap:Destroy() end

	if skinAnimationConnection then
		skinAnimationConnection:Disconnect()
		skinAnimationConnection = nil
	end

	local weaponsFolder = ReplicatedStorage.Shared.Systems.Locker:WaitForChild("Weapons", 5)
	local weaponTemplate = weaponsFolder and weaponsFolder:FindFirstChild(weaponName)

	if not weaponTemplate then
		-- Fallback a Default si no existe la específica (para evitar vacío)
		weaponTemplate = weaponsFolder:FindFirstChild("Default")
	end

	if not weaponTemplate then warn("Weapon model not found:", weaponName); return end

	local lockerFolder = workspace:WaitForChild("Locker", 5)
	local spawnLocation = lockerFolder and lockerFolder:WaitForChild("WeaponSpawn", 5)
	if not spawnLocation then warn("WeaponSpawn no encontrado en Workspace.Locker"); return end

	local newWeap = weaponTemplate:Clone()
	newWeap.Parent = spawnLocation
	newWeap:PivotTo(spawnLocation.CFrame)

	-- Asegurar que esté anclado para preview
	for _, part in newWeap:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
		end
	end

	if skinData then
		applySkin(newWeap, skinData)
	end

	previewWeapon:set(newWeap)
	return newWeap
end


-- Gestor de Apariencia
local FaceApplier = require(ReplicatedStorage.Shared.Systems.Appearance.FaceApplier)
local HatApplier = require(ReplicatedStorage.Shared.Systems.Appearance.HatApplier)
local OutfitApplier = require(ReplicatedStorage.Shared.Systems.Appearance.OutfitApplier)
local ItemsData = require(ReplicatedStorage.Shared.Systems.Locker.Data.ItemsData)
local DataController = require(ReplicatedStorage.Shared.Systems.Data.DataController)

-- Estado reactivo de los datos del jugador
local playerData = Value(scope, DataController:Get() or {})

DataController:OnReady(function()
    playerData:set(DataController:Get())
end)

-- FIX: Aseguramos la conexión en el scope para evitar Memory Leaks
local conn_data = DataController:OnRawChange(function()
    playerData:set(DataController:Get())
end)
table.insert(scope, conn_data)

local function restorePreview()
	local data = peek(playerData)

	-- Restore Weapon
	local equippedWeapon = (data and data.equipped and data.equipped.Weapons) or "Default"
	local skinName = (data and data.equipped and data.equipped.WeaponSkins) or "Default"
	local equippedSkinData = ItemsDataUtils.findByName("Arsenal", "WeaponSkins", skinName)

	spawnWeapon(equippedWeapon, equippedSkinData)

	-- Restore Character Appearance
	local char = spawnCharacter()
	if char and data and data.equipped then
		-- Face
		local faceItem = ItemsDataUtils.findByName("Cosmetics", "Faces", data.equipped.Faces)
		if faceItem then FaceApplier.Apply(char, faceItem) end

		-- Hat
		local hatItem = ItemsDataUtils.findByName("Cosmetics", "Hats", data.equipped.Hats)
		if hatItem then
			HatApplier.Apply(char, hatItem)
		else
			HatApplier.Clear(char)
		end

		-- Outfit
		local outfitItem = ItemsDataUtils.findByName("Cosmetics", "Outfits", data.equipped.Outfits)
		if outfitItem then OutfitApplier.Apply(char, outfitItem) end
	end
end

-- Observar cambios en la selección
local Observer = Fusion.Observer
local obsItem = Observer(scope, selectedItem)
obsItem:onChange(function()
	local item = peek(selectedItem)

	if item then
		local option = peek(selectedOption)

		-- SHOW PREVIEW
		if option == "Weapons" then
			local data = peek(playerData)
			local skinName = (data and data.equipped and data.equipped.WeaponSkins) or "Default"
			local equippedSkinData = ItemsDataUtils.findByName("Arsenal", "WeaponSkins", skinName)

			spawnWeapon(item.Name, equippedSkinData)
		elseif option == "WeaponSkins" then
			local data = peek(playerData)
			local currentWeapon = data.equipped and data.equipped.Weapons or "Default"
			spawnWeapon(currentWeapon, item) -- item is the skin data
		elseif option == "Faces" then
			local char = spawnCharacter()
			if char then FaceApplier.Apply(char, item) end
		elseif option == "Hats" then
			local char = spawnCharacter()
			if char then HatApplier.Apply(char, item) end

		elseif option == "Outfits" then
			local char = spawnCharacter()
			if char then OutfitApplier.Apply(char, item) end
		elseif option == "KillEffects" then
			task.spawn(function()
				playKillEffectPreview(item)
			end)
		end

		-- Auto-Equipar si se tiene (Owned)
		local data = peek(playerData)
		local isOwned = ItemsDataUtils.isItemOwned(data, option, item.Name)

		if isOwned and equipItemRF then
			-- Check if already equipped to avoid redundant calls
			if data.equipped and data.equipped[option] == item.Name then
				return
			end

			-- OPTIMISTIC UPDATE: Auto-equip locally immediately (deep-clone nested tables)
			local newData = table.clone(peek(playerData))
			newData.equipped = table.clone(newData.equipped or {})
			newData.equipped[option] = item.Name
			playerData:set(newData)

			task.spawn(function()
				equipItemRF:InvokeServer(option, item.Name)
			end)
		end
	else
		-- Si se deselecciona, restaurar equipado
		restorePreview()
	end
end)

local function updatePreviewScene()
	if not peek(isStoreOpen) then
		cleanupPreview()
		return
	end

	-- Si está abierto, forzar restauración basada en el tab actual
	-- Esto maneja el cambio entre pestañas (Arsenal <-> Cosmetics)

	if peek(selectedOption) == "KillEffects" then
		spawnKillEffectDummy(false)
	else
		restorePreview()
	end
end

-- Observer para cambio de Tab (para cambiar de escena Weapon <-> Character)
local obsTab = Observer(scope, selectedTab)
obsTab:onChange(function()
	-- updatePreviewScene() -- Redundante, obsOption ya lo maneja al cambiar de tab (que cambia option)
end)

local currentCameraTarget = "Locker"

-- Observer para cambio de Opción (para cambiar de Cámara en KillEffects)
local obsOption = Observer(scope, selectedOption)
obsOption:onChange(function()
	if not peek(isStoreOpen) then return end

	-- Restaurar preview al cambiar de opción (ej: Faces -> Hats debe resetear la Face preview)
	updatePreviewScene()

	local option = peek(selectedOption)
	local targetName = (option == "KillEffects") and "KillEffects" or "Locker"

	if currentCameraTarget ~= targetName then
		currentCameraTarget = targetName

		local camerasFolder = workspace:WaitForChild("Cameras")
		local cameraPart = camerasFolder:FindFirstChild(targetName)

		if cameraPart then
			local focusDist = (targetName == "KillEffects") and 17.06 or 10 -- Default 10 for Locker
			CameraManager.setTarget(cameraPart, true, nil, focusDist)
		end
	end

	-- AUTO-SELECT EQUIPPED ITEM
	local data = peek(playerData)
	local tab = peek(selectedTab)
	local equippedName = data.equipped and data.equipped[option]

	local foundEquipped = false
	if equippedName and equippedName ~= "" then
		local categoryData = ItemsData[tab]
		local optionData = categoryData and categoryData[option]

		if optionData then
			for _, item in optionData do
				if item.Name == equippedName then
					selectedItem:set(item)
					foundEquipped = true
					break
				end
			end
		end
	end

	-- If we switched to an option where we don't have something equipped (e.g. empty category)
	-- we might want to clear the selection or keep it. Original logic suggested clearing.
	if not foundEquipped then
		selectedItem:set(nil)
	end
end)

local function setStoreState(isOpen)
	if isOpen then
		-- Force default tab/option when opening
		selectedTab:set("Arsenal")
		selectedOption:set("Weapons")
		-- KillEffectDummy will be lazily spawned when the tab is selected
	end

	isStoreOpen:set(isOpen)
	updatePreviewScene()

	if isOpen then
		-- ABRIR
		currentCameraTarget = "Locker" -- Resetear al abrir
		local cameraPart = workspace:WaitForChild("Cameras"):FindFirstChild("Locker")
		if cameraPart then
			CameraManager.setTarget(cameraPart, true, nil, 10)
		end
	else
		-- CERRAR
		task.spawn(function()
			EffectsManager.fadeToBlack(0.2)
			CameraManager.reset(true) -- Instantáneo
			EffectsManager.fadeFromBlack(0.2)
		end)
	end
end

local function toggleStore()
	setStoreState(not peek(isStoreOpen))
end

local function closeStore()
	if peek(isStoreOpen) then
		setStoreState(false)
	end
end

--------------------------------------------------------------------------------
-- Selección de tab
--------------------------------------------------------------------------------
local function selectTab(tabName: string)
	selectedTab:set(tabName)
	-- Resetear la opción a la primera del nuevo tab
	local options = Constants.NavOptions[tabName]
	if options and options[1] then
		selectedOption:set(options[1].Name)
	end
end

--------------------------------------------------------------------------------
-- Navegación lateral (Option buttons) — generados dinámicamente
--------------------------------------------------------------------------------
local function createNavSection(scope: Fusion.Scope<typeof(Fusion)>)
	-- Children reactivos que cambian cuando cambia el tab seleccionado
	local navChildren = Computed(scope, function(use)
		local tabName = use(selectedTab)
		local options = Constants.NavOptions[tabName] or {}
		local children = {}

		-- UIListLayout siempre presente
		table.insert(children, scope:New "UIListLayout" {
			Name = "UIListLayout",
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0.08, 0),
			SortOrder = Enum.SortOrder.LayoutOrder,
		})

		for i, optionData in options do
			local optName = optionData.Name
			table.insert(children, NavButton(scope, {
				name = optName,
				title = optionData.Title or optName,
				image = optionData.Image,
				layoutOrder = i,
				isSelected = Computed(scope, function(use)
					return use(selectedOption) == optName
				end),
				onClick = function()
					selectedOption:set(optName)
				end,
			}))
		end

		return children
	end)

	return scope:New "Frame" {
		Name = "Nav",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.574, 0.22),
		Size = UDim2.fromScale(0.052, 0.308),

		[Children] = navChildren,
	}
end

--------------------------------------------------------------------------------
-- Grid de items (ScrollingFrame con tarjetas)
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Grid de items (ScrollingFrame con tarjetas)
--------------------------------------------------------------------------------

local function createItemGrid(scope: Fusion.Scope<typeof(Fusion)>)
	-- playerData ya está definido arriba en scope principal

	-- Limpieza al destruir el scope (aunque en este script LockerUI vive siempre, es buena práctica)
	-- table.insert(scope, { Destroy = ... }) -- conn_data es global ahora


	-- Lista de items reactiva según tab/opción
	-- Lista de items reactiva según tab/opción
	local currentItems = Computed(scope, function(use)
		local tab = use(selectedTab)
		local option = use(selectedOption)
		local data = use(playerData)

		local categoryData = ItemsData[tab]
		if not categoryData then return {} end

		local optionData = categoryData[option]
		if not optionData then return {} end

		-- Filtro estricto para WeaponSkins: SOLO mostrar si se tienen en el inventario
		if option == "WeaponSkins" then
			local filtered = {}
			local ownedCount = {}

			if data.inventory and data.inventory.WeaponSkins then
				for _, name in data.inventory.WeaponSkins do
					ownedCount[name] = (ownedCount[name] or 0) + 1
				end
			end
			-- Always ensure Default is visible (safety fallback)
			ownedCount["Default"] = 1

			for _, item in optionData do
				if ownedCount[item.Name] and ownedCount[item.Name] > 0 then
					-- Guardamos la cantidad temporalmente para poder ordenarlo u usarlo luego
					item._ownedCount = ownedCount[item.Name]
					table.insert(filtered, item)
				end
			end

			return filtered
		else
			-- Otras categorías muestran todo (bloqueado/desbloqueado)
			return optionData
		end
	end)

	local itemCards = Computed(scope, function(use)
		local items = use(currentItems)
		local data = use(playerData)
		local _currentTab = use(selectedTab)   -- "Cosmetics" (Unused but kept for reactivity if needed, prefixed with _)
		local currentOption = use(selectedOption) -- "Faces"

		local cards = {}

		-- UIListLayout / UIGridLayout siempre necesario
		table.insert(cards, scope:New "UIGridLayout" {
			Name = "UIGridLayout",
			-- Cuando AutomaticCanvasSize está activo, usar Scale en Y causa conflictos
			-- Calculamos su equivalente en Offset basado en el viewport.
			-- Re-calculamos offsets de celda pre-escala para que el UIScale superior
			-- no achique las tarjetas injustamente, forzando idéntico tamaño físico a 1920x1080.
			CellPadding = Computed(scope, function(use)
				local vSize = use(viewportSize)
				local scale = use(uiScale)
				local rootWidth = vSize.X / scale
				local gridWidth = rootWidth * 0.356 * 0.987

				-- En 1920x1080 (GridWidth = 674.63px) el PadY era 24.69px.
				local padY = gridWidth * (24.69 / 674.63)
				return UDim2.new(0.04, 0, 0, padY)
			end),

			CellSize = Computed(scope, function(use)
				local vSize = use(viewportSize)
				local scale = use(uiScale)
				local rootWidth = vSize.X / scale
				local gridWidth = rootWidth * 0.356 * 0.987

				local cellWidth = gridWidth * 0.3
				-- En 1920x1080 (CellWidth = 202.39px) el Alto era 222.25px.
				local cellHeight = cellWidth * (222.25 / 202.39)

				return UDim2.new(0.3, 0, 0, cellHeight)
			end),
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			SortOrder = Enum.SortOrder.LayoutOrder,
		})

		table.insert(cards, scope:New "UIPadding" {
			Name = "UIPadding",
			PaddingBottom = UDim.new(0, 25),
			PaddingLeft = UDim.new(0, 25),
			PaddingRight = UDim.new(0, 25),
			PaddingTop = UDim.new(0, 15),
		})

		-- Helper para verificar propiedad
		for i, item in items do
			local isOwned = ItemsDataUtils.isItemOwned(data, currentOption, item.Name)
			local isEquipped = data.equipped and data.equipped[currentOption] == item.Name

			-- Pre-calcular estado para ordenamiento estable luego si es necesario
			item._isOwned = isOwned
			item._isEquipped = isEquipped
		end

		-- Pesos de rareza (Mayor número = más arriba)
		local RARITY_WEIGHTS = {
			Legendary = 4,
			Epic = 3,
			Rare = 2,
			Common = 1
		}

		-- Clonar y ordenar
		local sortedItems = table.clone(items)
		table.sort(sortedItems, function(a, b)
			-- 1. Dueño primero
			if a._isOwned ~= b._isOwned then
				return a._isOwned -- true > false
			end

			-- 2. Por rareza (de mayor a menor)
			local rarityA = RARITY_WEIGHTS[a.Rarity] or 0
			local rarityB = RARITY_WEIGHTS[b.Rarity] or 0
			if rarityA ~= rarityB then
				return rarityA > rarityB
			end

			-- 3. Por precio (menor a mayor)
			local priceA = a.Price or 0
			local priceB = b.Price or 0
			if priceA ~= priceB then
				return priceA < priceB
			end

			-- 4. Fallback por nombre
			return a.Name < b.Name
		end)

		for i, item in sortedItems do
			local isOwned = item._isOwned
			local isEquipped = item._isEquipped

			-- Verificar bloqueo por nivel
			local isLevelLocked = ItemsDataUtils.isLevelLocked(item, data)

			if currentOption == "WeaponSkins" then
				table.insert(cards, SkinCard(scope, {
					skinName = item.Name,
					skinData = item,
					isEquipped = isEquipped, -- Pass equipped state
					ownedCount = item._ownedCount or 1, -- Pasamos la cuenta al SkinCard
					equippedWeapon = Computed(scope, function(use)
						local d = use(playerData)
						return d.equipped and d.equipped.Weapons or "Default"
					end),
					layoutOrder = i,
					isSelected = Computed(scope, function(use)
						local current = use(selectedItem)
						return current and current.Name == item.Name
					end),
					onClick = function()
						selectedItem:set(item)
					end,

				}))
			elseif currentOption == "Outfits" then
				table.insert(cards, OutfitCard(scope, {
					outfitName = item.Name,
					outfitData = item,
					layoutOrder = i,
					isOwned = isOwned,
					isEquipped = isEquipped,
					isSelected = Computed(scope, function(use)
						local current = use(selectedItem)
						return current and current.Name == item.Name
					end),
					onClick = function()
						selectedItem:set(item)
					end,
				}))
			else
				table.insert(cards, ItemCard(scope, {
					itemName = item.Name,
					price = tostring(item.Price),
					rarity = item.Rarity,
					itemImage = item.Image,
					layoutOrder = i,
					isOwned = isOwned,
					isEquipped = isEquipped,
					isLevelLocked = isLevelLocked,
					requiredLevel = item.Level or 0,
					isSelected = Computed(scope, function(use)
						local current = use(selectedItem)
						return current and current.Name == item.Name
					end),
					onClick = function()
						selectedItem:set(item)
					end,
					category = currentOption,
				}))
			end
		end

		-- Special "Plus" button for WeaponSkins (Custom + Skins)
		if currentOption == "WeaponSkins" then
			-- Clear standard items for skins to avoid double rendering if we want ONLY skins here
			-- Actually `items` comes from `ItemsData["Arsenal"]["WeaponSkins"]`, so `sortedItems` ARE the skins.
			-- Wait, `ItemCard` expects `Image` prop, but SkinData has `TextureID`. `ItemCard` is designed for static images.
			-- We should replace the loop above with a conditional check.
		end

		-- Special "Plus" button for WeaponSkins
		if currentOption == "WeaponSkins" then
			table.insert(cards, scope:New "ImageButton" {
				Name = "Weapon",
				AnchorPoint = Vector2.new(0.5, 0.5),
				AutoButtonColor = false,
				BackgroundColor3 = Color3.fromRGB(54, 54, 54),
				ClipsDescendants = true,
				Image = "rbxassetid://100090954804591",
				ImageColor3 = Color3.fromRGB(79, 79, 79),
				ImageTransparency = 0.14,
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				LayoutOrder = -1, -- Ensure it's at the beginning

				[Fusion.OnEvent "Activated"] = function()
					print("Opening Cases UI...")
					isLockerVisible:set(false) -- Hide Locker UI
					CasesUI.open(function()
						-- Callback when CasesUI closes
						print("Cases UI Closed")
						isLockerVisible:set(true) -- Show Locker UI again

						-- Optionally ensure Locker is in good state or camera reset
						if peek(isStoreOpen) then
							local cameraPart = workspace:WaitForChild("Cameras"):FindFirstChild("Locker")
							if cameraPart then
								CameraManager.setTarget(cameraPart, true, nil, 10)
							end
						end
					end)
				end,

				[Children] = {
					scope:New "UICorner" {
						Name = "UICorner",
						CornerRadius = UDim.new(0.08, 0),
					},

					scope:New "UIStroke" {
						Name = "UIStroke",
						Color = Color3.fromRGB(131, 131, 131),
						Thickness = 5,
					},

					scope:New "TextLabel" {
						Name = "Rarity",
						BackgroundTransparency = 1,
						FontFace = Font.new(
							"rbxasset://fonts/families/Arial.json",
							Enum.FontWeight.Bold,
							Enum.FontStyle.Normal
						),
						Size = UDim2.fromScale(1, 1),
						Text = "+",
						TextColor3 = Color3.fromRGB(253, 255, 255),
						TextScaled = true,
						ZIndex = 2,

						[Children] = {
							scope:New "UIStroke" {
								Name = "UIStroke",
								Thickness = 2,
							},

							scope:New "UITextSizeConstraint" {
								Name = "UITextSizeConstraint",
							},
						}
					},
				}
			})
		end

		return cards
	end)

	return scope:New "ScrollingFrame" {
		Name = "ItemGrid",
		CanvasSize = Computed(scope, function(use)
			local items = use(currentItems)
			local count = #items
			local option = use(selectedOption)

			if option == "WeaponSkins" then
				count = count + 1 -- Botón '+'
			end

			local rows = math.ceil(count / 3)
			if rows == 0 then return UDim2.new(0, 0, 0, 0) end

			local vSize = use(viewportSize)
			local scale = use(uiScale)
			local rootWidth = vSize.X / scale
			local gridWidth = rootWidth * 0.356 * 0.987

			local cellWidth = gridWidth * 0.3
			local cellHeight = cellWidth * (222.25 / 202.39)
			local padY = gridWidth * (24.69 / 674.63)

			-- Top padding = 15, Bottom padding = 25
			local totalHeight = (rows * cellHeight) + ((rows - 1) * padY) + 40
			return UDim2.new(0, 0, 0, totalHeight)
		end),
		BackgroundTransparency = 1,
		BottomImage = "",
		Position = UDim2.fromScale(0, 0.014),
		ScrollBarThickness = 10,
		ScrollBarImageColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(0.987, 0.986),
		TopImage = "",

		[Children] = itemCards,
	}
end

--------------------------------------------------------------------------------
-- Container principal (panel derecho)
--------------------------------------------------------------------------------
local function createContainer(scope: Fusion.Scope<typeof(Fusion)>)
	return scope:New "Frame" {
		Name = "Container",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Constants.Colors.Background,
		Position = UDim2.fromScale(0.809, 0.586),
		Size = UDim2.fromScale(0.356, 0.773),

		[Children] = {
			scope:New "UICorner" {
				Name = "UICorner",
				CornerRadius = UDim.new(0.05, 0),
			},

			scope:New "UIStroke" {
				Name = "UIStroke",
				Enabled = false,
				Thickness = 8,
			},

			createItemGrid(scope),
		},
	}
end

--------------------------------------------------------------------------------
-- Tabs de la tienda (Arsenal, Cosmetics) — con color reactivo
--------------------------------------------------------------------------------
local function createTabs(scope: Fusion.Scope<typeof(Fusion)>)
	local tabs = {}

	-- Posiciones predefinidas (Ajustadas para AnchorPoint 0.5)
	local positions = {
		UDim2.fromScale(0.7095, 0.1455),
		UDim2.fromScale(0.8585, 0.1455),
	}

	for i, tabData in Constants.Tabs do
		-- Color reactivo: azul si activo, gris si inactivo
		local tabColor = Computed(scope, function(use)
			if use(selectedTab) == tabData.Name then
				return Constants.Colors.TabActive
			else
				return Constants.Colors.TabInactive
			end
		end)

		table.insert(tabs, TabButton(scope, {
			text = tabData.Text,
			color = tabColor,
			position = positions[i] or UDim2.fromScale(0, 0),
			layoutOrder = tabData.LayoutOrder,
			onClick = function()
				selectTab(tabData.Name)
			end,
		}))
	end

	return tabs
end

-- Posición X del Root: 0 (abierto, centrado) vs 1.5 (cerrado)
local rootXOffset = Spring(scope, Computed(scope, function(use)
    return use(isStoreOpen) and 0 or 1.5
end), 30, 0.8)

local storeGui = scope:New "ScreenGui" {
    Name = "Locker",
    Parent = player.PlayerGui,
    Enabled = Computed(scope, function(use)
        return use(isStoreOpen) and use(isLockerVisible)
    end),
    IgnoreGuiInset = true,
    ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,

    [Children] = {
        scope:New "UIScale" {
            Scale = uiScale,
        },

        scope:New "Frame" {
            Name = "Root",
            BackgroundTransparency = 1,
            Size = UDim2.fromScale(1, 1),
            Position = Computed(scope, function(use)
                return UDim2.fromScale(use(rootXOffset), 0)
            end),

            [Children] = {
                createContainer(scope),

                CloseButton(scope, {
                    onClose = closeStore,
                }),

                createNavSection(scope),

                createTabs(scope),

                -- FIX: Indentación corregida y estructuración limpia
                ActionFrame(scope, {
                    price = Computed(scope, function(use)
                        local item = use(selectedItem)
                        if not item then return "0" end
                        local data = use(playerData)
                        if ItemsDataUtils.isLevelLocked(item, data) then
                            return "LEVEL " .. tostring(item.Level or 0)
                        else
                            return tostring(item.Price)
                        end
                    end),
                    title = Computed(scope, function(use)
                        local item = use(selectedItem)
                        if not item then return "PURCHASE" end
                        local data = use(playerData)

                        if ItemsDataUtils.isLevelLocked(item, data) then return "LOCKED" end

                        local currentOption = use(selectedOption)
                        local isOwned = ItemsDataUtils.isItemOwned(data, currentOption, item.Name)
                        return isOwned and "EQUIP" or "PURCHASE"
                    end),
                    isLocked = Computed(scope, function(use)
                        local item = use(selectedItem)
                        if not item then return false end
                        local data = use(playerData)
                        return ItemsDataUtils.isLevelLocked(item, data)
                    end),
                    isVisible = Computed(scope, function(use)
                        local item = use(selectedItem)
                        if not item then return false end
                        local data = use(playerData)

                        if ItemsDataUtils.isLevelLocked(item, data) then return true end

                        local currentOption = use(selectedOption)
                        if ItemsDataUtils.isItemOwned(data, currentOption, item.Name) then
                            return false
                        end
                        return true
                    end),
                    onPurchase = function()
                        local item = peek(selectedItem)
                        if not item then return end

                        local tab = peek(selectedTab)
                        local option = peek(selectedOption)
                        local data = peek(playerData)

                        if ItemsDataUtils.isLevelLocked(item, data) then return end
                        if ItemsDataUtils.isItemOwned(data, option, item.Name) then return end

                        if buyItemRF then
                            task.spawn(function()
                                local success = buyItemRF:InvokeServer(tab, option, item.Name)
                                if success then
                                    print("[Locker] Comprado exitosamente:", item.Name)
                                else
                                    warn("[Locker] Fallo al comprar:", item.Name)
                                end
                            end)
                        end
                    end
                }),
            }
        }
    },
}

-- Abrir/cerrar con una tecla
local UserInputService = game:GetService("UserInputService")

table.insert(scope, UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.B then
        toggleStore()
        -- FIX CRÍTICO: Eliminado 'storeGui.Enabled = peek(isStoreOpen)'.
        -- Hacer esto rompía el 'Computed' de Fusion y mataba la reactividad de la GUI.
    end
end))

print("[StoreUI] Cargado correctamente")
