--!strict
--[[
	Patrón "cancelar tween anterior, ejecutar nuevo, limpiar el slot al terminar".
	Uso:
		local slot = { current = nil :: Tween? }
		Retween.run(slot, instance, tweenInfo, { Prop = value })
		-- ...
		Retween.cancel(slot)  -- opcional, también cancela en :Destroy del consumidor

	Para dicts por target, almacenar slot tables en lugar de Tweens:
		dict[target] = dict[target] or { current = nil }
		Retween.run(dict[target], instance, info, goal)

	El identity-check en Completed evita que un tween viejo nilifique el slot de uno
	posterior que lo reemplazó.

	No sirve para transacciones multi-tween coordinadas (ver
	LockerCameraController:_cancelActiveTweens).
]]

local TweenService = game:GetService("TweenService")

export type Slot = { current: Tween? }

local Retween = {}

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

function Retween.cancel(slot: Slot)
	if slot.current then
		slot.current:Cancel()
		slot.current = nil
	end
end

return Retween
