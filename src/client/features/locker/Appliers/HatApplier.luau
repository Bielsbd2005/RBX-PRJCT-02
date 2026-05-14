--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LockerConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("LockerConfig"))
local LockerCategory = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("LockerCategory"))

local HatApplier = {}
HatApplier.__index = HatApplier

type HatApplier = {
	_model: Model,
	_itemsConfig: any,
	_hatsFolder: Folder?,
	GetHatsFolder: (self: HatApplier) -> Folder?,
	Clear: (self: HatApplier) -> (),
	Apply: (self: HatApplier, itemData: any) -> (),
	ApplyItemId: (self: HatApplier, itemId: string?) -> (),
	Reset: (self: HatApplier) -> (),
}

local function resolveHatsFolder(): Folder?
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	if not shared then
		return nil
	end

	local locker = shared:FindFirstChild("Locker")
	if locker and locker:IsA("Folder") then
		local hats = locker:FindFirstChild("Hats")
		if hats and hats:IsA("Folder") then
			return hats
		end
	end

	local systems = shared:FindFirstChild("Systems")
	if systems and systems:IsA("Folder") then
		local systemsLocker = systems:FindFirstChild("Locker")
		if systemsLocker and systemsLocker:IsA("Folder") then
			local systemsHats = systemsLocker:FindFirstChild("Hats")
			if systemsHats and systemsHats:IsA("Folder") then
				return systemsHats
			end
		end
	end

	return nil
end

local function getHatAttachmentFromHandle(handle: BasePart): Attachment?
	for _, child in handle:GetChildren() do
		if child:IsA("Attachment") then
			return child
		end
	end

	return nil
end

function HatApplier.new(model: Model, itemsConfig: any): HatApplier
	local self = setmetatable({}, HatApplier) :: any
	self._model = model
	self._itemsConfig = itemsConfig
	self._hatsFolder = resolveHatsFolder()
	return self
end

function HatApplier:GetHatsFolder(): Folder?
	if self._hatsFolder and self._hatsFolder.Parent then
		return self._hatsFolder
	end

	self._hatsFolder = resolveHatsFolder()
	return self._hatsFolder
end

function HatApplier:Clear()
	for _, child in self._model:GetChildren() do
		if child:IsA("Accessory") and child:GetAttribute("CosmeticHat") == true then
			child:Destroy()
		end
	end
end

function HatApplier:Apply(itemData: any)
	local head = self._model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end

	local hatsFolder = self:GetHatsFolder()
	if not hatsFolder then
		warn("[HatApplier] No se encontro la carpeta Hats en ReplicatedStorage.Shared")
		return
	end

	self:Clear()

	if type(itemData) ~= "table" then
		return
	end

	local itemName = if type(itemData.Name) == "string" then itemData.Name else nil
	local itemId = if type(itemData.id) == "string" then itemData.id else nil
	local hatTemplate = nil :: Instance?

	if itemName then
		hatTemplate = hatsFolder:FindFirstChild(itemName)
	end

	if not hatTemplate and itemId then
		hatTemplate = hatsFolder:FindFirstChild(itemId)
	end

	if not hatTemplate and type(itemData.qualifiedId) == "string" then
		local idSuffix = string.match(itemData.qualifiedId, "[^%.]+$")
		if idSuffix then
			hatTemplate = hatsFolder:FindFirstChild(idSuffix)
		end
	end

	if not hatTemplate or not hatTemplate:IsA("Accessory") then
		warn("[HatApplier] No se encontro el sombrero:", itemName or itemId or "<sin nombre>")
		return
	end

	local newHat = hatTemplate:Clone()
	local handle = newHat:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		newHat:Destroy()
		return
	end

	newHat:SetAttribute("CosmeticHat", true)
	local hatAttachment = getHatAttachmentFromHandle(handle)
	local headAttachment = if hatAttachment
		then head:FindFirstChild(hatAttachment.Name)
		else head:FindFirstChild("HatAttachment")

	if headAttachment and headAttachment:IsA("Attachment") then
		handle.CFrame = headAttachment.WorldCFrame * (if hatAttachment then hatAttachment.CFrame:Inverse() else CFrame.new())
	end

	local weld = Instance.new("WeldConstraint")
	weld.Name = "AccessoryWeld"
	weld.Part0 = handle
	weld.Part1 = head
	weld.Parent = handle

	newHat.Parent = self._model
end

function HatApplier:ApplyItemId(itemId: string?)
	if type(itemId) ~= "string" or itemId == "" then
		self:Reset()
		return
	end

	local hatsCategory = self._itemsConfig.Hats
	if type(hatsCategory) ~= "table" then
		self:Reset()
		return
	end

	local itemConfig = hatsCategory[itemId]
	if type(itemConfig) ~= "table" then
		self:Reset()
		return
	end

	self:Apply({
		qualifiedId = LockerConfig.makeQualifiedId(LockerCategory.HATS, itemId),
		id = itemId,
		Name = itemConfig.Name,
	})
end

function HatApplier:Reset()
	self:Clear()
end

return HatApplier
