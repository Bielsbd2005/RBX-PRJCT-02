--[[
	AdminConsole
	GUI de consola de administrador para ver y editar datos de jugadores.
	Se abre con F9. Solo funciona para admins (verificado por servidor).

	Ruta: StarterPlayerScripts > Client > AdminConsole
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

-- Fusion 0.3 imports
local Fusion = require(ReplicatedStorage.Packages.fusion)
local scoped = Fusion.scoped
local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local OnChange = Fusion.OnChange
local Value = Fusion.Value
local Computed = Fusion.Computed
local Spring = Fusion.Spring
local peek = Fusion.peek
local ForPairs = Fusion.ForPairs

-- Jugador local
local player = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Esperar a que existan los RemoteFunctions del admin
--------------------------------------------------------------------------------
local adminFolder = ReplicatedStorage:WaitForChild("AdminConsole", 10)
if not adminFolder then
	warn("[AdminConsole] No se encontraron los RemoteFunctions del admin")
	return
end

local isAdminRF = adminFolder:WaitForChild("IsAdmin")
local getPlayersRF = adminFolder:WaitForChild("GetPlayers")
local getPlayerDataRF = adminFolder:WaitForChild("GetPlayerData")
local updateDataRF = adminFolder:WaitForChild("UpdateData")

-- Verificar si somos admin
local isAdmin = isAdminRF:InvokeServer()
if not isAdmin then
	return -- No somos admin, no mostrar nada
end

print("[AdminConsole] Acceso de admin concedido para", player.Name)

--------------------------------------------------------------------------------
-- Colores y constantes
--------------------------------------------------------------------------------
local Colors = {
	Background = Color3.fromHex("#0d0d1a"),
	Panel = Color3.fromHex("#1a1a2e"),
	PanelLight = Color3.fromHex("#222240"),
	Accent = Color3.fromHex("#e94560"),
	AccentHover = Color3.fromHex("#ff6b81"),
	Green = Color3.fromHex("#2ecc71"),
	Red = Color3.fromHex("#e74c3c"),
	Yellow = Color3.fromHex("#f39c12"),
	Text = Color3.fromHex("#eaeaea"),
	TextDim = Color3.fromHex("#8888aa"),
	TextMuted = Color3.fromHex("#555577"),
	Border = Color3.fromHex("#2a2a4a"),
	InputBg = Color3.fromHex("#12122a"),
	Success = Color3.fromHex("#27ae60"),
}

local FONT_MONO = Font.new("rbxasset://fonts/families/RobotoMono.json")
local FONT_UI = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
local FONT_UI_BOLD = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)

--------------------------------------------------------------------------------
-- Scope y estado reactivo
--------------------------------------------------------------------------------
local scope = scoped(Fusion)

local isConsoleOpen = Value(scope, false)
local playerList = Value(scope, {})
local selectedPlayerId = Value(scope, nil)
local selectedPlayerName = Value(scope, "")
local selectedPlayerData = Value(scope, nil)
local statusMessage = Value(scope, "")
local statusColor = Value(scope, Colors.TextDim)

-- Tracking de cambios pendientes
local pendingChanges = {} -- { [path] = newValue }

--------------------------------------------------------------------------------
-- Funciones de datos
--------------------------------------------------------------------------------
local function refreshPlayerList()
	local ok, result = pcall(function()
		return getPlayersRF:InvokeServer()
	end)
	if ok and result then
		playerList:set(result)
	end
end

local function loadPlayerData(userId: number)
	local ok, result = pcall(function()
		return getPlayerDataRF:InvokeServer(userId)
	end)
	if ok and result then
		selectedPlayerData:set(result)
		pendingChanges = {}
	else
		selectedPlayerData:set(nil)
		statusMessage:set("Error al cargar datos")
		statusColor:set(Colors.Red)
	end
end

local function selectPlayer(userId: number, name: string)
	selectedPlayerId:set(userId)
	selectedPlayerName:set(name)
	statusMessage:set("Cargando datos...")
	statusColor:set(Colors.Yellow)
	loadPlayerData(userId)
	statusMessage:set("Datos cargados")
	statusColor:set(Colors.Green)
end

local function saveChange(path: string, value: any)
	local userId = peek(selectedPlayerId)
	if not userId then return end

	statusMessage:set("Guardando " .. path .. "...")
	statusColor:set(Colors.Yellow)

	local ok, result = pcall(function()
		return updateDataRF:InvokeServer(userId, path, value)
	end)

	if ok and result then
		statusMessage:set("✓ " .. path .. " guardado")
		statusColor:set(Colors.Green)
		-- Refrescar datos
		loadPlayerData(userId)
	else
		statusMessage:set("✗ Error al guardar " .. path)
		statusColor:set(Colors.Red)
	end
end

--------------------------------------------------------------------------------
-- Componentes UI
--------------------------------------------------------------------------------

--- Botón de jugador en la sidebar
local function PlayerButton(scope, props: { userId: number, name: string, displayName: string, hasData: boolean })
	local isHovered = Value(scope, false)
	local isSelected = Computed(scope, function(use)
		return use(selectedPlayerId) == props.userId
	end)

	return scope:New "TextButton" {
		Name = "Player_" .. props.userId,
		AutoButtonColor = false,
		BackgroundColor3 = Computed(scope, function(use)
			if use(isSelected) then return Colors.Accent end
			if use(isHovered) then return Colors.PanelLight end
			return Colors.Panel
		end),
		Size = UDim2.new(1, 0, 0, 50),
		Text = "",

		[OnEvent "MouseEnter"] = function()
			isHovered:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			isHovered:set(false)
		end,
		[OnEvent "Activated"] = function()
			selectPlayer(props.userId, props.name)
		end,

		[Children] = {
			scope:New "UICorner" { CornerRadius = UDim.new(0, 6) },
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, 12),
				PaddingRight = UDim.new(0, 12),
			},

			-- Indicador de estado
			scope:New "Frame" {
				Name = "StatusDot",
				AnchorPoint = Vector2.new(0, 0.5),
				BackgroundColor3 = props.hasData and Colors.Green or Colors.Red,
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.fromOffset(8, 8),
				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(1, 0) },
				},
			},

			-- Nombre
			scope:New "TextLabel" {
				Name = "Name",
				BackgroundTransparency = 1,
				FontFace = FONT_UI,
				Position = UDim2.fromOffset(20, 0),
				Size = UDim2.new(1, -24, 0.5, 0),
				Text = props.displayName,
				TextColor3 = Colors.Text,
				TextSize = 16,
				TextXAlignment = Enum.TextXAlignment.Left,
			},

			-- UserId
			scope:New "TextLabel" {
				Name = "UserId",
				BackgroundTransparency = 1,
				FontFace = FONT_MONO,
				Position = UDim2.new(0, 20, 0.5, 0),
				Size = UDim2.new(1, -24, 0.5, 0),
				Text = "ID: " .. tostring(props.userId),
				TextColor3 = Colors.TextMuted,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
			},
		},
	}
