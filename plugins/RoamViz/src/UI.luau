--!strict
--[[
	UI — construye el panel del DockWidget con Instance.new (sin dependencias).

	Layout (vertical):
	  • Selector de mapa (lista scrollable; refrescable).
	  • Botones Generar / Limpiar.
	  • Toggles: Anillos de alcance · Puntos de spawn + orientación.
	  • Parámetros FUNCIONALES: RoamMinDist, RoamMaxDist, Máx. rutas.
	  • Rutas reales (PathfindingService): desde selección · malla · limpiar.
	  • Botón Aplicar (relee inputs → Config) que además regenera.

	TEMA: el panel sigue el tema de Roblox Studio (claro/oscuro) leyendo
	StudioTheme, y se re-colorea en vivo al cambiar de tema (Studio.ThemeChanged).
	El fondo del root es TRANSPARENTE: el DockWidget deja ver el fondo temeado
	nativo de Studio. Cada elemento registra un "aplicador" (on(fn)) que se corre al
	construir y en cada cambio de tema; así no hay colores hardcodeados.

	La apariencia del render 3D (marcadores/flechas) vive en Style.luau, aparte.

	La UI es "tonta": expone callbacks (onRegenerate, onClear, onSelectMap,
	onStateChanged) que el main cablea. No conoce Scanner ni Renderer.
]]

local Config = require(script.Parent.Config)

local UI = {}
UI.__index = UI

export type Callbacks = {
	onSelectMap: (mapRoot: Instance) -> (),
	onRegenerate: () -> (),
	onClear: () -> (),
	onRefreshMaps: () -> { Instance },
	onStateChanged: (state: Config.State) -> (),
	-- Preview de rutas reales (PathfindingService)
	onDrawFromSelected: () -> (), -- rutas desde el punto seleccionado a sus vecinos
	onDrawMesh: () -> (), -- malla podada (todos los pares ≤ RoamMaxDist)
	onClearPaths: () -> (), -- borra solo las rutas
}

export type UI = typeof(setmetatable(
	{} :: {
		_gui: DockWidgetPluginGui,
		_state: Config.State,
		_cb: Callbacks,
		_mapListFrame: ScrollingFrame,
		_selectedMap: Instance?,
		_statusLabel: TextLabel,
		_themeRefs: { () -> () }, -- aplicadores de color, se corren en cada ThemeChanged
		_themeConn: RBXScriptConnection?,
	},
	UI
))

-- ---- tema de Studio --------------------------------------------------------

local Studio = settings().Studio
local SG = Enum.StudioStyleGuideColor
local MOD = Enum.StudioStyleGuideModifier

-- Color del tema ACTUAL de Studio (se relee Studio.Theme en cada llamada, así
-- tras ThemeChanged devuelve ya el tema nuevo).
local function themeColor(styleColor: EnumItem, modifier: EnumItem?): Color3
	return Studio.Theme:GetColor(styleColor, modifier or MOD.Default)
end

-- `on` (inyectado a cada helper) registra un aplicador de color y lo corre ya.
type OnTheme = (apply: () -> ()) -> ()

-- ---- helpers de construcción -----------------------------------------------

local function makeLabel(on: OnTheme, parent: Instance, text: string, order: number): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.new(1, -12, 0, 18)
	lbl.Font = Enum.Font.GothamMedium
	lbl.TextSize = 12
	on(function()
		lbl.TextColor3 = themeColor(SG.DimmedText)
	end)
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = text
	lbl.LayoutOrder = order
	lbl.Parent = parent
	return lbl
end

local function makeButton(on: OnTheme, parent: Instance, text: string, order: number, accent: boolean?): TextButton
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, -12, 0, 30)
	on(function()
		btn.BackgroundColor3 = themeColor(if accent then SG.DialogMainButton else SG.Button)
		btn.TextColor3 = themeColor(if accent then SG.DialogMainButtonText else SG.ButtonText)
	end)
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 13
	btn.Text = text
	btn.AutoButtonColor = true
	btn.LayoutOrder = order
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn
	btn.Parent = parent
	return btn
end

-- input etiquetado en una fila (label a la izq, TextBox a la der)
local function makeInput(on: OnTheme, parent: Instance, labelText: string, initial: string, order: number): TextBox
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -12, 0, 26)
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Parent = parent

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.new(0.55, 0, 1, 0)
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 12
	on(function()
		lbl.TextColor3 = themeColor(SG.MainText)
	end)
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = labelText
	lbl.Parent = row

	local box = Instance.new("TextBox")
	box.Size = UDim2.new(0.45, 0, 1, -2)
	box.Position = UDim2.new(0.55, 0, 0, 1)
	on(function()
		box.BackgroundColor3 = themeColor(SG.InputFieldBackground)
		box.TextColor3 = themeColor(SG.MainText)
	end)
	box.BorderSizePixel = 0
	box.Font = Enum.Font.Code
	box.TextSize = 12
	box.ClearTextOnFocus = false
	box.Text = initial
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = box
	box.Parent = row

	return box
