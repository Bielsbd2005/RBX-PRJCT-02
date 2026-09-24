--!strict
--[[
	Paquetes ByteNet. Requerir en server y cliente: ByteNet sincroniza los IDs de
	paquete vía ReplicatedValue al arrancar.

	Server: Packet.SendTo(data, player) | Packet.SendToAll(data). Cliente: Packet.Send(data).
	Packet.Listen(fn(data, player?)) devuelve una función de desconexión.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages          = ReplicatedStorage:WaitForChild("Packages")

local ByteNet = require(Packages.bytenet) :: any

local SettingsNamespace = ByteNet.DefineNamespace("Settings", function()
	return {
		-- C → S. value en [0, 1].
		UpdateSlider = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				key   = ByteNet.String,
				value = ByteNet.Float32,
			}),
			ReliabilityType = "Reliable",
		}),

		UpdateToggle = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				key   = ByteNet.String,
				value = ByteNet.Bool,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

local ShopNamespace = ByteNet.DefineNamespace("Shop", function()
	return {
		BuyItem = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				itemId   = ByteNet.String,
				category = ByteNet.String,
				weaponCategory = ByteNet.String,
				weaponId = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		EquipItem = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				category = ByteNet.String,
				itemId   = ByteNet.String,
				weaponCategory = ByteNet.String,
				weaponId = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		Response = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				success = ByteNet.Bool,
				message = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

local CombatNamespace = ByteNet.DefineNamespace("Combat", function()
	return {
		KillFeed = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				killerName = ByteNet.String,
				victimName = ByteNet.String,
				weaponId   = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

local RewardsNamespace = ByteNet.DefineNamespace("Rewards", function()
	return {
		ClaimLikeJoin = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		RedeemCode = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				code = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

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

-- Solo eventos one-shot. El estado ambiental (fase, mapa, votación, score) se
-- replica vía attributes en Shared/MatchSnapshot.
local MatchNamespace = ByteNet.DefineNamespace("Match", function()
	return {
		RequestJoinMatch = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- S → C. Spawn completo: el cliente quita el fade.
		JoinMatchSpawned = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		PlayerStreakState = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				userId = ByteNet.String,
				kills = ByteNet.Int32,
				deaths = ByteNet.Int32,
				assists = ByteNet.Int32,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C. Respuesta a RequestJoinMatch cuando no se entra: sin ella el cliente
		-- esperaría JOIN_CONFIRM_TIMEOUT. reason: "TeamsFull" | "DataNotLoaded" | "SpawnFailed".
		JoinRejected = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				reason = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- roster: "userId:A,userId:B" de los jugadores reales elegibles. El cliente no puede
		-- sacar el bando de Player.Team: SpawnAtLobby lo pone a nil en el mismo frame.
		RoundEnded = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				winnerTeam = ByteNet.String,
				scoreA = ByteNet.Int32,
				scoreB = ByteNet.Int32,
				roster = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C. json: array de bots activos.
		BotRoster = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				json = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C. Compañeros REALES del receptor para la pantalla de Resultados.
		-- json: [{ userId, outfitId, faceId, hatId }]
		TeamCosmetics = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				json = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C. Solo a elegibles y JUSTO antes de RoundEnded. Puramente visual: el cash
		-- ya se concedió server-side.
		-- json: { outcome = "Victory"|"Defeat", rewards = { { title, image, amount, locked }, ... } }
		-- amount > 0 = cash; amount == 0 = ítem.
		MatchResults = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				json = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		DeathScreenShow = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				respawnCooldown = ByteNet.Int32,
				killerUserId = ByteNet.String,
				killerName = ByteNet.String,
				killerLevel = ByteNet.Int32,
				-- ItemsConfig.Banners: el equipado (jugador) o el de su personalidad (bot).
				-- "Default" sin asesino o si no posee el equipado.
				killerBanner = ByteNet.String,
				weaponId = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		DeathScreenHide = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		RequestRespawn = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		RequestReturnToMenu = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		ReturnToMenuDone = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- C → S. Se puede cambiar el voto durante la ventana activa.
		CastVote = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				mapName = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- C → S. Pide streaks + roster de bots al terminar de cargar (MatchSnapshot no necesita resync).
		RequestMatchSync = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- C → S. Bootstrap del cliente terminado. Informativo, NO gatea el spawn: con
		-- CharacterAutoLoads=false StarterGui no se copia a PlayerGui hasta el primer spawn.
		-- Idempotente; ACK = atributo Player.JoinState = "Ready" (ClientBootStage.luau).
		ClientReady = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- C → S. kind: "Bullet" | "Health".
		RequestPickup = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				kind = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- Los skips de nivel no tienen packet: el cliente lanza PromptProductPurchase y el
-- servidor concede en ProcessReceipt (el resultado llega por Response).
local BattlePassNamespace = ByteNet.DefineNamespace("BattlePass", function()
	return {
		-- C → S. El servidor deduce free/pass del config y valida tier, Premium y doble claim.
		ClaimTier = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				tier = ByteNet.Int32,
			}),
			ReliabilityType = "Reliable",
		}),

		-- C → S. Premium se compra con Gems (BattlePassService:PromptPremium).
		BuyPremium = ByteNet.DefinePacket({
			Value = ByteNet.Struct({}),
			ReliabilityType = "Reliable",
		}),

		-- S → C. tier = 0 cuando no aplica.
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

-- SendGift valida y persiste GiftIntent antes del prompt; al procesarse el receipt
-- se entrega al receptor (online: PendingGifts; offline u otro server: MessageAsync).
-- La recepción no tiene packet: el cliente observa PendingGifts replicado.
local GiftingNamespace = ByteNet.DefineNamespace("Gifting", function()
	return {
		-- C → S. receiverUserId = UserId como string. productId en Float64: los ids de
		-- developer product desbordan Int32.
		SendGift = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				receiverUserId = ByteNet.String,
				productId      = ByteNet.Float64,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C. success = prompt de compra lanzado, NO regalo entregado (eso es GiftDelivered).
		SendResponse = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				success = ByteNet.Bool,
				message = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		-- S → C. Entregado o encolado para un receptor offline.
		GiftDelivered = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				receiverUserId = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

		ClaimGift = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				giftId = ByteNet.String,
			}),
			ReliabilityType = "Reliable",
		}),

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

-- C → S del WeaponsSystem. Los broadcasts S → C siguen en los RemoteEvents de
-- WeaponsSystem/Network. Van todos por aquí y no algunos por RemoteEvent: el server
-- descarta un WeaponHit cuyo WeaponFired no ha llegado, y ByteNet solo garantiza el
-- orden entre sus propios paquetes. El server revalida todo en WeaponSecurity.
local WeaponsNamespace = ByteNet.DefineNamespace("Weapons", function()
	return {
		WeaponFired = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				weapon = ByteNet.Inst,
				id     = ByteNet.Float64,
				origin = ByteNet.Vec3,
				dir    = ByteNet.Vec3,
				charge = ByteNet.Float32,
			}),
			ReliabilityType = "Reliable",
		}),

		WeaponHit = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				weapon = ByteNet.Inst,
				sid    = ByteNet.Float64,
				pid    = ByteNet.Uint8,
				part   = ByteNet.Inst,
				p      = ByteNet.Vec3,
				n      = ByteNet.Vec3,
				d      = ByteNet.Float32,
			}),
			ReliabilityType = "Reliable",
		}),

		WeaponReloadRequest = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				weapon = ByteNet.Inst,
			}),
			ReliabilityType = "Reliable",
		}),

		WeaponReloadCanceled = ByteNet.DefinePacket({
			Value = ByteNet.Struct({
				weapon = ByteNet.Inst,
			}),
			ReliabilityType = "Reliable",
		}),
	}
