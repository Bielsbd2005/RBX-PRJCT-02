--!strict
--[[
	Network.luau
	Definiciones centralizadas de todos los paquetes ByteNet del juego.
	Importar este módulo tanto en Server como en Client — ByteNet sincroniza
	los IDs de paquetes automáticamente vía ReplicatedValue al arrancar.

	Namespaces:
	  Network.Settings    — Sincronización de configuración del jugador
	  Network.Shop        — Acciones de tienda (compra / equip) y sus respuestas
	  Network.Combat      — Eventos de combate en tiempo real (kill feed, etc.)

	API de paquete:
	  Server envía:  Packet.SendTo(data, player)  |  Packet.SendToAll(data)
	  Client envía:  Packet.Send(data)
	  Escuchar:      Packet.Listen(fn)  donde  fn(data, player?) -> ()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages          = ReplicatedStorage:WaitForChild("Packages")

local ByteNet = require(Packages.bytenet) :: any

-- ────────────────────────────────────────────────────────────
-- NAMESPACE: Settings
-- Peticiones tipadas del cliente para actualizar sus propios Settings.
-- ────────────────────────────────────────────────────────────

local SettingsNamespace = ByteNet.DefineNamespace("Settings", function()
	return {
		-- C → S: Actualiza un setting numérico en rango [0, 1].
		UpdateSlider = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				key   = ByteNet.String,
				value = ByteNet.Float32,
			}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Actualiza un setting booleano.
		UpdateToggle = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				key   = ByteNet.String,
				value = ByteNet.Bool,
			}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Actualiza un setting tipo enum (string whitelisted).
		UpdateChoice = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				key   = ByteNet.String,
				value = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Actualiza un color RGB (componentes 0..1).
		UpdateColor = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				key = ByteNet.String,
				r   = ByteNet.Float32,
				g   = ByteNet.Float32,
				b   = ByteNet.Float32,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- NAMESPACE: Shop
-- Acciones de tienda bidireccionales.
-- ────────────────────────────────────────────────────────────

local ShopNamespace = ByteNet.DefineNamespace("Shop", function()
	return {
		-- C → S: Solicitud de compra de ítem
		BuyItem = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				itemId   = ByteNet.String,
				category = ByteNet.String,
				weaponCategory = ByteNet.String,
				weaponId = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Solicitud de equipar ítem (ya poseído)
		EquipItem = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				category = ByteNet.String,
				itemId   = ByteNet.String,
				weaponCategory = ByteNet.String,
				weaponId = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Respuesta a BuyItem o EquipItem
		Response = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				success = ByteNet.Bool,
				message = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- NAMESPACE: Combat
-- Eventos de combate de baja latencia (unreliable).
-- ────────────────────────────────────────────────────────────

local CombatNamespace = ByteNet.DefineNamespace("Combat", function()
	return {
		-- S → C: Evento de kill feed
		KillFeed = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				killerName = ByteNet.String,
				victimName = ByteNet.String,
				weaponId   = ByteNet.String,
			}),
			-- One-shot kill feed events must not drop under packet loss.
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- NAMESPACE: Rewards
-- Acciones y respuestas de recompensas sociales/códigos.
-- ────────────────────────────────────────────────────────────

local RewardsNamespace = ByteNet.DefineNamespace("Rewards", function()
	return {
		-- C → S: Claim de Like+Join (flujo mixto).
		ClaimLikeJoin = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Claim de recompensa de notificaciones.
		ClaimNotifications = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Canje de código.
		RedeemCode = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				code = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Respuesta unificada.
		Response = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				success = ByteNet.Bool,
				message = ByteNet.String,
				claimType = ByteNet.String,
				rewardCash = ByteNet.Int32,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- NAMESPACE: Match
-- Eventos one-shot del flujo de partida. El estado ambiental (fase, mapa,
-- votación, score) NO viaja por aquí: se replica vía attributes en
-- Shared/MatchSnapshot — los clientes leen el valor vigente y observan cambios.
-- ────────────────────────────────────────────────────────────

local MatchNamespace = ByteNet.DefineNamespace("Match", function()
	return {
		-- C → S: Solicitud para entrar a la partida (desde menu Play).
		RequestJoinMatch = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Confirmacion de spawn completo; permite quitar fade.
		JoinMatchSpawned = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Estado global de kills, muertes, asistencias y racha por jugador en
		-- la partida actual.
		PlayerStreakState = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				userId = ByteNet.String,
				kills = ByteNet.Int32,
				deaths = ByteNet.Int32,
				assists = ByteNet.Int32,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Resultado final de la ronda.
		RoundEnded = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				winnerTeam = ByteNet.String,
				scoreA = ByteNet.Int32,
				scoreB = ByteNet.Int32,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Roster de bots activos (JSON-encoded array).
		BotRoster = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				json = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Cosméticos (outfit/face/hat) de los compañeros REALES del receptor,
		-- para reconstruir sus réplicas en la pantalla de Resultados. Se envía solo
		-- a cada jugador su propio equipo (JSON: [{ userId, outfitId, faceId, hatId }]).
		TeamCosmetics = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				json = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Recompensas de fin de partida del receptor para la pantalla de
		-- Resultados (JSON). Se envía solo a jugadores elegibles, JUSTO antes de
		-- RoundEnded para que el cliente ya las tenga al mostrar la pantalla.
		-- El cash ya fue concedido server-side (independiente de que se vea o no).
		-- Forma: { outcome = "Victory"|"Defeat",
		--          rewards = { { title, image, amount, locked }, ... } }
		-- `rewards` es la lista aplanada (cash + items) — el cliente usa UN solo
		-- template (amount>0 = cash con Amount; amount==0 = item sin Amount).
		MatchResults = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				json = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Mostrar death screen con cooldown de respawn.
		DeathScreenShow = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				respawnCooldown = ByteNet.Int32,
				killerUserId = ByteNet.String,
				killerName = ByteNet.String,
				killerKills = ByteNet.Int32,
				killerLevel = ByteNet.Int32,
				weaponId = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Ocultar death screen.
		DeathScreenHide = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Respawn manual desde death screen.
		RequestRespawn = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Volver al menu desde death screen.
		RequestReturnToMenu = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Confirmacion de vuelta al menu.
		ReturnToMenuDone = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Voto del jugador (puede cambiar durante la ventana activa).
		CastVote = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				mapName = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Sync inicial del estado event-driven (streaks de todos los
		-- jugadores + roster de bots) cuando el cliente termina de cargar. El
		-- estado ambiental viaja por MatchSnapshot y no necesita resync.
		RequestMatchSync = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Recoger un pickup (Bullet o Health) generado por una kill.
		RequestPickup = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				kind = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- NAMESPACE: Locker
-- UX del Locker (acciones del cliente que no caben en Shop).
-- ────────────────────────────────────────────────────────────

local LockerNamespace = ByteNet.DefineNamespace("Locker", function()
	return {
		-- C → S: Quitar el badge "NEW!" de un ítem que el jugador acaba de ver.
		MarkItemSeen = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				category = ByteNet.String,
				itemId   = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- NAMESPACE: BattlePass
-- Claim de tiers, compra de Premium (Robux developer product) y respuesta
-- unificada server → client.
-- ────────────────────────────────────────────────────────────

local BattlePassNamespace = ByteNet.DefineNamespace("BattlePass", function()
	return {
		-- C → S: Reclamar la recompensa de un tier. Cada nivel tiene una sola
		-- recompensa (free o pass); el servidor deduce el tipo del config y valida
		-- tier completado, ownership Premium (si es pass) y no-doble-claim.
		ClaimTier = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				tier = ByteNet.Int32,
			}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Iniciar compra del pase Premium. El servidor llama a
		-- MarketplaceService:PromptProductPurchase con el productId activo.
		BuyPremium = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Iniciar compra del developer product "Skip Tier" (+1 nivel).
		BuySkip = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Respuesta unificada. tier=0 cuando no aplica (e.g. PremiumGranted).
		Response = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				success = ByteNet.Bool,
				message = ByteNet.String,
				tier    = ByteNet.Int32,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- NAMESPACE: Gifting
-- Envío de regalos (packs de cash comprados con Robux) y su claim.
--
-- Envío: el cliente elige receptor en UserInterface.Gifting y manda SendGift;
-- el servidor valida (producto, receptor, GiftsEnabled del receptor), persiste
-- la intención en el perfil del comprador (GiftIntent) y lanza el prompt de
-- compra. Al procesarse el receipt, el regalo se entrega al receptor (online:
-- write directo a PendingGifts; offline/otro server: ProfileStore MessageAsync)
-- y el comprador recibe GiftDelivered.
--
-- Recepción: NO tiene packet de aviso — PendingGifts se replica por
-- ReplicaService y el GiftAlert del cliente lo observa; solo el claim viaja.
-- ────────────────────────────────────────────────────────────

local GiftingNamespace = ByteNet.DefineNamespace("Gifting", function()
	return {
		-- C → S: Enviar un regalo. receiverUserId = UserId numérico como string.
		-- productId va en Float64: los developer products actuales (~3.5e9) ya
		-- desbordan Int32; Float64 es exacto para enteros hasta 2^53.
		SendGift = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				receiverUserId = ByteNet.String,
				productId      = ByteNet.Float64,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Resultado de la VALIDACIÓN de SendGift. success=true significa
		-- "prompt de compra lanzado", no "regalo entregado" (eso es GiftDelivered).
		SendResponse = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				success = ByteNet.Bool,
				message = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: El receipt se procesó y el regalo quedó entregado (o encolado
		-- para un receptor offline). Cierra el flujo de envío en el cliente.
		GiftDelivered = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				receiverUserId = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Reclamar un regalo pendiente (botón Claim del GiftAlert).
		ClaimGift = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				giftId = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Resultado del claim. cashAmount alimenta el toast de éxito.
		ClaimResponse = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				success    = ByteNet.Bool,
				giftId     = ByteNet.String,
				message    = ByteNet.String,
				cashAmount = ByteNet.Int32,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- NAMESPACE: WeaponStats
-- El locker muestra los stats de combate del arma seleccionada. Esos valores
-- viven en la Configuration del Tool real (ServerStorage.WeaponTools), que NO
-- se replica al cliente — así que el cliente los PIDE y el server los lee y
-- responde. Valores BASE (nivel 1): el escalado por nivel (WeaponLevelConfig)
-- es config pública compartida y lo aplica el cliente con sus propias kills,
-- evitando un round-trip por cada subida de nivel.
-- ────────────────────────────────────────────────────────────

local WeaponStatsNamespace = ByteNet.DefineNamespace("WeaponStats", function()
	return {
		-- C → S: pedir los stats de un arma (por categoría + id).
		Request = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				weaponCategory = ByteNet.String,  -- "Main" | "Special"
				weaponId       = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: stats BASE del arma + rangos del arsenal para normalizar barras.
		-- weaponCategory/weaponId se reflejan para que el cliente correlacione la
		-- respuesta con su selección actual (descarta respuestas tardías de un
		-- arma que ya no está seleccionada). damage = HitDamage o BlastDamage si
		-- el arma explota al impactar. fireRate = balas/min (60/ShotCooldown).
		-- damageMax/fireRateMax/reloadMin son agregados del arsenal entero.
		Response = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				weaponCategory = ByteNet.String,
				weaponId       = ByteNet.String,
				success        = ByteNet.Bool,
				damage         = ByteNet.Float32,
				fireRate       = ByteNet.Float32,
				reloadTime     = ByteNet.Float32,
				ammoCapacity   = ByteNet.Int32,
				damageMax      = ByteNet.Float32,
				fireRateMax    = ByteNet.Float32,
				reloadMin      = ByteNet.Float32,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- NAMESPACE: WrapCases
-- Unboxing de cases de wraps (Store). El cliente pide abrir una case; el
-- server valida cash, rolea wrap (ponderado, WrapCasesConfig) + arma (uniforme
-- entre las armas del inventario, excluyendo combinaciones ya poseídas),
-- concede y responde con el resultado — el cliente solo ANIMA el resultado.
-- ────────────────────────────────────────────────────────────

local WrapCasesNamespace = ByteNet.DefineNamespace("WrapCases", function()
	return {
		-- C → S: Abrir una case (compra + roll en la misma acción).
		Open = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				caseId = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Resultado del unboxing. Con success=false, los campos de roll
		-- van vacíos y message explica el rechazo.
		Result = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				success        = ByteNet.Bool,
				message        = ByteNet.String,
				caseId         = ByteNet.String,
				wrapId         = ByteNet.String,
				weaponCategory = ByteNet.String,
				weaponId       = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- EXPORT
-- ────────────────────────────────────────────────────────────

return {
	Settings    = SettingsNamespace,
	Shop        = ShopNamespace,
	Combat      = CombatNamespace,
	Rewards     = RewardsNamespace,
	Locker      = LockerNamespace,
	Match       = MatchNamespace,
	BattlePass  = BattlePassNamespace,
	Gifting     = GiftingNamespace,
	WeaponStats = WeaponStatsNamespace,
	WrapCases   = WrapCasesNamespace,
}
