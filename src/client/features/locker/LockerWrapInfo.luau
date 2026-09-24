--!strict
--[[
	Panel que explica cómo se desbloquea el wrap seleccionado en la vista Maestry.
	Studio: `UserInterface.Locker` (a cualquier profundidad) → Frame `WrapInfo` con un
	TextLabel hijo `Text`. Opcional: sin él el locker funciona igual.
	Aparece con fundido y un leve crecimiento; sus hijos deben ir en Scale.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local WrapMastery = require(Shared.data.WrapMastery)
local Retween = require(Shared.utils.Retween)
local UIUtils = require(script.Parent.Parent.Parent.core.ui.UIUtils)
local UIFade = require(script.Parent.Parent.Parent.core.ui.UIFade)

local SHOW_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local HIDE_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
-- Tamaño relativo desde el que crece y al que encoge.
local HIDDEN_SCALE = 0.95

export type WrapItem = {
	KillGoal: number?,
	MasteryScope: string?,
	PreviewWeaponDisplayName: string?,
}

local LockerWrapInfo = {}
LockerWrapInfo.__index = LockerWrapInfo

export type LockerWrapInfo = typeof(setmetatable(
	{} :: {
		_frame: GuiObject?,
		_label: TextLabel?,
		_openSize: UDim2,
		_hiddenSize: UDim2,
		_fadeTargets: { UIFade.FadeTarget },
		_fadeTweens: { Tween },
		_slot: Retween.Slot,
		_visible: boolean,
	},
	LockerWrapInfo
))

local function wrapDisplayName(wrapId: string): string
	local def = ItemsConfig.WeaponWraps[wrapId]
	return if type(def) == "table" and type(def.Name) == "string" then def.Name else wrapId
end

local function joinWrapNames(wrapIds: { string }): string
	local names = {}
	for _, wrapId in wrapIds do
		table.insert(names, wrapDisplayName(wrapId))
	end
	if #names <= 1 then
		return names[1] or ""
	end
	return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

local function describeUnlock(item: WrapItem, weaponCategory: string): string?
	local weaponName = item.PreviewWeaponDisplayName or "this weapon"
	if item.KillGoal and item.KillGoal > 0 then
		return `Get {UIUtils.formatCountShort(item.KillGoal)} kills with the {weaponName} to unlock this wrap.`
	end
	local scope = item.MasteryScope :: WrapMastery.Scope?
	if not scope then
		return nil
	end
	local required = joinWrapNames(WrapMastery.prerequisitesOf(scope))
	if scope == "Weapon" then
		return `Unlock {required} on the {weaponName} to earn this wrap.`
	elseif scope == "Category" then
		return `Unlock {required} on every {weaponCategory} weapon to earn this wrap for all of them.`
	end
	return `Unlock {required} on every weapon to earn this wrap for your whole arsenal.`
end

function LockerWrapInfo.new(lockerFrame: Instance): LockerWrapInfo
	local frameNode = lockerFrame:FindFirstChild("WrapInfo", true)
	local frame: GuiObject? = if frameNode and frameNode:IsA("GuiObject") then frameNode else nil
	local labelNode = if frame then frame:FindFirstChild("Text") else nil
	local label: TextLabel? = if labelNode and labelNode:IsA("TextLabel") then labelNode else nil
	if not (frame and label) then
		warn("[Locker] Falta Locker.WrapInfo con un TextLabel `Text`: no se explicará cómo desbloquear los wraps de Maestry.")
	end
	local openSize = if frame then frame.Size else UDim2.new()
	local fadeTargets = if frame then UIFade.collect(frame) else {}
	if frame then
		frame.Visible = false
	end

	return setmetatable({
		_frame = frame,
		_label = label,
		_openSize = openSize,
		_hiddenSize = UDim2.new(
			openSize.X.Scale * HIDDEN_SCALE,
			openSize.X.Offset * HIDDEN_SCALE,
			openSize.Y.Scale * HIDDEN_SCALE,
			openSize.Y.Offset * HIDDEN_SCALE
		),
		_fadeTargets = fadeTargets,
		_fadeTweens = {},
		_slot = { current = nil },
		_visible = false,
	}, LockerWrapInfo)
end

function LockerWrapInfo._animate(self: LockerWrapInfo, visible: boolean): Tween
	for _, tween in self._fadeTweens do
		tween:Cancel()
	end
	local info = if visible then SHOW_TWEEN_INFO else HIDE_TWEEN_INFO
	self._fadeTweens = UIFade.tween(self._fadeTargets, info, not visible)
	local size = if visible then self._openSize else self._hiddenSize
	return Retween.run(self._slot, self._frame :: GuiObject, info, { Size = size })
end

function LockerWrapInfo.hide(self: LockerWrapInfo)
	local frame = self._frame
	if not (frame and self._visible) then
		return
	end
	self._visible = false
	self:_animate(false).Completed:Once(function(state)
		if state == Enum.PlaybackState.Completed and not self._visible then
			frame.Visible = false
		end
	end)
end

-- nil oculta el panel (fuera de Maestry o sin wrap de maestría seleccionado).
function LockerWrapInfo.show(self: LockerWrapInfo, item: WrapItem?, weaponCategory: string)
	local frame = self._frame
	local label = self._label
	local text = if frame and label and item then describeUnlock(item, weaponCategory) else nil
	if not (frame and label and text) then
		self:hide()
		return
	end
	label.Text = text
	if self._visible then
		return
	end
	-- Si venía de ocultarse a medias, arranca desde oculto igualmente.
	UIFade.set(self._fadeTargets, true)
	frame.Size = self._hiddenSize
	frame.Visible = true
	self._visible = true
	self:_animate(true)
end

function LockerWrapInfo.Destroy(self: LockerWrapInfo)
	Retween.cancel(self._slot)
	for _, tween in self._fadeTweens do
		tween:Cancel()
	end
end

return LockerWrapInfo