end

-- toggle on/off con checkbox textual. Su aplicador de color lee el estado, así
-- refleja on/off y sigue el tema a la vez.
local function makeToggle(
	on: OnTheme,
	parent: Instance,
	label: string,
	order: number,
	getValue: () -> boolean,
	onClick: () -> ()
): ()
	local btn = makeButton(on, parent, "", order)
	local function refresh()
		local isOn = getValue()
		btn.Text = (isOn and "☑ " or "☐ ") .. label
		btn.BackgroundColor3 = if isOn then themeColor(SG.Item, MOD.Selected) else themeColor(SG.Button)
		btn.TextColor3 = themeColor(SG.ButtonText)
	end
	on(refresh)
	btn.MouseButton1Click:Connect(function()
		onClick()
		refresh()
	end)
end

-- ---- construcción ----------------------------------------------------------

function UI.new(gui: DockWidgetPluginGui, state: Config.State, callbacks: Callbacks): UI
	local self = setmetatable({
		_gui = gui,
		_state = state,
		_cb = callbacks,
		_selectedMap = nil,
		_themeRefs = {},
	}, UI) :: UI

	-- registra un aplicador de color y lo corre ya (y luego en cada ThemeChanged)
	local function on(apply: () -> ())
		table.insert(self._themeRefs, apply)
		apply()
	end

	-- root scrollable — fondo TRANSPARENTE (deja ver el fondo temeado del DockWidget)
	local root = Instance.new("ScrollingFrame")
	root.Size = UDim2.new(1, 0, 1, 0)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.ScrollBarThickness = 6
	on(function()
		root.ScrollBarImageColor3 = themeColor(SG.ScrollBar)
	end)
	root.CanvasSize = UDim2.new(0, 0, 0, 0)
	root.AutomaticCanvasSize = Enum.AutomaticSize.Y
	root.Parent = gui

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = root

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	-- título
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -12, 0, 22)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 15
	on(function()
		title.TextColor3 = themeColor(SG.MainText)
	end)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "RoamViz — navegación + spawns"
	title.LayoutOrder = nextOrder()
	title.Parent = root

	-- selector de mapa
	makeLabel(on, root, "MAPA (Workspace/Maps/*/AINav/RoamPoints)", nextOrder())

	local mapList = Instance.new("ScrollingFrame")
	mapList.Size = UDim2.new(1, -12, 0, 90)
	on(function()
		mapList.BackgroundColor3 = themeColor(SG.ScrollBarBackground)
		mapList.ScrollBarImageColor3 = themeColor(SG.ScrollBar)
	end)
	mapList.BorderSizePixel = 0
	mapList.ScrollBarThickness = 5
	mapList.CanvasSize = UDim2.new(0, 0, 0, 0)
	mapList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	mapList.LayoutOrder = nextOrder()
	local mlCorner = Instance.new("UICorner")
	mlCorner.CornerRadius = UDim.new(0, 6)
	mlCorner.Parent = mapList
	local mlLayout = Instance.new("UIListLayout")
	mlLayout.Padding = UDim.new(0, 2)
	mlLayout.SortOrder = Enum.SortOrder.LayoutOrder
	mlLayout.Parent = mapList
	mapList.Parent = root
	self._mapListFrame = mapList

	local refreshBtn = makeButton(on, root, "↻ Refrescar mapas", nextOrder())
	refreshBtn.MouseButton1Click:Connect(function()
		self:_populateMaps()
	end)

	-- acciones
	local regenBtn = makeButton(on, root, "► Generar / Actualizar", nextOrder(), true)
	regenBtn.MouseButton1Click:Connect(function()
		self._cb.onRegenerate()
	end)

	local clearBtn = makeButton(on, root, "✕ Limpiar", nextOrder())
	clearBtn.MouseButton1Click:Connect(function()
		self._cb.onClear()
	end)

	-- toggles de qué se dibuja (redibujan al instante)
	makeToggle(on, root, "Anillos de alcance (selección)", nextOrder(), function()
		return self._state.showRings
	end, function()
		self._state.showRings = not self._state.showRings
		self._cb.onStateChanged(self._state)
		self._cb.onRegenerate()
	end)

	makeToggle(on, root, "Puntos de spawn + orientación", nextOrder(), function()
		return self._state.showSpawns
	end, function()
		self._state.showSpawns = not self._state.showSpawns
		self._cb.onStateChanged(self._state)
		self._cb.onRegenerate()
	end)

	-- parámetros funcionales (no apariencia): definen el picking y el tope
	makeLabel(on, root, "PARÁMETROS", nextOrder())
	local minBox = makeInput(on, root, "RoamMinDist", tostring(state.roamMinDist), nextOrder())
	local maxBox = makeInput(on, root, "RoamMaxDist", tostring(state.roamMaxDist), nextOrder())
	local maxPathsBox = makeInput(on, root, "Máx. rutas (malla)", tostring(state.maxPaths), nextOrder())

	-- ── rutas reales (pathfinding) ──
	makeLabel(on, root, "RUTAS REALES (PathfindingService)", nextOrder())
	local fromSelBtn = makeButton(on, root, "➤ Rutas desde punto seleccionado", nextOrder())
	fromSelBtn.MouseButton1Click:Connect(function()
		self._cb.onDrawFromSelected()
	end)

	local meshBtn = makeButton(on, root, "⛬ Malla de rutas (≤ RoamMax)", nextOrder())
	meshBtn.MouseButton1Click:Connect(function()
		self._cb.onDrawMesh()
	end)

	local clearPathsBtn = makeButton(on, root, "✕ Limpiar solo rutas", nextOrder())
	clearPathsBtn.MouseButton1Click:Connect(function()
		self._cb.onClearPaths()
	end)

	local applyBtn = makeButton(on, root, "✓ Aplicar y regenerar", nextOrder(), true)
	applyBtn.MouseButton1Click:Connect(function()
		self._state.roamMinDist = math.max(0, tonumber(minBox.Text) or self._state.roamMinDist)
		self._state.roamMaxDist = math.max(self._state.roamMinDist, tonumber(maxBox.Text) or self._state.roamMaxDist)
		self._state.maxPaths = math.max(1, math.floor(tonumber(maxPathsBox.Text) or self._state.maxPaths))

		-- normalizar campos a los valores efectivos
		minBox.Text = tostring(self._state.roamMinDist)
		maxBox.Text = tostring(self._state.roamMaxDist)
		maxPathsBox.Text = tostring(self._state.maxPaths)

		self._cb.onStateChanged(self._state)
		self._cb.onRegenerate()
	end)

	-- status
	local status = Instance.new("TextLabel")
	status.BackgroundTransparency = 1
	status.Size = UDim2.new(1, -12, 0, 34)
	status.Font = Enum.Font.Gotham
	status.TextSize = 11
	status.TextWrapped = true
	on(function()
		status.TextColor3 = themeColor(SG.DimmedText)
	end)
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextYAlignment = Enum.TextYAlignment.Top
	status.Text = "Sin mapa seleccionado."
	status.LayoutOrder = nextOrder()
	status.Parent = root
	self._statusLabel = status

	-- Re-colorear en vivo al cambiar el tema de Studio.
	self._themeConn = Studio.ThemeChanged:Connect(function()
		self:_applyTheme()
		self:_populateMaps() -- las filas de mapa se reconstruyen con el tema nuevo
	end)

	self:_populateMaps()
	return self
