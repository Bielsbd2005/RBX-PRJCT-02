--!strict
-- Clona ReplicatedStorage.Templates.HealthBillboard sobre cada jugador/bot en partida
-- (menos el local): barra de vida con gradiente de aliado/enemigo y nombre en
-- Container.Name (DisplayName del jugador o atributo "DisplayName" del bot).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Templates = ReplicatedStorage:WaitForChild("Templates")
local TeamUtils = require(Shared.utils.TeamUtils)
local MatchState = require(script.Parent.MatchState)
local CollisionGroups = require(Shared.CollisionGroups)

local localPlayer = Players.LocalPlayer

local ALLY_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 255, 0)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 240, 176)),
})

local ENEMY_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 41, 37)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 95, 95)),
})

-- Daño: chips blancos contiguos cubren la vida perdida y se elevan/desvanecen de
-- derecha a izquierda formando una escalera.
local CHIP_HEALTH_PER_SEGMENT = 0.12 -- ~12% de vida por segmento → pocos y grandes
local CHIP_MAX_SEGMENTS = 3 -- tope de segmentos
local CHIP_MIN_DAMAGE = 0.01 -- ignorar bajadas < 1% (ruido / MaxHealth changes)
local CHIP_HEIGHT = 1.6 -- alto del chip relativo a la barra (sobresale arriba/abajo)
local CHIP_RISE = 1.6 -- subida en alturas de barra (scale)
local CHIP_STEP_DELAY = 0.08 -- delay entre escalones (derecha→izquierda)
local CHIP_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CHIP_COLOR = Color3.new(1, 1, 1)
-- No animar daño más allá de esto (≈ MaxDistance del BillboardGui): MaxDistance solo
-- culla el render, y los frames/tweens se crearían igual para enemigos que no se ven.
local CHIP_MAX_DISTANCE = 200
local CHIP_MAX_DISTANCE_SQ = CHIP_MAX_DISTANCE * CHIP_MAX_DISTANCE

local healthBillboardTemplate: BillboardGui? = nil

local function getTemplate(): BillboardGui?
	if healthBillboardTemplate then
		return healthBillboardTemplate
	end
	local found = Templates:FindFirstChild("HealthBillboard")
	if found and found:IsA("BillboardGui") then
		healthBillboardTemplate = found :: BillboardGui
		return healthBillboardTemplate
	end
	warn("[HealthBillboardController] HealthBillboard no encontrado en ReplicatedStorage.Templates")
	return nil
end

type TrackState = {
	billboard: BillboardGui,
	fill: GuiObject?,
	healthBG: GuiObject?,
	humanoid: Humanoid,
	model: Model,
	conns: { RBXScriptConnection },
	baseFillSize: UDim2,
	lastIsAlly: boolean?,
	damage: ImageLabel?,
	lastRatio: number?,
	damageToken: number,
	nameLabel: TextLabel?,
}

local tracked: { [Model]: TrackState } = {}

local function hideDefaultName(humanoid: Humanoid)
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
end

local function removeExistingHealthBillboards(model: Model)
	for _, child in model:GetChildren() do
		if child:IsA("BillboardGui") and child.Name == "HealthBillboard" then
			child:Destroy()
		end
	end

	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		for _, child in head:GetChildren() do
			if child:IsA("BillboardGui") and child.Name == "HealthBillboard" then
				child:Destroy()
			end
		end
	end
end

-- Jugador real: DisplayName (con fallback a Name). Bot: el nombre ficticio que
-- AIService estampa en el atributo "DisplayName" del modelo (y en
-- Humanoid.DisplayName). Nunca se muestra el Name interno del bot ("Bot_N").
local function resolveDisplayName(model: Model, humanoid: Humanoid): string
	local owner = Players:GetPlayerFromCharacter(model)
	if owner then
		return if owner.DisplayName ~= "" then owner.DisplayName else owner.Name
	end
	local attr = model:GetAttribute("DisplayName")
	if type(attr) == "string" and attr ~= "" then
		return attr
	end
	return humanoid.DisplayName
end

-- Container.Name puede ser el TextLabel en sí o un frame que lo contenga.
local function findNameLabel(container: Instance): TextLabel?
	local node = container:FindFirstChild("Name")
	if not node then
		return nil
	end
	if node:IsA("TextLabel") then
		return node
	end
	return node:FindFirstChildWhichIsA("TextLabel", true)