end

--- Campo editable para un valor de datos
local function DataField(scope, props: { path: string, label: string, value: any, depth: number })
	local currentValue = props.value
	local valueType = type(currentValue)
	local depth = props.depth or 0
	local inputText = Value(scope, tostring(currentValue))
	local isHovered = Value(scope, false)
	local isEdited = Value(scope, false)

	local function onSave()
		local raw = peek(inputText)
		local parsed

		if valueType == "number" then
			parsed = tonumber(raw)
			if not parsed then
				statusMessage:set("✗ Valor no numérico: " .. raw)
				statusColor:set(Colors.Red)
				return
			end
		elseif valueType == "boolean" then
			if string.lower(raw) == "true" then
				parsed = true
			elseif string.lower(raw) == "false" then
				parsed = false
			else
				statusMessage:set("✗ Usa true/false")
				statusColor:set(Colors.Red)
				return
			end
		else
			parsed = raw
		end

		isEdited:set(false)
		saveChange(props.path, parsed)
	end

	return scope:New "Frame" {
		Name = "Field_" .. props.label,
		BackgroundColor3 = Computed(scope, function(use)
			if use(isHovered) then return Colors.PanelLight end
			return Color3.new(0, 0, 0)
		end),
		BackgroundTransparency = Computed(scope, function(use)
			return use(isHovered) and 0.5 or 1
		end),
		Size = UDim2.new(1, 0, 0, 40),
		LayoutOrder = 0,

		[OnEvent "MouseEnter"] = function()
			isHovered:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			isHovered:set(false)
		end,

		[Children] = {
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, 12 + depth * 16),
				PaddingRight = UDim.new(0, 8),
			},

			-- Label (path)
			scope:New "TextLabel" {
				Name = "Label",
				BackgroundTransparency = 1,
				FontFace = FONT_MONO,
				Size = UDim2.fromScale(0.4, 1),
				Text = props.label,
				TextColor3 = Colors.TextDim,
				TextSize = 16,
				TextXAlignment = Enum.TextXAlignment.Left,
			},

			-- Type indicator
			scope:New "TextLabel" {
				Name = "Type",
				BackgroundTransparency = 1,
				FontFace = FONT_MONO,
				Position = UDim2.fromScale(0.4, 0),
				Size = UDim2.fromScale(0.1, 1),
				Text = valueType,
				TextColor3 = Colors.TextMuted,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
			},

			-- Input
			scope:New "TextBox" {
				Name = "Input",
				AnchorPoint = Vector2.new(1, 0.5),
				BackgroundColor3 = Colors.InputBg,
				Position = UDim2.new(0.82, 0, 0.5, 0),
				Size = UDim2.fromScale(0.3, 0.75),
				FontFace = FONT_MONO,
				Text = inputText,
				TextColor3 = Computed(scope, function(use)
					return use(isEdited) and Colors.Yellow or Colors.Text
				end),
				TextSize = 16,
				TextXAlignment = Enum.TextXAlignment.Left,
				ClearTextOnFocus = false,
				ClipsDescendants = true,

				[OnChange "Text"] = function(newText)
					inputText:set(newText)
					isEdited:set(newText ~= tostring(currentValue))
				end,

				[OnEvent "FocusLost"] = function(enterPressed)
					if enterPressed then
						onSave()
					end
				end,

				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(0, 4) },
					scope:New "UIPadding" {
						PaddingLeft = UDim.new(0, 6),
						PaddingRight = UDim.new(0, 6),
					},
				},
			},

			-- Save button (solo si hay cambios)
			scope:New "TextButton" {
				Name = "SaveBtn",
				AnchorPoint = Vector2.new(1, 0.5),
				BackgroundColor3 = Colors.Green,
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.fromOffset(50, 22),
				FontFace = FONT_UI_BOLD,
				Text = "SAVE",
				TextColor3 = Color3.new(1, 1, 1),
				TextSize = 13,
				Visible = isEdited,
				AutoButtonColor = false,

				[OnEvent "Activated"] = onSave,

				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(0, 4) },
				},
			},
		},
	}
