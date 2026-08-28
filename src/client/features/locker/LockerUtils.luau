--!strict
-- LockerUtils.luau (Client Feature Library)
-- Funciones utilitarias comunes para el vestuario (Locker) del cliente.

local LockerUtils = {}

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
