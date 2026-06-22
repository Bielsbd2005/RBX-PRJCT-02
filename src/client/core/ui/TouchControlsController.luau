--!strict
--[[
	TouchControlsController.luau
	Muestra/oculta los controles táctiles por defecto de Roblox (el joystick de
	movimiento y el botón de salto).

	Fuera de partida (menú, lobby, locker, resultados…) no hay personaje
	controlable —la cámara es fija o cinemática—, así que el joystick solo estorba
	y debe ocultarse. En partida activa se vuelve a mostrar.

	Implementado con UserInputService.ModalEnabled, la vía soportada para esconder
	los controles móviles por defecto cuando hay una UI "modal" en pantalla. Solo
	se escribe en dispositivos táctiles: en PC/consola no tocamos la propiedad para
	no alterar el cursor ni el bloqueo de mouse de la ShoulderCamera.
]]

local UserInputService = game:GetService("UserInputService")

-- Mismo criterio de "móvil" que el resto del cliente: solo táctil puro.
local IS_TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local TouchControlsController = {}

--- enabled = true  → joystick/botón de salto por defecto visibles (en partida).
--- enabled = false → ocultos (fuera de partida).
function TouchControlsController.setEnabled(enabled: boolean)
	if not IS_TOUCH then
		return
	end
	-- ModalEnabled = true esconde los controles táctiles por defecto.
	UserInputService.ModalEnabled = not enabled
end

return TouchControlsController
