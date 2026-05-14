--!strict
-- NavStaggerController: anima la aparición escalonada de los botones de uno
-- o varios containers Nav. Cada GuiButton entra con UIScale 0 → target
-- (NavSelectedScale para el activo, NavUnselectedScale para el resto) en
-- orden de child tree.
--
-- Comparte el UIScale que ya usa NavTabController en cada botón (busca por
-- class): si hubiera dos UIScales hermanos, Roblox solo aplica uno y el
-- stagger no se vería.

local TweenService = game:GetService("TweenService")

local UITheme = require(script.Parent.UITheme)

export type NavStaggerEntry = {
	container: Instance,
	getSelectedKey: () -> string?,
	exclude: { Instance }?,
}

export type NavStaggerOptions = {
	staggerDelay: number?,
	tweenInfo: TweenInfo?,
}

export type NavStaggerController = {
	_entries: { NavStaggerEntry },
	_staggerDelay: number,
	_tweenInfo: TweenInfo,
	_scales: { [GuiButton]: UIScale },
	_tweens: { [GuiButton]: Tween },
	play: (self: NavStaggerController) -> (),
	Destroy: (self: NavStaggerController) -> (),
}

local DEFAULT_STAGGER_DELAY = 0.12
local DEFAULT_TWEEN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

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

function NavStaggerController.new(entries: { NavStaggerEntry }, options: NavStaggerOptions?): NavStaggerController
	local self = setmetatable({}, NavStaggerController) :: any
	self._entries = entries
	self._staggerDelay = (options and options.staggerDelay) or DEFAULT_STAGGER_DELAY
	self._tweenInfo = (options and options.tweenInfo) or DEFAULT_TWEEN_INFO
	self._scales = {}
	self._tweens = {}
	return self
end

function NavStaggerController:play()
	for _, tween in self._tweens do
		tween:Cancel()
	end
	table.clear(self._tweens)
	-- Si algún container es dinámico (botones recreados, p.ej. Nav2 del
	-- Locker), las refs cacheadas pueden apuntar a instancias destruidas.
	-- Reseteamos y se reconstruyen en este play.
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
				local tween = TweenService:Create(scale, self._tweenInfo, { Scale = targetScale })
				self._tweens[btn] = tween
				local thisTween = tween
				local thisBtn = btn
				task.delay((index - 1) * self._staggerDelay, function()
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
	-- Restauramos scale = 1 por si nos destruyen mid-stagger; sin esto los
	-- botones quedarían invisibles para la próxima vida (hot reload).
	for _, scale in self._scales do
		if scale.Parent ~= nil then
			scale.Scale = 1
		end
	end
	table.clear(self._scales)
end

return NavStaggerController
