--!strict
--[[
	Retween.luau
	Helper para el patrón "cancelar tween anterior, ejecutar nuevo tween, limpiar
	el slot cuando termina". Sustituye boilerplate repetido en CameraFovEffect,
	InteractiveScaleTween y LockerGrid.

	Uso:
		local slot = { current = nil :: Tween? }
		Retween.run(slot, instance, tweenInfo, { Prop = value })
		-- ...
		Retween.cancel(slot)  -- opcional, también cancela en :Destroy del consumidor

	Para dicts por target, almacenar slot tables en lugar de Tweens:
		dict[target] = dict[target] or { current = nil }
		Retween.run(dict[target], instance, info, goal)

	Identity-check en Completed evita race con tweens posteriores: si otro
	Retween.run reemplazó el slot mientras el viejo tween se completaba, no
	nilificamos el slot del nuevo.

	NO maneja el patrón "transacción multi-tween coordinada" (ver
	LockerCameraController:_cancelActiveTweens).
]]

local TweenService = game:GetService("TweenService")

export type Slot = { current: Tween? }

local Retween = {}

--[[
	Reemplaza el tween activo en `slot` con uno nuevo que aplica `goal` a
	`instance` con `tweenInfo`. El tween anterior (si existe) se cancela. El
	nuevo se inicia con :Play() y se devuelve.
]]
function Retween.run(
	slot: Slot,
	instance: Instance,
	tweenInfo: TweenInfo,
	goal: { [string]: any }
): Tween
	if slot.current then
		slot.current:Cancel()
		slot.current = nil
	end

	local tween = TweenService:Create(instance, tweenInfo, goal)
	slot.current = tween

	tween.Completed:Once(function()
		if slot.current == tween then
			slot.current = nil
		end
	end)

	tween:Play()
	return tween
end

-- Cancela el tween activo en `slot` si existe. Idempotente.
function Retween.cancel(slot: Slot)
	if slot.current then
		slot.current:Cancel()
		slot.current = nil
	end
end

return Retween
