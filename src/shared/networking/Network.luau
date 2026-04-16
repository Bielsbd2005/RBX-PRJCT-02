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
			ReliabilityType = "Unreliable",
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
-- NAMESPACE: Cases
-- Acciones de cajas (compra, lucky boost, summon).
-- ────────────────────────────────────────────────────────────

local CasesNamespace = ByteNet.DefineNamespace("Cases", function()
	return {
		-- C → S: Comprar apertura de caja (single o multi)
		Summon = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				caseId = ByteNet.String,
				multi  = ByteNet.Bool,
			}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Comprar lucky boost (Robux, procesado via MarketplaceService)
		BuyLucky = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Respuesta genérica (compra, error, etc.)
		Response = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				success = ByteNet.Bool,
				message = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Resultado de un summon (para futura animación de unboxing)
		SummonResult = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				caseId    = ByteNet.String,
				skinId    = ByteNet.String,
				weaponCategory = ByteNet.String,
				weaponId  = ByteNet.String,
				isPity    = ByteNet.Bool,
				newPity   = ByteNet.Int32,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- NAMESPACE: Match
-- Flujo de votacion de mapa.
-- ────────────────────────────────────────────────────────────

local MatchNamespace = ByteNet.DefineNamespace("Match", function()
	return {
		-- S → C: Inicio de votacion con 3 opciones fijas.
		StartVote = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				optionAName = ByteNet.String,
				optionAImage = ByteNet.String,
				optionBName = ByteNet.String,
				optionBImage = ByteNet.String,
				optionCName = ByteNet.String,
				optionCImage = ByteNet.String,
				optionAMode = ByteNet.String,
				optionBMode = ByteNet.String,
				optionCMode = ByteNet.String,
				duration = ByteNet.Int32,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Estado de carga de mapa y disponibilidad de Play.
		MapLoadState = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				isLoading = ByteNet.Bool,
				playEnabled = ByteNet.Bool,
				mapName = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

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

		-- S → C: Estado de TeamDeathmatch (kills y tiempo restante).
		RoundState = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				scoreA = ByteNet.Int32,
				scoreB = ByteNet.Int32,
				timeLeft = ByteNet.Int32,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Estado global de kills y racha por jugador en la partida actual.
		PlayerStreakState = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				userId = ByteNet.String,
				kills = ByteNet.Int32,
				streak = ByteNet.Int32,
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

		-- S → C: Mostrar death screen con cooldown de respawn.
		DeathScreenShow = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				respawnCooldown = ByteNet.Int32,
				killerUserId = ByteNet.String,
				killerName = ByteNet.String,
				weaponName = ByteNet.String,
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

		-- C → S: Solicita re-sync del estado de votacion activo.
		RequestVoteSync = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Snapshot de votos y tiempo restante.
		VoteState = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				optionAName = ByteNet.String,
				optionAVotes = ByteNet.Int32,
				optionBName = ByteNet.String,
				optionBVotes = ByteNet.Int32,
				optionCName = ByteNet.String,
				optionCVotes = ByteNet.Int32,
				timeLeft = ByteNet.Int32,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Fin de votacion con mapa ganador.
		EndVote = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				winnerMapName = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- NAMESPACE: Debug
-- Herramientas de depuracion (solo Studio/dev en servidor).
-- ────────────────────────────────────────────────────────────


-- ────────────────────────────────────────────────────────────
-- EXPORT
-- ────────────────────────────────────────────────────────────

return {
	Settings   = SettingsNamespace,
	Shop       = ShopNamespace,
	Combat     = CombatNamespace,
	Rewards    = RewardsNamespace,
	Cases      = CasesNamespace,
	Match      = MatchNamespace,
}
