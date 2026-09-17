--!strict

local LockerUtils = {}

-- Deben coincidir con el contorno del personaje del lobby (LobbyCharacterPreview).
local PREVIEW_OUTLINE_NAME = "PreviewHighlight"
local PREVIEW_OUTLINE_COLOR = Color3.fromRGB(0, 0, 0)
local PREVIEW_OUTLINE_TRANSPARENCY = 0.1

-- Reutiliza el Highlight del asset: dos Highlight sobre lo mismo engordan el
-- contorno. Búsqueda recursiva porque el pase envuelve el arma en otro Model.
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

	if previewInstance:IsA("Model") or previewInstance:IsA("BasePart") then
		highlight.Adornee = previewInstance :: any
	end

	highlight.FillTransparency = 1
	highlight.FillColor = PREVIEW_OUTLINE_COLOR
	highlight.OutlineColor = PREVIEW_OUTLINE_COLOR
	highlight.OutlineTransparency = PREVIEW_OUTLINE_TRANSPARENCY
	highlight.Enabled = true
end

function LockerUtils.setPreviewHighlightsEnabled(previewInstance: Instance, enabled: boolean)
	if previewInstance:IsA("Highlight") then
		previewInstance.Enabled = enabled
	end

	for _, descendant in previewInstance:GetDescendants() do
		if descendant:IsA("Highlight") then
			descendant.Enabled = enabled
		end
	end
end

-- Animation compartida por id (el locker rehace previews en cada cambio de
-- selección); no se destruye con el preview.
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

-- Coloca el HumanoidRootPart en `target`. Versión por CFrame porque el podio de
-- Resultados solo guarda CFrames (el mapa ya puede estar desmontado; ver ResultsScene).
function LockerUtils.placePreviewCharacterAtCFrame(previewModel: Model, target: CFrame)
	local humanoid = previewModel:FindFirstChildWhichIsA("Humanoid", true)
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	local rootPart = previewModel:FindFirstChild("HumanoidRootPart", true)
	if rootPart and rootPart:IsA("BasePart") then
		local rootOffset = previewModel:GetPivot():ToObjectSpace(rootPart.CFrame)
		previewModel:PivotTo(target * rootOffset:Inverse())
		return
	end

	previewModel:MoveTo(target.Position)
end

function LockerUtils.placePreviewCharacter(previewModel: Model, spawnTarget: Instance)
	if spawnTarget:IsA("BasePart") then
		LockerUtils.placePreviewCharacterAtCFrame(previewModel, (spawnTarget :: BasePart).CFrame)
		return
	end

	local humanoid = previewModel:FindFirstChildWhichIsA("Humanoid", true)
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	previewModel:PivotTo(spawnTarget:GetPivot())
end

-- Si el template trae partes desplazadas (p.ej. Transform guardado), el ragdoll
-- sale deformado al destruir los Motor6D. 4 pasadas = profundidad del rig R15.
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

	local animationTrack = (animator :: Animator):LoadAnimation(getIdleAnimation(animationId))
	animationTrack.Name = "LockerPreviewIdle"
	animationTrack.Looped = true
	animationTrack.Priority = Enum.AnimationPriority.Idle
	animationTrack:Play(0.1)

	ownerJanitor:Add(function()
		animationTrack:Stop(0.1)
		animationTrack:Destroy()
	end, true)
end

return LockerUtils
