--!strict
--[[
	BattlePassScenePreview (Client)

	Decorado del panel del Battle Pass: cuatro peanas dentro de Workspace.BattlePass,
	una por clase de recompensa.

	  · HeadSpawn  → clon de ReplicatedStorage.HeadTemplate. Ahí se prueban los hats
	    (colgados del propio clon) y las faces (pintadas en Head.face).
	  · WrapSpawn  → el arma de la recompensa con el wrap aplicado. El modelo sale de
	    Shared.Locker.weapons.<categoría> y se viste con el MISMO código que pinta
	    los viewports de los slots (WeaponWrapPreviewer.applyAppearance), así que un
	    wrap se ve igual en el mundo que en la card.
	  · DummySpawn → maniquí de Shared.Bodies: el body de la recompensa, o el
	    KillEffectDummy ejecutando el kill effect en bucle (ver
	    _startKillEffectCycle). Va animado con la idle del locker.
	  · CardSpawn  → carta plana (ReplicatedStorage.Card) con la imagen del premio en
	    Container.SurfaceGui.Item, para lo que no tiene modelo 3D: cash, gems y
	    cualquier item de una categoría sin peana propia. Si el place aún no tiene
	    CardSpawn, la carta se apoya en HeadSpawn y avisa — es la peana que más sale
	    (el premio por defecto de un nivel es cash) y dejarla sin sitio vaciaría la
	    escena casi siempre.

	Cada una tiene su escala (ver *_SCALE) y se coloca en el pivote de su peana: el
	sitio y el ángulo se autoran en Studio moviendo la parte, no aquí. Ojo: el ancla
	marca el CENTRO del modelo, no sus pies.

	En escena hay SIEMPRE una sola, la de la recompensa seleccionada, así que la
	escena nunca se queda vacía ni depende de lo que hubiera seleccionado antes.

	Movimiento (RenderStepped, solo con el panel abierto):
	  · En reposo flota — sube y baja en seno, con un balanceo de yaw muy suave para
	    que no parezca una foto.
	  · Al cambiar de contenido SIN cambiar de peana (otro hat, otro wrap), da una
	    vuelta completa con un saltito y el cambio se aplica JUSTO cuando está de
	    espaldas: lo nuevo aparece al volver de cara, no de la nada.
	  · Al cambiar de peana, la que se va desaparece en el acto y la que llega
	    aparece ya en su sitio y da esa misma vuelta, de bienvenida. Sin viaje de
	    entrada ni de salida a propósito: las peanas están en sitios distintos de la
	    escena, así que verlas ir y venir no aportaba nada y se leía aparatoso.
	La primera recompensa tras abrir el panel entra puesta, sin vuelta: al abrir, el
	decorado ya se ve vestido en lugar de animarse por algo que el jugador no
	cambió.

	Los clones se crean en el primer `show`, NO al arrancar el feature: `start` corre
	durante el bootstrap del cliente, cuando el mapa puede no haber replicado todavía
	y Workspace.BattlePass no existir aún.

	Uso:
		local scene = ScenePreview.new()
		scene:show()
		scene:setReward(reward, { weaponCategory = "Main", weaponId = "AK", wrapId = "Wrap_Pink" })
		scene:hide()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Client = script.Parent.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local HatApplier = require(Client.features.locker.Appliers.HatApplier)
local FaceApplier = require(Client.features.locker.Appliers.FaceApplier)
local WeaponWrapPreviewer = require(Client.features.locker.Previewers.WeaponWrapPreviewer)
local LockerUtils = require(Client.features.locker.LockerUtils)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local AssetIds = require(Shared.constants.AssetIds)
local KillEffectsRegistry = require(Shared.Locker.killEffects.KillEffectsRegistry)

local TEMPLATE_NAME = "HeadTemplate"
local SCENE_NAME = "BattlePass"
local HEAD_SPAWN_NAME = "HeadSpawn"
local WRAP_SPAWN_NAME = "WrapSpawn"
local DUMMY_SPAWN_NAME = "DummySpawn"

-- Maniquíes: los outfits salen de Shared.Bodies.<outfitId> (fallback al Default)
-- y los kill effects se ejecutan sobre Shared.Bodies.KillEffectDummy, el mismo
-- maniquí que usa el locker.
local BODIES_FOLDER_NAME = "Bodies"
local DEFAULT_BODY_NAME = "Default"
local KILL_EFFECT_DUMMY_NAME = "KillEffectDummy"

-- Carta plana para lo que no tiene modelo 3D (cash, gems, y cualquier item cuya
-- categoría no tenga peana propia): ReplicatedStorage.Card, con la imagen del
-- premio en Container.SurfaceGui.Item.
local CARD_TEMPLATE_NAME = "Card"
local CARD_CONTAINER_NAME = "Container"
local CARD_IMAGE_NAME = "Item"
local CARD_SPAWN_NAME = "CardSpawn"

-- Tamaño de cada peana. La cabeza y el arma son objetos pequeños y necesitan más
-- aumento para llenar su hueco de la escena; el maniquí ya es un personaje entero,
-- así que con menos le sobra. Cada una es independiente: si una se ve grande o
-- pequeña, se toca solo la suya.
local HEAD_SCALE = 3
local WEAPON_SCALE = 3
local DUMMY_SCALE = 2
-- La carta se queda a 1: es un asset hecho a medida para esto, así que el tamaño
-- bueno es el que tenga en Studio, no uno multiplicado aquí.
local CARD_SCALE = 1

-- Flotación en reposo. Las distancias son studs de mundo (los modelos ya vienen
-- escalados, así que se leen tal cual sobre la escena).
local BOB_HEIGHT = 0.4
local BOB_SPEED = 1.5
local SWAY_ANGLE = math.rad(5)
local SWAY_SPEED = 0.8

-- Cambio de contenido: vuelta completa con saltito. Back/Out hace que se pase un
-- pelín de la vuelta y encaje de golpe al volver.
local SWAP_DURATION = 0.55
local SWAP_HOP_HEIGHT = 1.2
local SWAP_EASING_STYLE = Enum.EasingStyle.Back
local SWAP_EASING_DIRECTION = Enum.EasingDirection.Out
-- Fracción de vuelta a partir de la cual la peana está de espaldas: ahí es donde
-- se cambia el contenido. Se mide sobre la vuelta YA suavizada, no sobre el
-- tiempo: con Back/Out la media vuelta cae mucho antes de la mitad del tween, y
-- cambiar "a mitad de tiempo" se vería de frente.
local SWAP_HIDDEN_AT = 0.5

-- Relevo entre peanas: la que se va desaparece en el acto y la que llega aparece
-- ya en su sitio y da una vuelta de bienvenida — el MISMO giro que el cambio de
-- contenido, sin nada que aplicar a mitad. Sin animación de entrada/salida a
-- propósito: las peanas están en sitios distintos de la escena, así que verlas
-- viajar no aportaba nada y se leía aparatoso.

-- Ciclo del preview de kill effect: el maniquí aparece, se le ve un momento de pie,
-- revienta, y tras dejar ver el efecto se rehace y vuelve a empezar mientras esa
-- recompensa siga seleccionada.
--
-- El tiempo de pie es corto a propósito: lo que se viene a ver es el efecto, no el
-- maniquí. Solo la PRIMERA vuelta suma la vuelta de bienvenida, porque el efecto
-- suelta la física del modelo y eso corta cualquier giro en curso: disparar antes
-- dejaría la bienvenida cortada a medio camino. Los maniquíes siguientes del ciclo
-- no giran, así que van directos.
local KILL_EFFECT_STAND_TIME = 0.3
local KILL_EFFECT_REPLAY_DELAY = 2.5

-- ────────────────────────────────────────────────────────────
-- Peana: un modelo que flota sobre un ancla de Workspace.BattlePass y gira
-- cuando su contenido cambia. No sabe QUÉ muestra — eso lo pone ScenePreview.

local Stand = {}
Stand.__index = Stand

type Stand = typeof(setmetatable(
	{} :: {
		_spawnName: string,
		-- Ancla de repuesto si la propia no existe en el place (ver resolve).
		_fallbackSpawnName: string?,
		-- Escala fija de esta peana. Se aplica al montar el modelo y no se vuelve a
		-- tocar: la animación de la peana mueve, no escala.
		_scale: number,
		_spawn: Instance?,
		_pivot: CFrame,
		_model: Model?,
		-- Puesta en la escena (no solo "el panel está abierto"): solo la peana de
		-- la recompensa seleccionada lo está.
		_shown: boolean,
		_warned: boolean,
		-- Cambio de contenido dentro de la misma peana (giro).
		_pendingApply: (() -> ())?,
		_swapStart: number?,
		-- El modelo actual es un rig animado (maniquí), no atrezo.
		_rig: boolean,
		-- Física suelta: el kill effect se ha adueñado del modelo, así que la peana
		-- deja de moverlo y de anclarlo.
		_physics: boolean,
	},
	Stand
))

-- Atrezo (cabeza, arma): nada de caerse ni de chocar con el jugador del lobby.
-- Idempotente — se repasa tras cada cambio, que puede traer partes nuevas.
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

-- Maniquí (outfit, kill effect): se ancla SOLO el HumanoidRootPart. Anclar el rig
-- entero como al atrezo dejaría la animación idle sin efecto — un miembro anclado
-- no lo mueve su Motor6D — y el personaje se quedaría en T-pose. Con el HRP
-- anclado y el resto sujeto por los joints, ni se cae ni se queda tieso.
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

	-- Ancla de repuesto: mejor enseñar el premio en el sitio de otra peana que no
	-- enseñarlo. Avisa igual, porque el sitio bueno hay que crearlo en Studio.
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

-- Escala y coloca el modelo actual. Se llama al montar contenido, NO en cada
-- frame: el tamaño se pone una vez y no se vuelve a tocar (la transición mueve el
-- modelo, no lo escala). ScaleTo es absoluta —siempre desde la escala autorada— y
-- el pivote va después, porque ScaleTo escala alrededor del pivote del modelo y no
-- queremos que el resultado dependa de dónde estuviera.
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

-- Monta contenido con la peana APARCADA: en el pivote del ancla (recta) y a la
-- escala autorada. Los appliers colocan piezas en espacio de MUNDO —HatApplier
-- clava el Handle sobre headAttachment.WorldCFrame, que lleva la orientación que
-- tenga la cabeza en ese instante— y el cambio se aplica a mitad del giro, con la
-- cabeza de espaldas: vestirla ahí dejaba el sombrero alineado con la cabeza
-- TORCIDA, y al acabar la vuelta se quedaba de lado.
--
-- Aparcar primero hace que el resultado no dependa del punto del giro en que caiga
-- el cambio. Es invisible: pasa dentro del mismo frame, antes del PivotTo final de
-- `update`, que vuelve a poner el modelo donde toque en la vuelta.
--
-- La escala también se aparca porque el vestido depende de ella: HatApplier clona
-- el accesorio a su tamaño de origen, así que sobre una cabeza ya aumentada
-- entraría diminuto. `refresh` reescala el modelo entero después, que es justo lo
-- que ScaleTo sabe hacer (se lleva welds y attachments con él).
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

-- Reemplaza el modelo (destruye el anterior). nil deja la peana vacía. `rig` marca
-- un personaje animado, que se sujeta distinto que el atrezo (ver _freezeRig).
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

-- El kill effect se adueña del modelo: destruye los Motor6D, lo desancla y lo
-- lanza. A partir de aquí la peana deja de colocarlo y de anclarlo — seguir
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

-- Pone la peana en escena, ya en su sitio. El giro de bienvenida lo pide después
-- ScenePreview con `spin`, cuando el contenido ya está montado.
function Stand:enter()
	self._shown = true
	if self._model then
		(self._model :: Model).Parent = self._spawn
	end
	self:refresh()
end

-- Sale de escena: se retira en el acto.
function Stand:exit()
	if not self._shown then
		return
	end
	self:_cancelSwap()
	self:_detach()
end

-- Vuelta de bienvenida al aparecer: el mismo giro que el cambio de contenido, pero
-- sin nada que aplicar a mitad de camino.
function Stand:spin()
	self._pendingApply = nil
	self._swapStart = os.clock()
end

-- Cambia el contenido. En escena va envuelto en el giro; fuera de ella (o si se
-- pide `instant`) entra puesto.
--
-- Con la física suelta el cambio también entra puesto, y no es un atajo: el giro
-- lo mueve `update`, que no toca un modelo del que se ha adueñado el kill effect,
-- así que el cambio se quedaría esperando un giro que nunca corre y no llegaría a
-- aplicarse. Y aunque corriera, sería un ragdoll dando vueltas. `apply` monta un
-- modelo nuevo, que es lo que devuelve la peana a su estado normal.
function Stand:change(apply: () -> (), instant: boolean)
	if instant or not self._shown or self._physics then
		self:_cancelSwap()
		self:_applyParked(apply)
		return
	end
	-- Cambio encadenado (clics rápidos): gana el último. El giro se reinicia y lo
	-- que se pondrá de espaldas es lo nuevo, no lo que iba a medias.
	self._pendingApply = apply
	self._swapStart = os.clock()
end

-- Un frame de movimiento. Todo se compone sobre el pivote del ancla, así que nada
-- acumula deriva por muchos cambios que se encadenen.
function Stand:update(now: number)
	local model = self._model
	-- Fuera de escena no hay nada que animar: sin este guard, una peana oculta
	-- que conserva su modelo (cabeza/carta) seguiría haciendo PivotTo sobre un
	-- modelo sin parent en cada frame.
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

-- Cierre del panel. `applyPending` = aplicar un cambio que se quedó a medias en
-- vez de tirarlo: la cabeza sí (debe quedarse con lo último que se le pidió), el
-- arma no, porque se destruye al cerrar de todas formas y construir su modelo
-- para destruirlo acto seguido es trabajo tirado.
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

-- ────────────────────────────────────────────────────────────

-- Lo que el feature ya ha resuelto de la recompensa y aquí no se puede deducir:
-- el arma sobre la que va un wrap (sale del loadout del jugador) y la imagen del
-- premio para la carta (sale de BattlePassConfig/ItemsConfig).
export type RewardTarget = {
	weaponCategory: string,
	weaponId: string?,
	weaponName: string?,
	-- nil = la recompensa no es un wrap.
	wrapId: string?,
	-- Imagen del premio para la carta plana.
	image: string?,
}

local ScenePreview = {}
ScenePreview.__index = ScenePreview

export type ScenePreview = typeof(setmetatable(
	{} :: {
		_head: Stand,
		_weapon: Stand,
		_dummy: Stand,
		_card: Stand,
		-- Las tres de arriba, para recorrerlas sin nombrarlas una a una: olvidarse
		-- de una en el bucle de movimiento deja esa peana sin animar y, lo que es
		-- peor, sin terminar su salida — se quedaría clavada en la escena.
		_stands: { Stand },
		_hats: any,
		_face: any,
		_wrapJanitor: any,
		_headKey: string?,
		_cardKey: string?,
		-- ImageLabel de la carta (Container.SurfaceGui.Item): la carta se clona una
		-- vez y solo se le cambia la imagen.
		_cardImage: ImageLabel?,
		_weaponKey: string?,
		_dummyKey: string?,
		-- Janitor de la animación idle del maniquí y thread del ciclo del kill
		-- effect; ambos mueren con el maniquí.
		_dummyJanitor: any,
		_killEffectTask: thread?,
		-- Peana que está en escena ahora mismo (solo una a la vez).
		_active: Stand?,
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
	-- La carta sale en la mayoría de los niveles (el premio por defecto es cash),
	-- así que si el place aún no tiene su ancla se apoya en la de la cabeza en vez
	-- de dejar la escena vacía casi siempre.
	self._card = _newStand(CARD_SPAWN_NAME, CARD_SCALE, HEAD_SPAWN_NAME)
	self._stands = { self._head, self._weapon, self._dummy, self._card }
	self._hats = nil
	self._face = nil
	self._wrapJanitor = nil
	self._headKey = nil
	self._cardKey = nil
	self._cardImage = nil
	self._weaponKey = nil
	self._dummyKey = nil
	self._dummyJanitor = nil
	self._killEffectTask = nil
	self._active = nil
	self._instantNext = false
	self._conn = nil
	return self
end

-- ── Cabeza ───────────────────────────────────────────────────

-- El clon de la cabeza se hace una sola vez y se REUTILIZA: los hats y las faces
-- se le ponen y se le quitan encima, no se reconstruye por recompensa.
function ScenePreview:_ensureHead(): Model?
	local existing = self._head:getModel()
	if existing then
		return existing
	end
	if not self._head:resolve() then
		return nil
	end

	local template = ReplicatedStorage:FindFirstChild(TEMPLATE_NAME)
	if not (template and template:IsA("Model")) then
		warn(`[BattlePassScenePreview] Falta ReplicatedStorage.{TEMPLATE_NAME} (o no es un Model)`)
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
	-- apertura tiene que volver a intentarlo en vez de darse por hecha.
	local model = self:_ensureHead()
	if not model then
		return
	end
	self._headKey = key

	-- La cabeza llega aquí aparcada —recta y a escala autorada— porque la peana
	-- viste con `_applyParked`: HatApplier coloca el Handle con las CFrames de los
	-- attachments del head, en espacio de mundo, así que necesita la cabeza en una
	-- pose conocida. Ver Stand:_applyParked.
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

-- ── Arma ─────────────────────────────────────────────────────

function ScenePreview:_buildWeapon(target: RewardTarget): Model?
	local template = WeaponWrapPreviewer.resolveWeaponTemplate({
		PreviewWeaponCategory = target.weaponCategory,
		PreviewWeaponId = target.weaponId,
		PreviewWeaponDisplayName = target.weaponName,
	})
	if not template then
		return nil
	end

	-- Holder: el template puede ser un Model o un BasePart suelto, y solo un Model
	-- sabe escalarse y pivotarse de una pieza. Metiéndolo dentro de un Model vacío,
	-- ScaleTo/PivotTo valen para los dos casos sin ramas.
	local holder = Instance.new("Model")
	holder.Name = "WrapPreview"
	template:Clone().Parent = holder
	return holder
end

-- El janitor del wrap anterior se destruye SIEMPRE (aunque no haya wrap nuevo o
-- ni siquiera arma): dentro vive el loop que mueve las texturas animadas, y si no
-- se cierra seguiría escribiendo sobre las Texture del modelo ya destruido.
function ScenePreview:_dressWeapon(model: Model?, wrapId: string?)
	if self._wrapJanitor then
		self._wrapJanitor:Destroy()
		self._wrapJanitor = nil
	end
	if not (model and wrapId) then
		return
	end

	local catalog = ItemsConfig.WeaponWraps
	local wrapDef = if type(catalog) == "table" then catalog[wrapId] else nil
	if type(wrapDef) ~= "table" then
		return
	end

	-- El wrap se pinta sobre el modelo YA escalado, así que el tamaño de tile hay
	-- que escalarlo con él: con el StudsPerTile pelado, un arma a x4 saldría con
	-- cuatro veces más tiles que en la card del slot.
	local studsPerTile = (tonumber(wrapDef.StudsPerTile) or WeaponWrapPreviewer.DEFAULT_STUDS_PER_TILE) * WEAPON_SCALE

	self._wrapJanitor = Janitor.new()
	WeaponWrapPreviewer.applyAppearance(model, {
		TextureID = wrapDef.TextureID,
		BaseColor = wrapDef.BaseColor,
		Material = wrapDef.Material,
		isAnimated = wrapDef.isAnimated,
		StudsPerTile = studsPerTile,
	}, self._wrapJanitor)
end

function ScenePreview:_setWeapon(target: RewardTarget?, instant: boolean)
	if not target then
		return
	end

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
		-- La key se cachea solo si hay arma (misma regla que la cabeza): si el
		-- modelo aún no había replicado, reseleccionar el wrap debe reintentar.
		self._weaponKey = if model then key else nil
	end, instant)
end

-- ── Maniquí (bodies y kill effects) ──────────────────────────

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

-- Ciclo del kill effect mientras esa recompensa siga seleccionada: maniquí de pie
-- → efecto → se deja ver → maniquí nuevo. En bucle porque el efecto dura menos de
-- un segundo: enseñarlo una sola vez, justo después de que la peana entre girando,
-- es fácil de perderse, y deja un ragdoll tirado en la peana el resto del rato.
--
-- Un thread y no una cadena de task.delay: el ciclo se lee de arriba abajo y se
-- corta con un solo task.cancel. `key` es el guardia — si la selección cambió, el
-- ciclo se acaba solo.
function ScenePreview:_startKillEffectCycle(effectId: string?, key: string)
	self:_cancelKillEffect()
	self._killEffectTask = task.spawn(function()
		local first = true
		while self._dummyKey == key do
			local model = self:_spawnDummy(KILL_EFFECT_DUMMY_NAME)
			if not model then
				-- Sin maniquí el ciclo muere; se suelta la key para que
				-- reseleccionar la recompensa lo reintente.
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
			-- Parar la idle ANTES del apply (mismo criterio que el locker): el
			-- efecto destruye los Motor6Ds y la AnimationTrack quedaría viva
			-- apuntando a joints inexistentes hasta el siguiente maniquí.
			if self._dummyJanitor then
				self._dummyJanitor:Destroy()
				self._dummyJanitor = nil
			end
			KillEffectsRegistry.apply(effectId, model)
			task.wait(KILL_EFFECT_REPLAY_DELAY)
		end
		self._killEffectTask = nil
	end)
end

-- Suelta el maniquí entero: corta el ciclo del kill effect, mata la idle y
-- destruye el modelo (que puede haber quedado hecho un ragdoll). Se llama al
-- dejar de ser la peana en escena y al cerrar el panel — la salida de escena es
-- instantánea, así que nada necesita conservar el modelo, y la key se olvida
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
			-- El ciclo construye el maniquí en su primera vuelta, aquí y ahora
			-- (task.spawn corre hasta el primer yield), así que la peana ya tiene
			-- modelo cuando `change` lo coloca.
			self:_startKillEffectCycle(itemId, key)
		else
			-- El contorno es solo del body: sobre un kill effect acabaría dibujando
			-- el ragdoll despiezado.
			local model = self:_spawnDummy(itemId or DEFAULT_BODY_NAME, DEFAULT_BODY_NAME)
			if model then
				LockerUtils.applyPreviewOutline(model)
			else
				-- Sin maniquí no se cachea la key: reseleccionar debe reintentar
				-- (p. ej. Shared.Bodies aún sin replicar).
				self._dummyKey = nil
			end
		end
	end, instant)
end

-- ── Carta (premios sin modelo 3D) ────────────────────────────

-- La carta se clona UNA vez y se reutiliza: cambiar de cash a gems es cambiarle la
-- imagen, no rehacer el modelo.
function ScenePreview:_ensureCard(): Model?
	local existing = self._card:getModel()
	if existing then
		return existing
	end
	if not self._card:resolve() then
		return nil
	end

	local template = ReplicatedStorage:FindFirstChild(CARD_TEMPLATE_NAME)
	if not (template and template:IsA("Model")) then
		warn(`[BattlePassScenePreview] Falta ReplicatedStorage.{CARD_TEMPLATE_NAME} (o no es un Model)`)
		return nil
	end

	local model = (template :: Model):Clone()
	self._card:setModel(model)

	-- La imagen se resuelve una vez y se guarda; si el asset no la trae, la carta
	-- se sigue viendo (en blanco) en vez de no salir.
	local container = model:FindFirstChild(CARD_CONTAINER_NAME)
	local surface = if container then container:FindFirstChildOfClass("SurfaceGui") else nil
	local imageNode = if surface then surface:FindFirstChild(CARD_IMAGE_NAME) else nil
	if imageNode and imageNode:IsA("ImageLabel") then
		self._cardImage = imageNode
	else
		warn(
			`[BattlePassScenePreview] {CARD_TEMPLATE_NAME}.{CARD_CONTAINER_NAME}.SurfaceGui.{CARD_IMAGE_NAME} no encontrado; la carta sale sin imagen`
		)
	end
	return model
end

function ScenePreview:_setCard(image: string?, instant: boolean)
	local key = image or ""
	if key == self._cardKey then
		return
	end

	local model = self:_ensureCard()
	if not model then
		return
	end
	self._cardKey = key

	self._card:change(function()
		local label = self._cardImage
		if label then
			label.Image = image or ""
		end
	end, instant)
end

-- ── API ──────────────────────────────────────────────────────

-- En escena hay SIEMPRE una sola peana: la de la recompensa elegida. Un wrap saca
-- el arma, un body o un kill effect sacan el maniquí, y todo lo demás (hats,
-- faces, cash, gems…) saca la cabeza, que con una recompensa que no es hat ni face
-- se queda limpia. Así la escena nunca se queda vacía ni depende de lo que hubiera
-- antes.
function ScenePreview:setReward(reward: BattlePassConfig.Reward?, target: RewardTarget?)
	local instant = self._instantNext
	self._instantNext = false

	local category = if reward and reward.Kind == "Item" then reward.Category else nil
	local wantsWeapon = target ~= nil and target.wrapId ~= nil
	local wantsDummy = not wantsWeapon and (category == "Outfits" or category == "KillEffects")
	local wantsHead = not wantsWeapon and (category == "Hats" or category == "Faces")

	local stand = if wantsWeapon
		then self._weapon
		elseif wantsDummy then self._dummy
		elseif wantsHead then self._head
		else self._card
	local switching = stand ~= self._active

	-- El relevo va ANTES de montar el contenido, no después: `enter` es lo que
	-- pone la peana en la escena, y un maniquí al que se le lanza la animación
	-- idle estando fuera del mundo no la reproduce (se quedaría en T-pose).
	if switching then
		if self._active then
			self._active:exit()
			-- Salir de escena apaga lo que esa peana tuviera corriendo (el ciclo de
			-- ragdolls del maniquí, el scroll de un wrap animado) y SIEMPRE olvida
			-- su key: exit() tira un cambio pendiente sin aplicarlo, así que una key
			-- cacheada aquí podría describir contenido que nunca llegó a ponerse y
			-- bloquear la reselección de esa recompensa para siempre.
			if self._active == self._dummy then
				self:_releaseDummy()
			elseif self._active == self._weapon then
				self:_dressWeapon(nil, nil)
				self._weaponKey = nil
			elseif self._active == self._head then
				self._headKey = nil
			elseif self._active == self._card then
				self._cardKey = nil
			end
		end
		stand:enter()
		self._active = stand
	end

	-- La peana que ENTRA se viste al instante: acaba de aparecer, y el giro de
	-- cambio de contenido encima del de bienvenida sería ruido sobre ruido.
	local contentInstant = instant or switching
	if wantsWeapon then
		self:_setWeapon(target, contentInstant)
	elseif wantsDummy then
		self:_setDummy(category, if reward then reward.ItemId else nil, contentInstant)
	elseif wantsHead then
		self:_setHead(reward, contentInstant)
	else
		self:_setCard(if target then target.image else nil, contentInstant)
	end

	-- La bienvenida va DESPUÉS del contenido: se pide aquí y no en `enter` porque
	-- montar el contenido cancela cualquier giro en curso (ver `change`), así que
	-- pedirla antes sería pedirla para nada.
	if switching and not instant then
		stand:spin()
	end
end

function ScenePreview:show()
	-- Ninguna peana entra aquí: la pone en escena el primer setReward, que es
	-- quien sabe cuál toca.
	self._instantNext = true

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
	-- Solo la cabeza recupera un cambio a medias; las otras dos se rehacen en la
	-- próxima apertura, así que construir su modelo para tirarlo sería trabajo
	-- perdido.
	self._head:hide(true)
	self._card:hide(true)
	self._weapon:hide(false)
	self._dummy:hide(false)
	-- Sin peana en escena: la próxima apertura vuelve a elegir cuál entra.
	self._active = nil

	-- El maniquí se suelta entero: su idle y, si era un kill effect, su ciclo de
	-- ragdolls no tienen nada que hacer con el panel cerrado.
	self:_releaseDummy()

	-- El arma sí se destruye al cerrar (la cabeza no): un wrap animado deja un
	-- loop escribiendo sus texturas cada Heartbeat, y con el panel cerrado eso es
	-- trabajo tirado. Se reconstruye en la siguiente apertura.
	self._weapon:setModel(nil)
	self:_dressWeapon(nil, nil)
	self._weaponKey = nil
end

function ScenePreview:Destroy()
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
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
