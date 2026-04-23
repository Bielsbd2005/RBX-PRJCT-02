--!strict
-- BotNames: pool of fake identities assigned to bots each round.

export type BotIdentity = {
	name: string,
	image: string,
}

local PLACEHOLDER_IMAGE = "rbxassetid://0" -- TODO: replace with real placeholder

local BotNames: { BotIdentity } = {
{ name = "xX_Blaze99_Xx",    image = PLACEHOLDER_IMAGE },
{ name = "CoolDude2012",      image = PLACEHOLDER_IMAGE },
{ name = "pro_gamer_lol",     image = PLACEHOLDER_IMAGE },
{ name = "NightOwl_034",      image = PLACEHOLDER_IMAGE },
{ name = "itzKevinn",         image = PLACEHOLDER_IMAGE },
{ name = "DarkSlayer007",     image = PLACEHOLDER_IMAGE },
{ name = "Frosty_Vibes",      image = PLACEHOLDER_IMAGE },
{ name = "noob2pro_rblx",     image = PLACEHOLDER_IMAGE },
{ name = "LegendKiller21",    image = PLACEHOLDER_IMAGE },
{ name = "SkullCrusher_X",    image = PLACEHOLDER_IMAGE },
{ name = "epicguy_2",       image = PLACEHOLDER_IMAGE },
{ name = "MrPvP_2014",        image = PLACEHOLDER_IMAGE },
{ name = "zZShadowzZ",        image = PLACEHOLDER_IMAGE },
{ name = "TheBestPlayer1",    image = PLACEHOLDER_IMAGE },
{ name = "Destroyer_9000",    image = PLACEHOLDER_IMAGE },
{ name = "iAmNotANoob",       image = PLACEHOLDER_IMAGE },
{ name = "RealGhost_YT",      image = PLACEHOLDER_IMAGE },
{ name = "Sniperking_RBX",    image = PLACEHOLDER_IMAGE },
{ name = "ultrafast99",       image = PLACEHOLDER_IMAGE },
{ name = "xProHunterx",       image = PLACEHOLDER_IMAGE },

}

return BotNames
