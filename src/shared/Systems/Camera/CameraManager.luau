local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting") -- Necesario para el efecto visual

local CameraManager = {}
local camera = Workspace.CurrentCamera

-- Configuración del efecto de desenfoque
local dof = Lighting:FindFirstChild("ShowcaseDOF") or Instance.new("DepthOfFieldEffect")
dof.Name = "ShowcaseDOF"
dof.Enabled = false
dof.FarIntensity = 1      -- Qué tan borroso está el fondo (0 a 1)
dof.FocusDistance = 20     -- Distancia al objeto (se ajustará dinámicamente)
dof.InFocusRadius = 0     -- Radio de nitidez alrededor del objeto
dof.NearIntensity = 0     -- No queremos que lo que está muy cerca esté borroso
dof.Parent = Lighting

local DEFAULT_TWEEN_INFO = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TRANSITION_OFFSET = CFrame.new(0, -5, 0)

function CameraManager.setTarget(targetPart, animated, tweenInfo, focusDistance)
	if not targetPart then
		CameraManager.reset()
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable
	local targetCF = targetPart.CFrame

	-- 1. Activamos el desenfoque
	dof.Enabled = true

	-- 2. Calculamos la distancia de enfoque
	-- Asumimos que el objeto está a unos 5-7 studs de la pieza de la cámara
	dof.FocusDistance = focusDistance or 16.66

	if animated then
		camera.CFrame = targetCF * TRANSITION_OFFSET
		local info = tweenInfo or DEFAULT_TWEEN_INFO

		-- Tween de la cámara
		TweenService:Create(camera, info, {CFrame = targetCF}):Play()

		-- Tween del efecto (aparece el desenfoque suavemente)
		dof.FarIntensity = 0
		TweenService:Create(dof, info, {FarIntensity = 1}):Play()
	else
		camera.CFrame = targetCF
		dof.FarIntensity = 1
	end
end

function CameraManager.reset(instant)
	camera.CameraType = Enum.CameraType.Custom

	if instant then
		dof.Enabled = false
		dof.FarIntensity = 0
		camera.FieldOfView = 70 -- Resetear FOV por defecto (o el valor que use tu juego)
	else
		-- Desvanecer el desenfoque antes de apagarlo
		local tween = TweenService:Create(dof, TweenInfo.new(0.5), {FarIntensity = 0})
		tween:Play()
		tween.Completed:Connect(function()
			dof.Enabled = false
		end)
	end
end

return CameraManager
