--!strict
--[[
	Fuente única de los assets de Roblox referenciados desde la LÓGICA del juego
	(UI, VFX, animaciones y sonidos).

	NO viven aquí, a propósito, los assets que son contenido de catálogo (thumbnails
	en ItemsConfig, LockerConfig, DailyTasks, GameConfig): son un campo más del ítem.

	Los nombres describen el USO, no el arte: dos entradas pueden compartir id sin
	que deban cambiar juntas.
]]

local function asset(assetId: number): string
	return "rbxassetid://" .. tostring(assetId)
end

local AssetIds = {}

AssetIds.Images = table.freeze({
	-- Locker: estado del ítem en la grid y acción del botón de compra.
	LockerLocked = asset(86881935952206),
	LockerPurchase = asset(120069483795815),
	LockerStatusCash = asset(70857919112721),
	LockerStatusGems = asset(136585960459787),
	-- Placeholder del card de un wrap que el jugador aún no posee.
	WrapLockedPlaceholder = asset(82849715642061),

	-- Icono de recompensa en Cash (Resultados y tiers del pase).
	CashReward = asset(113694528712529),

	-- HUD de partida.
	Skull = asset(130437553674754),
	-- Placeholder compartido por los cinco tiers de badge (Kill…Godlike) hasta
	-- que cada uno tenga su arte propio.
	KillBadge = asset(130873581439859),
	-- Spritesheet de la racha: ver COLUMNS/FRAME_WIDTH en StreakDisplay.
	StreakSheet = asset(79402287010899),
	HealPlus = asset(117688967482768),
	-- Fondo de los slots Item1/Item2 del hotbar de armas.
	HotbarSlotSelected = asset(129313135866427), --MIGRADO
	HotbarSlotIdle = asset(106733729660666), --MIGRADO

	-- Selector de destinatario del regalo.
	GiftRealPlayer = asset(91500847756674),
	GiftNpc = asset(109044845487335),
})

AssetIds.Animations = table.freeze({
	-- Animaciones stock de Roblox para el rig R6 de los bots.
	CharacterIdle = asset(507766388),
	CharacterRun = asset(507767714),
	CharacterJump = asset(507765000),
	BotToolHold = asset(80449761976468),

	-- Idle de los maniquíes en preview (locker y pantalla de resultados).
	PreviewIdle = asset(115197033304718),
	-- Idle del asesino en el viewport de la pantalla de muerte.
	KillerViewportIdle = asset(126774009783214),
})

AssetIds.Sounds = table.freeze({
	Pickup = asset(5728423829),
})

return table.freeze(AssetIds)
