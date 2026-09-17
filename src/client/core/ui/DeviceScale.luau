--!strict
--[[
	Escala por dispositivo (UIScale en la raíz del grupo) para GUIs medidas en
	OFFSETS sobre un viewport de diseño de 1920x1080.

	El Thickness de UIStroke NO lo escala el UIScale: hay que escalarlo aparte.

	El UIScale encoge desde el AnchorPoint: un contenedor a pantalla completa necesita
	AnchorPoint y Position (0.5, 0.5), o el contenido se va arriba a la izquierda.

	Roblox aplica UN UIScale por objeto, pero los de ancestro y descendiente se
	multiplican: por eso va en la raíz y los "pop" de los hijos siguen funcionando.
	Si el objeto ya trae un UIScale ajeno, `attach` avisa y no hace nada.
]]

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local SCALE_NODE_NAME = "DeviceScale"

local DEFAULT_REFERENCE = Vector2.new(1920, 1080)
-- 0 = tamaño fijo en píxeles, 1 = totalmente proporcional al viewport. Al 100% el
-- texto queda ilegible en teléfono (ratio ~0.4), por eso solo parte de la diferencia.
local DEFAULT_WEIGHT = 0.8
-- En táctil la pantalla se mira desde más lejos y el dedo tapa parte de la UI.
local DEFAULT_TOUCH_BOOST = 1.15
local DEFAULT_MIN = 0.5
local DEFAULT_MAX = 1.25

-- Misma heurística que TouchControlsController/BlurController: táctil "de
-- verdad" es el que no tiene ratón.
local IS_TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

export type DeviceScaleOptions = {
	reference: Vector2?,
	weight: number?,
	touchBoost: number?,
	min: number?,
	max: number?,
}

local DeviceScale = {}

--- Pública para quien necesite el número sin montar un UIScale (p. ej. el Thickness de un UIStroke).
function DeviceScale.compute(options: DeviceScaleOptions?): number
	local opts = options or {}
	local reference = opts.reference or DEFAULT_REFERENCE
	local weight = opts.weight or DEFAULT_WEIGHT
	local touchBoost = opts.touchBoost or DEFAULT_TOUCH_BOOST

	local camera = Workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.zero
	if viewport.X <= 0 or viewport.Y <= 0 or reference.X <= 0 or reference.Y <= 0 then
		-- Durante una transición la cámara puede reportar 0: dejamos el diseño base
		-- y ya reajustará el listener de ViewportSize.
		return 1
	end

	-- El MENOR de los dos ejes: así una GUI ancha tampoco se sale por los lados.
	local ratio = math.min(viewport.X / reference.X, viewport.Y / reference.Y)
	local scale = 1 + (weight * (ratio - 1))
	if IS_TOUCH then
		scale *= touchBoost
	end
	return math.clamp(scale, opts.min or DEFAULT_MIN, opts.max or DEFAULT_MAX)
end

--- Devuelve la función de limpieza para el janitor del llamante.
function DeviceScale.attach(target: GuiObject, options: DeviceScaleOptions?): () -> ()
	local existing = target:FindFirstChild(SCALE_NODE_NAME)
	local node: UIScale
	if existing and existing:IsA("UIScale") then
		node = existing
	else
		local foreign = target:FindFirstChildOfClass("UIScale")
		if foreign then
			warn(
				`[DeviceScale] {target:GetFullName()} ya tiene un UIScale ({foreign.Name}) y Roblox solo aplica uno: `
					.. "envuelve el contenido en un contenedor y engancha ahí la escala de dispositivo."
			)
			return function() end
		end
		node = Instance.new("UIScale")
		node.Name = SCALE_NODE_NAME
		node.Parent = target
	end

	local function apply()
		node.Scale = DeviceScale.compute(options)
	end

	-- CurrentCamera puede sustituirse (respawn, cinemáticas): se reengancha el listener
	-- de ViewportSize en cada cambio.
	local viewportConn: RBXScriptConnection? = nil
	local function watchViewport()
		if viewportConn then
			viewportConn:Disconnect()
			viewportConn = nil
		end
		local camera = Workspace.CurrentCamera
		if camera then
			viewportConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(apply)
		end
		apply()
	end

	local cameraConn = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchViewport)
	watchViewport()

	return function()
		cameraConn:Disconnect()
		if viewportConn then
			viewportConn:Disconnect()
			viewportConn = nil
		end
	end
end

return DeviceScale
