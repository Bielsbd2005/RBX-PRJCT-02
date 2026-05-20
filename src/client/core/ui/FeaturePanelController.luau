--!strict
-- FeaturePanelController: patrón unificado para features con ScreenGui propia
-- (Store, Fusion, Locker). Encapsula el ciclo open/close + cámara +
-- sincronización con menú principal.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any

local MenuHover = require(script.Parent.MenuHover)

export type FeaturePanelOptions = {
	menuController: any,
	screenGui: ScreenGui,
	openButton: GuiButton,
	closeButton: GuiButton?,
	cameraController: any?,
	cameraLockKey: string?,
	cameraLockModule: any?,
	onOpen: (() -> ())?,
	onClose: (() -> ())?,
}

export type FeaturePanelController = {
	_janitor: any,
	_options: FeaturePanelOptions,
	_isOpen: boolean,
	open: (self: FeaturePanelController) -> (),
	close: (self: FeaturePanelController) -> (),
	isOpen: (self: FeaturePanelController) -> boolean,
	Destroy: (self: FeaturePanelController) -> (),
}

local FeaturePanelController = {}
FeaturePanelController.__index = FeaturePanelController

function FeaturePanelController.new(options: FeaturePanelOptions): FeaturePanelController
	local self = setmetatable({}, FeaturePanelController) :: any
	self._janitor = Janitor.new()
	self._options = options
	self._isOpen = options.screenGui.Enabled

	local menuController = options.menuController
	menuController:registerPanel(options.screenGui)
	self._janitor:Add(function()
		menuController:unregisterPanel(options.screenGui)
	end, true)

	if options.screenGui.Enabled then
		options.screenGui.Enabled = false
		self._isOpen = false
	end

	self._janitor:Add(options.openButton.MouseButton1Click:Connect(function()
		self:open()
	end), "Disconnect")

	if options.closeButton then
		local resetClose = MenuHover.bindButton(options.closeButton, self._janitor)
		self._janitor:Add(options.closeButton.MouseButton1Click:Connect(function()
			resetClose()
			self:close()
		end), "Disconnect")
	end

	self._janitor:Add(options.screenGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if options.screenGui.Enabled == false and self._isOpen then
			self:_handleExternalClose()
		end
	end), "Disconnect")

	return self
end

function FeaturePanelController:_handleExternalClose()
	self._isOpen = false
	local options = self._options
	if options.cameraController then
		options.cameraController:restore()
	end
	if options.cameraLockKey and options.cameraLockModule then
		options.cameraLockModule.release(options.cameraLockKey)
	end
	options.menuController:show()
	if options.onClose then
		options.onClose()
	end
end

function FeaturePanelController:open()
	if self._isOpen then
		return
	end
	self._isOpen = true

	local options = self._options
	if options.cameraLockKey and options.cameraLockModule then
		options.cameraLockModule.acquire(options.cameraLockKey)
	end
	if options.cameraController then
		options.cameraController:apply()
	end

	options.screenGui.Enabled = true
	options.menuController:hide()

	if options.onOpen then
		options.onOpen()
	end
end

function FeaturePanelController:close()
	if not self._isOpen then
		return
	end
	self._isOpen = false

	local options = self._options
	options.screenGui.Enabled = false

	if options.cameraController then
		options.cameraController:restore()
	end
	if options.cameraLockKey and options.cameraLockModule then
		options.cameraLockModule.release(options.cameraLockKey)
	end
	options.menuController:show()

	if options.onClose then
		options.onClose()
	end
end

function FeaturePanelController:isOpen(): boolean
	return self._isOpen
end

function FeaturePanelController:Destroy()
	if self._isOpen then
		self:close()
	end
	self._janitor:Destroy()
end

return FeaturePanelController
