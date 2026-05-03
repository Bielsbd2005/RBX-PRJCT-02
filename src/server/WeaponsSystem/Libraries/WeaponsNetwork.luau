--!strict
-- WeaponsNetwork: capa fina sobre los RemoteEvents del sistema de armas.
-- Permite que las armas no conozcan los nombres de los packets ni la API
-- subyacente — y abre la puerta a swap de transporte sin tocar cada arma.

local WeaponsNetwork = {}

local _system: any = nil

local function getEvent(name: string)
	return _system.getRemoteEvent(name)
end

function WeaponsNetwork.bind(weaponsSystem: any)
	_system = weaponsSystem
end

-- ── Client → Server ───────────────────────────────────────────

function WeaponsNetwork.fireWeaponFired(weaponInst: Instance, fireInfo: any)
	getEvent("WeaponFired"):FireServer(weaponInst, fireInfo)
end

function WeaponsNetwork.fireWeaponHit(weaponInst: Instance, hitInfo: any)
	getEvent("WeaponHit"):FireServer(weaponInst, hitInfo)
end

function WeaponsNetwork.fireReloadRequest(weaponInst: Instance)
	getEvent("WeaponReloadRequest"):FireServer(weaponInst)
end

function WeaponsNetwork.fireReloadCanceled(weaponInst: Instance)
	getEvent("WeaponReloadCanceled"):FireServer(weaponInst)
end

-- ── Server → All Clients ──────────────────────────────────────

function WeaponsNetwork.broadcastWeaponFired(player: Player?, weaponInst: Instance, fireInfo: any)
	getEvent("WeaponFired"):FireAllClients(player, weaponInst, fireInfo)
end

function WeaponsNetwork.broadcastWeaponActivated(player: Player?, weaponInst: Instance, activated: boolean)
	getEvent("WeaponActivated"):FireAllClients(player, weaponInst, activated)
end

function WeaponsNetwork.broadcastReloaded(player: Player?, weaponInst: Instance)
	getEvent("WeaponReloaded"):FireAllClients(player, weaponInst)
end

function WeaponsNetwork.broadcastReloadCanceled(player: Player?, weaponInst: Instance)
	getEvent("WeaponReloadCanceled"):FireAllClients(player, weaponInst)
end

function WeaponsNetwork.broadcastExplosionVFX(position: Vector3)
	getEvent("PlayExplosionVFX"):FireAllClients(position)
end

return WeaponsNetwork
