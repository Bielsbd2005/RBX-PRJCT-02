--!strict
--[[
	Gestiona `PlayerGui.Shadow`, el overlay que acompaña a los paneles del lobby.
	Dirigido por atributos: cada frame decide QUÉ capas enciende y de qué color.

	Estructura del overlay (StarterGui.Shadow):
		Shadow             ← ScreenGui (o Frame contenedor, siempre transparente)
		  Top              ← capa simple: se tiñe su BackgroundColor3 y se muestra
		  Center           ← capa compuesta:
		    CanvasGroup    ← se tiñe su BackgroundColor3; GroupTransparency desvanece
		                     el fondo y su contenido (imagen/gradiente) a la vez
		      Image        ← ImageLabel con el patrón (opcional; ver `*Pattern` abajo).
		                     Con ScaleType Tile se desplaza en diagonal sin fin
		                     mientras la capa está encendida (ver SCROLL_*).
		  Bottom           ← capa simple, igual que Top

	Una capa es COMPUESTA si tiene un hijo `CanvasGroup`; si no, se tiñe y desvanece
	el propio frame. Las tres son opcionales: la que no exista no se enciende.

	Atributos (se definen en Studio sobre el nodo que abre/cierra):
		ShadowTop    : Color3 | true
		ShadowCenter : Color3 | true
		ShadowBottom : Color3 | true
		ShadowTopPattern / ShadowCenterPattern / ShadowBottomPattern : string | number

	Cada atributo enciende SU capa mientras el nodo esté en pantalla, y son
	combinables entre nodos y capas.
	  • Color3 → muestra la capa con ese color.
	  • true   → muestra la capa con el color diseñado en Studio (sin teñir).

	`Shadow<Capa>Pattern` elige la imagen de `CanvasGroup.Image` en esa capa:
	"rbxassetid://123" o el id a secas (número o texto). No enciende la capa por sí
	solo, acompaña a su `Shadow<Capa>` en el mismo nodo. Sin él se ve la imagen
	montada en Studio.

	Dónde ponerlo (`nodo` es cualquiera de estos):
	  • una ScreenGui de PlayerGui — Menu, MatchHud, … — y entonces cuenta su
	    `Enabled`, que es como se abren y cierran (el Menu no usa `Visible`);
	  • un hijo directo de cualquier ScreenGui: los paneles de UserInterface
	    (Settings, Rewards, …), que cuentan por su `Visible`;
	  • un frame más adentro que ya traiga el atributo puesto en Studio.
	Un nodo cuenta como "en pantalla" solo si él, sus contenedores y su ScreenGui
	lo están, así que un frame dentro del Menu apagado no enciende nada.

	`ShadeColor` sigue valiendo como alias de `ShadowCenter` en paneles ya montados.

	Si dos nodos visibles piden la MISMA capa, gana el que se pinta encima
	(DisplayOrder de su ScreenGui y, dentro de una misma, ZIndex). Cada capa se
	resuelve por separado.

	Blur: solo lo arrastra la capa Center (la que oscurece la pantalla entera);
	Top/Bottom son decorativas.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any
local BlurController = require(script.Parent.BlurController)

local SHADOW_GUI_NAME = "Shadow"
local LEGACY_CENTER_ATTRIBUTE = "ShadeColor"
local BLUR_KEY = "Shade"
-- Solo se aplica si el overlay cuelga de la misma ScreenGui que los paneles, para
-- quedar detrás. Como ScreenGui propia manda su DisplayOrder de Studio.
local SHADE_ZINDEX = -1
local SHOW_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HIDE_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Desplazamiento infinito del patrón (`CanvasGroup.Image` en Tile): la imagen mide
-- su padre + una baldosa y avanza una baldosa por ciclo; el inicio es idéntico, así
-- que el salto no se ve. Se mueve a mano por frame y en Scale, no con tween de Offset:
-- Offset es entero y a pocos px/s avanza a saltos de píxel.
local SCROLL_TILE_SECONDS = 2.5

type LayerDef = {
	-- Nombre del hijo dentro de `Shadow` y raíz del atributo (`Shadow` .. key).
	key: string,
	attribute: string,
	pattern: string,
	-- Atributo antiguo que sigue encendiendo la capa (solo Center).
	legacy: string?,
	-- Si la capa arrastra el blur de fondo mientras está encendida.
	blur: boolean,
}

local LAYER_DEFS: { LayerDef } = {
	{ key = "Top", attribute = "ShadowTop", pattern = "ShadowTopPattern", legacy = nil, blur = false },
	{
		key = "Center",
		attribute = "ShadowCenter",
		pattern = "ShadowCenterPattern",
		legacy = LEGACY_CENTER_ATTRIBUTE,
		blur = true,
	},
	{ key = "Bottom", attribute = "ShadowBottom", pattern = "ShadowBottomPattern", legacy = nil, blur = false },
}

local WATCHED_ATTRIBUTES: { [string]: boolean } = {}
for _, def in LAYER_DEFS do
	WATCHED_ATTRIBUTES[def.attribute] = true
	WATCHED_ATTRIBUTES[def.pattern] = true
	if def.legacy then
		WATCHED_ATTRIBUTES[def.legacy] = true
	end
end

type Scroll = {
	image: ImageLabel,
	-- El CanvasGroup: su AbsoluteSize convierte los píxeles de la baldosa a Scale.
	container: GuiObject,
	tileX: number,
	tileY: number,
	-- Segundos dentro de la baldosa actual; se conserva al ocultar para reanudar.
	elapsed: number,
	connection: RBXScriptConnection?,
}

type Layer = {
	def: LayerDef,
	root: GuiObject,
	-- Recibe el color pedido por el panel y se desvanece: el CanvasGroup en una
	-- capa compuesta, el propio frame en una simple.
	surface: GuiObject,
	fadeProperty: string,
	-- Transparencia montada en Studio: la del estado visible.
	visibleTransparency: number,
	-- Color montado en Studio: el que se repone cuando el panel enciende la capa
	-- con `true` (sin color propio).
	designedColor: Color3,
	-- `CanvasGroup.Image` (solo capas compuestas) y la imagen montada en Studio, que
	-- se repone cuando el panel no pide patrón.
	image: ImageLabel?,
	designedImage: string,
	scroll: Scroll?,
	tween: Tween?,
	shown: boolean,
}

local ShadeController = {}

local function setNumberProperty(instance: Instance, property: string, value: number)
	local target: any = instance
	target[property] = value
end

-- X va de -tileX a 0 e Y de 0 a -tileY (hacia arriba a la derecha).
local function applyScroll(scroll: Scroll)
	local size = scroll.container.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end
	local phase = scroll.elapsed / SCROLL_TILE_SECONDS
	scroll.image.Position = UDim2.fromScale(-scroll.tileX * (1 - phase) / size.X, -scroll.tileY * phase / size.Y)
end

-- Solo con ScaleType Tile y TileSize en píxeles: si no, no hay baldosa con la que
-- cuadrar el bucle y la imagen se queda quieta.
local function buildScroll(image: ImageLabel, container: GuiObject): Scroll?
	local tileX = image.TileSize.X.Offset
	local tileY = image.TileSize.Y.Offset
	if image.ScaleType ~= Enum.ScaleType.Tile or tileX <= 0 or tileY <= 0 then
		return nil
	end

	image.Size = UDim2.new(1, tileX, 1, tileY)
	local scroll: Scroll = {
		image = image,
		container = container,
		tileX = tileX,
		tileY = tileY,
		elapsed = 0,
		connection = nil,
	}
	applyScroll(scroll)
	return scroll
end

local function startScroll(scroll: Scroll)
	if scroll.connection then
		return
	end
	scroll.connection = RunService.RenderStepped:Connect(function(dt: number)
		scroll.elapsed = (scroll.elapsed + dt) % SCROLL_TILE_SECONDS
		applyScroll(scroll)
	end)
end

local function stopScroll(scroll: Scroll)
	if scroll.connection then
		scroll.connection:Disconnect()
		scroll.connection = nil
	end
end

local function buildLayer(shadowRoot: Instance, def: LayerDef): Layer?
	local node = shadowRoot:FindFirstChild(def.key)
	if not (node and node:IsA("GuiObject")) then
		return nil
	end

	local canvas = node:FindFirstChild("CanvasGroup")
	local surface: GuiObject
	local fadeProperty: string
	local visibleTransparency: number
	local image: ImageLabel? = nil
	local scroll: Scroll? = nil
	if canvas and canvas:IsA("CanvasGroup") then
		-- GroupTransparency ya desvanece el BackgroundColor3 del propio grupo, así
		-- que no hace falta tocar su BackgroundTransparency.
		surface = canvas
		fadeProperty = "GroupTransparency"
		visibleTransparency = canvas.GroupTransparency
		local imageInst = canvas:FindFirstChild("Image")
		if imageInst and imageInst:IsA("ImageLabel") then
			image = imageInst
			scroll = buildScroll(imageInst, canvas)
		end
	else
		surface = node
		fadeProperty = "BackgroundTransparency"
		visibleTransparency = node.BackgroundTransparency
	end

	setNumberProperty(surface, fadeProperty, 1)
	node.Visible = false

	return {
		def = def,
		root = node,
		surface = surface,
		fadeProperty = fadeProperty,
		visibleTransparency = visibleTransparency,
		designedColor = surface.BackgroundColor3,
		image = image,
		designedImage = if image then image.Image else "",
		scroll = scroll,
		tween = nil,
		shown = false,
	}
end

function ShadeController.start(_menuController: any?): any
	local janitor = Janitor.new()

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui

	-- Se acepta también colgado de UserInterface por si se reagrupa en Studio.
	local shadowRoot: Instance? = playerGui:WaitForChild(SHADOW_GUI_NAME, 10)
	if not shadowRoot then
		shadowRoot = uiGui:FindFirstChild(SHADOW_GUI_NAME)
	end
	if not shadowRoot then
		warn("[ShadeController] No se encontró PlayerGui.Shadow — overlay deshabilitado.")
		return janitor
	end

	if shadowRoot:IsA("GuiObject") then
		shadowRoot.ZIndex = SHADE_ZINDEX
	end

	local layers: { Layer } = {}
	local missing: { string } = {}
	for _, def in LAYER_DEFS do
		local layer = buildLayer(shadowRoot, def)
		if layer then
			table.insert(layers, layer)
		else
			table.insert(missing, def.key)
		end
	end

	if #layers == 0 then
		warn("[ShadeController] Shadow no tiene ninguna capa (Top/Center/Bottom) — overlay deshabilitado.")
		return janitor
	end
	if #missing > 0 then
		warn(`[ShadeController] Capas de Shadow no encontradas: {table.concat(missing, ", ")} (los atributos que las pidan no harán nada).`)
	end

	local function cancelTween(layer: Layer)
		if layer.tween then
			layer.tween:Cancel()
			layer.tween = nil
		end
	end

	janitor:Add(function()
		for _, layer in layers do
			cancelTween(layer)
			if layer.scroll then
				stopScroll(layer.scroll)
			end
		end
		-- Soltar el blur si nos destruyen con el overlay activo (hot reload).
		BlurController.release(BLUR_KEY)
	end, true)

	local function tweenLayer(layer: Layer, info: TweenInfo, hidden: boolean): Tween
		cancelTween(layer)

		local target = if hidden then 1 else layer.visibleTransparency
		local tween = TweenService:Create(layer.surface, info, { [layer.fadeProperty] = target })
		layer.tween = tween
		tween:Play()
		return tween
	end

	-- `color` nil = el panel pidió la capa sin color propio (atributo `true`);
	-- `pattern` nil = sin `*Pattern`. En ambos casos se repone lo montado en Studio.
	local function showLayer(layer: Layer, color: Color3?, pattern: string?)
		layer.surface.BackgroundColor3 = color or layer.designedColor
		if layer.image then
			layer.image.Image = pattern or layer.designedImage
		end

		if layer.shown then
			return
		end
		layer.shown = true

		if layer.def.blur then
			BlurController.acquire(BLUR_KEY)
		end

		layer.root.Visible = true
		tweenLayer(layer, SHOW_INFO, false)
		-- Si ya corría (fade-out cancelado a medias), no hace nada.
		if layer.scroll then
			startScroll(layer.scroll)
		end
	end

	local function hideLayer(layer: Layer)
		if not layer.shown then
			return
		end
		layer.shown = false

		if layer.def.blur then
			BlurController.release(BLUR_KEY)
		end

		local tween = tweenLayer(layer, HIDE_INFO, true)
		tween.Completed:Once(function(state: Enum.PlaybackState)
			-- No ocultar si un showLayer() canceló este fade-out en el camino.
			if state == Enum.PlaybackState.Completed and not layer.shown then
				layer.root.Visible = false
				if layer.scroll then
					stopScroll(layer.scroll)
				end
			end
		end)
	end

	-- Un frame interior con el atributo solo se detecta en el escaneo inicial y en
	-- DescendantAdded: añadir el atributo en runtime solo funciona sobre ScreenGuis
	-- de PlayerGui y sus hijos directos.
	local tracked: { Instance } = {}
	local trackedConns: { [Instance]: { RBXScriptConnection } } = {}

	local function declaresAnyLayer(node: Instance): boolean
		for _, def in LAYER_DEFS do
			if node:GetAttribute(def.attribute) ~= nil then
				return true
			end
			if def.legacy and node:GetAttribute(def.legacy) ~= nil then
				return true
			end
		end
		return false
	end

	-- Un nodo destruido no llega a ninguna ScreenGui, así que deja de contar solo.
	local function isShowing(node: Instance): boolean
		local current: Instance? = node
		while current do
			if current:IsA("LayerCollector") then
				return current.Enabled
			end
			if current:IsA("GuiObject") and not current.Visible then
				return false
			end
			current = current.Parent
		end
		return false
	end

	-- Una ScreenGui pierde contra cualquier frame suyo (está debajo de todos).
	local function priorityOf(node: Instance): (number, number)
		if node:IsA("LayerCollector") then
			return node.DisplayOrder, -math.huge
		end
		local collector = node:FindFirstAncestorWhichIsA("LayerCollector")
		local order = if collector then collector.DisplayOrder else 0
		local zIndex = if node:IsA("GuiObject") then node.ZIndex else 0
		return order, zIndex
	end

	local function readRequest(node: Instance, def: LayerDef): (boolean, Color3?)
		local value = node:GetAttribute(def.attribute)
		if value == nil and def.legacy then
			value = node:GetAttribute(def.legacy)
		end

		if typeof(value) == "Color3" then
			return true, value :: Color3
		end
		if value == true then
			return true, nil
		end
		return false, nil
	end

	local function readPattern(node: Instance, def: LayerDef): string?
		local value = node:GetAttribute(def.pattern)
		if typeof(value) == "number" or (typeof(value) == "string" and tonumber(value) ~= nil) then
			return string.format("rbxassetid://%d", tonumber(value) :: number)
		end
		if typeof(value) == "string" and value ~= "" then
			return value
		end
		return nil
	end

	local function refresh()
		for _, layer in layers do
			local found = false
			local topOrder, topZIndex = -math.huge, -math.huge
			local topColor: Color3? = nil
			local topPattern: string? = nil

			for _, node in tracked do
				local wants, color = readRequest(node, layer.def)
				if not wants or not isShowing(node) then
					continue
				end
				local order, zIndex = priorityOf(node)
				if not found or order > topOrder or (order == topOrder and zIndex > topZIndex) then
					found = true
					topOrder, topZIndex = order, zIndex
					topColor = color
					topPattern = readPattern(node, layer.def)
				end
			end

			if found then
				showLayer(layer, topColor, topPattern)
			else
				hideLayer(layer)
			end
		end
	end

	-- El propio overlay no se sigue (encendería sus capas consigo mismo).
	local function isPanelHost(node: Instance): boolean
		if node == shadowRoot or node:IsDescendantOf(shadowRoot :: Instance) then
			return false
		end
		if node:IsA("LayerCollector") then
			return node.Parent == playerGui
		end
		if not node:IsA("GuiObject") then
			return false
		end
		local parent = node.Parent
		if parent and parent:IsA("LayerCollector") then
			return true
		end
		return declaresAnyLayer(node)
	end

	local function track(node: Instance)
		if trackedConns[node] or not isPanelHost(node) then
			return
		end

		local conns: { RBXScriptConnection } = {}
		local visibilityProperty = if node:IsA("LayerCollector") then "Enabled" else "Visible"
		-- El HUD y compañía cambian de visibilidad a todas horas: si el nodo no pide
		-- ninguna capa, su cambio no mueve el overlay y no hace falta re-evaluar.
		table.insert(
			conns,
			node:GetPropertyChangedSignal(visibilityProperty):Connect(function()
				if declaresAnyLayer(node) then
					refresh()
				end
			end)
		)
		table.insert(
			conns,
			node.AttributeChanged:Connect(function(attribute: string)
				if WATCHED_ATTRIBUTES[attribute] then
					refresh()
				end
			end)
		)

		trackedConns[node] = conns
		table.insert(tracked, node)
	end

	local function untrack(node: Instance)
		local conns = trackedConns[node]
		if not conns then
			return
		end
		for _, conn in conns do
			conn:Disconnect()
		end
		trackedConns[node] = nil
		local index = table.find(tracked, node)
		if index then
			table.remove(tracked, index)
		end
	end

	janitor:Add(function()
		for _, node in table.clone(tracked) do
			untrack(node)
		end
	end, true)

	for _, descendant in playerGui:GetDescendants() do
		track(descendant)
	end
	janitor:Add(playerGui.DescendantAdded:Connect(function(descendant: Instance)
		track(descendant)
		if trackedConns[descendant] then
			refresh()
		end
	end), "Disconnect")
	-- DescendantRemoving llega ANTES de desparentar: hay que sacarlo de `tracked` a
	-- mano o un panel destruido dejaría su capa encendida para siempre.
	janitor:Add(playerGui.DescendantRemoving:Connect(function(descendant: Instance)
		if trackedConns[descendant] then
			untrack(descendant)
			refresh()
		end
	end), "Disconnect")

	refresh()

	return janitor
end

return ShadeController
