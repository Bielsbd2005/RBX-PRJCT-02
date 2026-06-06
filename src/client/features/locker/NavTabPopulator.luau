--!strict
-- NavTabPopulator.luau (Client Feature Library)
-- Gestiona la población dinámica y los eventos de hover/click de la barra de subcategorías (Nav2) en el vestuario.

local Client = script.Parent.Parent.Parent
local UITheme = require(Client:WaitForChild("core"):WaitForChild("ui"):WaitForChild("UITheme"))

local STROKE_DEFAULT = UITheme.StrokeDefault
local STROKE_WHITE = UITheme.StrokeHover

type LockerNavItemDefinition = {
	key: string,
	title: string,
	thumbnail: string,
}

local NavTabPopulator = {}
NavTabPopulator.__index = NavTabPopulator

function NavTabPopulator.new(
	navContainer: GuiObject,
	navTemplate: GuiButton,
	defaultNavItemSize: UDim2,
	navItemController: any
)
	local self = setmetatable({}, NavTabPopulator)
	self.navContainer = navContainer
	self.navTemplate = navTemplate
	self.defaultNavItemSize = defaultNavItemSize
	self.navItemController = navItemController

	return self
end

local function getButtonStroke(button: GuiButton): UIStroke?
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		return stroke
	end
	local folder = button:FindFirstChild("Stroke")
	if folder then
		return folder:FindFirstChildOfClass("UIStroke")
	end
	return nil
end

local function setNavButtonContent(button: GuiButton, definition: LockerNavItemDefinition)
	local label = button:FindFirstChild("Label") :: TextLabel?
	if label then
		label.Text = definition.title
	end

	local imageNode = button:FindFirstChild("Image") :: ImageLabel?
	if imageNode then
		imageNode.Image = definition.thumbnail
	end

	local titleNode = button:FindFirstChild("Title") :: TextLabel?
	if titleNode then
		titleNode.Text = definition.title
	end
end

local function bindStrokeHover(button: GuiButton, parentJanitor: any, isSelected: () -> boolean)
	local stroke = getButtonStroke(button)
	if not stroke then return end

	parentJanitor:Add(button.MouseEnter:Connect(function()
		stroke.Color = STROKE_WHITE
	end), "Disconnect")

	parentJanitor:Add(button.MouseLeave:Connect(function()
		if not isSelected() then
			stroke.Color = STROKE_DEFAULT
		end
	end), "Disconnect")
end

function NavTabPopulator:populate(
	categoryKey: string,
	itemDefinitions: { LockerNavItemDefinition },
	navItemsJanitor: any,
	onNavSelected: (definition: LockerNavItemDefinition, navButton: GuiButton) -> (),
	getSelectedNavButton: () -> GuiButton?,
	setSelectedNavButton: (button: GuiButton) -> (),
	nav2Stagger: any?
)
	local navButtons = {}
	for layoutOrder, definition in ipairs(itemDefinitions) do
		local navButton = self.navTemplate:Clone()
		navButton.Name = definition.key
		navButton.Visible = true
		navButton.LayoutOrder = layoutOrder
		navButton.Size = self.defaultNavItemSize
		setNavButtonContent(navButton, definition)
		navButton.Parent = self.navContainer
		table.insert(navButtons, navButton)
		self.navItemController:register(definition.key, navButton)

		local stroke = getButtonStroke(navButton)
		if stroke then
			stroke.Color = STROKE_DEFAULT
		end

		bindStrokeHover(navButton, navItemsJanitor, function()
			return navButton == getSelectedNavButton()
		end)

		navItemsJanitor:Add(navButton.Activated:Connect(function()
			setSelectedNavButton(navButton)
			onNavSelected(definition, navButton)
		end), "Disconnect")
	end

	if #navButtons > 0 then
		setSelectedNavButton(navButtons[1])
		onNavSelected(itemDefinitions[1], navButtons[1])
	end

	if nav2Stagger then
		nav2Stagger:play()
	end

	return navButtons
end

return NavTabPopulator