end

--- Sección de encabezado para una categoría anidada
local function SectionHeader(scope, props: { name: string, depth: number })
	return scope:New "Frame" {
		Name = "Section_" .. props.name,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 34),
		LayoutOrder = 0,

		[Children] = {
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, 8 + (props.depth or 0) * 16),
			},

			scope:New "TextLabel" {
				Name = "SectionLabel",
				BackgroundTransparency = 1,
				FontFace = FONT_UI_BOLD,
				Size = UDim2.fromScale(1, 1),
				Text = "▸ " .. string.upper(props.name),
				TextColor3 = Colors.Accent,
				TextSize = 16,
				TextXAlignment = Enum.TextXAlignment.Left,
			},

			-- Línea divisora
			scope:New "Frame" {
				Name = "Divider",
				AnchorPoint = Vector2.new(0, 1),
				BackgroundColor3 = Colors.Border,
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.new(1, 0, 0, 1),
			},
		},
	}
end

--- Sección para tablas de inventario (muestra los items como lista)
local function ArrayField(scope, props: { path: string, label: string, items: { string }, depth: number })
	local itemsText = table.concat(props.items, ", ")
	if #props.items == 0 then
		itemsText = "(vacío)"
	end

	return scope:New "Frame" {
		Name = "Array_" .. props.label,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 40),
		LayoutOrder = 0,

		[Children] = {
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, 12 + (props.depth or 0) * 16),
				PaddingRight = UDim.new(0, 8),
			},

			scope:New "TextLabel" {
				Name = "Label",
				BackgroundTransparency = 1,
				FontFace = FONT_MONO,
				Size = UDim2.fromScale(0.35, 1),
				Text = props.label,
				TextColor3 = Colors.TextDim,
				TextSize = 16,
				TextXAlignment = Enum.TextXAlignment.Left,
			},

			scope:New "TextLabel" {
				Name = "Type",
				BackgroundTransparency = 1,
				FontFace = FONT_MONO,
				Position = UDim2.fromScale(0.35, 0),
				Size = UDim2.fromScale(0.1, 1),
				Text = "array[" .. #props.items .. "]",
				TextColor3 = Colors.TextMuted,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
			},

			scope:New "TextLabel" {
				Name = "Items",
				BackgroundTransparency = 1,
				FontFace = FONT_MONO,
				Position = UDim2.fromScale(0.5, 0),
				Size = UDim2.fromScale(0.5, 1),
				Text = itemsText,
				TextColor3 = Colors.Text,
				TextSize = 15,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			},
		},
	}
