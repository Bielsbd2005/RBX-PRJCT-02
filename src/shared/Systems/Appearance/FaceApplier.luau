local FaceApplier = {}

function FaceApplier.Apply(character: Model, itemData: table)
	if not character then return end
	if not itemData or not itemData.Image then return end

	local head = character:FindFirstChild("Head")
	if not head then return end

	local face = head:FindFirstChild("face")
	if not face then
		face = Instance.new("Decal")
		face.Name = "face"
		face.Parent = head
	end

	face.Texture = itemData.Image
end

return FaceApplier
