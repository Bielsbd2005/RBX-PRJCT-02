--!strict
-- NavTabController: gestión reutilizable de tabs/nav buttons con
-- tween de scale + ImageColor3 cancelable. Sustituye el patrón duplicado
-- en store, cases, locker.

local TweenService = game:GetService("TweenService")
local UITheme = require(script.Parent.UITheme)

export type NavTabController = {
	_buttons: { [string]: GuiButton },
	_activeKey: string?,
	_scaleTweens: { [GuiButton]: Tween },
	_colorTweens: { [GuiButton]: Tween },
	setActive: (self: NavTabController, key: string?) -> (),
	register: (self: NavTabController, key: string, button: GuiButton) -> (),
	clear: (self: NavTabController) -> (),
	Destroy: (self: NavTabController) -> (),
}

local NavTabController = {}
NavTabController.__index = NavTabController

local function getOrCreateScaleNode(button: GuiButton): UIScale
	local existing = button:FindFirstChildOfClass("UIScale")
	if existing then
		return existing
	end

	local created = Instance.new("UIScale")
	created.Name = "NavScale"
	created.Parent = button
	return created
end

local function cancelTween(tweens: { [GuiButton]: Tween }, button: GuiButton)
	local existing = tweens[button]
	if existing then
		existing:Cancel()
		tweens[button] = nil
	end
end

function NavTabController.new(): NavTabController
	local self = setmetatable({}, NavTabController) :: any
	self._buttons = {}
	self._activeKey = nil
	self._scaleTweens = {}
	self._colorTweens = {}
	return self
end

function NavTabController:register(key: string, button: GuiButton)
	self._buttons[key] = button
end

function NavTabController:setActive(key: string?)
	self._activeKey = key

	for buttonKey, button in self._buttons do
		local isSelected = (buttonKey == key)
		local targetScale = if isSelected then UITheme.NavSelectedScale else UITheme.NavUnselectedScale
		local targetColor = if isSelected then UITheme.NavSelected else UITheme.NavUnselected

		local scaleNode = getOrCreateScaleNode(button)
		cancelTween(self._scaleTweens, button)
		local scaleTween = TweenService:Create(scaleNode, UITheme.NavTweenInfo, { Scale = targetScale })
		self._scaleTweens[button] = scaleTween
		scaleTween.Completed:Connect(function()
			if self._scaleTweens[button] == scaleTween then
				self._scaleTweens[button] = nil
			end
		end)
		scaleTween:Play()

		if button:IsA("ImageButton") or button:IsA("ImageLabel") then
			cancelTween(self._colorTweens, button)
			local colorTween = TweenService:Create(button, UITheme.NavTweenInfo, { ImageColor3 = targetColor })
			self._colorTweens[button] = colorTween
			colorTween.Completed:Connect(function()
				if self._colorTweens[button] == colorTween then
					self._colorTweens[button] = nil
				end
			end)
			colorTween:Play()
		end
	end
end

function NavTabController:clear()
	for _, tween in self._scaleTweens do
		tween:Cancel()
	end
	for _, tween in self._colorTweens do
		tween:Cancel()
	end
	table.clear(self._scaleTweens)
	table.clear(self._colorTweens)
	table.clear(self._buttons)
	self._activeKey = nil
end

function NavTabController:Destroy()
	self:clear()
end

return NavTabController