end

--- Campo para añadir un item a un array de inventario
local function AddItemField(scope, props: { path: string, currentItems: { string }, depth: number })
	local inputText = Value(scope, "")
	local isHovered = Value(scope, false)

	local function onAdd()
		local raw = peek(inputText)
		if raw == "" then
			statusMessage:set("✗ Escribe un nombre de item")
			statusColor:set(Colors.Red)
			return
		end

		-- Verificar si ya existe
		for _, item in props.currentItems do
			if item == raw then
				statusMessage:set("✗ El item '" .. raw .. "' ya existe")
				statusColor:set(Colors.Yellow)
				return
			end
		end

		-- Crear nueva tabla con el item añadido
		local newItems = {}
		for _, item in props.currentItems do
			table.insert(newItems, item)
		end
		table.insert(newItems, raw)

		inputText:set("")
		saveChange(props.path, newItems)
	end

	return scope:New "Frame" {
		Name = "AddItem_" .. props.path,
		BackgroundColor3 = Computed(scope, function(use)
			if use(isHovered) then return Colors.PanelLight end
			return Color3.new(0, 0, 0)
		end),
		BackgroundTransparency = Computed(scope, function(use)
			return use(isHovered) and 0.5 or 1
		end),
		Size = UDim2.new(1, 0, 0, 36),
		LayoutOrder = 0,

		[OnEvent "MouseEnter"] = function()
			isHovered:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			isHovered:set(false)
		end,

		[Children] = {
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, 12 + (props.depth or 0) * 16),
				PaddingRight = UDim.new(0, 8),
			},

			-- Label
			scope:New "TextLabel" {
				Name = "AddLabel",
				BackgroundTransparency = 1,
				FontFace = FONT_UI,
				Size = UDim2.fromScale(0.25, 1),
				Text = "+ Añadir item",
				TextColor3 = Colors.Green,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Left,
			},

			-- Input
			scope:New "TextBox" {
				Name = "AddInput",
				AnchorPoint = Vector2.new(0, 0.5),
				BackgroundColor3 = Colors.InputBg,
				Position = UDim2.new(0.25, 4, 0.5, 0),
				Size = UDim2.new(0.5, -8, 0, 26),
				FontFace = FONT_MONO,
				Text = inputText,
				PlaceholderText = "Nombre del item...",
				PlaceholderColor3 = Colors.TextMuted,
				TextColor3 = Colors.Text,
				TextSize = 14,
				ClearTextOnFocus = false,
				ClipsDescendants = true,

				[OnChange "Text"] = function(newText)
					inputText:set(newText)
				end,

				[OnEvent "FocusLost"] = function(enterPressed)
					if enterPressed then
						onAdd()
					end
				end,

				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(0, 4) },
					scope:New "UIPadding" {
						PaddingLeft = UDim.new(0, 6),
						PaddingRight = UDim.new(0, 6),
					},
				},
			},

			-- ADD button
			scope:New "TextButton" {
				Name = "AddBtn",
				AnchorPoint = Vector2.new(1, 0.5),
				BackgroundColor3 = Colors.Green,
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.fromOffset(55, 24),
				FontFace = FONT_UI_BOLD,
				Text = "ADD",
				TextColor3 = Color3.new(1, 1, 1),
				TextSize = 13,
				AutoButtonColor = false,

				[OnEvent "Activated"] = onAdd,

				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(0, 4) },
				},
			},
		},
	}
end

