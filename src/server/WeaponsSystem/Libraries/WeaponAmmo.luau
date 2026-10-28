--!strict
-- Munición que ve el jugador. El cliente predice la de su arma en LOCAL_ATTR: un atributo
-- puesto en cliente no replica y el servidor nunca lo pisa. SERVER_ATTR (lo escribe el
-- servidor) llega RTT×cadencia disparos tarde y no debe sobrescribir la cuenta local.

local WeaponAmmo = {}

WeaponAmmo.SERVER_ATTR = "CurrentAmmo"
WeaponAmmo.LOCAL_ATTR = "LocalAmmo"

function WeaponAmmo.read(tool: Instance): number?
	local localAmmo = tool:GetAttribute(WeaponAmmo.LOCAL_ATTR)
	if typeof(localAmmo) == "number" then
		return localAmmo
	end
	local serverAmmo = tool:GetAttribute(WeaponAmmo.SERVER_ATTR)
	return if typeof(serverAmmo) == "number" then serverAmmo else nil
end

return WeaponAmmo
