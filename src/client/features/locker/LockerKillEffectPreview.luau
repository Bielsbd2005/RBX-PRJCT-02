--!strict
--[[
	Preview de kill effects y emotes en el Locker. Se hace SOBRE el personaje del lobby
	(P1), al que apunta Workspace.Cameras.killEffects: al clic se oculta y en su sitio y
	pose aparece un doble (LobbyCharacterPreview:buildLookClone) que recibe el efecto;
	pasado KillEffectsRegistry.previewTime el doble se destruye. Sin preview del lobby se
	usa el maniquí Shared.Bodies.KillEffectDummy en Workspace.Locker.DummySpawn.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Janitor = require(ReplicatedStorage:WaitForChild("Packages").janitor) :: any
local AssetIds = require(Shared.constants.AssetIds)
local KillEffectsRegistry = require(Shared.Locker.killEffects.KillEffectsRegistry)
local EmotePlayer = require(Shared.Locker.emotes.EmotePlayer)
local LockerUtils = require(script.Parent.LockerUtils)

local PREVIEW_COOLDOWN = 0.4

export type Deps = {
	lobbyCharacter: any,
	cameraController: any,
	lockerFolder: Instance,
	dummySpawn: Instance,
	dummyTemplate: Model,
}

export type LockerKillEffectPreview = {
	destroyDummy: (self: LockerKillEffectPreview) -> (),
	previewKillEffect: (self: LockerKillEffectPreview, effectId: string) -> (),
	spawnEmoteDummy: (self: LockerKillEffectPreview) -> (),
	previewEmote: (self: LockerKillEffectPreview, emoteId: string) -> (),
	Destroy: (self: LockerKillEffectPreview) -> (),
}

type Internal = LockerKillEffectPreview & {
	_deps: Deps,
	_dummy: Model?,
	_respawnTask: thread?,
	_previewingEffectId: string?,
	_nextAllowedAt: number,
}

local LockerKillEffectPreview = {}
LockerKillEffectPreview.__index = LockerKillEffectPreview

function LockerKillEffectPreview.new(deps: Deps): LockerKillEffectPreview
	local self = setmetatable({
		_deps = deps,
		_dummy = nil,
		_respawnTask = nil,
		_previewingEffectId = nil,
		_nextAllowedAt = 0,
	}, LockerKillEffectPreview) :: any
	return self
end

function LockerKillEffectPreview.destroyDummy(self: Internal)
	if self._respawnTask then
		task.cancel(self._respawnTask)
		self._respawnTask = nil
	end
	if self._dummy and self._dummy.Parent then
		self._dummy:Destroy()
	end
	self._dummy = nil
	self._previewingEffectId = nil
	self._deps.cameraController:followSubject(nil)
	self._deps.lobbyCharacter:setHiddenByOwner(false)
end

-- Doble del personaje del lobby (o el maniquí), listo para recibir el efecto.
local function spawnDummy(self: Internal): Model
	self:destroyDummy()
	local deps = self._deps

	local clone = deps.lobbyCharacter:buildLookClone()
	if clone then
		-- Ya viene con la pose del personaje vivo: no se recoloca ni se pasa a la pose
		-- canónica, o dejaría de coincidir con lo que se ve.
		local hrp = clone:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			hrp.Anchored = true
		end
		clone.Parent = deps.lockerFolder
		deps.lobbyCharacter:setHiddenByOwner(true)
	else
		clone = deps.dummyTemplate:Clone()
		clone.Parent = deps.lockerFolder
		LockerUtils.placePreviewCharacter(clone, deps.dummySpawn)
		LockerUtils.snapPartsToCanonicalPose(clone)
		-- Anclar HRP para que el maniquí no caiga antes de que el efecto lo suelte (los
		-- kill effects desanclan todo en su paso final).
		local hrp = clone:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			hrp.Anchored = true
		end
	end
	self._dummy = clone
	return clone
end

function LockerKillEffectPreview.previewKillEffect(self: Internal, effectId: string)
	if self._previewingEffectId == effectId and self._respawnTask then
		return
	end
	local now = os.clock()
	if now < self._nextAllowedAt then
		return
	end
	self._nextAllowedAt = now + PREVIEW_COOLDOWN

	local dummy = spawnDummy(self)
	self._previewingEffectId = effectId
	-- La cámara sigue un poco al cuerpo si sale volando hacia arriba. Se engancha antes
	-- de aplicar el efecto para medir la subida desde la pose de reposo.
	local followPart = dummy:FindFirstChild("LowerTorso")
		or dummy:FindFirstChild("Torso")
		or dummy:FindFirstChild("HumanoidRootPart")
	if followPart and followPart:IsA("BasePart") then
		self._deps.cameraController:followSubject(followPart)
	end
	KillEffectsRegistry.apply(effectId, dummy)
	self._respawnTask = task.delay(KillEffectsRegistry.previewTime(effectId), function()
		self._respawnTask = nil
		self:destroyDummy()
	end)
end

-- Emotes: mismo dummy que los kill effects, pero con el idle del lobby debajo (el emote
-- va en Action4) para que al acabar no se quede congelado. Debe ser la misma animación
-- que LobbyCharacterPreview.
function LockerKillEffectPreview.spawnEmoteDummy(self: Internal)
	local dummy = spawnDummy(self)
	local idleJanitor = Janitor.new()
	idleJanitor:LinkToInstance(dummy)
	LockerUtils.playPreviewIdleAnimation(dummy, idleJanitor, AssetIds.Animations.CharacterIdle)
end

-- Si el dummy está a medio kill effect (o no existe), se respawnea antes.
function LockerKillEffectPreview.previewEmote(self: Internal, emoteId: string)
	if not self._dummy or self._respawnTask then
		self:spawnEmoteDummy()
	end
	EmotePlayer.play(self._dummy :: Model, emoteId)
end

function LockerKillEffectPreview.Destroy(self: Internal)
	self:destroyDummy()
end

return LockerKillEffectPreview
