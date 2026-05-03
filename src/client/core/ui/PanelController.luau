--!strict
-- PanelController: patrón reutilizable para abrir/cerrar cualquier panel GUI.
-- El menú compartido queda bajo ownership de MenuController; este controlador
-- solo se suscribe a sus botones y limpia sus conexiones al destruirse.
--
-- Hooks opcionales `onOpen`/`onClose` permiten que cada feature reaccione al
-- ciclo (p. ej. activar blur, sonidos, telemetría) sin acoplar el controlador
-- genérico a esas dependencias.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any

local GuiAnimator = require(script.Parent.animators.GuiAnimator)
local MenuHover    = require(script.Parent.MenuHover)

export type PanelControllerOptions = {
	onOpen: (() -> ())?,
	onClose: (() -> ())?,
}

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
	container: Frame,
	menuBtn:   GuiButton,
	closeBtn:  GuiButton,
	options:   PanelControllerOptions?
): PanelController
	local self = setmetatable({}, PanelController) :: any

	self._janitor = Janitor.new()
	self._animator = GuiAnimator.new(nil, container)
	self._menuController = menuController
	self._container = container
	self._isOpen = container.Visible
	self._onOpen = options and options.onOpen
	self._onClose = options and options.onClose

	menuController:registerPanel(container)
	self._janitor:Add(function()
		menuController:unregisterPanel(container)
	end, true)

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

	if self._onOpen then
		self._onOpen()
	end
end

function PanelController:close()
	if not self._isOpen then
		return
	end

	self._isOpen = false
	self._animator:close()
	self._menuController:show()

	if self._onClose then
		self._onClose()
	end
end

function PanelController:Destroy()
	-- Si el panel queda abierto al destruir, dispara onClose para liberar
	-- recursos externos (blur, sonidos, telemetría) — sin esto, el blur
	-- queda activo si el feature se hot-reloadea con el panel abierto.
	if self._isOpen and self._onClose then
		pcall(self._onClose)
	end
	self._janitor:Destroy()
end

return PanelController