--- Campo para añadir un par clave-valor a un diccionario (ej: caseSpins)
local function AddDictField(scope, props: { path: string, currentData: { [string]: any }, depth: number })
	local inputKey = Value(scope, "")
	local inputValue = Value(scope, "")
	local isHovered = Value(scope, false)

	local function onAdd()
		local keyRaw = peek(inputKey)
		local valRaw = peek(inputValue)

		if keyRaw == "" or valRaw == "" then
			statusMessage:set("✗ Completa clave y valor")
			statusColor:set(Colors.Red)
			return
		end

		local numVal = tonumber(valRaw)
		if not numVal then
			statusMessage:set("✗ El valor debe ser numérico")
			statusColor:set(Colors.Red)
			return
		end

		-- Crear copia del diccionario y añadir
		local newData = {}
		for k, v in props.currentData do
			newData[k] = v
		end
		newData[keyRaw] = numVal

		inputKey:set("")
		inputValue:set("")
		saveChange(props.path, newData)
	end

	return scope:New "Frame" {
		Name = "AddDict_" .. props.path,
		BackgroundColor3 = Computed(scope, function(use)
			if use(isHovered) then return Colors.PanelLight end
			return Color3.new(0, 0, 0)
		end),
		BackgroundTransparency = Computed(scope, function(use)
			return use(isHovered) and 0.5 or 1
		end),
		Size = UDim2.new(1, 0, 0, 36),
		LayoutOrder = 99999, -- Que aparezca al final de la sección

		[OnEvent "MouseEnter"] = function()
			isHovered:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			isHovered:set(false)
		end,

		[Children] = {
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, 12 + (props.depth or 0) * 16),
				PaddingRight = UDim.new(0, 8),
			},

			-- Label
			scope:New "TextLabel" {
				Name = "AddLabel",
				BackgroundTransparency = 1,
				FontFace = FONT_UI,
				Size = UDim2.fromScale(0.20, 1),
				Text = "+ Clave: Valor",
				TextColor3 = Colors.Green,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Left,
			},

			-- Input Key
			scope:New "TextBox" {
				Name = "InputKey",
				AnchorPoint = Vector2.new(0, 0.5),
				BackgroundColor3 = Colors.InputBg,
				Position = UDim2.new(0.20, 4, 0.5, 0),
				Size = UDim2.new(0.35, -4, 0, 26),
				FontFace = FONT_MONO,
				Text = inputKey,
				PlaceholderText = "Mbox...",
				PlaceholderColor3 = Colors.TextMuted,
				TextColor3 = Colors.Text,
				TextSize = 14,
				ClearTextOnFocus = false,
				ClipsDescendants = true,

				[OnChange "Text"] = function(newText)
					inputKey:set(newText)
				end,

				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(0, 4) },
					scope:New "UIPadding" {
						PaddingLeft = UDim.new(0, 6),
						PaddingRight = UDim.new(0, 6),
					},
				},
			},

			-- Input Value
			scope:New "TextBox" {
				Name = "InputValue",
				AnchorPoint = Vector2.new(0, 0.5),
				BackgroundColor3 = Colors.InputBg,
				Position = UDim2.new(0.55, 4, 0.5, 0),
				Size = UDim2.new(0.25, -4, 0, 26),
				FontFace = FONT_MONO,
				Text = inputValue,
				PlaceholderText = "10",
				PlaceholderColor3 = Colors.TextMuted,
				TextColor3 = Colors.Text,
				TextSize = 14,
				ClearTextOnFocus = false,
				ClipsDescendants = true,

				[OnChange "Text"] = function(newText)
					inputValue:set(newText)
				end,

				[OnEvent "FocusLost"] = function(enterPressed)
					if enterPressed then
						onAdd()
					end
				end,

				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(0, 4) },
					scope:New "UIPadding" {
						PaddingLeft = UDim.new(0, 6),
						PaddingRight = UDim.new(0, 6),
					},
				},
			},

			-- ADD button
			scope:New "TextButton" {
				Name = "AddBtn",
				AnchorPoint = Vector2.new(1, 0.5),
				BackgroundColor3 = Colors.Green,
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.fromOffset(55, 24),
				FontFace = FONT_UI_BOLD,
				Text = "ADD",
				TextColor3 = Color3.new(1, 1, 1),
				TextSize = 13,
				AutoButtonColor = false,

				[OnEvent "Activated"] = onAdd,

				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(0, 4) },
				},
			},
		},
	}
