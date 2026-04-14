--!strict
--[[
	CasesConfig.luau
	Definición estática de todas las cajas y su contenido.
	Cada Case referencia skins de ItemsConfig.WeaponSkins por skinId.

	Estructura:
	  CasesConfig.Cases[caseId] = CaseDefinition
	  CasesConfig.LuckyBoost = { ... }
]]

-- ────────────────────────────────────────────────────────────
-- TIPOS
-- ────────────────────────────────────────────────────────────

export type CaseDrop = {
	SkinId: string,
	Weight: number,      -- Peso base (sin lucky)
	LuckyWeight: number, -- Peso con lucky activo
}

export type CaseDefinition = {
	Name: string,
	Price: number,           -- Precio en Cash por 1 apertura
	PriceMulti: number,      -- Precio en Cash por X aperturas
	PityThreshold: number,   -- Tiradas hasta pity drop garantizado
	PityDropSkinId: string,  -- SkinId que se entrega en pity
	Drops: { CaseDrop },
}

export type LuckyBoostDefinition = {
	DurationMinutes: number, -- Duración del boost en minutos
	ProductId: number,       -- ID del DevProduct de Robux
	PriceText: string,       -- Texto de precio para la UI
}

export type RarityGradientStyle = {
	StartColor: Color3,
	EndColor: Color3,
	Rotation: number,
	StrokeColor: Color3?,
}

export type CasesConfigType = {
	Cases: { [string]: CaseDefinition },
	CasesInOrder: { string },
	MultiCount: number,
	LuckyBoost: LuckyBoostDefinition,
	RarityOrder: { string },
	RarityGradients: { [string]: RarityGradientStyle },
}

-- ────────────────────────────────────────────────────────────
-- DATOS
-- ────────────────────────────────────────────────────────────

local CasesConfig: CasesConfigType = {
	MultiCount = 4,

	LuckyBoost = {
		DurationMinutes = 10,
		ProductId = 3575379226,
		PriceText = " 99",
	},

	RarityOrder = {
		"Common",
		"Uncommon",
		"Rare",
		"Epic",
		"Legendary",
	},

	RarityGradients = {
		Common = {
			StartColor = Color3.fromRGB(122, 136, 154),
			EndColor = Color3.fromRGB(165, 175, 188),
			Rotation = 20,
			StrokeColor = Color3.fromRGB(189, 199, 214),
		},
		Uncommon = {
			StartColor = Color3.fromRGB(71, 161, 90),
			EndColor = Color3.fromRGB(104, 198, 123),
			Rotation = 20,
			StrokeColor = Color3.fromRGB(130, 229, 149),
		},
		Rare = {
			StartColor = Color3.fromRGB(68, 112, 214),
			EndColor = Color3.fromRGB(95, 151, 255),
			Rotation = 20,
			StrokeColor = Color3.fromRGB(125, 178, 255),
		},
		Epic = {
			StartColor = Color3.fromRGB(173, 87, 224),
			EndColor = Color3.fromRGB(210, 127, 255),
			Rotation = 20,
			StrokeColor = Color3.fromRGB(225, 156, 255),
		},
		Legendary = {
			StartColor = Color3.fromRGB(222, 153, 48),
			EndColor = Color3.fromRGB(255, 211, 109),
			Rotation = 20,
			StrokeColor = Color3.fromRGB(255, 227, 150),
		},
		Default = {
			StartColor = Color3.fromRGB(79, 94, 124),
			EndColor = Color3.fromRGB(113, 131, 168),
			Rotation = 20,
			StrokeColor = Color3.fromRGB(134, 154, 192),
		},
	},

	CasesInOrder = { "Case1", "Case2" },

	Cases = {
		Case1 = {
			Name = "Starter Case",
			Price = 200,
			PriceMulti = 1800,
			PityThreshold = 35,
			PityDropSkinId = "Skin_Blue",
			Drops = {
				{ SkinId = "Default",   Weight = 75, LuckyWeight = 58 },
				{ SkinId = "Skin_Blue", Weight = 25, LuckyWeight = 42 },
                { SkinId = "Skin_Red",  Weight = 80, LuckyWeight = 62 },
				{ SkinId = "Skin_Gold", Weight = 20, LuckyWeight = 38 },
			},
		},
		Case2 = {
			Name = "Premium Case",
			Price = 650,
			PriceMulti = 5800,
			PityThreshold = 50,
			PityDropSkinId = "Skin_Gold",
			Drops = {
				{ SkinId = "Skin_Red",  Weight = 80, LuckyWeight = 62 },
				{ SkinId = "Skin_Gold", Weight = 20, LuckyWeight = 38 },
			},
		},
	},
}

return table.freeze(CasesConfig)