end

local function updateName(state: TrackState)
	local label = state.nameLabel
	if not label then
		return
	end
	local name = resolveDisplayName(state.model, state.humanoid)
	if label.Text ~= name then
		label.Text = name
	end
end

local function ensureFillGradient(fill: GuiObject): UIGradient
	local grad = fill:FindFirstChildOfClass("UIGradient")
	if not grad then
		grad = Instance.new("UIGradient")
		grad.Name = "TeamGradient"
		grad.Parent = fill
	end
	return grad
end

-- Pinta el nombre con el mismo degradado que el Fill. UIGradient multiplica sobre
-- TextColor3, así que el texto base va en blanco para que el color sea idéntico
-- al de la barra.
local function applyNameColor(state: TrackState, color: ColorSequence)
	local label = state.nameLabel
	if not label then
		return
	end
	label.TextColor3 = Color3.new(1, 1, 1)
	local grad = ensureFillGradient(label)
	grad.Color = color
	local fillGrad = state.fill and state.fill:FindFirstChildOfClass("UIGradient")
	if fillGrad then
		grad.Rotation = fillGrad.Rotation
	end
end

-- Indicador "Damage" (hijo del Fill, sigue el punto de vida): aparece instantáneo y
-- no se oculta hasta que acaban los chips. El token invalida ocultados de golpes anteriores.
local function showDamageIndicator(state: TrackState, holdTime: number)
	local dmg = state.damage
	if not dmg then
		return
	end
	dmg.Visible = true
	dmg.ImageTransparency = 0
	state.damageToken += 1
	local token = state.damageToken
	task.delay(holdTime, function()
		if state.damageToken == token and dmg.Parent then
			dmg.Visible = false
		end
	end)
end

-- Cubre el trozo perdido [newRatio, oldRatio] con N chips (N proporcional al daño) que
-- desaparecen escalonados de derecha a izquierda y se autodestruyen. Devuelve la
-- duración total, para que el indicador "Damage" sepa cuándo ocultarse.
local function spawnDamageChips(state: TrackState, newRatio: number, oldRatio: number): number
	local healthBG = state.healthBG
	local fill = state.fill
	if not healthBG or not fill then
		return 0
	end

	local lostWidth = oldRatio - newRatio
	if lostWidth < CHIP_MIN_DAMAGE then
		return 0
	end

	-- Mapear fracciones de vida a la geometría real del Fill (full = baseFillSize.X).
	local fullScale = state.baseFillSize.X.Scale
	local n = math.clamp(math.ceil(lostWidth / CHIP_HEALTH_PER_SEGMENT), 1, CHIP_MAX_SEGMENTS)
	local segW = lostWidth / n
	local baseZ = fill.ZIndex + 2

	for i = 0, n - 1 do
		local xScale = (newRatio + i * segW) * fullScale
		local chip = Instance.new("Frame")
		chip.Name = "DamageChip"
		chip.BackgroundColor3 = CHIP_COLOR
		chip.BorderSizePixel = 0
		chip.BackgroundTransparency = 0
		chip.ZIndex = baseZ
		chip.AnchorPoint = Vector2.new(0, 0.5)
		chip.Position = UDim2.fromScale(xScale, 0.5)
		chip.Size = UDim2.fromScale(segW * fullScale, CHIP_HEIGHT)
		chip.Parent = healthBG

		-- El de más a la derecha (i = n-1) sale primero; el de la izquierda al final.
		local stagger = (n - 1 - i) * CHIP_STEP_DELAY
		task.delay(stagger, function()
			if not chip.Parent then
				return
			end
			local tween = TweenService:Create(chip, CHIP_TWEEN, {
				Position = UDim2.fromScale(xScale, 0.5 - CHIP_RISE),
				BackgroundTransparency = 1,
			})
			tween:Play()
			tween.Completed:Once(function()
				chip:Destroy()
			end)
		end)
	end

	return (n - 1) * CHIP_STEP_DELAY + CHIP_TWEEN.Time
end

local function isWithinAnimDistance(state: TrackState): boolean
	local cam = workspace.CurrentCamera
	if not cam then
		return false
	end
	local ref: BasePart? = state.humanoid.RootPart
	if not ref then
		local head = state.model:FindFirstChild("Head")
		ref = if head and head:IsA("BasePart") then head else nil
	end
	if not ref then
		return true -- sin referencia de posición, no bloquear
	end
	local delta = cam.CFrame.Position - ref.Position
	return delta:Dot(delta) <= CHIP_MAX_DISTANCE_SQ
