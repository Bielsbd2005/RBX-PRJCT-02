--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local WeaponSkinWrapPreviewer = require(script.Parent.Parent.locker.Previewers.WeaponSkinWrapPreviewer)

export type SkinPreviewItem = {
	ItemKey: string,
	Name: string,
	Rarity: string,
	TextureID: string?,
	BaseColor: Color3?,
	Animated: boolean?,
	StudsPerTile: number?,
	PreviewWeaponCategory: string?,
	PreviewWeaponKey: string?,
	PreviewWeaponName: string?,
}

export type FusionSkinRenderer = {
	_previewJanitors: { [ViewportFrame]: any },
	ClearViewport: (self: FusionSkinRenderer, viewport: ViewportFrame) -> (),
	RenderSkin: (self: FusionSkinRenderer, viewport: ViewportFrame, item: SkinPreviewItem) -> boolean,
	Destroy: (self: FusionSkinRenderer) -> (),
}

local FusionSkinRenderer = {}
FusionSkinRenderer.__index = FusionSkinRenderer

function FusionSkinRenderer.new(): FusionSkinRenderer
	local self = setmetatable({}, FusionSkinRenderer) :: any
	self._previewJanitors = {}
	return self
end

function FusionSkinRenderer:ClearViewport(viewport: ViewportFrame): ()
	local previewJanitor = self._previewJanitors[viewport]
	if previewJanitor then
		previewJanitor:Cleanup()
	end

	viewport.CurrentCamera = nil
	for _, child in viewport:GetChildren() do
		child:Destroy()
	end
	viewport.Visible = false
end

function FusionSkinRenderer:RenderSkin(viewport: ViewportFrame, item: SkinPreviewItem): boolean
	self:ClearViewport(viewport)

	local previewJanitor = self._previewJanitors[viewport]
	if not previewJanitor then
		previewJanitor = Janitor.new()
		self._previewJanitors[viewport] = previewJanitor
	end

	return WeaponSkinWrapPreviewer.Render(viewport, item, previewJanitor)
end

function FusionSkinRenderer:Destroy(): ()
	for _, previewJanitor in self._previewJanitors do
		previewJanitor:Destroy()
	end
	table.clear(self._previewJanitors)
end

return FusionSkinRenderer
