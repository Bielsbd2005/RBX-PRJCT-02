--!strict
-- LockerUtils.luau (Client Feature Library)
-- Funciones utilitarias comunes para el vestuario (Locker) del cliente.

local LockerUtils = {}

-- Contorno de los previews 3D: negro y sin relleno. Los valores son los del
-- personaje del lobby (LobbyCharacterPreview), para que una misma pieza se recorte
-- igual la mires donde la mires.
local PREVIEW_OUTLINE_NAME = "PreviewHighlight"
local PREVIEW_OUTLINE_COLOR = Color3.fromRGB(0, 0, 0)
local PREVIEW_OUTLINE_TRANSPARENCY = 0.1

-- Pinta el contorno sobre un preview (arma del locker, arma o body del pase).
-- Reutiliza el Highlight que el asset ya traiga en vez de amontonar otro: dos
-- Highlight sobre lo mismo se suman y el contorno sale más grueso de lo que toca.
-- La búsqueda es recursiva a propósito: el pase envuelve el arma en un Model
-- contenedor, así que un Highlight que venga dentro del asset queda un nivel más
-- abajo y una búsqueda de hijos directos no lo vería.
function LockerUtils.applyPreviewOutline(previewInstance: Instance)
	local existing = previewInstance:FindFirstChildWhichIsA("Highlight", true)
	local highlight: Highlight
	if existing then
		highlight = existing
	else
		highlight = Instance.new("Highlight")
		highlight.Name = PREVIEW_OUTLINE_NAME
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = previewInstance
	end

	-- Adornee explícito: el preview puede ser un Model o un BasePart suelto.
	if previewInstance:IsA("Model") or previewInstance:IsA("BasePart") then
		highlight.Adornee = previewInstance :: any
	end

	highlight.FillTransparency = 1
	highlight.FillColor = PREVIEW_OUTLINE_COLOR
	highlight.OutlineColor = PREVIEW_OUTLINE_COLOR
	highlight.OutlineTransparency = PREVIEW_OUTLINE_TRANSPARENCY
	highlight.Enabled = true
end

-- Animation cacheada por id: LoadAnimation copia la data del asset, así que
-- reutilizar la misma instancia evita crear y destruir un Instance por preview
-- (el locker rehace previews en cada cambio de selección).
local _animationById: { [string]: Animation } = {}

local function getIdleAnimation(animationId: string): Animation
	local cached = _animationById[animationId]
	if cached then
		return cached
	end

	local anim = Instance.new("Animation")
	anim.Name = "LockerPreviewIdle"
	anim.AnimationId = animationId
	_animationById[animationId] = anim
	return anim
end

function LockerUtils.placePreviewCharacter(previewModel: Model, spawnTarget: Instance)
	local humanoid = previewModel:FindFirstChildWhichIsA("Humanoid", true)
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	if not spawnTarget:IsA("BasePart") then
		previewModel:PivotTo(spawnTarget:GetPivot())
		return
	end

	local rootPart = previewModel:FindFirstChild("HumanoidRootPart", true)
	if rootPart and rootPart:IsA("BasePart") then
		local rootOffset = previewModel:GetPivot():ToObjectSpace(rootPart.CFrame)
		local targetPivot = (spawnTarget :: BasePart).CFrame * rootOffset:Inverse()
		previewModel:PivotTo(targetPivot)
		return
	end

	previewModel:MoveTo((spawnTarget :: BasePart).Position)
end

-- Reposiciona cada Part1 a la pose canónica del Motor6D
-- (Part0.CFrame * C0 * C1:Inverse). Si el template guardado en RS tiene partes
-- desplazadas físicamente (ej: Transform aplicado al guardar), el ragdoll aparece
-- deformado al destruir los Motor6Ds. 4 pasadas cubren la profundidad del rig R15
-- (HRP → LowerTorso → UpperTorso → extremidades → manos/pies).
function LockerUtils.snapPartsToCanonicalPose(char: Model)
	local motors = {}
	for _, m in char:GetDescendants() do
		if m:IsA("Motor6D") and m.Part0 and m.Part1 then
			table.insert(motors, m)
		end
	end
	for _ = 1, 4 do
		for _, m in motors do
			m.Part1.CFrame = m.Part0.CFrame * m.C0 * m.C1:Inverse()
		end
	end
end

function LockerUtils.playPreviewIdleAnimation(previewModel: Model, ownerJanitor: any, animationId: string)
	local animator = previewModel:FindFirstChildWhichIsA("Animator", true)
	if not animator then
		local humanoid = previewModel:FindFirstChildWhichIsA("Humanoid", true)
		if humanoid then
			animator = humanoid:FindFirstChildOfClass("Animator")
			if not animator then
				animator = Instance.new("Animator")
				animator.Parent = humanoid
			end
		else
			local animationController = previewModel:FindFirstChildWhichIsA("AnimationController", true)
			if not animationController then
				animationController = Instance.new("AnimationController")
				animationController.Name = "LockerPreviewAnimationController"
				animationController.Parent = previewModel
			end

			animator = animationController:FindFirstChildOfClass("Animator")
			if not animator then
				animator = Instance.new("Animator")
				animator.Parent = animationController
			end
		end
	end

	if not animator then
		return nil
	end

	local animationTrack = animator:LoadAnimation(getIdleAnimation(animationId))
	animationTrack.Name = "LockerPreviewIdle"
	animationTrack.Looped = true
	animationTrack.Priority = Enum.AnimationPriority.Idle
	animationTrack:Play(0.1)

	-- La Animation NO se destruye: vive en la cache compartida.
	ownerJanitor:Add(function()
		animationTrack:Stop(0.1)
		animationTrack:Destroy()
	end, true)

	return animationTrack
end

return LockerUtils
