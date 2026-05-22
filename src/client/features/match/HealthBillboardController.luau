--!strict
-- HealthBillboardController: clona el template HealthBillboard de RS sobre cada
-- jugador/bot en partida y muestra solo barra de vida (solo enemigos).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)

local localPlayer = Players.LocalPlayer

local ALLY_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 255, 0)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 240, 176)),
})

local ENEMY_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 41, 37)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 95, 95)),
})

-- ── Template (cacheado una sola vez) ────────────────────────────
local healthBillboardTemplate: BillboardGui? = nil

local function getTemplate(): BillboardGui?
	if healthBillboardTemplate then
		return healthBillboardTemplate
	end
	-- Buscar solo hijos directos de RS para no capturar clones en workspace
	local found = ReplicatedStorage:FindFirstChild("HealthBillboard")
	if not found then
		-- Buscar dentro de carpetas comunes
		for _, child in ReplicatedStorage:GetChildren() do
			if child:IsA("Folder") or child:IsA("Configuration") then
				local inner = child:FindFirstChild("HealthBillboard")
				if inner and inner:IsA("BillboardGui") then
					found = inner
					break
				end
			end
		end
	end
	if found and found:IsA("BillboardGui") then
		healthBillboardTemplate = found :: BillboardGui
		return healthBillboardTemplate
	end
	warn("[HealthBillboardController] HealthBillboard no encontrado en ReplicatedStorage")
	return nil
end

-- ── Tracked state ───────────────────────────────────────────────
type TrackState = {
	billboard: BillboardGui,
	container: Instance?,
	fill: GuiObject?,
	healthBG: GuiObject?,
	humanoid: Humanoid,
	model: Model,
	conns: { RBXScriptConnection },
	baseFillSize: UDim2,
}

local tracked: { [Model]: TrackState } = {}

-- ── Ocultar nombre por defecto de Roblox ────────────────────────
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

local function ensureFillGradient(fill: GuiObject): UIGradient
	local grad = fill:FindFirstChildOfClass("UIGradient")
	if not grad then
		grad = Instance.new("UIGradient")
		grad.Name = "TeamGradient"
		grad.Parent = fill
	end
	return grad
end

-- ── Actualizar un billboard ─────────────────────────────────────
local function updateState(state: TrackState)
	local model = state.model
	local humanoid = state.humanoid

	-- Vida
	if not state.fill and state.healthBG then
		local f = state.healthBG:FindFirstChild("Fill")
		if f and f:IsA("GuiObject") then
			state.fill = f
			state.baseFillSize = f.Size
		end
	end

	if not state.healthBG and state.container then
		local template = getTemplate()
		if template then
			local templateContainer = template:FindFirstChild("Container")
			if templateContainer then
				local templateHealthBG = templateContainer:FindFirstChild("HealthBG")
				if templateHealthBG and templateHealthBG:IsA("GuiObject") then
					local newHealthBG = templateHealthBG:Clone()
					newHealthBG.Parent = state.container
					state.healthBG = newHealthBG

					local newFill = newHealthBG:FindFirstChild("Fill")
					if newFill and newFill:IsA("GuiObject") then
						state.fill = newFill
						state.baseFillSize = newFill.Size
					end
				end
			end
		end
	end

	if state.fill then
		local localChar = localPlayer.Character
		local isAlly = localChar ~= nil and TeamUtils.isSameTeam(localChar, model)

		local gradient = ensureFillGradient(state.fill)
		gradient.Color = if isAlly then ALLY_GRADIENT else ENEMY_GRADIENT

		state.fill.Visible = true
		local maxHp = math.max(1, humanoid.MaxHealth)
		local ratio = math.clamp(humanoid.Health / maxHp, 0, 1)
		local base = state.baseFillSize
		-- Escalar eje X (horizontal) con el ratio de vida
		state.fill.Size = UDim2.new(
			base.X.Scale * ratio,
			math.floor(base.X.Offset * ratio + 0.5),
			base.Y.Scale,
			base.Y.Offset
		)
	end
end

-- ── Untrack ─────────────────────────────────────────────────────
local function untrackModel(model: Model)
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

-- ── Track ───────────────────────────────────────────────────────
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

	hideDefaultName(humanoid)

	-- Limpiar billboard previo (si lo hubiera)
	removeExistingHealthBillboards(model)

	local template = getTemplate()
	if not template then return end

	local billboard = template:Clone()
	billboard.Name = "HealthBillboard"
	billboard.Adornee = head :: BasePart
	-- Parentear al Head (BasePart) para que Roblox lo renderice correctamente
	billboard.Parent = head :: BasePart

	-- Resolver nodos cacheados una sola vez
	local container = billboard:FindFirstChild("Container")
	if not container then
		-- Intentar buscar un frame/folder hijo que haga de container
		for _, child in billboard:GetChildren() do
			if child:IsA("GuiObject") then
				container = child
				break
			end
		end
	end

	local fill: GuiObject? = nil
	local healthBG: GuiObject? = nil
	local baseFillSize = UDim2.new(1, 0, 1, 0)

	if container then
		-- HealthBG y Fill
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
		container = container,
		fill = fill,
		healthBG = healthBG,
		humanoid = humanoid,
		model = model,
		conns = conns,
		baseFillSize = baseFillSize,
	}
	tracked[model] = state

	-- Conectar eventos. `HealthChanged` y el property signal de Health disparan
	-- ambos en el mismo frame en el cambio de vida — antes ejecutábamos
	-- updateState 2× por daño × N enemigos. Mantenemos solo el property signal
	-- (cubre Health) + MaxHealth (no expuesto por HealthChanged).
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
		if attr == "Team" or attr == "TeamSide" or attr == "BotTeam" or attr == "Side"
			or attr == "TeamAffinity" then
			updateState(state)
		end
	end))
	table.insert(conns, model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			untrackModel(model)
		end
	end))

	-- Primer update inmediato
	updateState(state)
