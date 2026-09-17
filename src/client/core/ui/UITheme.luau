--!strict
-- Constantes visuales usadas en ≥2 archivos; las animaciones one-off de un
-- feature se quedan locales.

return table.freeze({
	StrokeDefault   = Color3.fromRGB(38, 38, 38),
	StrokeHover     = Color3.fromRGB(255, 255, 255),
	NavSelected     = Color3.fromRGB(249, 217, 93),
	NavUnselected   = Color3.fromRGB(35, 54, 99),

	NavTweenInfo    = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	HoverTweenInfo  = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	ClickTweenInfo  = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),

	NavSelectedScale   = 1.15,
	NavUnselectedScale = 1.0,
	ButtonHoverScale   = 1.04,
	ButtonClickScale   = 0.96,

	-- Color del Glow de la card del locker según rareza. Los consumidores caen
	-- a su RARITY_FALLBACK si la rareza no tiene entrada.

	LockerRarityGlow = table.freeze({
		Common    = Color3.fromRGB(0,230,30),
		Rare    = Color3.fromRGB(0, 124, 255),
		Legendary = Color3.fromRGB(221, 69, 0),
		Epic      = Color3.fromRGB(151, 0, 255),
		Mythic    = Color3.fromRGB(234, 0, 84),
	}) :: { [string]: Color3 },

	-- ColorSequence para Template.UIGradient de la card del locker por rareza.
	LockerRarityGradients = table.freeze({
		Common = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(0,230,30)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(91, 255, 180)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(0,230,30)),
		}),
		Rare = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(1, 88, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 224, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(1, 88, 255)),
		}),
		Epic = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(114, 0, 162)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(251, 9, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(114, 0, 162)),
		}),
		Legendary = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 120, 0)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 230, 100)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 120, 0)),
		}),
		Mythic = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 22)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(239, 128, 115)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 22)),
		}),
	}) :: { [string]: ColorSequence },
})
