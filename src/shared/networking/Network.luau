--!strict
--[[
	Network.luau
	Definiciones centralizadas de todos los paquetes ByteNet del juego.
	Importar este módulo tanto en Server como en Client — ByteNet sincroniza
	los IDs de paquetes automáticamente vía ReplicatedValue al arrancar.

	Namespaces:
	  Network.PlayerData  — Sincronización de configuración del jugador
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
-- NAMESPACE: PlayerData
-- Peticiones del cliente para actualizar sus propios Settings.
-- ────────────────────────────────────────────────────────────

local PlayerDataNamespace = ByteNet.DefineNamespace("PlayerData", function()
	return {
		-- C → S: Actualiza una clave de Settings (key = nombre, value = valor serializado como string)
		UpdateSetting = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				key   = ByteNet.String,
				value = ByteNet.String, -- serializar en cliente, deserializar en servidor
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
			}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Solicitud de equipar ítem (ya poseído)
		EquipItem = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				category = ByteNet.String,
				itemId   = ByteNet.String,
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
-- NAMESPACE: Admin
-- Consola de administración: gestión y testeo de datos de jugadores.
-- El servidor identifica al admin por el argumento `player` nativo
-- de ByteNet — nunca por datos del payload (evita suplantación).
-- ────────────────────────────────────────────────────────────

local AdminNamespace = ByteNet.DefineNamespace("Admin", function()
	return {
		-- C → S: Solicita la lista de jugadores en el servidor.
		-- _placeholder existe porque ByteNet.Struct requiere al menos un campo.
		RequestPlayerList = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				_placeholder = ByteNet.Bool,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Lista de jugadores serializada "userId|displayName;userId|displayName"
		PlayerListSnapshot = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				list = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Solicita el perfil completo de un jugador objetivo.
		RequestProfile = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				targetUserId = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Perfil serializado como JSON string.
		ProfileSnapshot = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				targetUserId = ByteNet.String,
				snapshot     = ByteNet.String, -- HttpService:JSONEncode(profile.Data)
				success      = ByteNet.Bool,
				message      = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- C → S: Ejecuta un comando admin sobre un jugador objetivo.
		-- command: "SetStat" | "SetInventoryItem" | "SetLoadoutSlot" |
		--          "SetSetting" | "GiveCash" | "GiveGems" | "ResetProfile"
		-- payload: HttpService:JSONEncode({...}) según el comando
		ExecuteCommand = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				targetUserId = ByteNet.String,
				command      = ByteNet.String,
				payload      = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C: Resultado del comando ejecutado.
		CommandResponse = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				success = ByteNet.Bool,
				message = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- ────────────────────────────────────────────────────────────
-- EXPORT
-- ────────────────────────────────────────────────────────────

return {
	PlayerData = PlayerDataNamespace,
	Shop       = ShopNamespace,
	Combat     = CombatNamespace,
	Admin      = AdminNamespace,
}
