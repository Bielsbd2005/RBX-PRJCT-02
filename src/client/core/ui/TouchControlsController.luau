--!strict
--[[
	Muestra/oculta el joystick y el botón de salto por defecto (visibles solo en partida).
	Usa UserInputService.ModalEnabled y solo lo escribe en táctil: en PC/consola
	alteraría el cursor y el bloqueo de mouse de la ShoulderCamera.
]]

local UserInputService = game:GetService("UserInputService")

-- Mismo criterio de "móvil" que el resto del cliente: solo táctil puro.
local IS_TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local TouchControlsController = {}

function TouchControlsController.setEnabled(enabled: boolean)
	if not IS_TOUCH then
		return
	end
	-- ModalEnabled = true esconde los controles táctiles por defecto.
	UserInputService.ModalEnabled = not enabled
end

return TouchControlsController
