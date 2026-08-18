--!strict
--[[
	Style — apariencia CENTRALIZADA del render.

	Antes esto era configurable desde la UI (color/grosor/transparencia por cada
	tipo de adorno), pero esos controles no aportaban nada al trabajo real —
	solo ruido. La apariencia vive acá, hardcodeada y con nombres claros; si algún
	día querés retocar un color, es un único lugar.

	Lo FUNCIONAL (RoamMinDist/RoamMaxDist, tope de rutas, qué se muestra) sigue en
	Config.luau porque sí cambia el resultado, no solo cómo se ve.
]]

local Style = {}

-- Marcadores de RoamPoints (esferas).
Style.markerColor = Color3.fromRGB(0, 200, 255)
Style.markerRadius = 1.5
Style.markerTransparency = 0.35

-- Anillos de alcance (discos min/max).
Style.ringColor = Color3.fromRGB(255, 180, 0)
Style.ringTransparency = 0.8

-- Rutas reales (PathfindingService).
Style.pathColor = Color3.fromRGB(0, 255, 120)
Style.pathThickness = 3 -- px (LineHandleAdornment: grosor en pantalla)
Style.pathTransparency = 0

-- Puntos de spawn (jugadores y NPCs de IA) + flecha de orientación.
-- El punto de spawn es una esfera; la flecha apunta EXACTAMENTE hacia donde
-- mirará quien aparezca ahí (LookVector del BasePart del spawn, ver Scanner/Renderer).
Style.spawnColor = Color3.fromRGB(255, 80, 80)
Style.spawnRadius = 1.4
Style.spawnTransparency = 0.3
Style.spawnArrowColor = Color3.fromRGB(255, 190, 40)
Style.spawnArrowThickness = 4 -- px (grosor de la línea en pantalla)
Style.spawnArrowLength = 6 -- studs (largo del cuerpo de la flecha)
Style.spawnArrowHeadLength = 1.8 -- studs (largo de cada barba de la punta)
Style.spawnArrowHeadAngle = 32 -- grados de apertura de la punta (V)

return Style
