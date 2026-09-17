--!strict
-- Abrir/cerrar un panel GUI. El menú compartido es de MenuController; este
-- controlador solo se suscribe a sus botones y limpia sus conexiones al destruirse.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any

local GuiAnimator = require(script.Parent.animators.GuiAnimator)
local GameSounds  = require(script.Parent.GameSounds)
local MenuHover    = require(script.Parent.MenuHover)

export type PanelControllerOptions = {
	onOpen: (() -> ())?,
	onClose: (() -> ())?,
	animationMode: GuiAnimator.AnimatorMode?,
	-- Claves de GameSounds; por defecto `Open` / `Close`.
	openSound: string?,
	closeSound: string?,
}

export type PanelController = {
	_janitor: any,
	_animator: any,
	_menuController: any,
	_isOpen: boolean,
	open:  (self: PanelController, silent: boolean?) -> (),
	close: (self: PanelController, silent: boolean?) -> (),
	Destroy: (self: PanelController) -> (),
}

local PanelController = {}
PanelController.__index = PanelController

function PanelController.new(
	menuController: any,
	container: GuiObject,
	menuBtn:   GuiButton?,
	closeBtn:  GuiButton?,
	options:   PanelControllerOptions?
): PanelController
	local self = setmetatable({}, PanelController) :: any

	self._janitor = Janitor.new()
	self._animator = GuiAnimator.new(container, {
		mode = if options then options.animationMode else nil,
	})
	self._menuController = menuController
	self._isOpen = container.Visible
	self._onOpen = options and options.onOpen
	self._onClose = options and options.onClose
	self._openSound = (options and options.openSound) or GameSounds.Open
	self._closeSound = (options and options.closeSound) or GameSounds.Close

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
		MenuHover.bindButton(closeBtn, self._janitor)
		self._janitor:Add(closeBtn.MouseButton1Click:Connect(function()
			self:close()
		end), "Disconnect")
	end

	return self
end

-- `silent`: sin sonido. Para transiciones entre paneles hermanos (Settings ⇄ Credits)
-- y aperturas programáticas, donde el usuario no ha abierto nada.
function PanelController:open(silent: boolean?)
	if self._isOpen then
		return
	end

	self._isOpen = true
	if not silent then
		GameSounds.play(self._openSound)
	end
	self._animator:open()
	self._menuController:hide()

	if self._onOpen then
		self._onOpen()
	end
end

function PanelController:close(silent: boolean?)
	if not self._isOpen then
		return
	end

	self._isOpen = false
	if not silent then
		GameSounds.play(self._closeSound)
	end

	-- El menú reaparece solo si no se abrió otro panel en medio, para que el salto
	-- entre paneles (Settings → Credits) no haga parpadear el menú.
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
	-- Si se destruye abierto (hot reload), dispara onClose para liberar recursos
	-- externos como el blur.
	if self._isOpen and self._onClose then
		pcall(self._onClose)
	end
	self._janitor:Destroy()
end

return PanelController
