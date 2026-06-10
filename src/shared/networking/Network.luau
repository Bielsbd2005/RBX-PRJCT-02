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
				streak = ByteNet.Int32,
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
-- Selección del destinatario de un regalo: el cliente manda un nombre de
-- usuario, el servidor lo resuelve (GetUserIdFromNameAsync) + filtra el texto
-- (TextService) y responde con el userId/nombre canónico o un error.
-- ────────────────────────────────────────────────────────────

local GiftingNamespace = ByteNet.DefineNamespace("Gifting", function()
	return {
		-- C → S: Validar un nombre de usuario como posible destinatario.
		ValidateUser = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				username = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Resultado de la validación. success=false ⇒ message contiene el
		-- motivo (usuario inexistente, no se puede uno mismo, etc.). En éxito,
		-- userId es el UserId numérico como string y username el nombre filtrado.
		Response = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				success  = ByteNet.Bool,
				message  = ByteNet.String,
				userId   = ByteNet.String,
				username = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- EXPORT
-- ────────────────────────────────────────────────────────────

return {
	Settings   = SettingsNamespace,
	Shop       = ShopNamespace,
	Combat     = CombatNamespace,
	Rewards    = RewardsNamespace,
	Locker     = LockerNamespace,
	Match      = MatchNamespace,
	BattlePass = BattlePassNamespace,
	Gifting    = GiftingNamespace,
}