end

-- Un muerto no lleva barra. Se mira la vida Y el atributo de ragdoll de los kill effects
-- en vez de fiarlo a `Died`: los reintentos de `scheduleTrack` pueden alcanzar a un
-- cuerpo que murió antes de montar el tracking, y el evento ya habría pasado.
local function isCorpse(model: Model, humanoid: Humanoid): boolean
	return humanoid.Health <= 0 or model:GetAttribute(CollisionGroups.RAGDOLL_ATTRIBUTE) == true
end

local untrackModel: (model: Model) -> ()

local function updateState(state: TrackState)
	local model = state.model
	local humanoid = state.humanoid

	if isCorpse(model, humanoid) then
		untrackModel(model)
		return
	end

	-- Color de equipo: barra y nombre comparten degradado.
	-- Por bando local y no por isSameTeam(localChar): muerto, localChar es el cuerpo del
	-- lobby sin Team y todos saldrían como enemigos.
	local isAlly = MatchState.isLocalAlly(model)
	if state.lastIsAlly ~= isAlly then
		state.lastIsAlly = isAlly
		local color = if isAlly then ALLY_GRADIENT else ENEMY_GRADIENT
		if state.fill then
			ensureFillGradient(state.fill).Color = color
		end
		applyNameColor(state, color)
	end

	if state.fill then

		-- Indicador "Damage" (hijo del Fill): se resuelve una vez, oculto hasta el primer golpe.
		if not state.damage then
			local d = state.fill:FindFirstChild("Damage")
			if d and d:IsA("ImageLabel") then
				state.damage = d
				d.Visible = false
			end
		end

		state.fill.Visible = true
		local maxHp = math.max(1, humanoid.MaxHealth)
		local ratio = math.clamp(humanoid.Health / maxHp, 0, 1)

		-- Daño: chips sobre el trozo perdido + indicador. El Fill baja instantáneo, sin tween.
		local last = state.lastRatio
		if last ~= nil and ratio < last - CHIP_MIN_DAMAGE and isWithinAnimDistance(state) then
			local chipsDuration = spawnDamageChips(state, ratio, last)
			showDamageIndicator(state, chipsDuration)
		end
		state.lastRatio = ratio

		local base = state.baseFillSize
		state.fill.Size = UDim2.new(
			base.X.Scale * ratio,
			math.floor(base.X.Offset * ratio + 0.5),
			base.Y.Scale,
			base.Y.Offset
		)
	end
end

function untrackModel(model: Model)
	local state = tracked[model]
	if not state then return end
	for _, conn in state.conns do
		conn:Disconnect()
	end
	if state.billboard and state.billboard.Parent then
		state.billboard:Destroy()
	end
	tracked[model] = nil
end