end

--------------------------------------------------------------------------------
-- Construir panel de datos dinámicamente
--------------------------------------------------------------------------------
local function buildDataFields(scope, data, prefix, depth)
	local fields = {}
	depth = depth or 0
	prefix = prefix or ""

	-- Ordenar claves para consistencia
	local keys = {}
	for k in data do
		table.insert(keys, k)
	end
	table.sort(keys)

	for _, key in keys do
		local value = data[key]
		local path = prefix == "" and key or (prefix .. "." .. key)

		if type(value) == "table" then
			-- Verificar si es un array
			local isArray = true
			for k, _ in value do
				if type(k) ~= "number" then
					isArray = false
					break
				end
			end

			-- Tablas vacías se tratan como arrays EXCEPTO si es caseSpins o stats
			if next(value) == nil then
				if key == "caseSpins" or key == "stats" then
					isArray = false
				else
					isArray = true
				end
			end

			if isArray then
				-- Es un array: mostrar como lista
				table.insert(fields, ArrayField(scope, {
					path = path,
					label = key,
					items = value,
					depth = depth,
				}))

				-- Si es un array de inventario, añadir campo para agregar items
				if string.find(path, "^inventory%.") then
					table.insert(fields, AddItemField(scope, {
						path = path,
						currentItems = value,
						depth = depth + 1,
					}))
				end
			else
				-- Es un diccionario: sección recursiva
				table.insert(fields, SectionHeader(scope, {
					name = key,
					depth = depth,
				}))

				-- Añadir tool de insertar en dict para caseSpins y stats
				if key == "caseSpins" or key == "stats" then
					table.insert(fields, AddDictField(scope, {
						path = path,
						currentData = value,
						depth = depth + 1,
					}))
				end

				local subFields = buildDataFields(scope, value, path, depth + 1)
				for _, f in subFields do
					table.insert(fields, f)
				end
			end
		else
			-- Valor primitivo: campo editable
			table.insert(fields, DataField(scope, {
				path = path,
				label = key,
				value = value,
				depth = depth,
			}))
		end
	end

	return fields
end

--------------------------------------------------------------------------------
-- Panel izquierdo: lista de jugadores
--------------------------------------------------------------------------------
local function createPlayerListPanel(scope)
	return scope:New "Frame" {
		Name = "PlayerList",
		BackgroundColor3 = Colors.Panel,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(0, 220, 1, 0),

		[Children] = {
			scope:New "UICorner" { CornerRadius = UDim.new(0, 8) },

			-- Header
			scope:New "Frame" {
				Name = "Header",
				BackgroundColor3 = Colors.Accent,
				Size = UDim2.new(1, 0, 0, 40),

				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(0, 8) },
					-- Ocultar esquinas inferiores del header radius
					scope:New "Frame" {
						BackgroundColor3 = Colors.Accent,
						Position = UDim2.new(0, 0, 1, -8),
						Size = UDim2.new(1, 0, 0, 8),
					},

					scope:New "TextLabel" {
						Name = "Title",
						BackgroundTransparency = 1,
						FontFace = FONT_UI_BOLD,
						Size = UDim2.fromScale(1, 1),
						Text = "👥 PLAYERS",
						TextColor3 = Color3.new(1, 1, 1),
						TextSize = 16,
					},
				},
			},

			-- Botón refrescar
			scope:New "TextButton" {
				Name = "RefreshBtn",
				AnchorPoint = Vector2.new(1, 0),
				BackgroundColor3 = Colors.PanelLight,
				Position = UDim2.new(1, -8, 0, 48),
				Size = UDim2.new(1, -16, 0, 28),
				FontFace = FONT_UI,
				Text = "⟳ Refrescar",
				TextColor3 = Colors.TextDim,
				TextSize = 14,
				AutoButtonColor = false,

				[OnEvent "Activated"] = refreshPlayerList,

				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(0, 4) },
				},
			},

			-- ScrollFrame de jugadores
			scope:New "ScrollingFrame" {
				Name = "PlayerScroll",
				BackgroundTransparency = 1,
				Position = UDim2.new(0, 8, 0, 84),
				Size = UDim2.new(1, -16, 1, -92),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				CanvasSize = UDim2.fromScale(0, 0),
				ScrollBarThickness = 4,
				ScrollBarImageColor3 = Colors.TextMuted,
				TopImage = "",
				BottomImage = "",

				[Children] = {
					scope:New "UIListLayout" {
						Padding = UDim.new(0, 4),
						SortOrder = Enum.SortOrder.Name,
					},

					Computed(scope, function(use)
						local players = use(playerList)
						local buttons = {}
						for _, pData in players do
							table.insert(buttons, PlayerButton(scope, {
								userId = pData.UserId,
								name = pData.Name,
								displayName = pData.DisplayName,
								hasData = pData.HasData,
							}))
						end
						return buttons
					end),
				},
			},
		},
	}
