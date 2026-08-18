--!strict

local MenuAnimator = {}
MenuAnimator.__index = MenuAnimator

function MenuAnimator.new(menuGui: ScreenGui)
	local self = setmetatable({}, MenuAnimator)
	self._gui = menuGui
	return self
end

function MenuAnimator:hide(): ()
	self._gui.Enabled = false
end

function MenuAnimator:show(): ()
	self._gui.Enabled = true
end

function MenuAnimator:Destroy(): ()
end

return MenuAnimator