local function trackModel(model: Model)
	if tracked[model] then
		updateState(tracked[model])
		return
	end

	if not model.Parent then return end
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then return end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	if isCorpse(model, humanoid) then
		-- Cuerpo ya muerto: ni se monta el billboard ni se deja el que hubiera.
		removeExistingHealthBillboards(model)
		return
	end

	hideDefaultName(humanoid)

	removeExistingHealthBillboards(model)

	local template = getTemplate()
	if not template then return end

	local billboard = template:Clone()
	billboard.Name = "HealthBillboard"
	billboard.Adornee = head :: BasePart
	-- Parentear al Head (BasePart) para que Roblox lo renderice correctamente
	billboard.Parent = head :: BasePart

	local container = billboard:FindFirstChild("Container")
	if not container then
		for _, child in billboard:GetChildren() do
			if child:IsA("GuiObject") then
				container = child
				break
			end
		end
	end

	local fill: GuiObject? = nil
	local healthBG: GuiObject? = nil
	local nameLabel: TextLabel? = nil
	local baseFillSize = UDim2.new(1, 0, 1, 0)

	if container then
		nameLabel = findNameLabel(container)

		local bg = container:FindFirstChild("HealthBG")
		if bg and bg:IsA("GuiObject") then
			healthBG = bg
			local f = bg:FindFirstChild("Fill")
			if f and f:IsA("GuiObject") then
				fill = f
				baseFillSize = f.Size
			end
		end
	end

	local conns: { RBXScriptConnection } = {}

	local state: TrackState = {
		billboard = billboard,
		fill = fill,
		healthBG = healthBG,
		humanoid = humanoid,
		model = model,
		conns = conns,
		baseFillSize = baseFillSize,
		damageToken = 0,
		nameLabel = nameLabel,
	}
	tracked[model] = state

	-- Solo el property signal de Health (HealthChanged dispara en el mismo frame y
	-- duplicaría updateState) + MaxHealth.
	table.insert(conns, humanoid:GetPropertyChangedSignal("Health"):Connect(function()
		updateState(state)
	end))
	table.insert(conns, humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		updateState(state)
	end))
	table.insert(conns, humanoid.Died:Connect(function()
		untrackModel(model)
	end))
	table.insert(conns, model.AttributeChanged:Connect(function(attr)
		if attr == CollisionGroups.RAGDOLL_ATTRIBUTE then
			-- El kill effect acaba de ragdollear el cuerpo.
			if model:GetAttribute(attr) == true then
				untrackModel(model)
			end
		elseif attr == "Team" or attr == "TeamSide" or attr == "BotTeam" or attr == "Side"
			or attr == "TeamAffinity" then
			updateState(state)
		elseif attr == "DisplayName" then
			-- El atributo puede llegar tras el modelo, y AIService lo reescribe si
			-- la identidad del bot choca con la de un jugador que acaba de entrar.
			updateName(state)
		end
	end))
	table.insert(conns, humanoid:GetPropertyChangedSignal("DisplayName"):Connect(function()
		updateName(state)
	end))
	table.insert(conns, model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			untrackModel(model)
		end
	end))

	updateName(state)
	updateState(state)
end

local function isBot(model: Model): boolean
	return string.find(model.Name, "^Bot_") ~= nil or TeamUtils.getSide(model) ~= nil
end

local function tryTrack(model: Model)
	local owner = Players:GetPlayerFromCharacter(model)
	if owner then
		if owner == localPlayer then
			removeExistingHealthBillboards(model)
			untrackModel(model)
			return
		end
		trackModel(model)
		return
	end
	if model:FindFirstChildOfClass("Humanoid") and isBot(model) then
		trackModel(model)
	end
end

-- Reintentos por modelo mientras su Humanoid/Head aún no ha replicado.
local _trackRetryConns: { [Model]: { RBXScriptConnection } } = {}
local _trackRetryThreads: { [Model]: { thread } } = {}

local function _cleanupTrackRetry(model: Model)
	local conns = _trackRetryConns[model]
	if conns then
		for _, c in conns do
			c:Disconnect()
		end
		_trackRetryConns[model] = nil
	end
	local threads = _trackRetryThreads[model]
	if threads then
		for _, t in threads do
			-- pcall: el thread en curso no es cancelable; los pendientes sí,
			-- liberando la referencia al model.
			pcall(task.cancel, t)
		end
		_trackRetryThreads[model] = nil
	end
end

-- ¿El modelo llegará a ser trackeable (player char o bot) una vez replique del
-- todo? Evita colgar watchers de reintento en props decorativos con Humanoid.
local function isTrackCandidate(model: Model): boolean
	if Players:GetPlayerFromCharacter(model) ~= nil then
		return true
	end
	local parent = model.Parent
	if parent ~= nil and parent.Name == "Bots" then
		return true
	end
	return isBot(model)
end

-- Programa el tracking de un modelo cuyo Humanoid/Head puede no haber replicado.
-- `tryTrack` es idempotente; si aún no se pudo y el modelo es candidato, instala
-- ChildAdded + reintentos temporizados a 0.1/0.5/2s. Los timers son necesarios:
-- ChildAdded a veces NO dispara para hijos que llegan en la replicación INICIAL del
-- Model (mismo gotcha que CharacterHighlightController).
--
-- `assumeCandidate` lo fuerzan los callers que ya saben que es player/bot (en
-- mid-replicación el owner puede no resolver aún).
local function scheduleTrack(model: Model, assumeCandidate: boolean?)
	if not model.Parent then
		return
	end
	tryTrack(model)
	if tracked[model] or _trackRetryConns[model] then
		return
	end
	if not (assumeCandidate or isTrackCandidate(model)) then
		return
	end

	local conns: { RBXScriptConnection } = {}
	_trackRetryConns[model] = conns

	local function tryRetry()
		if not model.Parent then
			_cleanupTrackRetry(model)
			return
		end
		tryTrack(model)
		if tracked[model] then
			_cleanupTrackRetry(model)
		end
	end

	table.insert(conns, model.ChildAdded:Connect(tryRetry))
	table.insert(conns, model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			_cleanupTrackRetry(model)
		end
	end))

	_trackRetryThreads[model] = {
		task.delay(0.1, tryRetry),
		task.delay(0.5, tryRetry),
		task.delay(2.0, tryRetry),
	}