end

--------------------------------------------------------------------------------
-- Panel derecho: datos del jugador
--------------------------------------------------------------------------------
local function createDataPanel(scope)
	return scope:New "Frame" {
		Name = "DataPanel",
		BackgroundColor3 = Colors.Panel,
		Position = UDim2.new(0, 228, 0, 0),
		Size = UDim2.new(1, -228, 1, 0),

		[Children] = {
			scope:New "UICorner" { CornerRadius = UDim.new(0, 8) },

			-- Header con nombre del jugador seleccionado
			scope:New "Frame" {
				Name = "Header",
				BackgroundColor3 = Colors.PanelLight,
				Size = UDim2.new(1, 0, 0, 40),

				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(0, 8) },
					scope:New "Frame" {
						BackgroundColor3 = Colors.PanelLight,
						Position = UDim2.new(0, 0, 1, -8),
						Size = UDim2.new(1, 0, 0, 8),
					},

					scope:New "TextLabel" {
						Name = "Title",
						BackgroundTransparency = 1,
						FontFace = FONT_UI_BOLD,
						Position = UDim2.fromOffset(16, 0),
						Size = UDim2.new(0.6, -16, 1, 0),
						Text = Computed(scope, function(use)
							local name = use(selectedPlayerName)
							if name == "" then
								return "📋 Selecciona un jugador"
							end
							return "📋 " .. name
						end),
						TextColor3 = Colors.Text,
						TextSize = 16,
						TextXAlignment = Enum.TextXAlignment.Left,
					},

					-- Botón de Reset
					scope:New "TextButton" {
						Name = "ResetBtn",
						AnchorPoint = Vector2.new(1, 0.5),
						BackgroundColor3 = Colors.Red,
						Position = UDim2.new(1, -12, 0.5, 0),
						Size = UDim2.fromOffset(110, 24),
						FontFace = FONT_UI_BOLD,
						Text = "⚠️ RESET DEFAULT",
						TextColor3 = Color3.new(1, 1, 1),
						TextSize = 11,
						AutoButtonColor = false,
						Visible = Computed(scope, function(use)
							return use(selectedPlayerId) ~= nil
						end),

						[OnEvent "Activated"] = function()
							local userId = peek(selectedPlayerId)
							if not userId then return end

							-- Simple confirm logic via status message for now
							statusMessage:set("Reseteando datos...")
							statusColor:set(Colors.Yellow)

							local resetDataRF = adminFolder:WaitForChild("ResetData", 5)
							if resetDataRF then
								local ok, msg = resetDataRF:InvokeServer(userId)
								if ok then
									statusMessage:set("✓ " .. msg)
									statusColor:set(Colors.Green)
									loadPlayerData(userId)
								else
									statusMessage:set("✗ " .. tostring(msg))
									statusColor:set(Colors.Red)
								end
							end
						end,

						[Children] = {
							scope:New "UICorner" { CornerRadius = UDim.new(0, 4) },
						},
					},

					-- Status message
					scope:New "TextLabel" {
						Name = "Status",
						BackgroundTransparency = 1,
						FontFace = FONT_MONO,
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.new(1, -135, 0, 0), -- Moved left of button
						Size = UDim2.new(0.4, 0, 1, 0),
						Text = statusMessage,
						TextColor3 = statusColor,
						TextSize = 14,
						TextXAlignment = Enum.TextXAlignment.Right,
					},
				},
			},

			-- ScrollFrame de campos de datos
			scope:New "ScrollingFrame" {
				Name = "DataScroll",
				BackgroundTransparency = 1,
				Position = UDim2.new(0, 0, 0, 44),
				Size = UDim2.new(1, 0, 1, -44),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				CanvasSize = UDim2.fromScale(0, 0),
				ScrollBarThickness = 6,
				ScrollBarImageColor3 = Colors.TextMuted,
				TopImage = "",
				BottomImage = "",

				[Children] = {
					scope:New "UIListLayout" {
						Padding = UDim.new(0, 2),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},

					Computed(scope, function(use)
						local data = use(selectedPlayerData)
						if not data then
							return {
								scope:New "TextLabel" {
									BackgroundTransparency = 1,
									Size = UDim2.new(1, 0, 0, 60),
									FontFace = FONT_UI,
									Text = "Selecciona un jugador para ver sus datos",
									TextColor3 = Colors.TextMuted,
									TextSize = 14,
								},
							}
						end
						return buildDataFields(scope, data, "", 0)
					end),
				},
			},
		},
	}
