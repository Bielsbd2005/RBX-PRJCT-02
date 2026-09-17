--!strict
--[[
	Animación del "pew" de cada arma. Estructura requerida en la Tool:
		Tool.PewPart.PewEffect.ImageLabel
	PewEffect.play(tool) es noop si falta. Llamadas repetidas reinician el tween (automáticas).

	Solo cliente: los cambios a GUIs en Workspace desde un LocalScript no replican, así
	que se invoca desde simulateFire, que ya corre en cada cliente cuando alguien dispara.
]]

local TweenService = game:GetService("TweenService")

local EXPAND_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CONTRACT_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Sine, Enum.EasingDirection.In)

local EXPAND_GOALS = {
	Size = UDim2.new(1.8, 0, 1.8, 0),
	ImageTransparency = 0,
	Rotation = 10,
}

local CONTRACT_GOALS = {
	Size = UDim2.new(0, 0, 0, 0),
	ImageTransparency = 1,
	Rotation = -10,
}

type State = {
	tween: Tween?,
	conn: RBXScriptConnection?,
}

-- Estado por ImageLabel y no de módulo: varias armas lo usan en paralelo.
local states: { [ImageLabel]: State } = {}

local function cancelState(state: State)
	if state.conn then
		state.conn:Disconnect()
		state.conn = nil
	end
	if state.tween then
		state.tween:Cancel()
		state.tween = nil
	end
end

local function findImageLabel(tool: Instance): ImageLabel?
	local pewPart = tool:FindFirstChild("PewPart")
	if not pewPart then return nil end
	local pewEffect = pewPart:FindFirstChild("PewEffect")
	if not pewEffect then return nil end
	local label = pewEffect:FindFirstChild("ImageLabel")
	if label and label:IsA("ImageLabel") then
		return label
	end
	return nil
end

local function ensureState(label: ImageLabel): State
	local existing = states[label]
	if existing then return existing end

	local state: State = { tween = nil, conn = nil }
	states[label] = state

	-- Liberar la entrada cuando la Tool se despawnea.
	label.AncestryChanged:Connect(function(_child, parent)
		if parent == nil then
			cancelState(state)
			states[label] = nil
		end
	end)

	return state
end

local PewEffect = {}

function PewEffect.play(tool: Instance)
	local label = findImageLabel(tool)
	if not label then return end

	local state = ensureState(label)
	cancelState(state)

	label.Visible = true
	label.Size = UDim2.new(0, 0, 0, 0)
	label.ImageTransparency = 1
	label.Rotation = -10

	local tweenUp = TweenService:Create(label, EXPAND_INFO, EXPAND_GOALS)
	local tweenDown = TweenService:Create(label, CONTRACT_INFO, CONTRACT_GOALS)

	state.tween = tweenUp
	state.conn = tweenUp.Completed:Connect(function()
		if state.conn then
			state.conn:Disconnect()
			state.conn = nil
		end

		state.tween = tweenDown
		state.conn = tweenDown.Completed:Connect(function()
			if state.conn then
				state.conn:Disconnect()
				state.conn = nil
			end
			state.tween = nil
			label.Visible = false
		end)
		tweenDown:Play()
	end)

	tweenUp:Play()
end

return PewEffect
