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
})
