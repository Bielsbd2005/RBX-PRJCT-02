--!strict
--[[
	Tira de pestañas del Locker (Nav1 y Nav2): clona la plantilla por definición, pinta
	título e icono, borde al pasar el ratón y estado activo con NavTabController. El Name
	de cada botón clonado ES su key (NavStaggerController también indexa por Name).
	Studio: la plantilla trae un hijo Title (TextLabel) y, opcional, Icon (ImageLabel).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent.Parent
local Janitor = require(ReplicatedStorage:WaitForChild("Packages").janitor) :: any
local NavTabController = require(Client.core.ui.NavTabController)
local UITheme = require(Client.core.ui.UITheme)

export type TabDefinition = {
	key: string,
	title: string,
	thumbnail: string?,
	onActivated: () -> (),
}

export type Deps = {
	container: Instance,
	template: GuiButton,
	-- Botones del contenedor que no son pestañas y sobreviven al repoblar (CloseBtn).
	keep: { Instance }?,
	canUseHoverAnimations: boolean,
}

export type LockerNavStrip = {
	populate: (self: LockerNavStrip, definitions: { TabDefinition }, selectedKey: string?) -> (),
	setActive: (self: LockerNavStrip, key: string?) -> (),
	has: (self: LockerNavStrip, key: string) -> boolean,
	Destroy: (self: LockerNavStrip) -> (),
}

type Internal = LockerNavStrip & {
	_deps: Deps,
	_keys: { [string]: true },
	_tabs: any,
	_buttonsJanitor: any,
}

local LockerNavStrip = {}
LockerNavStrip.__index = LockerNavStrip

function LockerNavStrip.new(deps: Deps): LockerNavStrip
	deps.template.Visible = false
	return setmetatable({
		_deps = deps,
		_keys = {},
		_tabs = NavTabController.new(),
		_buttonsJanitor = Janitor.new(),
	}, LockerNavStrip) :: any
end

local function bindStrokeHover(self: Internal, button: GuiButton, stroke: UIStroke)
	self._buttonsJanitor:Add(button.MouseEnter:Connect(function()
		stroke.Color = UITheme.StrokeHover
	end), "Disconnect")
	self._buttonsJanitor:Add(button.MouseLeave:Connect(function()
		stroke.Color = UITheme.StrokeDefault
	end), "Disconnect")
end

local function clear(self: Internal)
	self._buttonsJanitor:Cleanup()
	self._tabs:clear()
	table.clear(self._keys)
	local deps = self._deps
	for _, child in deps.container:GetChildren() do
		if child:IsA("GuiButton") and child ~= deps.template and not (deps.keep and table.find(deps.keep, child)) then
			child:Destroy()
		end
	end
end

-- `selectedKey` marca la pestaña activa (nil = ninguna).
function LockerNavStrip.populate(self: Internal, definitions: { TabDefinition }, selectedKey: string?)
	clear(self)
	local deps = self._deps
	for layoutOrder, definition in ipairs(definitions) do
		local button = deps.template:Clone()
		button.Name = definition.key
		button.Visible = true
		button.LayoutOrder = layoutOrder
		local titleNode = button:FindFirstChild("Title")
		if titleNode and titleNode:IsA("TextLabel") then
			titleNode.Text = definition.title
		end
		local iconNode = button:FindFirstChild("Icon")
		if definition.thumbnail and iconNode and (iconNode:IsA("ImageLabel") or iconNode:IsA("ImageButton")) then
			iconNode.Image = definition.thumbnail
		end
		button.Parent = deps.container
		self._tabs:register(definition.key, button)
		self._keys[definition.key] = true

		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = UITheme.StrokeDefault
			if deps.canUseHoverAnimations then
				bindStrokeHover(self, button, stroke)
			end
		end
		self._buttonsJanitor:Add(button.Activated:Connect(definition.onActivated), "Disconnect")
	end

	if selectedKey then
		self._tabs:setActive(selectedKey)
	end
end

function LockerNavStrip.setActive(self: Internal, key: string?)
	self._tabs:setActive(key)
end

function LockerNavStrip.has(self: Internal, key: string): boolean
	return self._keys[key] == true
end

function LockerNavStrip.Destroy(self: Internal)
	self._buttonsJanitor:Destroy()
	self._tabs:Destroy()
end

return LockerNavStrip
