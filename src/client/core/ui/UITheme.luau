--!strict
--[[
	UITheme.luau
	Single source of truth para constantes visuales reutilizadas (colores,
	TweenInfos, escalas). Cualquier curva de animación que aparezca en ≥2
	archivos vive aquí — promueve consistencia visual y evita allocations
	duplicadas al cargar módulos.

	Convención:
	  • TweenInfos cortas (≤0.15s) para micro-interacciones (hover/click).
	  • HoverMedium (0.2s) para transiciones suaves de estado en panels.
	  • Si una animación es one-off de un feature, mantenerla local —
	    UITheme solo agrega lo compartido.
]]

return table.freeze({
	StrokeDefault   = Color3.fromRGB(38, 38, 38),
	StrokeHover     = Color3.fromRGB(255, 255, 255),
	NavSelected     = Color3.fromRGB(249, 217, 93),
	NavUnselected   = Color3.fromRGB(35, 54, 99),

	NavTweenInfo    = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	HoverTweenInfo  = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	HoverMedium     = TweenInfo.new(0.2,  Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	ClickTweenInfo  = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),

	NavSelectedScale   = 1.15,
	NavUnselectedScale = 1.0,
	ButtonHoverScale   = 1.04,
	ButtonClickScale   = 0.96,

	-- Color por rareza (labels de rarity del CaseContent, glow del unboxing…).
	RarityColors = table.freeze({
		Common    = Color3.fromRGB(190, 190, 190),
		Uncommon  = Color3.fromRGB(96, 200, 96),
		Rare      = Color3.fromRGB(80, 150, 255),
		Epic      = Color3.fromRGB(180, 90, 255),
		Legendary = Color3.fromRGB(249, 217, 93),
	}) :: { [string]: Color3 },

	-- Color del Glow (aro/resplandor) de la card del locker según rareza. Set
	-- nuevo de 4 tiers del rediseño del template; las rarezas legacy
	-- (Uncommon/Rare) caen al fallback Common vía LockerRarityGlow[...] or Common.
	LockerRarityGlow = table.freeze({
		Common    = Color3.fromRGB(0, 124, 255),
		Legendary = Color3.fromRGB(221, 69, 0),
		Epic      = Color3.fromRGB(151, 0, 255),
		Mythic    = Color3.fromRGB(234, 0, 84),
	}) :: { [string]: Color3 },

	-- ColorSequence para Template.UIGradient de la card del locker por rareza.
	LockerRarityGradients = table.freeze({
		Common = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(1, 88, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 224, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(1, 88, 255)),
		}),
		Legendary = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 120, 0)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 230, 100)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 120, 0)),
		}),
		Epic = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(114, 0, 162)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(251, 9, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(114, 0, 162)),
		}),
		Mythic = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 22)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(239, 128, 115)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 22)),
		}),
	}) :: { [string]: ColorSequence },
})
