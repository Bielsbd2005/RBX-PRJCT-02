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
	animationMode: GuiAnimator.AnimatorMode?,
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

-- `menuBtn` y `closeBtn` son opcionales: durante la migración de la GUI el Menu
-- puede estar vacío y un panel puede aún no tener su botón de cerrar. En ambos
-- casos el panel se configura igual —carga datos, anima— y solo se omite el
-- binding ausente.
function PanelController.new(
	menuController: any,
	container: GuiObject,
	menuBtn:   GuiButton?,
	closeBtn:  GuiButton?,
	options:   PanelControllerOptions?
): PanelController
	local self = setmetatable({}, PanelController) :: any

	self._janitor = Janitor.new()
	self._animator = GuiAnimator.new(nil, container, {
		mode = if options then options.animationMode else nil,
	})
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

	if menuBtn then
		self._janitor:Add(menuBtn.MouseButton1Click:Connect(function()
			self:open()
		end), "Disconnect")
	end

	if closeBtn then
		local resetClose = MenuHover.bindButton(closeBtn, self._janitor)
		self._janitor:Add(closeBtn.MouseButton1Click:Connect(function()
			resetClose()
			self:close()
		end), "Disconnect")
	end

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

	-- El menú reaparece al terminar la animación de cierre (no de golpe, que
	-- taparía el tween). Y solo si no se abrió otro panel en medio — así el salto
	-- de un panel a otro (Settings → Credits) no hace parpadear el menú.
	self._animator:close(function()
		if not self._menuController:hasOpenPanel() then
			self._menuController:show()
		end
	end)

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
