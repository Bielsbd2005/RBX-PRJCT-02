--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DebugFlags = require(Shared:WaitForChild("utils"):WaitForChild("DebugFlags"))
local ItemsConfig = require(Shared:WaitForChild("constants"):WaitForChild("ItemsConfig"))
local ItemDefaults = require(Shared:WaitForChild("constants"):WaitForChild("ItemDefaults"))

local IS_STUDIO = RunService:IsStudio()
local IS_CLIENT = RunService:IsClient()
local unlockAllFlag = DebugFlags.bind(ReplicatedStorage, "UnlockAllLocker")

export type LockerCategoryKey = "Style" | "Arsenal" | "Effects"

export type LockerNavItemDefinition = {
	key: string,
	title: string,
	thumbnail: string,
}

local STYLE_NAV_ITEMS = table.freeze({
	{ key = "Body", title = "Body", thumbnail = "rbxassetid://137817236260095" },
	{ key = "Faces", title = "Faces", thumbnail = "rbxassetid://130328966728722" },
	{ key = "Hats", title = "Hats", thumbnail = "rbxassetid://126122024454210" },
})

local ARSENAL_NAV_ITEMS = table.freeze({
	{ key = "Main", title = "Main", thumbnail = "rbxassetid://99665561004765" },
	{ key = "Special", title = "Special", thumbnail = "rbxassetid://94351975111962" },
})

local EFFECTS_NAV_ITEMS = table.freeze({
	{ key = "KillEffects", title = "Kill Effects", thumbnail = "rbxassetid://130437553674754" },
	-- Thumbnail PROVISIONAL (el de Kill Effects) hasta que haya icono propio.
	{ key = "Banners", title = "Banners", thumbnail = "rbxassetid://130437553674754" },
	-- Thumbnail provisional (el de Kill Effects): subir un icono propio de emotes.
	{ key = "Emotes", title = "Emotes", thumbnail = "rbxassetid://130437553674754" },
})

local NAV_ITEMS = table.freeze({
	Style = STYLE_NAV_ITEMS,
	Arsenal = ARSENAL_NAV_ITEMS,
	Effects = EFFECTS_NAV_ITEMS,
})

-- Nav-key → categoría del catálogo. La única traducción no-identidad es Body→Outfits.
local ITEMS_CONFIG_BY_NAV = table.freeze({
	Style = table.freeze({
		Body = "Outfits",
		Faces = "Faces",
		Hats = "Hats",
	}),
	Arsenal = table.freeze({
		Main = "Main",
		Special = "Special",
		WeaponWraps = "WeaponWraps",
	}),
	Effects = table.freeze({
		KillEffects = "KillEffects",
		Banners = "Banners",
		Emotes = "Emotes",
	}),
})

local CATEGORY_TO_LOADOUT_SLOT = table.freeze({
	Main = "MainWeapon",
	Special = "SpecialWeapon",
	-- WeaponWraps no se mapea: el wrap equipado es por arma (MainWeaponWraps[weaponId] /
	-- SpecialWeaponWraps[weaponId]); sus call-sites (ShopService, locker/init) tienen ramas explícitas.
	KillEffects = "KillEffect",
	Emotes = "Emote",
	Faces = "Face",
	Hats = "Hat",
	Outfits = "Outfit",
	Banners = "Banner",
})

local RARITY_RANK = table.freeze({
	Common = 1,
	Rare = 2,
	Epic = 3,
	Legendary = 4,
	Mythic = 5,
})

local function makeQualifiedId(category: string, id: string): string
	return category .. "." .. id
end

local LockerConfig: any

-- Único UserId con permiso de admin para UnlockAll en servidores públicos.
local ADMIN_USER_ID = 286176976

local function isUserAdmin(playerOrUserId: (Player | number)?): boolean
	local userId: number? = nil

	if playerOrUserId == nil then
		if IS_CLIENT then
			local player = Players.LocalPlayer
			userId = if player then player.UserId else nil
		end
	elseif typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		userId = (playerOrUserId :: Player).UserId
	else
		userId = tonumber(playerOrUserId)
	end

	return userId == ADMIN_USER_ID
end

-- En Studio manda solo el BoolValue Debug.UnlockAllLocker (desbloquea a todos), para
-- que el admin pueda probar el locker como un jugador normal. Fuera, solo el admin.
local function isUnlockAllActive(playerOrUserId: (Player | number)?): boolean
	if IS_STUDIO then
		return unlockAllFlag() == true
	end
	return LockerConfig.UnlockAll == true and isUserAdmin(playerOrUserId)
end

local function getTotalNonDefaultWrapsCount(): number
	local count = 0
	for wrapId in ItemsConfig.WeaponWraps do
		if wrapId ~= ItemDefaults.ITEM_ID then
			count += 1
		end
	end
	return count
end

LockerConfig = {
	-- Solo cuenta fuera de Studio, y solo para el admin (ver isUnlockAllActive).
	UnlockAll = true,
	AdminUserId = ADMIN_USER_ID,
	NavItems = NAV_ITEMS,
	ItemsConfigByNav = ITEMS_CONFIG_BY_NAV,
	CategoryToLoadoutSlot = CATEGORY_TO_LOADOUT_SLOT,
	RarityRank = RARITY_RANK,
	makeQualifiedId = makeQualifiedId,
	isUnlockAllActive = isUnlockAllActive,
	isUserAdmin = isUserAdmin,
	getTotalNonDefaultWrapsCount = getTotalNonDefaultWrapsCount,
}

return table.freeze(LockerConfig)
