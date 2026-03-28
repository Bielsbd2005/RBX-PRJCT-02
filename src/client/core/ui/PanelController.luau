--!strict
-- PanelController: patrón reutilizable para abrir/cerrar cualquier panel GUI.
-- El menú compartido queda bajo ownership de MenuController; este controlador
-- solo se suscribe a sus botones y limpia sus conexiones al destruirse.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any

local GuiAnimator = require(script.Parent.animators.GuiAnimator)
local MenuHover    = require(script.Parent.MenuHover)

export type PanelController = {
	_janitor: any,
	_animator: any,
	_menuController: any,
	_isOpen: boolean,
	open:  (self: PanelController) -> (),
	close: (self: PanelController) -> (),
	Destroy: (self: PanelController) -> (),
}

local PanelController = {}
PanelController.__index = PanelController

function PanelController.new(
	menuController: any,
	screenGui: ScreenGui,
	container: Frame,
	menuBtn:   GuiButton,
	closeBtn:  GuiButton
): PanelController
	local self = setmetatable({}, PanelController) :: any

	self._janitor = Janitor.new()
	self._animator = GuiAnimator.new(screenGui, container)
	self._menuController = menuController
	self._isOpen = screenGui.Enabled

	self._janitor:Add(self._animator, "Destroy")

	local resetClose = MenuHover.bindButton(closeBtn, self._janitor)

	self._janitor:Add(menuBtn.MouseButton1Click:Connect(function()
		self:open()
	end), "Disconnect")

	self._janitor:Add(closeBtn.MouseButton1Click:Connect(function()
		resetClose()
		self:close()
	end), "Disconnect")

	return self
end

function PanelController:open()
	if self._isOpen then
		return
	end

	self._isOpen = true
	self._animator:open()
	self._menuController:hide()
end

function PanelController:close()
	if not self._isOpen then
		return
	end

	self._isOpen = false
	self._animator:close()
	self._menuController:show()
end

function PanelController:Destroy()
	self._janitor:Destroy()
end

return PanelController
