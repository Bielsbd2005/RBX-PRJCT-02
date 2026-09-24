--!strict
--[[
	Caps de longitud de strings y rangos numéricos para los packets C→S.

	ByteNet NO impone maxLength a strings: el server debe rechazar payloads
	excesivos antes de procesarlos (strings de 1MB → gsub/concat O(n) en hot paths,
	presión de GC, DoS asimétrico). Campo que no cumple → validate devuelve false.
]]

local NetGuards = {}

-- Caps por tipo lógico (en bytes — ByteNet escribe strings como UTF-8 raw).
-- Los valores son intencionalmente generosos para no bloquear UX legítimo.
NetGuards.MAX = table.freeze({
	Id            = 32,   -- itemId, weaponId, wrapId
	Category      = 16,
	SettingKey    = 32,   -- claves de Settings (whitelisted server-side igualmente)
	Code          = 24,   -- códigos canjeables (típicamente <12 chars)
	ClaimType     = 16,   -- "LikeJoin" | "Code"
	MapName       = 32,
	Kind          = 16,   -- "Bullet" | "Health"
	UserIdString  = 16,   -- numeric UserId codificado como string
	AssetUri      = 96,   -- "rbxassetid://<digits>"
	Username      = 32,   -- nombre de usuario Roblox (≤20 chars; margen para espacios/typos)
	GiftId        = 64,   -- key de PendingGifts (PurchaseId del receipt, GUID-like)
})

export type NumberRule = {
	kind: "number",
	min: number?,
	max: number?,
	integer: boolean?,
}

-- Una entrada de schema es:
--   * un number  → cap de bytes para un campo string (además exige UTF-8 válido)
--   * una tabla  → regla numérica { kind = "number", min?, max?, integer? }
export type Rule = number | NumberRule

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

function NetGuards.validate(data: any, schema: { [string]: Rule }): boolean
	if type(data) ~= "table" then
		return false
	end

	for field, rule in schema do
		local value = data[field]
		if type(rule) == "number" then
			if type(value) ~= "string" or #value > rule then
				return false
			end
			-- Rechaza UTF-8 inválido: algunos strings (username, code) se reenvían a web
			-- APIs de Roblox.
			if utf8.len(value) == nil then
				return false
			end
		else
			if not validNumber(value, rule) then
				return false
			end
		end
	end

	return true
end

return table.freeze(NetGuards)