end

-- Re-corre todos los aplicadores de color con el tema actual.
function UI:_applyTheme()
	for _, apply in self._themeRefs do
		apply()
	end
end

-- Rellena la lista de mapas. Selecciona el primero si no hay selección.
function UI:_populateMaps()
	self._mapListFrame:ClearAllChildren()
	local mlLayout = Instance.new("UIListLayout")
	mlLayout.Padding = UDim.new(0, 2)
	mlLayout.SortOrder = Enum.SortOrder.LayoutOrder
	mlLayout.Parent = self._mapListFrame

	local maps = self._cb.onRefreshMaps()
	if #maps == 0 then
		self:setStatus("No se encontró ningún Workspace/Maps/*/AINav/RoamPoints.")
	end

	-- si el mapa seleccionado ya no existe, resetear
	local stillValid = false
	for _, m in maps do
		if m == self._selectedMap then
			stillValid = true
			break
		end
	end
	if not stillValid then
		self._selectedMap = nil
	end

	local order = 0
	for _, mapRoot in maps do
		order += 1
		local selected = mapRoot == self._selectedMap
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1, -4, 0, 24)
		btn.BackgroundColor3 = if selected then themeColor(SG.Item, MOD.Selected) else themeColor(SG.Item)
		btn.BorderSizePixel = 0
		btn.Font = Enum.Font.Gotham
		btn.TextSize = 12
		btn.TextColor3 = themeColor(SG.MainText, if selected then MOD.Selected else MOD.Default)
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.Text = "  " .. mapRoot.Name
		btn.LayoutOrder = order
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 4)
		c.Parent = btn
		btn.Parent = self._mapListFrame

		btn.MouseButton1Click:Connect(function()
			self._selectedMap = mapRoot
			self:_populateMaps() -- re-render para reflejar highlight
			self._cb.onSelectMap(mapRoot)
		end)
	end
end

function UI:getSelectedMap(): Instance?
	return self._selectedMap
end

function UI:setStatus(text: string)
	self._statusLabel.Text = text
end

-- Desconecta el listener de tema (al descargar el plugin).
function UI:destroy()
	if self._themeConn then
		self._themeConn:Disconnect()
		self._themeConn = nil
	end
end

return UI