end

--------------------------------------------------------------------------------
-- ScreenGui principal
--------------------------------------------------------------------------------
local consoleYOffset = Spring(scope, Computed(scope, function(use)
	return use(isConsoleOpen) and 0 or 1.2
end), 25, 0.85)

local consoleGui = scope:New "ScreenGui" {
	Name = "AdminConsole",
	Parent = player.PlayerGui,
	DisplayOrder = 100,
	IgnoreGuiInset = true,
	ResetOnSpawn = false,

	[Children] = {
		-- Fondo oscuro semitransparente
		scope:New "Frame" {
			Name = "Overlay",
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = Spring(scope, Computed(scope, function(use)
				return use(isConsoleOpen) and 0.4 or 1
			end), 20, 1),
			Size = UDim2.fromScale(1, 1),
		},

		-- Contenedor principal que se anima
		scope:New "Frame" {
			Name = "ConsoleContainer",
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = Colors.Background,
			Position = Computed(scope, function(use)
				return UDim2.new(0.5, 0, 0.5 + use(consoleYOffset), 0)
			end),
			Size = UDim2.fromScale(0.75, 0.8),

			[Children] = {
				scope:New "UICorner" { CornerRadius = UDim.new(0, 12) },
				scope:New "UIStroke" {
					Color = Colors.Accent,
					Thickness = 2,
					Transparency = 0.5,
				},
				scope:New "UIPadding" {
					PaddingBottom = UDim.new(0, 8),
					PaddingLeft = UDim.new(0, 8),
					PaddingRight = UDim.new(0, 8),
					PaddingTop = UDim.new(0, 8),
				},

				-- Título de la consola
				scope:New "TextLabel" {
					Name = "ConsoleTitle",
					BackgroundTransparency = 1,
					Position = UDim2.fromOffset(8, -30),
					Size = UDim2.new(1, 0, 0, 24),
					FontFace = FONT_UI_BOLD,
					Text = "⚡ ADMIN CONSOLE",
					TextColor3 = Colors.Accent,
					TextSize = 14,
					TextXAlignment = Enum.TextXAlignment.Left,
				},

				-- Botón cerrar
				scope:New "TextButton" {
					Name = "CloseBtn",
					AnchorPoint = Vector2.new(1, 0),
					BackgroundColor3 = Colors.Red,
					Position = UDim2.new(1, 4, 0, -28),
					Size = UDim2.fromOffset(24, 24),
					FontFace = FONT_UI_BOLD,
					Text = "✕",
					TextColor3 = Color3.new(1, 1, 1),
					TextSize = 14,
					AutoButtonColor = false,

					[OnEvent "Activated"] = function()
						isConsoleOpen:set(false)
					end,

					[Children] = {
						scope:New "UICorner" { CornerRadius = UDim.new(0, 6) },
					},
				},

				-- Layout de paneles
				scope:New "Frame" {
					Name = "PanelsContainer",
					BackgroundTransparency = 1,
					Size = UDim2.fromScale(1, 1),

					[Children] = {
						createPlayerListPanel(scope),
						createDataPanel(scope),
					},
				},
			},
		},
	},
}

--------------------------------------------------------------------------------
-- Keybind: T para toggle
--------------------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.T then
		local willOpen = not peek(isConsoleOpen)
		isConsoleOpen:set(willOpen)
		if willOpen then
			refreshPlayerList()
		end
	end
end)

-- Cargar lista inicial
refreshPlayerList()

print("[AdminConsole] GUI de admin cargada — pulsa T para abrir")