end)

-- Payloads C → S tal como llegan al handler. Deben coincidir con el Struct de cada
-- packet de arriba; el contenido es del cliente y se valida con NetGuards.
export type Empty = {}
export type SliderPayload = { key: string, value: number }
export type TogglePayload = { key: string, value: boolean }
export type ShopItemPayload = { itemId: string, category: string, weaponCategory: string, weaponId: string }
export type RedeemCodePayload = { code: string }
export type CastVotePayload = { mapName: string }
export type RequestPickupPayload = { kind: string }
export type ClaimTierPayload = { tier: number }
export type SendGiftPayload = { receiverUserId: string, productId: number }
export type ClaimGiftPayload = { giftId: string }
export type WeaponFiredPayload = { weapon: Instance?, id: number, origin: Vector3, dir: Vector3, charge: number }
export type WeaponHitPayload = {
	weapon: Instance?,
	sid: number,
	pid: number,
	part: Instance?,
	p: Vector3,
	n: Vector3,
	d: number,
}
export type WeaponPayload = { weapon: Instance? }

return {
	Settings    = SettingsNamespace,
	Shop        = ShopNamespace,
	Combat      = CombatNamespace,
	Rewards     = RewardsNamespace,
	Match       = MatchNamespace,
	BattlePass  = BattlePassNamespace,
	Gifting     = GiftingNamespace,
	Weapons     = WeaponsNamespace,
}
