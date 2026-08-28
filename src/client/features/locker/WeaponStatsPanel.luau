--!strict
--[[
	WeaponStatsPanel.luau (Client)
	Vista + animación del panel Locker.Stats (stats del arma seleccionada) con
	COMPARACIÓN contra el arma equipada, estilo shooter AAA.

	Jerarquía esperada (autoría en Studio):
		Locker.Stats
		  ├─ Damage.Bar.Fill   Damage.Bar.Delta   Damage.Title.Value   Damage.Title.Delta
		  ├─ Reload.Bar.Fill   Reload.Bar.Delta   Reload.Title.Value   Reload.Title.Delta
		  ├─ FireRate.Bar.Fill FireRate.Bar.Delta FireRate.Title.Value FireRate.Title.Delta
		  └─ Ammo.Value   Ammo.Delta            (sin barra)

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

-- Definición de cada stat: nodo bajo Stats, si tiene barra y los formateadores.
local STAT_DEFS = {
	{ key = "Damage", hasBar = true, format = formatInt, formatDelta = formatDeltaInt },
	{ key = "Reload", hasBar = true, format = formatReload, formatDelta = formatDeltaReload },
	{ key = "FireRate", hasBar = true, format = formatInt, formatDelta = formatDeltaInt },
	{ key = "Ammo", hasBar = false, format = formatInt, formatDelta = formatDeltaInt },
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

-- Modelo que recibe :setStats. fill/compareFill son 0..1 (Ammo no usa barra).
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

function WeaponStatsPanel.new(lockerFrame: Instance, janitor: any): WeaponStatsPanel
	-- Locker.WeaponStats: se renombró desde "Stats" cuando el Locker adoptó el HUD
	-- de monedas del Menu, que trae su propio nodo "Stats".
	local statsFrame = lockerFrame:FindFirstChild("WeaponStats")
	local statsGui = if statsFrame and statsFrame:IsA("GuiObject") then statsFrame else nil

	local nodes: { [string]: StatNodes } = {}
	for _, def in STAT_DEFS do
		local container = if statsGui then statsGui:FindFirstChild(def.key) else nil
		local valueLabel: TextLabel?
		local deltaLabel: TextLabel?
		local fill: GuiObject? = nil
		local deltaBar: GuiObject? = nil
		if def.hasBar then
			-- <Stat>.Title.{Value, Delta} y <Stat>.Bar.{Fill, Delta}
			local title = if container then container:FindFirstChild("Title") else nil
			local bar = if container then container:FindFirstChild("Bar") else nil
			valueLabel = resolveTextLabel(title, "Value")
			deltaLabel = resolveTextLabel(title, "Delta")
			fill = resolveGuiObject(bar, "Fill")
			deltaBar = resolveGuiObject(bar, "Delta")
			-- El Delta va DETRÁS del Fill: ocupa todo el ancho hasta `hi` y sólo
			-- asoma el tramo sobrante del Fill, así que debe quedar por debajo.
			if fill and deltaBar then
				deltaBar.ZIndex = fill.ZIndex - 1
			end
		else
			-- Ammo.Value y Ammo.Delta (directos)
			valueLabel = resolveTextLabel(container, "Value")
			deltaLabel = resolveTextLabel(container, "Delta")
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
		_statsFrame = statsGui,
		_nodes = nodes,
		_alive = true,
	}, WeaponStatsPanel) :: any

	if janitor then
		janitor:Add(self, "Destroy")
	end

	return self
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
	if self._statsFrame then
		self._statsFrame.Visible = true
	end

	for _, def in STAT_DEFS do
		local stat = (model :: any)[def.key] :: StatValue?
		if stat then
			local node = self._nodes[def.key]
			self:_animateValue(node, stat.value, stat.dir)
			if def.hasBar then
				applyBars(node, stat.fill, stat.compareFill, stat.dir)
			end
			applyDelta(node, stat.delta, stat.dir)
		end
	end
end

-- Oculta el panel y cancela animaciones en curso.
function WeaponStatsPanel.hide(self: any)
	if self._statsFrame then
		self._statsFrame.Visible = false
	end
	for _, node in self._nodes do
		node.gen += 1 -- aborta count-up en curso
		Retween.cancel(node.fillSlot)
		Retween.cancel(node.deltaSlot)
	end
end

function WeaponStatsPanel.Destroy(self: any)
	self._alive = false
	for _, node in self._nodes do
		node.gen += 1
		Retween.cancel(node.fillSlot)
		Retween.cancel(node.deltaSlot)
	end
end

return WeaponStatsPanel
