--!strict

local AIConfig = require(script.Parent.AIConfig)

export type Side = "A" | "B"

export type NPCEntityType = {
	id: number,
	side: Side,
	name: string,
	model: Model?,
	destroy: (self: NPCEntityType, suppressDeathCallback: boolean?) -> (),
}

type OnDiedCallback = (Side, string) -> ()

type NPCEntityPrivate = NPCEntityType & {
	_humanoidDiedConn: RBXScriptConnection?,
	_deathCallback: OnDiedCallback?,
	_suppressDeathCallback: boolean,
}

local NPCEntity = {}
NPCEntity.__index = NPCEntity

local function _pickSpawnPoint(spawnPoints: { BasePart }): BasePart?
	if #spawnPoints == 0 then
		return nil
	end

	return spawnPoints[math.random(1, #spawnPoints)]
end

local function _resolveModelClone(template: Instance): Model?
	if template:IsA("Model") then
		return template:Clone()
	end

	for _, child in template:GetChildren() do
		if child:IsA("Model") then
			return child:Clone()
		end
	end

	return nil
end

function NPCEntity.new(id: number, side: Side, template: Instance, spawnPoints: { BasePart }, onDied: OnDiedCallback?): NPCEntityType?
	local model = _resolveModelClone(template)
	if not model then
		return nil
	end

	local self = setmetatable({} :: NPCEntityPrivate, NPCEntity)
	self.id = id
	self.side = side
	self.name = string.format("%s_%s_%03d", AIConfig.BotNamePrefix, side, id)
	self.model = model
	self._deathCallback = onDied
	self._humanoidDiedConn = nil
	self._suppressDeathCallback = false

	model.Name = self.name
	model:SetAttribute("IsBot", true)
	model:SetAttribute("BotTeam", side)

	local teamValue = model:FindFirstChild("TeamSide")
	if not teamValue then
		teamValue = Instance.new("StringValue")
		teamValue.Name = "TeamSide"
		teamValue.Parent = model
	end
	if teamValue:IsA("StringValue") then
		teamValue.Value = side
	end

	if not model.PrimaryPart then
		local rootPart = model:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") then
			model.PrimaryPart = rootPart
		end
	end

	local spawnPoint = _pickSpawnPoint(spawnPoints)
	if spawnPoint and model.PrimaryPart then
		model:PivotTo(spawnPoint.CFrame + Vector3.new(0, AIConfig.SpawnHeightOffset, 0))
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		self._humanoidDiedConn = humanoid.Died:Connect(function()
			if self._suppressDeathCallback then
				return
			end
			if self._deathCallback then
				self._deathCallback(self.side, self.name)
			end
		end)
	end

	model.Parent = workspace
	return self
end

function NPCEntity:destroy(suppressDeathCallback: boolean?)
	self._suppressDeathCallback = suppressDeathCallback == true

	if self._humanoidDiedConn then
		self._humanoidDiedConn:Disconnect()
		self._humanoidDiedConn = nil
	end

	if self.model then
		self.model:Destroy()
		self.model = nil
	end
end

return NPCEntity
