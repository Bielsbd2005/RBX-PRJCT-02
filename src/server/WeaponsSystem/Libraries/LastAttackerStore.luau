--!strict

export type LastAttackerInfo = { UserId: number, At: number, WeaponId: string, Headshot: boolean }

local store: { [Humanoid]: LastAttackerInfo } = setmetatable({}, { __mode = "k" }) :: any

local LastAttackerStore = {}

function LastAttackerStore.get(humanoid: Humanoid): LastAttackerInfo?
	return store[humanoid]
end

function LastAttackerStore.set(humanoid: Humanoid, userId: number, weaponId: string, headshot: boolean?)
	local now = time()
	store[humanoid] = {
		UserId = userId,
		At = now,
		WeaponId = weaponId,
		Headshot = headshot == true,
	}
	humanoid:SetAttribute("LastAttackerAt", now)
end

return LastAttackerStore
