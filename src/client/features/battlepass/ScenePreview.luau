--!strict
--[[
	Decorado 3D del panel del Battle Pass. Peanas en Workspace.BattlePass; el
	pivote de cada parte (autorado en Studio) marca sitio, ángulo y el CENTRO del
	modelo, no sus pies:
	  · HeadSpawn  → clon de ReplicatedStorage.Templates.HeadTemplate (hats y faces).
	  · WrapSpawn  → arma de Shared.Locker.weapons.<categoría> vestida con
	    WeaponWrapPainter, igual que en la card del slot y en partida.
	  · DummySpawn → maniquí de Shared.Bodies: el body, o KillEffectDummy con el
	    kill effect en bucle.
	  · PileSpawn  → Templates.CoinPile (Cash) / GemPile (Gems), cantidad en
	    Part.SurfaceGui.Value. Si falta el ancla usa HeadSpawn y avisa.
	Los banners no tienen peana: van en Workspace.BattlePass.Banner (BannerPreviewer).
	En escena hay siempre una sola peana, la de la recompensa seleccionada.
	Los clones se crean en el primer `show`, no en `start`: durante el bootstrap
	Workspace.BattlePass puede no haber replicado.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Client = script.Parent.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Templates = ReplicatedStorage:WaitForChild("Templates")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any
local DataController = require(Client.core.data.DataController)
local BannerPreviewer = require(Client.features.locker.Previewers.BannerPreviewer)
local HatApplier = require(Client.features.locker.Appliers.HatApplier)
local FaceApplier = require(Client.features.locker.Appliers.FaceApplier)
local WeaponWrapPreviewer = require(Client.features.locker.Previewers.WeaponWrapPreviewer)
local WeaponWrapPainter = require(Shared.Locker.WeaponWrapPainter)
local LockerUtils = require(Client.features.locker.LockerUtils)
local UIUtils = require(Client.core.ui.UIUtils)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local AssetIds = require(Shared.constants.AssetIds)
local KillEffectsRegistry = require(Shared.Locker.killEffects.KillEffectsRegistry)

local TEMPLATE_NAME = "HeadTemplate"
local SCENE_NAME = "BattlePass"
local HEAD_SPAWN_NAME = "HeadSpawn"
local WRAP_SPAWN_NAME = "WrapSpawn"
local DUMMY_SPAWN_NAME = "DummySpawn"
local BANNER_NAME = "Banner"

local BODIES_FOLDER_NAME = "Bodies"
local DEFAULT_BODY_NAME = "Default"
local KILL_EFFECT_DUMMY_NAME = "KillEffectDummy"

local COIN_PILE_TEMPLATE_NAME = "CoinPile"
local GEM_PILE_TEMPLATE_NAME = "GemPile"
local PILE_PART_NAME = "Part"
local PILE_VALUE_NAME = "Value"
local PILE_SPAWN_NAME = "PileSpawn"

local HEAD_SCALE = 3
local WEAPON_SCALE = 3
local DUMMY_SCALE = 2
-- Los montones son assets hechos a medida: su tamaño bueno es el de Studio.
local PILE_SCALE = 1

-- Distancias en studs de mundo (los modelos ya vienen escalados).
local BOB_HEIGHT = 0.4
local BOB_SPEED = 1.5
local SWAY_ANGLE = math.rad(5)
local SWAY_SPEED = 0.8

local SWAP_DURATION = 0.55
local SWAP_HOP_HEIGHT = 1.2
local SWAP_EASING_STYLE = Enum.EasingStyle.Back
local SWAP_EASING_DIRECTION = Enum.EasingDirection.Out
-- Fracción de vuelta en la que está de espaldas y se cambia el contenido. Se mide
-- sobre la vuelta YA suavizada: con Back/Out la media vuelta cae mucho antes de la
-- mitad del tiempo.
local SWAP_HIDDEN_AT = 0.5

-- Solo la PRIMERA vuelta del ciclo espera además la vuelta de bienvenida: el efecto
-- suelta la física del modelo y cortaría el giro a medias.
local KILL_EFFECT_STAND_TIME = 0.3
local KILL_EFFECT_REPLAY_DELAY = 2.5

-- Peana: un modelo que flota sobre un ancla y gira cuando su contenido cambia.
-- No sabe QUÉ muestra; eso lo pone ScenePreview.

local Stand = {}
Stand.__index = Stand

type Stand = typeof(setmetatable(
	{} :: {
		_spawnName: string,
		-- Ancla de repuesto si la propia no existe en el place (ver resolve).
		_fallbackSpawnName: string?,
		-- Se aplica al montar el modelo; la animación mueve, no escala.
		_scale: number,
		_spawn: Instance?,
		_pivot: CFrame,
		_model: Model?,
		-- En escena (no solo "panel abierto"): solo la peana seleccionada.
		_shown: boolean,
		_warned: boolean,
		-- Cambio de contenido dentro de la misma peana (giro).
		_pendingApply: (() -> ())?,
		_swapStart: number?,
		-- El modelo actual es un rig animado (maniquí), no atrezo.
		_rig: boolean,
		-- El kill effect se ha adueñado del modelo: la peana deja de moverlo y anclarlo.
		_physics: boolean,
	},
	Stand
))

-- Atrezo (cabeza, arma). Idempotente: se repasa tras cada cambio, que puede traer
-- partes nuevas.
local function _freezeProp(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
end

-- Maniquí: se ancla SOLO el HumanoidRootPart. Un miembro anclado no lo mueve su
-- Motor6D y la idle se quedaría en T-pose.
local function _freezeRig(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	local humanoid = model:FindFirstChildWhichIsA("Humanoid", true)
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	local hrp = model:FindFirstChild("HumanoidRootPart", true)
	if hrp and hrp:IsA("BasePart") then
		(hrp :: BasePart).Anchored = true
	end
end

local function _newStand(spawnName: string, scale: number, fallbackSpawnName: string?): Stand
	local self = setmetatable({}, Stand) :: any
	self._spawnName = spawnName
	self._fallbackSpawnName = fallbackSpawnName
	self._scale = scale
	self._spawn = nil
	self._pivot = CFrame.new()
	self._model = nil
	self._shown = false
	self._warned = false
	self._pendingApply = nil
	self._swapStart = nil
	self._rig = false
	self._physics = false
	return self
end

-- Localiza el ancla. Avisa UNA vez (no en cada apertura) y no cachea el fallo: si
-- el mapa aún no había replicado, la siguiente apertura lo vuelve a intentar.
function Stand:resolve(): boolean
	if self._spawn then
		return true
	end

	local sceneFolder = Workspace:FindFirstChild(SCENE_NAME)
	local spawn = sceneFolder and sceneFolder:FindFirstChild(self._spawnName)

	local fallbackName = self._fallbackSpawnName
	if not spawn and fallbackName and sceneFolder then
		spawn = sceneFolder:FindFirstChild(fallbackName)
		if spawn and not self._warned then
			self._warned = true
			warn(
				`[BattlePassScenePreview] Falta Workspace.{SCENE_NAME}.{self._spawnName}; se usa {fallbackName} mientras tanto`
			)
		end
	end

	if not (spawn and spawn:IsA("PVInstance")) then
		if not self._warned then
			self._warned = true
			warn(`[BattlePassScenePreview] Falta Workspace.{SCENE_NAME}.{self._spawnName}; esa peana se queda vacía`)
		end
		return false
	end

	self._spawn = spawn
	self._pivot = (spawn :: PVInstance):GetPivot()
	return true
end

-- Se llama al montar contenido, no por frame. ScaleTo es absoluta y escala
-- alrededor del pivote, por eso el PivotTo va después.
function Stand:refresh()
	local model = self._model
	if not model or self._physics then
		return
	end
	model:ScaleTo(self._scale)
	model:PivotTo(self._pivot)
	if self._rig then
		_freezeRig(model)
	else
		_freezeProp(model)
	end
end

-- Monta contenido con la peana APARCADA (pivote recto y escala 1). Los appliers
-- colocan piezas en espacio de MUNDO (HatApplier usa headAttachment.WorldCFrame) y
-- el cambio cae a mitad del giro: sin aparcar, el sombrero quedaría torcido. Y
-- HatApplier clona el accesorio a su tamaño de origen, así que sobre una cabeza ya
-- escalada entraría diminuto. Es invisible: el PivotTo de `update` va en el mismo frame.
function Stand:_applyParked(apply: () -> ())
	local model = self._model
	if model and not self._physics then
		model:ScaleTo(1)
		model:PivotTo(self._pivot)
	end
	apply()
	self:refresh()
end

function Stand:getModel(): Model?
	return self._model
end

-- nil deja la peana vacía. `rig` marca un personaje animado (ver _freezeRig).
function Stand:setModel(model: Model?, rig: boolean?)
	if self._model == model then
		return
	end
	if self._model then
		(self._model :: Model):Destroy()
	end
	self._model = model
	self._rig = rig == true
	self._physics = false
	if model then
		model.Parent = if self._shown then self._spawn else nil
		self:refresh()
	end
end

function Stand:_cancelSwap()
	self._pendingApply = nil
	self._swapStart = nil
end

-- El kill effect destruye los Motor6D, desancla y lanza el modelo: seguir
-- pivotándolo cada frame pelearía contra la física del ragdoll.
function Stand:releasePhysics()
	self._physics = true
	self:_cancelSwap()
end

function Stand:_detach()
	self._shown = false
	if self._model then
		(self._model :: Model).Parent = nil
	end
end

-- El giro de bienvenida lo pide después ScenePreview con `spin`, ya montado el contenido.
function Stand:enter()
	self._shown = true
	if self._model then
		(self._model :: Model).Parent = self._spawn
	end
	self:refresh()
end

function Stand:exit()
	self:_cancelSwap()
	self:_detach()
end

function Stand:spin()
	self._pendingApply = nil
	self._swapStart = os.clock()
end

-- En escena va envuelto en el giro; fuera de ella, con `instant` o con la física
-- suelta entra puesto. Con física suelta `update` no corre, así que el cambio
-- esperaría un giro que nunca llega.
function Stand:change(apply: () -> (), instant: boolean)
	if instant or not self._shown or self._physics then
		self:_cancelSwap()
		self:_applyParked(apply)
		return
	end
	-- Cambio encadenado (clics rápidos): gana el último y el giro se reinicia.
	self._pendingApply = apply
	self._swapStart = os.clock()
end

-- Todo se compone sobre el pivote del ancla, así que no acumula deriva.
function Stand:update(now: number)
	local model = self._model
	if not model or not self._shown or self._physics then
		return
	end

	local height = math.sin(now * BOB_SPEED) * BOB_HEIGHT
	local yaw = math.sin(now * SWAY_SPEED) * SWAY_ANGLE

	local swapStart = self._swapStart
	if swapStart then
		local alpha = math.clamp((now - swapStart) / SWAP_DURATION, 0, 1)
		local turn = TweenService:GetValue(alpha, SWAP_EASING_STYLE, SWAP_EASING_DIRECTION)

		local pendingApply = self._pendingApply
		if pendingApply and turn >= SWAP_HIDDEN_AT then
			self._pendingApply = nil
			self:_applyParked(pendingApply)
			-- `apply` puede haber cambiado el modelo entero.
			model = self._model
			if not model then
				return
			end
		end

		if alpha >= 1 then
			self._swapStart = nil
		else
			yaw += turn * math.pi * 2
			height += math.sin(alpha * math.pi) * SWAP_HOP_HEIGHT
		end
	end

	-- La altura va en mundo (flota hacia arriba aunque la peana esté inclinada) y
	-- el giro sobre el eje vertical del propio modelo.
	model:PivotTo(CFrame.new(0, height, 0) * self._pivot * CFrame.Angles(0, yaw, 0))
end

-- `applyPending`: aplicar un cambio a medias en vez de tirarlo. Sí para lo que se
-- conserva al cerrar (cabeza, montón); no para lo que se destruye igualmente.
function Stand:hide(applyPending: boolean?)
	local pendingApply = self._pendingApply
	self:_cancelSwap()
	if pendingApply and applyPending then
		self:_applyParked(pendingApply)
	end
	self:_detach()
end

function Stand:destroy()
	self:_cancelSwap()
	if self._model then
		(self._model :: Model):Destroy()
		self._model = nil
	end
end

-- Lo que el feature ya ha resuelto de la recompensa y aquí no se puede deducir:
-- el arma sobre la que va un wrap (sale del loadout del jugador).
export type RewardTarget = {
	weaponCategory: string,
	weaponId: string?,
	weaponName: string?,
	-- nil = la recompensa no es un wrap.
	wrapId: string?,
}

local ScenePreview = {}
ScenePreview.__index = ScenePreview

export type ScenePreview = typeof(setmetatable(
	{} :: {
		_head: Stand,
		_weapon: Stand,
		_dummy: Stand,
		_pile: Stand,
		-- Las cuatro de arriba: olvidar una en el bucle de movimiento la deja sin
		-- animar y sin terminar su salida.
		_stands: { Stand },
		_hats: any,
		_face: any,
		_headKey: string?,
		_pileKey: string?,
		-- Divisa del montón clonado: mientras no cambie, cambiar de cantidad solo
		-- reescribe el texto.
		_pileKind: string?,
		_pileValue: TextLabel?,
		-- Plantillas mal montadas ya avisadas, para no repetir el warn.
		_pileWarned: { [string]: boolean },
		_weaponKey: string?,
		_dummyKey: string?,
		-- Idle del maniquí y thread del ciclo del kill effect; mueren con el maniquí.
		_dummyJanitor: any,
		_killEffectTask: thread?,
		_active: Stand?,
		-- Workspace.BattlePass.Banner; perezosa porque el mapa puede no haber replicado.
		_banner: any,
		_bannerWarned: boolean,
		_instantNext: boolean,
		_conn: RBXScriptConnection?,
	},
	ScenePreview
))

function ScenePreview.new(): ScenePreview
	local self = setmetatable({}, ScenePreview) :: any
	self._head = _newStand(HEAD_SPAWN_NAME, HEAD_SCALE)
	self._weapon = _newStand(WRAP_SPAWN_NAME, WEAPON_SCALE)
	self._dummy = _newStand(DUMMY_SPAWN_NAME, DUMMY_SCALE)
	self._pile = _newStand(PILE_SPAWN_NAME, PILE_SCALE, HEAD_SPAWN_NAME)
	self._stands = { self._head, self._weapon, self._dummy, self._pile }
	self._hats = nil
	self._face = nil
	self._headKey = nil
	self._pileKey = nil
	self._pileKind = nil
	self._pileValue = nil
	self._pileWarned = {}
	self._weaponKey = nil
	self._dummyKey = nil
	self._dummyJanitor = nil
	self._killEffectTask = nil
	self._active = nil
	self._banner = nil
	self._bannerWarned = false
	self._instantNext = false
	self._conn = nil
	return self
end

-- El clon de la cabeza se REUTILIZA: hats y faces se ponen y quitan encima.
function ScenePreview:_ensureHead(): Model?
	local existing = self._head:getModel()
	if existing then
		return existing
	end
	if not self._head:resolve() then
		return nil
	end

	local template = Templates:FindFirstChild(TEMPLATE_NAME)
	if not (template and template:IsA("Model")) then
		warn(`[BattlePassScenePreview] Falta ReplicatedStorage.Templates.{TEMPLATE_NAME} (o no es un Model)`)
		return nil
	end

	local model = (template :: Model):Clone()
	self._head:setModel(model)
	self._hats = HatApplier.new(model, ItemsConfig)
	self._face = FaceApplier.new(model, ItemsConfig)
	return model
end

function ScenePreview:_setHead(reward: BattlePassConfig.Reward?, instant: boolean)
	local category = if reward and reward.Kind == "Item" then reward.Category else nil
	local itemId = if reward then reward.ItemId else nil
	if category ~= "Hats" and category ~= "Faces" then
		category, itemId = nil, nil
	end

	local key = `{category or ""}|{itemId or ""}`
	if key == self._headKey then
		return
	end

	-- La key se cachea solo si hay cabeza: si faltaba el mapa, la próxima
	-- apertura debe reintentarlo.
	local model = self:_ensureHead()
	if not model then
		return
	end
	self._headKey = key

	self._head:change(function()
		if category == "Hats" then
			self._face:Reset()
			self._hats:ApplyItemId(itemId)
		elseif category == "Faces" then
			self._hats:Reset()
			self._face:ApplyItemId(itemId)
		else
			self._hats:Reset()
			self._face:Reset()
		end
	end, instant)
end

function ScenePreview:_buildWeapon(target: RewardTarget): Model?
	local template = WeaponWrapPreviewer.resolveWeaponTemplate({
		PreviewWeaponCategory = target.weaponCategory,
		PreviewWeaponId = target.weaponId,
		PreviewWeaponDisplayName = target.weaponName,
	})
	if not template then
		return nil
	end

	-- Holder: el template puede ser un BasePart suelto y solo un Model sabe
	-- ScaleTo/PivotTo.
	local holder = Instance.new("Model")
	holder.Name = "WrapPreview"
	template:Clone().Parent = holder
	return holder
end

-- Se pinta sobre el modelo YA escalado: el tile escala con él o saldrían más tiles
-- que en la card del slot.
function ScenePreview:_dressWeapon(model: Model?, wrapId: string?)
	if not (model and wrapId) then
		return
	end
	WeaponWrapPainter.paint(model, WeaponWrapPainter.getDefinition(wrapId), WEAPON_SCALE)
end

function ScenePreview:_setWeapon(target: RewardTarget, instant: boolean)
	local key = `{target.weaponCategory}|{target.weaponId or ""}|{target.wrapId or ""}`
	if key == self._weaponKey then
		return
	end
	if not self._weapon:resolve() then
		return
	end

	self._weapon:change(function()
		local model = self:_buildWeapon(target)
		-- setModel escala y coloca; el wrap va DESPUÉS porque su tamaño de tile
		-- depende de la escala final.
		self._weapon:setModel(model)
		self:_dressWeapon(model, target.wrapId)
		if model then
			LockerUtils.applyPreviewOutline(model)
		end
		-- La key se cachea solo si hay arma: si el modelo no había replicado,
		-- reseleccionar debe reintentar.
		self._weaponKey = if model then key else nil
	end, instant)
end

local function _bodiesFolder(): Instance?
	return Shared:FindFirstChild(BODIES_FOLDER_NAME)
end

function ScenePreview:_spawnDummy(templateName: string, fallbackName: string?): Model?
	local folder = _bodiesFolder()
	if not folder then
		warn(`[BattlePassScenePreview] Falta ReplicatedStorage.Shared.{BODIES_FOLDER_NAME}`)
		return nil
	end

	local template = folder:FindFirstChild(templateName)
		or (if fallbackName then folder:FindFirstChild(fallbackName) else nil)
	if not (template and template:IsA("Model")) then
		warn(`[BattlePassScenePreview] Falta Shared.{BODIES_FOLDER_NAME}.{templateName}`)
		return nil
	end

	if self._dummyJanitor then
		self._dummyJanitor:Destroy()
	end
	self._dummyJanitor = Janitor.new()

	local model = (template :: Model):Clone()
	-- Pose canónica antes de nada: si el template viene con partes desplazadas, el
	-- ragdoll del kill effect sale deformado al destruir los Motor6D.
	LockerUtils.snapPartsToCanonicalPose(model)
	self._dummy:setModel(model, true)
	LockerUtils.playPreviewIdleAnimation(model, self._dummyJanitor, AssetIds.Animations.PreviewIdle)
	return model
end

function ScenePreview:_cancelKillEffect()
	if self._killEffectTask then
		task.cancel(self._killEffectTask)
		self._killEffectTask = nil
	end
end

-- En bucle mientras la recompensa siga seleccionada: el efecto dura menos de un
-- segundo y verlo una vez es fácil de perderse. Un thread (cortable con un
-- task.cancel) y `key` como guardia: si la selección cambió, el ciclo acaba solo.
function ScenePreview:_startKillEffectCycle(effectId: string?, key: string)
	self:_cancelKillEffect()
	self._killEffectTask = task.spawn(function()
		local first = true
		while self._dummyKey == key do
			local model = self:_spawnDummy(KILL_EFFECT_DUMMY_NAME)
			if not model then
					-- Se suelta la key para que reseleccionar lo reintente.
				if self._dummyKey == key then
					self._dummyKey = nil
				end
				break
			end

			task.wait(if first then SWAP_DURATION + KILL_EFFECT_STAND_TIME else KILL_EFFECT_STAND_TIME)
			first = false
			if self._dummyKey ~= key then
				break
			end

			self._dummy:releasePhysics()
				-- Parar la idle ANTES del apply: el efecto destruye los Motor6D y la
				-- AnimationTrack quedaría viva apuntando a joints inexistentes.
			if self._dummyJanitor then
				self._dummyJanitor:Destroy()
				self._dummyJanitor = nil
			end
			KillEffectsRegistry.apply(effectId, model)
			-- Efectos largos (Burning y su cierre) piden más tiempo de cadáver en escena.
			task.wait(math.max(KILL_EFFECT_REPLAY_DELAY, KillEffectsRegistry.previewTime(effectId)))
		end
		self._killEffectTask = nil
	end)
end

-- Corta el ciclo del kill effect, mata la idle, destruye el modelo y olvida la key
-- para que volver a la misma recompensa lo rehaga de cero.
function ScenePreview:_releaseDummy()
	self:_cancelKillEffect()
	self._dummyKey = nil
	if self._dummyJanitor then
		self._dummyJanitor:Destroy()
		self._dummyJanitor = nil
	end
	self._dummy:setModel(nil)
end

function ScenePreview:_setDummy(category: string?, itemId: string?, instant: boolean)
	local key = `{category or ""}|{itemId or ""}`
	if key == self._dummyKey then
		return
	end
	if not self._dummy:resolve() then
		return
	end
	self:_cancelKillEffect()
	self._dummyKey = key

	self._dummy:change(function()
		if category == "KillEffects" then
				-- task.spawn corre hasta el primer yield: el maniquí ya existe cuando
				-- `change` lo coloca.
			self:_startKillEffectCycle(itemId, key)
		else
			-- El contorno es solo del body: sobre un kill effect acabaría dibujando
			-- el ragdoll despiezado.
			local model = self:_spawnDummy(itemId or DEFAULT_BODY_NAME, DEFAULT_BODY_NAME)
			if model then
				LockerUtils.applyPreviewOutline(model)
			else
					-- Sin maniquí no se cachea la key (p. ej. Shared.Bodies sin replicar).
				self._dummyKey = nil
			end
		end
	end, instant)
end

-- No se cachea el fallo: si Templates no había replicado, reseleccionar reintenta.
function ScenePreview:_pileTemplate(kind: string): Model?
	local name = if kind == "Gems" then GEM_PILE_TEMPLATE_NAME else COIN_PILE_TEMPLATE_NAME
	local template = Templates:FindFirstChild(name)
	if template and template:IsA("Model") then
		return template
	end
	if not self._pileWarned[name] then
		self._pileWarned[name] = true
		warn(`[BattlePassScenePreview] Falta ReplicatedStorage.Templates.{name} (o no es un Model)`)
	end
	return nil
end

-- Si el asset no trae el TextLabel, el montón sale sin número en vez de no salir.
function ScenePreview:_bindPileValue(model: Model, templateName: string)
	local part = model:FindFirstChild(PILE_PART_NAME)
	local surface = if part then part:FindFirstChildOfClass("SurfaceGui") else nil
	local valueNode = if surface then surface:FindFirstChild(PILE_VALUE_NAME) else nil
	if valueNode and valueNode:IsA("TextLabel") then
		self._pileValue = valueNode
		return
	end
	self._pileValue = nil
	local warnKey = `{templateName}.value`
	if not self._pileWarned[warnKey] then
		self._pileWarned[warnKey] = true
		warn(
			`[BattlePassScenePreview] {templateName}.{PILE_PART_NAME}.SurfaceGui.{PILE_VALUE_NAME} no encontrado (o no es un TextLabel); el montón sale sin cantidad`
		)
	end
end

-- El modelo solo se rehace al cambiar de divisa.
function ScenePreview:_setPile(kind: string, amount: number?, instant: boolean)
	local key = `{kind}|{amount or 0}`
	if key == self._pileKey then
		return
	end
	if not self._pile:resolve() then
		return
	end
	-- Plantilla ANTES de cachear la key: sin ella, la key bloquearía la reselección.
	local needsModel = self._pileKind ~= kind or self._pile:getModel() == nil
	local template = if needsModel then self:_pileTemplate(kind) else nil
	if needsModel and not template then
		return
	end
	self._pileKey = key

	self._pile:change(function()
		if template then
			local model = (template :: Model):Clone()
			self._pile:setModel(model)
			self._pileKind = kind
			self:_bindPileValue(model, (template :: Model).Name)
		end
		local label = self._pileValue
		if label then
			label.Text = UIUtils.formatCashAmount(amount or 0)
		end
	end, instant)
end

-- No cachea el fallo: la siguiente selección de un banner reintenta.
function ScenePreview:_ensureBanner(): any
	if self._banner then
		return self._banner
	end
	local sceneFolder = Workspace:FindFirstChild(SCENE_NAME)
	local bannerFolder = sceneFolder and sceneFolder:FindFirstChild(BANNER_NAME)
	if not bannerFolder then
		if not self._bannerWarned then
			self._bannerWarned = true
			warn(`[BattlePassScenePreview] Falta Workspace.{SCENE_NAME}.{BANNER_NAME}; los banners no se previsualizan`)
		end
		return nil
	end
	self._banner = BannerPreviewer.new(bannerFolder)
	return self._banner
end

function ScenePreview:_showBanner(bannerId: string?)
	local banner = self:_ensureBanner()
	if not banner then
		return
	end
	local stats = Fusion.peek(DataController.Stats)
	local level = if type(stats) == "table" then math.floor(tonumber(stats.Level) or 0) else 0
	banner:setContent(Players.LocalPlayer.Name, level, bannerId)
	banner:setVisible(true)
end

function ScenePreview:_hideBanner()
	local banner = self:_ensureBanner()
	if banner then
		banner:setVisible(false)
	end
end

-- SIEMPRE olvida la key: exit() tira un cambio pendiente sin aplicarlo, y una key
-- cacheada bloquearía la reselección de esa recompensa.
function ScenePreview:_exitActive()
	local active = self._active
	if not active then
		return
	end
	active:exit()
	if active == self._dummy then
		self:_releaseDummy()
	elseif active == self._weapon then
		self:_dressWeapon(nil, nil)
		self._weaponKey = nil
	elseif active == self._head then
		self._headKey = nil
	elseif active == self._pile then
		self._pileKey = nil
	end
	self._active = nil
end

function ScenePreview:setReward(reward: BattlePassConfig.Reward, target: RewardTarget)
	local instant = self._instantNext
	self._instantNext = false

	local category = if reward.Kind == "Item" then reward.Category else nil

	-- La peana que toque después entra como tras abrir, con su bienvenida.
	if category == "Banners" then
		self:_exitActive()
		self:_showBanner(reward.ItemId)
		return
	end
	self:_hideBanner()

	local wantsWeapon = target.wrapId ~= nil
	local wantsDummy = not wantsWeapon and (category == "Outfits" or category == "KillEffects")
	local wantsPile = not wantsWeapon and (reward.Kind == "Cash" or reward.Kind == "Gems")

	local stand = if wantsWeapon
		then self._weapon
		elseif wantsDummy then self._dummy
		elseif wantsPile then self._pile
		else self._head
	local switching = stand ~= self._active

	-- El relevo va ANTES de montar el contenido: una idle lanzada fuera del mundo
	-- no se reproduce (T-pose).
	if switching then
		self:_exitActive()
		stand:enter()
		self._active = stand
	end

	-- La peana que ENTRA se viste al instante: el giro de cambio encima del de
	-- bienvenida sería ruido.
	local contentInstant = instant or switching
	if wantsWeapon then
		self:_setWeapon(target, contentInstant)
	elseif wantsDummy then
		self:_setDummy(category, reward.ItemId, contentInstant)
	elseif wantsPile then
		self:_setPile(reward.Kind, reward.Amount, contentInstant)
	else
		self:_setHead(reward, contentInstant)
	end

	-- Bienvenida DESPUÉS del contenido: montarlo cancela cualquier giro en curso.
	if switching and not instant then
		stand:spin()
	end
end

function ScenePreview:show()
	-- Ninguna peana entra aquí: la pone el primer setReward.
	self._instantNext = true
	-- La tarjeta de banner viene encendida de Studio: resolverla ya la apaga.
	self:_hideBanner()

	if not self._conn then
		self._conn = RunService.RenderStepped:Connect(function()
			local now = os.clock()
			for _, stand in self._stands do
				stand:update(now)
			end
		end)
	end
end

function ScenePreview:hide()
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
	self:_hideBanner()
	-- Solo cabeza y montón recuperan un cambio a medias; arma y maniquí se
	-- rehacen en la próxima apertura.
	self._head:hide(true)
	self._pile:hide(true)
	self._weapon:hide(false)
	self._dummy:hide(false)
	self._active = nil

	self:_releaseDummy()

	-- Un wrap animado deja un loop escribiendo texturas cada Heartbeat: el arma
	-- se destruye al cerrar.
	self._weapon:setModel(nil)
	self:_dressWeapon(nil, nil)
	self._weaponKey = nil
end

function ScenePreview:Destroy()
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
	if self._banner then
		self._banner:Destroy()
		self._banner = nil
	end
	self:_releaseDummy()
	if self._wrapJanitor then
		self._wrapJanitor:Destroy()
		self._wrapJanitor = nil
	end
	for _, stand in self._stands do
		stand:destroy()
	end
end

return ScenePreview
