--!strict
--[[
	Columna de la tienda medida por su ANCHO, para que escale igual en PC, móvil y tablet.

	Dentro de un ScrollingFrame, el Scale vertical se mide contra el canvas (que sale del
	alto de la pantalla) y el horizontal contra el ancho: si las filas miden su alto por
	el canvas y la columna su ancho por la pantalla, cada aspect ratio las descuadra.
	Por eso cada hijo directo de Content debe llevar un UIAspectRatioConstraint
	ScaleWithParentSize + DominantAxis Width, y aquí se fijan en píxeles el ancho de la
	columna, el hueco entre filas y el alto del canvas.
]]

local Client = script.Parent.Parent.Parent

local DeviceScale = require(Client.core.ui.DeviceScale)

-- Ancho de Content a 1920x1080 (su Size.X de Studio sobre 1920); DeviceScale lo
-- adapta al resto de pantallas.
local COLUMN_WIDTH_PX = 888
-- Tope para pantallas estrechas (móvil en vertical).
local MAX_COLUMN_FRACTION = 0.9
-- Hueco vertical / ancho de columna. En offset y no en Scale: el Scale de un
-- UIListLayout vertical va contra el alto de Content, que aquí depende del canvas.
local ROW_GAP_RATIO = 0.036

local StoreLayout = {}

-- GuiAnimator abre la tienda con un UIScale 0→1 y AbsoluteSize ya viene escalado,
-- mientras que los offsets que fijamos se vuelven a escalar al render: hay que medir
-- en píxeles sin escalar, o un recálculo a mitad del tween deja la columna pequeña.
local function accumulatedScale(gui: Instance): number
	local scale = 1
	local node: Instance? = gui
	while node and not node:IsA("LayerCollector") do
		local uiScale = node:FindFirstChildOfClass("UIScale")
		if uiScale then
			scale *= uiScale.Scale
		end
		node = node.Parent
	end
	return scale
end

--- Devuelve la función de limpieza para el janitor del llamante.
function StoreLayout.attach(storeFrame: GuiObject): () -> ()
	local contentNode = storeFrame:FindFirstChild("Content", true)
	local content = if contentNode and contentNode:IsA("GuiObject") then contentNode else nil
	local scroller = content and content:FindFirstAncestorWhichIsA("ScrollingFrame")
	local layout = content and content:FindFirstChildOfClass("UIListLayout")
	if not (content and scroller and layout) then
		warn("[StoreLayout] Falta ScrollingFrame/Content/UIListLayout bajo la tienda; se queda el layout de Studio.")
		return function() end
	end

	local heightSize = content.Size.Y
	content.AnchorPoint = Vector2.new(0.5, content.AnchorPoint.Y)
	content.Position = UDim2.new(0.5, 0, content.Position.Y.Scale, content.Position.Y.Offset)
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.None

	local gap = 0

	local function applyCanvas()
		local scale = accumulatedScale(scroller)
		if scale <= 0 then
			return
		end
		-- Al menos la ventana: con menos, el fondo de Container no llegaría abajo.
		local height = math.max(layout.AbsoluteContentSize.Y / scale + gap, scroller.AbsoluteSize.Y / scale)
		scroller.CanvasSize = UDim2.fromOffset(0, math.round(height))
	end

	local function applyColumn()
		local scale = accumulatedScale(scroller)
		local frameWidth = if scale > 0 then scroller.AbsoluteSize.X / scale else 0
		if frameWidth <= 0 then
			return
		end
		local width = math.round(math.min(COLUMN_WIDTH_PX * DeviceScale.compute(), frameWidth * MAX_COLUMN_FRACTION))
		gap = math.round(width * ROW_GAP_RATIO)
		content.Size = UDim2.new(UDim.new(0, width), heightSize)
		layout.Padding = UDim.new(0, gap)
		applyCanvas()
	end

	local connections = {
		scroller:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyColumn),
		layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(applyCanvas),
		-- Por si la ventana cambió de tamaño con la tienda cerrada.
		storeFrame:GetPropertyChangedSignal("Visible"):Connect(applyColumn),
	}
	applyColumn()

	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
	end
end

return StoreLayout
