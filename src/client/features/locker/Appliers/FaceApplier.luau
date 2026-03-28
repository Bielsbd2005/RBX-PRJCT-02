--!strict

local FaceApplier = {}
FaceApplier.__index = FaceApplier

type FaceObject = Decal | Texture

type FaceApplier = {
	_model: Model,
	_itemsConfig: any,
	_faceObject: FaceObject?,
	_defaultTexture: string,
	ApplyImage: (self: FaceApplier, image: string?) -> (),
	ApplyItemKey: (self: FaceApplier, itemKey: string?) -> (),
	ApplyFromLoadoutFace: (self: FaceApplier, loadoutFace: string?) -> (),
	Reset: (self: FaceApplier) -> (),
}

local function resolveFaceObject(model: Model): FaceObject?
	local head = model:FindFirstChild("Head", true)
	if not head or not head:IsA("BasePart") then
		return nil
	end

	local namedFace = head:FindFirstChild("face") or head:FindFirstChild("Face")
	if namedFace and (namedFace:IsA("Decal") or namedFace:IsA("Texture")) then
		return namedFace
	end

	for _, child in head:GetChildren() do
		if child:IsA("Decal") or child:IsA("Texture") then
			return child
		end
	end

	return nil
end

function FaceApplier.new(model: Model, itemsConfig: any): FaceApplier
	local self = setmetatable({}, FaceApplier) :: any
	self._model = model
	self._itemsConfig = itemsConfig
	self._faceObject = resolveFaceObject(model)
	self._defaultTexture = if self._faceObject then self._faceObject.Texture else ""
	return self
end

function FaceApplier:ApplyImage(image: string?)
	if not self._faceObject then
		return
	end

	if type(image) == "string" and image ~= "" then
		self._faceObject.Texture = image
	else
		self._faceObject.Texture = self._defaultTexture
	end
end

function FaceApplier:ApplyItemKey(itemKey: string?)
	if type(itemKey) ~= "string" or itemKey == "" then
		self:Reset()
		return
	end

	local facesCategory = self._itemsConfig.Faces
	if type(facesCategory) ~= "table" then
		self:Reset()
		return
	end

	local itemConfig = facesCategory[itemKey]
	if type(itemConfig) ~= "table" then
		self:Reset()
		return
	end

	self:ApplyImage(itemConfig.Image)
end

function FaceApplier:ApplyFromLoadoutFace(loadoutFace: string?)
	self:ApplyItemKey(loadoutFace)
end

function FaceApplier:Reset()
	self:ApplyImage(nil)
end

return FaceApplier
