--[[
	StoreConstants
	Constantes centralizadas para la Store UI.
	Colores, fuentes, y configuraciones de tabs.
]]

local StoreConstants = {}

-- Paleta de colores
StoreConstants.Colors = {
	Background = Color3.fromRGB(25, 25, 25),
	White = Color3.fromRGB(253, 255, 255),
	CardBackground = Color3.fromRGB(244, 250, 255),
	CardStroke = Color3.fromRGB(131, 131, 131),
	CloseBase = Color3.fromRGB(202, 44, 73),
	CloseTop = Color3.fromRGB(255, 63, 77),
	TabActive = Color3.fromRGB(85, 126, 239),
	TabInactive = Color3.fromRGB(54, 54, 76),
	NavOptionActive = Color3.fromRGB(85, 126, 239),
	Selected = Color3.fromRGB(255, 255, 255),
}

-- Fuente principal
StoreConstants.Font = Font.new(
	"rbxasset://fonts/families/HighwayGothic.json",
	Enum.FontWeight.Bold,
	Enum.FontStyle.Normal
)

-- Asset IDs
StoreConstants.Assets = {
	CardTexture = "rbxassetid://71136216021149",
	CurrencyIcon = "rbxassetid://96222277892751",
	LockIcon = "rbxassetid://121709682417919",
	Placeholder = "rbxasset://textures/ui/GuiImagePlaceholder.png",
}

-- Tabs de la tienda (se iteran para generar los botones)
StoreConstants.Tabs = {
	{
		Name = "Arsenal",
		Text = "ARSENAL",
		LayoutOrder = 1,
	},
	{
		Name = "Cosmetics",
		Text = "COSMETICS",
		LayoutOrder = 2,
	},
}

-- Opciones de navegación por tab
StoreConstants.NavOptions = {
	Arsenal = {
		{ Name = "Weapons",     Image = "rbxassetid://86111407632869", Title = "Weapons" },
		{ Name = "WeaponSkins", Image = "rbxassetid://86111407632869", Title = "Weapon Skins" },
		{ Name = "KillEffects", Image = "rbxassetid://86111407632869", Title = "Kill Effects" },
	},
	Cosmetics = {
		{ Name = "Hats",  Image = "rbxassetid://86111407632869", Title = "Hats" },
		{ Name = "Faces", Image = "rbxassetid://86111407632869", Title = "Faces" },
		{ Name = "Outfits", Image = "rbxassetid://86111407632869", Title = "Outfits" },
	},
}

-- Animation IDs (shared across LockerUI, OutfitCard, etc.)
StoreConstants.AnimationIds = {
	Idle = "rbxassetid://77576237797818",
}

-- Spawn location names in Workspace.Locker
StoreConstants.SpawnNames = {
	Character = "CharacterSpawn",
	Weapon = "WeaponSpawn",
	KillEffect = "KillEffectSpawn",
}

-- Camera part names in Workspace.Cameras
StoreConstants.CameraNames = {
	Locker = "Locker",
	KillEffects = "KillEffects",
}

-- Rarity-based color themes for item cards
StoreConstants.RarityThemes = {
	Legendary = {
		Background   = Color3.fromRGB(253, 236, 118),
		ImageColor   = Color3.fromRGB(238, 184, 95),
		Stroke       = Color3.fromRGB(249, 181, 73),
		RarityText   = Color3.new(1, 1, 1),
		RarityStroke = Color3.fromRGB(200, 154, 57),
	},
	Epic = {
		Background   = Color3.fromRGB(224, 126, 255),
		ImageColor   = Color3.fromRGB(186, 98, 255),
		Stroke       = Color3.fromRGB(172, 0, 247),
		RarityText   = Color3.fromRGB(255, 210, 255),
		RarityStroke = Color3.fromRGB(161, 60, 241),
	},
	Rare = {
		Background   = Color3.fromRGB(184, 220, 255),
		ImageColor   = Color3.fromRGB(151, 190, 240),
		Stroke       = Color3.fromRGB(92, 132, 236),
		RarityText   = Color3.fromRGB(235, 244, 231),
		RarityStroke = Color3.fromRGB(114, 162, 220),
	},
	Common = {
		Background   = Color3.fromRGB(204, 255, 102),
		ImageColor   = Color3.fromRGB(153, 204, 102),
		Stroke       = Color3.fromRGB(153, 204, 102),
		RarityText   = Color3.new(1, 1, 1),
		RarityStroke = Color3.fromRGB(143, 143, 143),
	},
	Limited = {
		Background   = Color3.fromRGB(240, 102, 102),
		ImageColor   = Color3.fromRGB(155, 0, 11),
		Stroke       = Color3.fromRGB(155, 0, 11),
		RarityText   = Color3.fromRGB(255, 151, 136),
		RarityStroke = Color3.fromRGB(155, 0, 11),
	},
}

-- Convenience: get theme for a rarity string (case-insensitive first letter)
function StoreConstants.getTheme(rarity: string)
	local key = rarity and (rarity:sub(1,1):upper() .. rarity:sub(2):lower()) or "Common"
	return StoreConstants.RarityThemes[key] or StoreConstants.RarityThemes.Common
end

-- Layout constants for rarity/price labels (matching user templates)
StoreConstants.CardLayout = {
	RarityPosition = UDim2.fromScale(0, 0.0225),
	RaritySize     = UDim2.fromScale(1, 0.1685),
	RarityStrokeThickness = 2.1,
	RarityMaxTextSize = 46,
	PricePosition  = UDim2.fromScale(0.422, 0.8145),
	PriceSize      = UDim2.fromScale(0.578, 0.129),
	PriceMaxTextSize = 42,
}

return StoreConstants
