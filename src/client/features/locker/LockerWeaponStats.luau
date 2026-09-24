--!strict
--[[
	Stats del arma en el Locker: se derivan en local de Shared (WeaponDisplayStats), sin
	red, y comparan la SELECCIONADA contra la EQUIPADA de su categoría. Pinta en
	WeaponStatsPanel (SurfaceGui de Workspace.Locker.Stats).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponDisplayStats = require(Shared.constants.WeaponsConfig.DisplayStats)
local WeaponCategoryMod = require(Shared.constants.WeaponCategory)
local WeaponStatsPanel = require(script.Parent.WeaponStatsPanel)
local LockerCatalog = require(script.Parent.LockerCatalog)

type WeaponCategory = WeaponCategoryMod.WeaponCategory
type LockerCatalogItem = LockerCatalog.LockerCatalogItem
type WeaponBaseStats = WeaponDisplayStats.WeaponDisplayStats

-- Debounce: al scrollear solo se renderiza el arma donde uno se detiene.
local RENDER_DELAY = 0.06

type DisplayStats = {
	damage: number,
	fireRate: number,
	reload: number,
	ammo: number,
	damageFill: number,
	fireRateFill: number,
	reloadFill: number,
	ammoFill: number,
}

export type Deps = {
	anchor: Instance?,
	janitor: any,
	-- Solo se pinta con la cámara de armas delante (Arsenal fuera de la vista de wraps).
	isVisibleContext: () -> boolean,
	getEquippedWeapon: (category: WeaponCategory) -> string,
}

export type LockerWeaponStats = {
	request: (self: LockerWeaponStats, item: LockerCatalogItem?) -> (),
	Destroy: (self: LockerWeaponStats) -> (),
}

type Internal = LockerWeaponStats & {
	_deps: Deps,
	_panel: any,
	_category: string,
	_itemId: string,
	_token: number,
	_alive: boolean,
}

local LockerWeaponStats = {}
LockerWeaponStats.__index = LockerWeaponStats

-- Fills 0..1 normalizados contra los rangos del arsenal. Reload invertido: más fill =
-- recarga más rápida.
local function displayStatsFor(base: WeaponBaseStats): DisplayStats
	local damage = base.damage
	local ammo = base.ammoCapacity
	local fireRate = base.fireRate
	local reload = base.reloadTime
	return {
		damage = damage,
		fireRate = fireRate,
		reload = reload,
		ammo = ammo,
		damageFill = if base.damageMax > 0 then damage / base.damageMax else 0,
		fireRateFill = if base.fireRateMax > 0 then fireRate / base.fireRateMax else 0,
		reloadFill = if reload > 0 then base.reloadMin / reload else 1,
		ammoFill = if base.ammoMax > 0 then ammo / base.ammoMax else 0,
	}
end

-- Los fills ya codifican dirección: más fill = mejor en todos los stats.
local function dirFromFill(selFill: number, eqFill: number): string
	if selFill > eqFill + 1e-3 then
		return "up"
	elseif selFill < eqFill - 1e-3 then
		return "down"
	end
	return "equal"
end

local function statEntry(value: number, fill: number, eqValue: number, eqFill: number)
	return {
		value = value,
		fill = fill,
		compareFill = eqFill,
		delta = value - eqValue,
		dir = dirFromFill(fill, eqFill),
	}
end

local function buildStatsModel(sel: DisplayStats, eq: DisplayStats): WeaponStatsPanel.StatsModel
	return {
		Damage = statEntry(sel.damage, sel.damageFill, eq.damage, eq.damageFill),
		FireRate = statEntry(sel.fireRate, sel.fireRateFill, eq.fireRate, eq.fireRateFill),
		Reload = statEntry(sel.reload, sel.reloadFill, eq.reload, eq.reloadFill),
		Ammo = statEntry(sel.ammo, sel.ammoFill, eq.ammo, eq.ammoFill),
	} :: any
end

function LockerWeaponStats.new(deps: Deps): LockerWeaponStats
	return setmetatable({
		_deps = deps,
		_panel = WeaponStatsPanel.new(deps.anchor, deps.janitor),
		_category = "",
		_itemId = "",
		_token = 0,
		_alive = true,
	}, LockerWeaponStats) :: any
end

local function render(self: Internal)
	local category = self._category
	if category == "" or self._itemId == "" or not self._deps.isVisibleContext() then
		return
	end
	local selected = WeaponDisplayStats.Get(category, self._itemId)
	local equipped = WeaponDisplayStats.Get(category, self._deps.getEquippedWeapon(category :: WeaponCategory))
	self._panel:setStats(buildStatsModel(displayStatsFor(selected), displayStatsFor(equipped)))
end

function LockerWeaponStats.request(self: Internal, item: LockerCatalogItem?)
	if not item or not WeaponCategoryMod.isValid(item.Category) or not self._deps.isVisibleContext() then
		self._category = ""
		self._itemId = ""
		return
	end

	self._category = item.Category
	self._itemId = item.id
	self._token += 1
	local token = self._token
	task.delay(RENDER_DELAY, function()
		if self._alive and token == self._token then
			render(self)
		end
	end)
end

function LockerWeaponStats.Destroy(self: Internal)
	self._alive = false
end

return LockerWeaponStats
