local KillEffectUtils = {}

function KillEffectUtils.anchor(char: Instance, anchored: boolean)
	for _, child in ipairs(char:GetChildren()) do
		if child:IsA("BasePart") then
			child.Anchored = anchored
		end
	end
end

function KillEffectUtils.destroyMotors(char: Instance)
	for _, desc in ipairs(char:GetDescendants()) do
		if desc:IsA("Motor6D") then
			desc:Destroy()
		end
	end
end

function KillEffectUtils.createBallJoint(att0: Attachment?, att1: Attachment?, limits: { UpperAngle: number }?)
	if not att0 or not att1 then
		return
	end

	local joint = Instance.new("BallSocketConstraint")
	joint.Attachment0 = att0
	joint.Attachment1 = att1
	joint.LimitsEnabled = true
	joint.UpperAngle = limits and limits.UpperAngle or 45
	joint.Parent = att0
end

function KillEffectUtils.createWeld(p0: BasePart?, p1: BasePart?)
	if not p0 or not p1 then
		return
	end

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = p0
	weld.Part1 = p1
	weld.Parent = p0
end

function KillEffectUtils.applyImpulse(part: BasePart, force: Vector3)
	if not part then
		return
	end
	part.AssemblyLinearVelocity = force
end

return KillEffectUtils