end

-- ── Deteccion de modelos elegibles ──────────────────────────────
local function isBot(model: Model): boolean
	return string.find(model.Name, "^Bot_") ~= nil or TeamUtils.getSide(model) ~= nil
end

local function tryTrack(model: Model)
	local owner = Players:GetPlayerFromCharacter(model)
	if owner then
		if owner == localPlayer then
			-- Nunca mostrar billboard del propio jugador local.
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

-- ── Modulo publico ──────────────────────────────────────────────
local HealthBillboardController = {}

-- Conexiones a nivel de módulo (PlayerAdded, DescendantAdded, etc.) y
-- watchers efímeros de bots aún sin Humanoid. Sin tracking explícito, los
-- listeners se duplicaban en cada Start() (re-entrar al menú de match) y
-- nunca se limpiaban en Stop().
local _moduleConns: { RBXScriptConnection } = {}
local _pendingWatchers: { () -> () } = {}
local _started = false

local function _wireCharacterAddedFor(player: Player)
	table.insert(_moduleConns, player.CharacterAdded:Connect(function(character)
		-- Esperar a que Head y Humanoid existan.
		if not character:FindFirstChild("Head") then
			character:WaitForChild("Head", 5)
		end
		if not character:FindFirstChildOfClass("Humanoid") then
			character:WaitForChild("Humanoid", 5)
		end
		tryTrack(character)
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

	-- Jugadores existentes
	for _, player in Players:GetPlayers() do
		if player.Character then
			tryTrack(player.Character)
		end
		_wireCharacterAddedFor(player)
	end

	-- Nuevos jugadores
	table.insert(_moduleConns, Players.PlayerAdded:Connect(function(player)
		_wireCharacterAddedFor(player)
		if player.Character then
			tryTrack(player.Character)
		end
	end))

	-- Bots que aparecen como descendants de workspace (típicamente en
	-- mapRoot/Bots, dentro de ActiveMap). El filtro IsA("Model") descarta de
	-- inmediato la enorme mayoría de adds (partes, attachments, partículas).
	table.insert(_moduleConns, workspace.DescendantAdded:Connect(function(instance)
		if not instance:IsA("Model") then return end
		-- Heurística rápida: si el padre es un Model, NO es un character.
		if instance.Parent and instance.Parent:IsA("Model") then return end

		local function attemptTrack()
			if not instance.Parent then return end
			tryTrack(instance :: Model)
		end

		if instance:FindFirstChildOfClass("Humanoid") and instance:FindFirstChild("Head") then
			attemptTrack()
			return
		end

		local resolved = false
		local ancestryConn: RBXScriptConnection? = nil
		local childConn: RBXScriptConnection? = nil
		local function cleanup()
			if ancestryConn then ancestryConn:Disconnect() ancestryConn = nil end
			if childConn then childConn:Disconnect() childConn = nil end
		end
		table.insert(_pendingWatchers, cleanup)
		ancestryConn = instance.AncestryChanged:Connect(function()
			if not instance:IsDescendantOf(game) then cleanup() end
		end)
		childConn = instance.ChildAdded:Connect(function()
			if resolved then return end
			if instance:FindFirstChildOfClass("Humanoid") and instance:FindFirstChild("Head") then
				resolved = true
				cleanup()
				attemptTrack()
			end
		end)
		task.delay(5, function() if not resolved then cleanup() end end)
	end))

	-- Cuando cambia el equipo local, refrescar todos
	table.insert(_moduleConns, localPlayer:GetPropertyChangedSignal("Team"):Connect(function()
		for _, state in tracked do
			updateState(state)
		end
	end))

	-- Scan inicial: una sola pasada al arrancar. Si el caller pasa
	-- `prescannedModels` (init.luau hace un solo scan compartido con CharacterHighlight),
	-- lo reusamos en vez de re-escanear workspace.
	if prescannedModels then
		for _, model in prescannedModels do
			tryTrack(model)
		end
	else
		for _, desc in workspace:GetDescendants() do
			if desc:IsA("Model") then
				tryTrack(desc)
			end
		end
	end
end

-- Limpia listeners de módulo, watchers pendientes y todos los billboards
-- activos. Permite que MatchFeature vuelva a hacer Start() después sin que
-- los listeners se dupliquen (D1 — connection leak por reload del feature).
function HealthBillboardController:Stop()
	if not _started then
		return
	end
	_started = false

	for _, conn in _moduleConns do
		conn:Disconnect()
	end
	table.clear(_moduleConns)

	for _, cleanup in _pendingWatchers do
		pcall(cleanup)
	end
	table.clear(_pendingWatchers)

	for model, _ in tracked do
		untrackModel(model)
	end
end

return HealthBillboardController