end

local HealthBillboardController = {}

-- Conexiones de módulo: se limpian en Stop() para que Start() pueda repetirse sin duplicarlas.
local _moduleConns: { RBXScriptConnection } = {}
local _started = false

local function _wireCharacterAddedFor(player: Player)
	table.insert(_moduleConns, player.CharacterAdded:Connect(function(character)
		-- Player conocido → candidato seguro.
		scheduleTrack(character, true)
	end))
end

-- `prescannedModels` opcional: si el caller ya hizo `workspace:GetDescendants()`
-- + filtró Models, lo reusamos para evitar un segundo escaneo en `Start`. Si es
-- nil, escaneamos workspace nosotros (uso standalone).
function HealthBillboardController:Start(prescannedModels: { Model }?)
	if _started then
		return
	end
	_started = true

	for _, player in Players:GetPlayers() do
		if player.Character then
			scheduleTrack(player.Character, true)
		end
		_wireCharacterAddedFor(player)
	end

	table.insert(_moduleConns, Players.PlayerAdded:Connect(function(player)
		_wireCharacterAddedFor(player)
		if player.Character then
			scheduleTrack(player.Character, true)
		end
	end))

	-- Bots que aparecen como descendants de workspace (típicamente en
	-- mapRoot/Bots, dentro de ActiveMap). El filtro IsA("Model") descarta de
	-- inmediato la enorme mayoría de adds (partes, attachments, partículas).
	table.insert(_moduleConns, workspace.DescendantAdded:Connect(function(instance)
		if not instance:IsA("Model") then return end
		-- Heurística rápida: si el padre es un Model, NO es un character.
		if instance.Parent and instance.Parent:IsA("Model") then return end

		-- Filtro para mapas con muchos props decorativos: solo bots (padre "Bots"),
		-- modelos con Humanoid o characters de jugador.
		local parent = instance.Parent
		local isBotChild = parent ~= nil and parent.Name == "Bots"
		local hasHumanoid = instance:FindFirstChildOfClass("Humanoid") ~= nil
		local isPlayerChar = Players:GetPlayerFromCharacter(instance) ~= nil
		if not (isBotChild or hasHumanoid or isPlayerChar) then
			return
		end

		scheduleTrack(instance :: Model)
	end))

	local function refreshAllStates()
		for _, state in tracked do
			updateState(state)
		end
	end
	table.insert(_moduleConns, localPlayer:GetPropertyChangedSignal("Team"):Connect(refreshAllStates))
	table.insert(_moduleConns, localPlayer:GetAttributeChangedSignal("MatchSide"):Connect(refreshAllStates))

	-- Scan inicial; `prescannedModels` evita re-escanear (init.luau comparte un scan
	-- con CharacterHighlight). Cubre el join mid-partida con combatientes aún replicando.
	if prescannedModels then
		for _, model in prescannedModels do
			scheduleTrack(model)
		end
	else
		for _, desc in workspace:GetDescendants() do
			if desc:IsA("Model") then
				scheduleTrack(desc)
			end
		end
	end
end

-- Limpia listeners de módulo, watchers pendientes y billboards activos, para que
-- MatchFeature pueda volver a hacer Start() sin duplicar listeners.
function HealthBillboardController:Stop()
	if not _started then
		return
	end
	_started = false

	for _, conn in _moduleConns do
		conn:Disconnect()
	end
	table.clear(_moduleConns)

	-- Watchers de reintento pendientes (conns + threads temporizados). Los dos
	-- mapas comparten claves: scheduleTrack los rellena a la vez y
	-- _cleanupTrackRetry los vacía a la vez.
	for model in _trackRetryConns do
		_cleanupTrackRetry(model)
	end

	for model, _ in tracked do
		untrackModel(model)
	end
end

return HealthBillboardController
