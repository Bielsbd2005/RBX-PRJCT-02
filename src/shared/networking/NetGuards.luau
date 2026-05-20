--!strict
--[[
	NetGuards.luau
	Caps de longitud de strings para todos los packets C→S.

	ByteNet 0.4.7 NO impone maxLength a strings — el server es responsable de
	rechazar payloads excesivos antes de procesarlos. Sin esto, un cliente puede
	mandar strings arbitrariamente grandes (`itemId` de 1MB → gsub/concat O(n)
	en hot paths, presión de GC, ataque DoS asimétrico).

	Uso:
		local NetGuards = require(Shared.networking.NetGuards)
		local M = NetGuards.MAX

		Network.Shop.BuyItem.Listen(function(data, player)
			if not NetGuards.validate(data, {
				itemId = M.Id, category = M.Category,
				weaponCategory = M.Category, weaponId = M.Id,
			}) then
				return
			end
			-- ... lógica del handler
		end)

	Cualquier campo string que exceda el cap → handler retorna sin procesar.
]]

local NetGuards = {}

-- Caps por tipo lógico (en bytes — ByteNet escribe strings como UTF-8 raw).
-- Los valores son intencionalmente generosos para no bloquear UX legítimo.
NetGuards.MAX = table.freeze({
	Id            = 32,   -- itemId, weaponId, wrapId
	Category      = 16,   -- "Main", "Special", "Faces", "Hats", "KillEffects", "Outfits", "WeaponWraps"
	SettingKey    = 32,   -- claves de Settings (whitelisted server-side igualmente)
	SettingChoice = 32,   -- valores enum de Settings (whitelisted)
	Code          = 24,   -- códigos canjeables (típicamente <12 chars)
	ClaimType     = 16,   -- "LikeJoin" | "Notifications" | "Code"
	Track         = 16,   -- "Free" | "Premium"
	MapName       = 32,
	Mode          = 24,   -- "TeamDeathmatch", etc.
	Kind          = 16,   -- "Bullet" | "Health"
	UserIdString  = 16,   -- numeric UserId codificado como string
	AssetUri      = 96,   -- "rbxassetid://<digits>"
})

--[[
	validate(data, schema) → boolean
	Chequea que cada campo en `schema` sea un string ≤ max.
	Devuelve false si `data` no es tabla, si falta un campo, o si excede el cap.

	schema: { [fieldName] = maxBytes }
]]
function NetGuards.validate(data: any, schema: { [string]: number }): boolean
	if type(data) ~= "table" then
		return false
	end

	for field, max in schema do
		local value = data[field]
		if type(value) ~= "string" or #value > max then
			return false
		end
	end

	return true
end

return table.freeze(NetGuards)
