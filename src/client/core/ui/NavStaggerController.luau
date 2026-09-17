--!strict
-- Comparte el UIScale que ya usa NavTabController en cada botón (busca por
-- class): con dos UIScales hermanos Roblox solo aplica uno y el stagger no se vería.

local TweenService = game:GetService("TweenService")

local UITheme = require(script.Parent.UITheme)

export type NavStaggerEntry = {
	container: Instance,
	getSelectedKey: () -> string?,
	exclude: { Instance }?,
}

export type NavStaggerController = {
	_entries: { NavStaggerEntry },
	_scales: { [GuiButton]: UIScale },
	_tweens: { [GuiButton]: Tween },
	play: (self: NavStaggerController) -> (),
	Destroy: (self: NavStaggerController) -> (),
}

local STAGGER_DELAY = 0.12
local TWEEN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local NavStaggerController = {}
NavStaggerController.__index = NavStaggerController

local function ensureScale(btn: GuiButton): UIScale
	local existing = btn:FindFirstChildOfClass("UIScale")
	if existing then return existing end
	local scale = Instance.new("UIScale")
	scale.Name = "NavScale"
	scale.Parent = btn
	return scale
end

function NavStaggerController.new(entries: { NavStaggerEntry }): NavStaggerController
	local self = setmetatable({}, NavStaggerController) :: any
	self._entries = entries
	self._scales = {}
	self._tweens = {}
	return self
end

function NavStaggerController:play()
	for _, tween in self._tweens do
		tween:Cancel()
	end
	table.clear(self._tweens)
	-- Containers dinámicos (p.ej. Nav2 del Locker) recrean botones: las refs
	-- cacheadas pueden estar destruidas, así que se reconstruyen en cada play.
	table.clear(self._scales)

	for _, entry in self._entries do
		local excludeSet: { [Instance]: boolean } = {}
		if entry.exclude then
			for _, item in entry.exclude do
				excludeSet[item] = true
			end
		end
		local selectedKey = entry.getSelectedKey()
		local index = 0
		for _, child in entry.container:GetChildren() do
			if child:IsA("GuiButton") and not excludeSet[child] then
				local btn = child :: GuiButton
				index += 1
				local scale = ensureScale(btn)
				self._scales[btn] = scale
				scale.Scale = 0
				local targetScale = if btn.Name == selectedKey
					then UITheme.NavSelectedScale
					else UITheme.NavUnselectedScale
				local tween = TweenService:Create(scale, TWEEN_INFO, { Scale = targetScale })
				self._tweens[btn] = tween
				local thisTween = tween
				local thisBtn = btn
				task.delay((index - 1) * STAGGER_DELAY, function()
					if self._tweens[thisBtn] ~= thisTween then return end
					thisTween:Play()
				end)
			end
		end
	end
end

function NavStaggerController:Destroy()
	for _, tween in self._tweens do
		tween:Cancel()
	end
	table.clear(self._tweens)
	-- Scale = 1 por si nos destruyen mid-stagger; si no, los botones quedarían
	-- invisibles para la próxima vida (hot reload).
	for _, scale in self._scales do
		if scale.Parent ~= nil then
			scale.Scale = 1
		end
	end
	table.clear(self._scales)
end

return NavStaggerController
