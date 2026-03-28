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
-- NAMESPACE: Prestige
-- Solicitud de ascenso de prestige y respuesta del servidor.
-- ────────────────────────────────────────────────────────────

local PrestigeNamespace = ByteNet.DefineNamespace("Prestige", function()
	return {
		-- C → S: intento de subir de prestige.
		Request = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: resultado de la operacion.
		Response = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				success = ByteNet.Bool,
				message = ByteNet.String,
				newPrestige = ByteNet.Int32,
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
	Prestige   = PrestigeNamespace,
}
