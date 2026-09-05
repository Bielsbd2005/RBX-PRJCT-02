--!strict
--[[
	WeaponStatsPanel.luau (Client)
	Vista + animación del panel de stats del arma seleccionada, con COMPARACIÓN
	contra el arma equipada, estilo shooter AAA.

	El panel ya NO vive en la GUI del locker: es un BillboardGui en el mundo
	(Workspace.Locker.Stats.Part.BillboardGui.WeaponStats), así que sólo debe
	verse mientras se previsualiza un arma. Quien lo monta decide cuándo
	mostrarlo (:setStats) y cuándo ocultarlo (:hide) — ocultar apaga el
	BillboardGui entero, no sólo el frame.

	Jerarquía esperada (autoría en Studio) — los CUATRO stats llevan barra:
		Workspace.Locker.Stats.Part.BillboardGui.WeaponStats
		  └─ <Stat>.Bar.{Fill, Delta}   +   los labels Value / Delta

	Los labels pueden colgar de un contenedor `<Stat>.Title` (Damage, Reload,
	FireRate) o directamente de `<Stat>` (Ammo, donde `Title` es el propio label
	del nombre): se resuelven en ambas formas.

	Cada `Bar` se descompone en dos tramos (delta bar):
	  • Fill  = tramo sólido = min(seleccionada, equipada) — lo compartido.
	  • Delta = tramo de la diferencia, posicionado al final de Fill, coloreado
	            VERDE si la seleccionada es mejor, ROJO si es peor (oculto si igual).
	El nodo `Title.Delta` (y `Ammo.Delta`) muestra el número "+N"/"−N" con el
	mismo color; "=" en blanco cuando no hay diferencia.

	Animaciones (:setStats):
	  • Value: count-up numérico + color y prefijo de dirección vs la equipada
	    ("+ X" mejor / "- X" peor / "X" igual; easeOutCubic).
	  • Fill / Delta: tween de Size/Position vía Retween (cancela el anterior).

	Resolución defensiva: si la UI no trae algún nodo, ese stat (o su delta)
	simplemente no se anima — el resto sigue funcionando.

	NOTA de layout: barras horizontales con AnchorPoint a la izquierda (Fill y
	Delta crecen por Size.X.Scale; Delta arranca en Position.X.Scale = min). Si
	en Studio crecen en otro eje, ajustar `applyBars`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Retween = require(Shared:WaitForChild("utils"):WaitForChild("Retween"))

local BAR_TWEEN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COUNT_UP_TIME = 0.45
local EPSILON = 1e-3

-- Colores del delta (barra y número). Equal usa blanco (sólo el número).
local COLOR_GAIN = Color3.fromRGB(90, 200, 120)
local COLOR_LOSS = Color3.fromRGB(232, 86, 86)
local COLOR_NEUTRAL = Color3.fromRGB(255, 255, 255)

local function colorForDir(dir: string): Color3
	if dir == "up" then
		return COLOR_GAIN
	elseif dir == "down" then
		return COLOR_LOSS
	end
	return COLOR_NEUTRAL
end

-- Prefijo del Value según la comparación: "+ " mejor, "- " peor, "" igual.
local function valuePrefixForDir(dir: string): string
	if dir == "up" then
		return "+ "
	elseif dir == "down" then
		return "- "
	end
	return ""
end

-- Formateadores del Value principal.
local function formatInt(n: number): string
	return tostring(math.floor(n + 0.5))
end

local function formatReload(n: number): string
	return string.format("%.1fs", n)
end

-- Formateadores del número delta (con signo; "=" cuando es ~0).
local function formatDeltaInt(d: number): string
	local r = math.floor(math.abs(d) + 0.5)
	if r == 0 then
		return "="
	end
	return (if d > 0 then "+" else "−") .. tostring(r)
end

local function formatDeltaReload(d: number): string
	local a = math.abs(d)
	if a < 0.05 then
		return "="
	end
	return (if d > 0 then "+" else "−") .. string.format("%.1fs", a)
end

-- Definición de cada stat: nodo bajo WeaponStats y sus formateadores. Todos
-- llevan barra; los que no traigan los nodos simplemente no la animan.
local STAT_DEFS = {
	{ key = "Damage", format = formatInt, formatDelta = formatDeltaInt },
	{ key = "Reload", format = formatReload, formatDelta = formatDeltaReload },
	{ key = "FireRate", format = formatInt, formatDelta = formatDeltaInt },
	{ key = "Ammo", format = formatInt, formatDelta = formatDeltaInt },
}

type StatNodes = {
	valueLabel: TextLabel?,
	deltaLabel: TextLabel?,
	fill: GuiObject?,
	deltaBar: GuiObject?,
	format: (number) -> string,
	formatDelta: (number) -> string,
	-- Estado de animación
	displayed: number, -- último valor mostrado (origen del próximo count-up)
	gen: number, -- generación del count-up activo (para cancelar el anterior)
	fillSlot: Retween.Slot,
	deltaSlot: Retween.Slot,
}

-- Modelo que recibe :setStats. fill/compareFill son 0..1.
-- delta = diferencia en unidades de stat (seleccionada − equipada). dir es la
-- "bondad": "up" mejor, "down" peor, "equal" igual — colorea barra y número.
export type StatValue = {
	value: number,
	fill: number,
	compareFill: number,
	delta: number,
	dir: string,
}
export type StatsModel = {
	Damage: StatValue?,
	Reload: StatValue?,
	FireRate: StatValue?,
	Ammo: StatValue?,
}

export type WeaponStatsPanel = {
	setStats: (self: WeaponStatsPanel, model: StatsModel) -> (),
	hide: (self: WeaponStatsPanel) -> (),
	Destroy: (self: WeaponStatsPanel) -> (),
}

local WeaponStatsPanel = {}
WeaponStatsPanel.__index = WeaponStatsPanel

local function resolveTextLabel(parent: Instance?, name: string): TextLabel?
	if not parent then
		return nil
	end
	local node = parent:FindFirstChild(name)
	return if node and node:IsA("TextLabel") then node else nil
end

local function resolveGuiObject(parent: Instance?, name: string): GuiObject?
	if not parent then
		return nil
	end
	local node = parent:FindFirstChild(name)
	return if node and node:IsA("GuiObject") then node else nil
end

-- easeOutCubic: arranca rápido y desacelera al llegar al objetivo.
local function easeOutCubic(t: number): number
	return 1 - (1 - t) ^ 3
end

-- Tramo sólido (min) + tramo delta (diferencia, coloreado por dir) de la barra.
local function applyBars(node: StatNodes, fill: number, compareFill: number, dir: string)
	local lo = math.clamp(math.min(fill, compareFill), 0, 1)
	local hi = math.clamp(math.max(fill, compareFill), 0, 1)

	local fillBar = node.fill
	if fillBar then
		local y = fillBar.Size.Y
		Retween.run(node.fillSlot, fillBar, BAR_TWEEN_INFO, {
			Size = UDim2.new(lo, 0, y.Scale, y.Offset),
		})
	end

	local deltaBar = node.deltaBar
	if deltaBar then
		if (hi - lo) < EPSILON or dir == "equal" then
			Retween.cancel(node.deltaSlot)
			deltaBar.Visible = false
		else
			deltaBar.BackgroundColor3 = colorForDir(dir)
			deltaBar.Visible = true
			-- El Delta ocupa TODO el ancho hasta `hi` (= Fill + el extra) arrancando
			-- en el mismo inicio que el Fill, y va DETRÁS de él: sólo asoma el tramo
			-- sobrante (lo..hi). Así la unión no tiene hueco aunque las esquinas
			-- sean redondeadas.
			local startScale, startOffset = 0, 0
			if fillBar then
				startScale = fillBar.Position.X.Scale
				startOffset = fillBar.Position.X.Offset
			end
			local sz = deltaBar.Size
			local pos = deltaBar.Position
			Retween.run(node.deltaSlot, deltaBar, BAR_TWEEN_INFO, {
				Position = UDim2.new(startScale, startOffset, pos.Y.Scale, pos.Y.Offset),
				Size = UDim2.new(hi, 0, sz.Y.Scale, sz.Y.Offset),
			})
		end
	end
end

-- Número delta "+N"/"−N"/"=" con color por dir.
local function applyDelta(node: StatNodes, delta: number, dir: string)
	local label = node.deltaLabel
	if not label then
		return
	end
	label.Text = node.formatDelta(delta)
	label.TextColor3 = colorForDir(dir)
end

-- `statsRoot` es el ancla del billboard en el mundo (Workspace.Locker.Stats):
-- dentro busca el BillboardGui y, dentro de él, el frame WeaponStats. Si falta
-- alguno, el panel queda inerte (todo el módulo es defensivo).
local function resolveStatsNodes(statsRoot: Instance?): (BillboardGui?, GuiObject?)
	if not statsRoot then
		return nil, nil
	end

	local billboard = if statsRoot:IsA("BillboardGui")
		then statsRoot :: BillboardGui
		else statsRoot:FindFirstChildWhichIsA("BillboardGui", true)
	if not billboard then
		return nil, nil
	end

	local frame = billboard:FindFirstChild("WeaponStats", true)
	return billboard, if frame and frame:IsA("GuiObject") then frame else nil
end

function WeaponStatsPanel.new(statsRoot: Instance?, janitor: any): WeaponStatsPanel
	local billboard, statsGui = resolveStatsNodes(statsRoot)
	if not statsGui then
		warn("[WeaponStatsPanel] No se encontró el BillboardGui con WeaponStats — el panel de stats no se mostrará")
	end

	local nodes: { [string]: StatNodes } = {}
	for _, def in STAT_DEFS do
		local container = if statsGui then statsGui:FindFirstChild(def.key) else nil

		-- Value/Delta cuelgan del contenedor `Title` cuando lo hay; si `Title` es
		-- el propio label del nombre del stat (Ammo), se buscan bajo el stat.
		local title = if container then container:FindFirstChild("Title") else nil
		local labelParent = if title and not title:IsA("TextLabel") then title else container
		local valueLabel = resolveTextLabel(labelParent, "Value") or resolveTextLabel(container, "Value")
		local deltaLabel = resolveTextLabel(labelParent, "Delta") or resolveTextLabel(container, "Delta")

		-- <Stat>.Bar.{Fill, Delta}
		local bar = if container then container:FindFirstChild("Bar") else nil
		local fill = resolveGuiObject(bar, "Fill")
		local deltaBar = resolveGuiObject(bar, "Delta")
		-- El Delta va DETRÁS del Fill: ocupa todo el ancho hasta `hi` y sólo
		-- asoma el tramo sobrante del Fill, así que debe quedar por debajo.
		if fill and deltaBar then
			deltaBar.ZIndex = fill.ZIndex - 1
		end

		nodes[def.key] = {
			valueLabel = valueLabel,
			deltaLabel = deltaLabel,
			fill = fill,
			deltaBar = deltaBar,
			format = def.format,
			formatDelta = def.formatDelta,
			displayed = 0,
			gen = 0,
			fillSlot = { current = nil },
			deltaSlot = { current = nil },
		}
	end

	local self = setmetatable({
		_billboard = billboard,
		_statsFrame = statsGui,
		_nodes = nodes,
		_alive = true,
	}, WeaponStatsPanel) :: any

	-- El billboard vive en el mundo: arranca apagado para que no asome en el
	-- lobby ni en las cámaras que no son la de armas.
	self:_setVisible(false)

	if janitor then
		janitor:Add(self, "Destroy")
	end

	return self
end

-- Apaga/enciende el BillboardGui entero (no basta con el frame: el billboard
-- seguiría ocupando y renderizando en el mundo).
function WeaponStatsPanel._setVisible(self: any, visible: boolean)
	if self._billboard then
		self._billboard.Enabled = visible
	end
	if self._statsFrame then
		self._statsFrame.Visible = visible
	end
end

-- Anima el Value de un stat desde su valor mostrado hasta `target`. `dir` colorea
-- el label y le pone el prefijo de dirección ("+ "/"- "/"") vs el arma equipada.
function WeaponStatsPanel._animateValue(self: any, node: StatNodes, target: number, dir: string)
	local label = node.valueLabel
	if not label then
		node.displayed = target
		return
	end

	label.TextColor3 = colorForDir(dir)
	local prefix = valuePrefixForDir(dir)

	local startValue = node.displayed
	local span = target - startValue

	-- Nueva generación: cancela cualquier count-up previo de este stat.
	node.gen += 1
	local myGen = node.gen

	if math.abs(span) < 1e-4 then
		label.Text = prefix .. node.format(target)
		node.displayed = target
		return
	end

	local startClock = os.clock()
	task.spawn(function()
		while true do
			if not self._alive or node.gen ~= myGen or not label.Parent then
				return -- superado por otro count-up, panel destruido o label fuera
			end
			local t = (os.clock() - startClock) / COUNT_UP_TIME
			if t >= 1 then
				label.Text = prefix .. node.format(target)
				node.displayed = target
				return
			end
			local current = startValue + span * easeOutCubic(t)
			label.Text = prefix .. node.format(current)
			task.wait()
		end
	end)
end

-- Muestra y anima los stats del arma. Sólo se animan los stats presentes en el
-- modelo; el resto se deja intacto.
function WeaponStatsPanel.setStats(self: any, model: StatsModel)
	if not self._alive then
		return
	end
	self:_setVisible(true)

	for _, def in STAT_DEFS do
		local stat = (model :: any)[def.key] :: StatValue?
		if stat then
			local node = self._nodes[def.key]
			self:_animateValue(node, stat.value, stat.dir)
			applyBars(node, stat.fill, stat.compareFill, stat.dir)
			applyDelta(node, stat.delta, stat.dir)
		end
	end
end

-- Oculta el panel y cancela animaciones en curso.
function WeaponStatsPanel.hide(self: any)
	self:_setVisible(false)
	for _, node in self._nodes do
		node.gen += 1 -- aborta count-up en curso
		Retween.cancel(node.fillSlot)
		Retween.cancel(node.deltaSlot)
	end
end

function WeaponStatsPanel.Destroy(self: any)
	self._alive = false
	self:_setVisible(false)
	for _, node in self._nodes do
		node.gen += 1
		Retween.cancel(node.fillSlot)
		Retween.cancel(node.deltaSlot)
	end
end

return WeaponStatsPanel
