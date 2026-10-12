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
local WeaponMasteryClasses = require(Shared.constants.WeaponMasteryClasses)
local WrapMastery = require(Shared.data.WrapMastery)
local Retween = require(Shared.utils.Retween)
local UIUtils = require(script.Parent.Parent.Parent.core.ui.UIUtils)
local UIFade = require(script.Parent.Parent.Parent.core.ui.UIFade)
local LockerInventoryState = require(script.Parent.LockerInventoryState)

local SHOW_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local HIDE_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
-- Tamaño relativo desde el que crece y al que encoge.
local HIDDEN_SCALE = 0.95

export type WrapItem = {
	id: string,
	MasteryScope: string?,
	PreviewWeaponCategory: string?,
	PreviewWeaponId: string?,
	PreviewWeaponDisplayName: string?,
}

type Inventory = LockerInventoryState.LockerInventoryState

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

local function displayName(category: string, itemId: string): string
	local catalog = ItemsConfig[category]
	local def = if type(catalog) == "table" then catalog[itemId] else nil
	return if type(def) == "table" and type(def.Name) == "string" and def.Name ~= "" then def.Name else itemId
end

local function joinNames(names: { string }): string
	if #names <= 1 then
		return names[1] or ""
	end
	return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

local function joinWrapNames(wrapIds: { string }): string
	local names = {}
	for _, wrapId in wrapIds do
		table.insert(names, displayName("WeaponWraps", wrapId))
	end
	return joinNames(names)
end

-- Qué hay que hacer con el arma para completar el desafío, sin el "to unlock".
local function describeChallenge(challenge: WrapMastery.Challenge, weaponCategory: string, weaponId: string, weaponName: string): string
	local goal = UIUtils.formatCountShort(challenge.goal)
	if challenge.stat == "Kills" then
		return `Get {goal} kills with the {weaponName}`
	end
	local class = WrapMastery.classOf(weaponCategory, weaponId)
	if challenge.stat == "Streaks" then
		return `Get {class.StreakLength} kills in a single life with the {weaponName}, {goal} times`
	elseif class.Precision == "CloseKills" then
		return `Get {goal} kills within {WeaponMasteryClasses.CloseRange} studs with the {weaponName}`
	elseif class.Precision == "LongKills" then
		return `Get {goal} kills from {WeaponMasteryClasses.LongRange}+ studs away with the {weaponName}`
	end
	return `Get {goal} headshot kills with the {weaponName}`
end

-- Solo nombra lo que aún falta: lo ya conseguido lo cuenta la tarjeta.
local function describeUnlock(item: WrapItem, inventory: Inventory): string?
	local weaponCategory, weaponId = item.PreviewWeaponCategory, item.PreviewWeaponId
	if not (weaponCategory and weaponId) then
		return nil
	end
	local weaponName = item.PreviewWeaponDisplayName or "this weapon"
	local function owns(category: string, id: string, wrapId: string): boolean
		return inventory:ownsWrap(category, id, wrapId)
	end
	if owns(weaponCategory, weaponId, item.id) then
		return `Unlocked on the {weaponName}.`
	end

	local challenge = WrapMastery.challengeOf(item.id, weaponCategory, weaponId)
	if challenge then
		local requires = challenge.requires
		local needsRequired = requires ~= nil and not owns(weaponCategory, weaponId, requires)
		local remaining = challenge.goal - inventory:getWeaponStat(weaponCategory :: any, weaponId, challenge.stat)
		if remaining <= 0 and requires then
			return `Unlock {displayName("WeaponWraps", requires)} on the {weaponName} to earn this wrap.`
		end
		local objective = describeChallenge(challenge, weaponCategory, weaponId, weaponName)
		return if needsRequired and requires
			then `{objective} and unlock {displayName("WeaponWraps", requires)} on it to earn this wrap.`
			else `{objective} to unlock this wrap.`
	end

	local scope = item.MasteryScope :: WrapMastery.Scope?
	if not scope then
		return nil
	end
	if scope == "Weapon" then
		local missing = joinWrapNames(WrapMastery.missingWraps(owns, weaponCategory, weaponId))
		return `Unlock {missing} on the {weaponName} to earn this wrap.`
	end

	local required = joinWrapNames(WrapMastery.prerequisitesOf(scope))
	local missing = WrapMastery.missingWeapons(owns, scope, weaponCategory, weaponId)
	local _, total = WrapMastery.progress(owns, scope, weaponCategory, weaponId)
	if scope == "Category" then
		if #missing == total then
			return `Unlock {required} on every {weaponCategory} weapon to earn this wrap for all of them.`
		end
		local weaponNames = {}
		for _, target in missing do
			table.insert(weaponNames, displayName(target[1], target[2]))
		end
		return `Unlock {required} on the {joinNames(weaponNames)} to earn this wrap for every {weaponCategory} weapon.`
	end
	if #missing == total then
		return `Unlock {required} on every weapon to earn this wrap for your whole arsenal.`
	end
	local categories = {}
	for _, target in missing do
		if not table.find(categories, target[1]) then
			table.insert(categories, target[1])
		end
	end
	return `Unlock {required} on every {joinNames(categories)} weapon to earn this wrap for your whole arsenal.`
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
function LockerWrapInfo.show(self: LockerWrapInfo, item: WrapItem?, inventory: Inventory)
	local frame = self._frame
	local label = self._label
	local text = if frame and label and item then describeUnlock(item, inventory) else nil
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
