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
	MapName       = 32,
	Kind          = 16,   -- "Bullet" | "Health"
	UserIdString  = 16,   -- numeric UserId codificado como string
	AssetUri      = 96,   -- "rbxassetid://<digits>"
	Username      = 32,   -- nombre de usuario Roblox (≤20 chars; margen para espacios/typos)
})

--[[
	Regla numérica para campos Float32/Int32 que vienen del cliente.
	Uso en un schema:
		Network.Settings.UpdateSlider.Listen(function(data, player)
			if not NetGuards.validate(data, {
				key   = M.SettingKey,
				value = { kind = "number", min = 0, max = 1 },
			}) then return end
		end)
]]
export type NumberRule = {
	kind: "number",
	min: number?,
	max: number?,
	integer: boolean?,
}

-- Una entrada de schema es:
--   * un number  → cap de bytes para un campo string (comportamiento original)
--   * una tabla  → regla numérica { kind = "number", min?, max?, integer? }
export type Rule = number | NumberRule

--[[
	validNumber(value, rule) → boolean
	Rechaza no-números, NaN (v ~= v), ±inf, no-enteros (si rule.integer) y
	valores fuera de [rule.min, rule.max].
]]
local function validNumber(value: any, rule: NumberRule): boolean
	if type(value) ~= "number" then
		return false
	end
	-- NaN: el único valor que no es igual a sí mismo.
	if value ~= value then
		return false
	end
	if value == math.huge or value == -math.huge then
		return false
	end
	if rule.integer and value % 1 ~= 0 then
		return false
	end
	if rule.min ~= nil and value < rule.min then
		return false
	end
	if rule.max ~= nil and value > rule.max then
		return false
	end
	return true
end

--[[
	validate(data, schema) → boolean
	Chequea cada campo en `schema`:
		* regla number → string ≤ max bytes y UTF-8 válido (comportamiento original + UTF-8).
		* regla tabla {kind="number", ...} → número finito dentro de rango (validNumber).
	Devuelve false si `data` no es tabla, si falta un campo, o si alguna regla falla.

	schema: { [fieldName] = Rule }
]]
function NetGuards.validate(data: any, schema: { [string]: Rule }): boolean
	if type(data) ~= "table" then
		return false
	end

	for field, rule in schema do
		local value = data[field]
		if type(rule) == "number" then
			-- Cap de bytes para strings (comportamiento original).
			if type(value) ~= "string" or #value > rule then
				return false
			end
			-- Rechaza secuencias UTF-8 inválidas (strings que se reenvían a web APIs
			-- de Roblox como username/code romperían/abusarían esos endpoints).
			if utf8.len(value) == nil then
				return false
			end
		else
			-- Regla numérica.
			if not validNumber(value, rule) then
				return false
			end
		end
	end

	return true
end

return table.freeze(NetGuards)
