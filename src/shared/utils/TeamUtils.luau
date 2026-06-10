--!strict
-- TeamUtils: single source of truth for team normalization and resolution.
-- Every team reference in the codebase should go through this module.

local Players = game:GetService("Players")

local TEAM_ATTRS = { "Team", "TeamSide", "BotTeam", "Side", "TeamAffinity" }

local TeamUtils = {}

function TeamUtils.normalize(raw: string?): string?
	if not raw or raw == "" then return nil end
	-- Case-fold so "Red"/"red" compare equal. Teams are TeamA/TeamB (GameConfig);
	-- unknown strings return nil (rather than original casing) so callers don't
	-- treat an unrecognized team as a distinct, enemy-eligible side.
	local low = string.lower(raw)
	if low == "a" or low == "teama" then return "A" end
	if low == "b" or low == "teamb" then return "B" end
	return nil
end

function TeamUtils.getSide(character: Model?): string?
	if not character then return nil end
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		if player.Team then
			return TeamUtils.normalize(player.Team.Name)
		end
		local attr = player:GetAttribute("TeamName")
		if typeof(attr) == "string" then
			return TeamUtils.normalize(attr)
		end
		return nil
	end
	for _, attrName in TEAM_ATTRS do
		local v = character:GetAttribute(attrName)
		if type(v) == "string" and v ~= "" then
			return TeamUtils.normalize(v)
		end
	end
	local leaderstats = character:FindFirstChild("leaderstats")
	if leaderstats then
		for _, attrName in TEAM_ATTRS do
			local sv = leaderstats:FindFirstChild(attrName)
			if sv and sv:IsA("StringValue") and sv.Value ~= "" then
				return TeamUtils.normalize(sv.Value)
			end
		end
	end
	return nil
end

function TeamUtils.isSameTeam(charA: Model?, charB: Model?): boolean
	local sideA = TeamUtils.getSide(charA)
	local sideB = TeamUtils.getSide(charB)
	if not sideA or not sideB then return false end
	return sideA == sideB
end

function TeamUtils.areEnemies(charA: Model?, charB: Model?): boolean
	-- Require BOTH sides to resolve to a real team. A teamless/lobby/mid-teleport
	-- character must NOT be treated as an enemy (which `not isSameTeam` would do,
	-- since two nil sides are "not same team").
	local sideA = TeamUtils.getSide(charA)
	local sideB = TeamUtils.getSide(charB)
	return sideA ~= nil and sideB ~= nil and sideA ~= sideB
end

return TeamUtils
