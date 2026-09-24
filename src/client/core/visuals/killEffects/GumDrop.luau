--!strict
--[[
	Kill effect GumDrop, parte de cliente (Shared.Locker.killEffects.GumDrop posa el
	cuerpo y deja la gominola a tamaño final): la gominola crece desde su base con un
	rebote. Local para que sea fluido; quien llega tarde la ve ya entera.

	Sin Model:ScaleTo: escala respecto a la escala que el modelo cree tener, y una pieza
	que replicara a mitad de animación saldría multiplicada al restaurarla. Se toma una
	foto del estado final de cada pieza (con todas ya llegadas) y se interpola hacia ella.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local GumDrop = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Locker"):WaitForChild("killEffects"):WaitForChild("GumDrop")
)
local Types = require(script.Parent.Parent.KillEffectTypes)

local CONFIG = {
	GROW_TIME = 0.4, -- s
	START_SCALE = 0.05, -- fracción del tamaño final
	LATE_TOLERANCE = 0.3, -- s; quien llega más tarde no ve el crecimiento
	PARTS_TIMEOUT = 0.5, -- s esperando a que repliquen todas las piezas
}

type PartState = { part: BasePart, cframe: CFrame, size: Vector3 }
type MeshState = { mesh: SpecialMesh, scale: Vector3, offset: Vector3 }

local GumDropVisuals = {}

local function countParts(drop: Model): number
	local n = 0
	for _, desc in drop:GetDescendants() do
		if desc:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

-- true si llegaron todas a tiempo.
local function waitForParts(drop: Model): boolean
	local expected = drop:GetAttribute(GumDrop.ATTR_PARTS)
	if type(expected) ~= "number" then
		return true
	end
	local startedAt = os.clock()
	while countParts(drop) < expected do
		if os.clock() - startedAt > CONFIG.PARTS_TIMEOUT or not drop.Parent then
			return false
		end
		RunService.Heartbeat:Wait()
	end
	return true
end

local function grow(drop: Model, ctx: Types.Ctx)
	if not waitForParts(drop) then
		return
	end

	local parts: { PartState } = {}
	local meshes: { MeshState } = {}
	for _, desc in drop:GetDescendants() do
		if desc:IsA("BasePart") then
			table.insert(parts, { part = desc, cframe = desc.CFrame, size = desc.Size })
		elseif desc:IsA("SpecialMesh") then
			table.insert(meshes, { mesh = desc, scale = desc.Scale, offset = desc.Offset })
		end
	end
	-- Crece desde el centro de la cara de abajo de su caja: la base no se mueve.
	local boxCFrame, boxSize = drop:GetBoundingBox()
	local base = (boxCFrame * CFrame.new(0, -boxSize.Y / 2, 0)).Position

	local function setGrowth(k: number)
		for _, state in parts do
			local pos = base + (state.cframe.Position - base) * k
			state.part.Size = state.size * k
			state.part.CFrame = CFrame.new(pos) * state.cframe.Rotation
		end
		for _, state in meshes do
			state.mesh.Scale = state.scale * k
			state.mesh.Offset = state.offset * k
		end
	end

	setGrowth(CONFIG.START_SCALE)
	local startedAt = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		local alpha = (os.clock() - startedAt) / CONFIG.GROW_TIME
		if alpha >= 1 or not drop.Parent then
			(conn :: RBXScriptConnection):Disconnect()
			setGrowth(1)
			return
		end
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		setGrowth(CONFIG.START_SCALE + (1 - CONFIG.START_SCALE) * eased)
	end)
	ctx.add(conn :: RBXScriptConnection)
	-- Si el contexto termina a mitad (cadáver borrado), que no quede encogida.
	ctx.add(function()
		if drop.Parent then
			setGrowth(1)
		end
	end)
end

function GumDropVisuals.play(char: Model, ctx: Types.Ctx)
	if not ctx.isFresh(CONFIG.LATE_TOLERANCE) then
		return
	end
	local drop = char:FindFirstChild(GumDrop.DROP_NAME)
	if drop and drop:IsA("Model") then
		ctx.add(task.spawn(grow, drop, ctx))
	end
end

return GumDropVisuals
