--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Network = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("networking"):WaitForChild("Network"))

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local WeaponsNetwork = {}

local _system: any = nil
local SHOT_RANGE_SQ = GameConfig.ShotBroadcastRange ^ 2
local SHOT_LOD_SQ = GameConfig.ShotBroadcastLodDistance ^ 2
local SHOT_LOD_DIVISOR = math.max(1, math.floor(GameConfig.ShotBroadcastLodDivisor))

-- HumanoidRootPart de cada jugador: los broadcasts corren por jugador y por disparo
-- (los bots disparan mucho) y un FindFirstChild por observador sumaría.
local _rootByPlayer: { [Player]: BasePart } = {}

local function trackCharacter(player: Player, character: Model)
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)
	if root and root:IsA("BasePart") and player.Character == character then
		_rootByPlayer[player] = root
	end
end

local function trackPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		trackCharacter(player, character)
	end)
	player.CharacterRemoving:Connect(function()
		_rootByPlayer[player] = nil
	end)
	if player.Character then
		task.spawn(trackCharacter, player, player.Character)
	end
end

if RunService:IsServer() then
	Players.PlayerAdded:Connect(trackPlayer)
	for _, player in Players:GetPlayers() do
		trackPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		_rootByPlayer[player] = nil
	end)
end

local function getEvent(name: string)
	return _system.getRemoteEvent(name)
end

function WeaponsNetwork.bind(weaponsSystem: any)
	_system = weaponsSystem
end

-- Cliente → server por ByteNet (ver Network.Weapons). Send serializa en el momento:
-- el caller puede reutilizar las tablas que pasa.
function WeaponsNetwork.fireWeaponFired(weaponInst: Instance, fireInfo: any)
	Network.Weapons.WeaponFired.Send({
		weapon = weaponInst,
		id = fireInfo.id,
		origin = fireInfo.origin,
		dir = fireInfo.dir,
		charge = fireInfo.charge or 1,
	})
end

function WeaponsNetwork.fireWeaponHit(weaponInst: Instance, hitInfo: any)
	Network.Weapons.WeaponHit.Send({
		weapon = weaponInst,
		sid = hitInfo.sid,
		pid = hitInfo.pid,
		part = hitInfo.part,
		p = hitInfo.p,
		n = hitInfo.n,
		d = hitInfo.d or 0,
	})
end

function WeaponsNetwork.fireReloadRequest(weaponInst: Instance)
	Network.Weapons.WeaponReloadRequest.Send({ weapon = weaponInst })
end

function WeaponsNetwork.fireReloadCanceled(weaponInst: Instance)
	Network.Weapons.WeaponReloadCanceled.Send({ weapon = weaponInst })
end

export type BroadcastOptions = {
	-- Solo para tiradores sin Player (bots): su origin lo calcula el server.
	origin: Vector3?,
	-- nil = no se sabe si acierta (disparo de jugador): no se aclara a distancia.
	hit: boolean?,
}

-- Único broadcast de disparos, para jugadores y bots (ver GameConfig.ShotBroadcast*).
function WeaponsNetwork.broadcastWeaponFired(player: Player?, weaponInst: Instance, fireInfo: any, options: BroadcastOptions?)
	-- Culling con la posición server-side del tirador, no con fireInfo.origin (dato del
	-- cliente, manipulable).
	local origin = if options then options.origin else nil
	local shooterChar = player and player.Character
	local shooterRoot = shooterChar and shooterChar:FindFirstChild("HumanoidRootPart")
	if shooterRoot then
		origin = (shooterRoot :: BasePart).Position
	end
	local event = getEvent("WeaponFired")
	if typeof(origin) ~= "Vector3" then
		event:FireAllClients(player, weaponInst, fireInfo)
		return
	end

	local hit = if options then options.hit else nil
	local shotId = if typeof(fireInfo) == "table" then tonumber(fireInfo.id) else nil
	local sendFar = hit == nil or (hit == true and (shotId or 0) % SHOT_LOD_DIVISOR == 0)
	for observer, root in _rootByPlayer do
		if observer == player or not root.Parent then
			continue
		end
		local delta = root.Position - origin
		local d2 = delta:Dot(delta)
		if d2 <= SHOT_LOD_SQ or (d2 <= SHOT_RANGE_SQ and sendFar) then
			event:FireClient(observer, player, weaponInst, fireInfo)
		end
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
			if delta:Dot(delta) > SHOT_RANGE_SQ then continue end
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
			if delta:Dot(delta) > SHOT_RANGE_SQ then continue end
		end
		event:FireClient(p, player, weaponInst)
	end
end

function WeaponsNetwork.broadcastExplosionVFX(position: Vector3)
	getEvent("PlayExplosionVFX"):FireAllClients(position)
end

return WeaponsNetwork
