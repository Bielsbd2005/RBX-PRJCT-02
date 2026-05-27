--!strict

local RunService = game:GetService("RunService")

local KillEffectUtils = {}

-- Roblox's internal character controller forces CanCollide = false on dead
-- humanoid parts every physics step. This helper re-enforces CanCollide = true
-- each Stepped frame so the ragdoll doesn't clip through the floor.
-- Auto-disconnects after `duration` seconds or when the character is destroyed.
local ENFORCE_DURATION = 12

function KillEffectUtils.enforceCanCollide(parts: { BasePart }, char: Model)
	local conn: RBXScriptConnection? = nil
	local startAt = time()

	conn = RunService.Stepped:Connect(function()
		if time() - startAt > ENFORCE_DURATION or not char.Parent then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			return
		end
		for _, part in parts do
			if part.Parent and part.Name ~= "HumanoidRootPart" and not part.CanCollide then
				part.CanCollide = true
			end
		end
	end)
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
