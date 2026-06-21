--!strict
-- WeaponsNetwork: capa fina sobre los RemoteEvents del sistema de armas.
-- Permite que las armas no conozcan los nombres de los packets ni la API
-- subyacente — y abre la puerta a swap de transporte sin tocar cada arma.

local Players = game:GetService("Players")

local WeaponsNetwork = {}

local _system: any = nil
local SHOT_BROADCAST_RANGE = 300
local SHOT_BROADCAST_RANGE_SQ = SHOT_BROADCAST_RANGE * SHOT_BROADCAST_RANGE

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
	-- Culling con la posición server-side del tirador, no con fireInfo.origin
	-- (dato del cliente: permitía manipular qué clientes reciben el broadcast).
	-- Fallback a fireInfo.origin solo para armas sin Player (montadas/NPC),
	-- donde el payload lo generó el propio server.
	local origin = nil
	local shooterChar = player and player.Character
	local shooterRoot = shooterChar and shooterChar:FindFirstChild("HumanoidRootPart")
	if shooterRoot then
		origin = (shooterRoot :: BasePart).Position
	elseif not player and typeof(fireInfo) == "table" and typeof(fireInfo.origin) == "Vector3" then
		origin = fireInfo.origin
	end
	if typeof(origin) ~= "Vector3" then
		getEvent("WeaponFired"):FireAllClients(player, weaponInst, fireInfo)
		return
	end

	local event = getEvent("WeaponFired")
	for _, p in Players:GetPlayers() do
		if p == player then
			continue
		end
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			local delta = (root :: BasePart).Position - origin
			if delta:Dot(delta) > SHOT_BROADCAST_RANGE_SQ then
				continue
			end
		end
		event:FireClient(p, player, weaponInst, fireInfo)
	end
end

function WeaponsNetwork.broadcastReloaded(player: Player?, weaponInst: Instance)
	local origin = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not origin then
		getEvent("WeaponReloaded"):FireAllClients(player, weaponInst)
		return
	end
	local pos = (origin :: BasePart).Position
	local event = getEvent("WeaponReloaded")
	for _, p in Players:GetPlayers() do
		if p == player then continue end
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			local delta = (root :: BasePart).Position - pos
			if delta:Dot(delta) > SHOT_BROADCAST_RANGE_SQ then continue end
		end
		event:FireClient(p, player, weaponInst)
	end
end

function WeaponsNetwork.broadcastReloadCanceled(player: Player?, weaponInst: Instance)
	local origin = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not origin then
		getEvent("WeaponReloadCanceled"):FireAllClients(player, weaponInst)
		return
	end
	local pos = (origin :: BasePart).Position
	local event = getEvent("WeaponReloadCanceled")
	for _, p in Players:GetPlayers() do
		if p == player then continue end
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			local delta = (root :: BasePart).Position - pos
			if delta:Dot(delta) > SHOT_BROADCAST_RANGE_SQ then continue end
		end
		event:FireClient(p, player, weaponInst)
	end
end

function WeaponsNetwork.broadcastExplosionVFX(position: Vector3)
	getEvent("PlayExplosionVFX"):FireAllClients(position)
end

return WeaponsNetwork
