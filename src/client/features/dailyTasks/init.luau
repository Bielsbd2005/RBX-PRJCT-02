--!strict
--[[
	DailyTasksFeature  (Client)
	Pinta los slots Task1/Task2/Task3 en dos sitios:
	  MatchHud.LeftContainer.TaskFrame.Task<N>             (HUD de partida)
	  Workspace.Lobby.Daily.Board.SurfaceGui.Container.Task<N>  (board del lobby)
	El SurfaceGui está en Workspace, pero los cambios desde un LocalScript no
	replican: cada cliente pinta el board con sus propias tasks, así cada
	jugador ve su progreso local.
	Reactivo a cambios en DataController.DailyTasks (replicado desde server).

	Per-slot UI esperada:
	  Task<N>.Title          — TextLabel
	  Task<N>.Value          — TextLabel ("p/o")
	  Task<N>.Bar.Fill       — Frame  (Size.X.Scale = p/o)
	  Task<N>.Reward.Value   — TextLabel (cash)
	  Task<N>.Icon           — ImageLabel
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any

local DailyTasks = require(Shared.constants.DailyTasks)
local ActionRewards = require(Shared.constants.ActionRewards)
local DataController = require(Client.core.data.DataController)
local UIUtils = require(Client.core.ui.UIUtils)

local COMPLETED_COLOR = Color3.fromRGB(60, 200, 90)

type Slot = {
	id: string,
	titleLabel: TextLabel?,
	valueLabel: TextLabel?,
	barFill: GuiObject?,
	rewardNode: GuiObject?,
	rewardLabel: TextLabel?,
	icon: ImageLabel?,
	-- Colores originales cacheados al primer paint (para restaurar al resetear).
	originalFillColor: Color3?,
	originalIconColor: Color3?,
}

local function _findChild(parent: Instance?, name: string): Instance?
	if not parent then return nil end
	return parent:FindFirstChild(name)
end

-- Resuelve los nodos UI de un slot Task<N>. Tolera nodos faltantes —
-- la UI puede tener otra forma; solo se pintan los nodos presentes.
local function _resolveSlot(taskFrame: Instance, id: string): Slot?
	local node = taskFrame:FindFirstChild(id)
	if not node then return nil end

	local bar = _findChild(node, "Bar")
	local reward = _findChild(node, "Reward")

	return {
		id = id,
		titleLabel = _findChild(node, "Title") :: TextLabel?,
		valueLabel = _findChild(node, "Value") :: TextLabel?,
		barFill = if bar then _findChild(bar, "Fill") :: GuiObject? else nil,
		rewardNode = if reward and reward:IsA("GuiObject") then reward :: GuiObject else nil,
		rewardLabel = if reward then _findChild(reward, "Value") :: TextLabel? else nil,
		icon = _findChild(node, "Icon") :: ImageLabel?,
	}
end

local function _setText(label: TextLabel?, text: string)
	if label then label.Text = text end
end

local function _paintSlot(slot: Slot, def: any, progress: number, claimed: boolean)
	local objective = math.max(1, def.Objective)
	local clampedProgress = math.clamp(progress, 0, objective)
	local ratio = clampedProgress / objective

	_setText(slot.titleLabel, def.Title)
	_setText(slot.valueLabel, string.format("%d/%d", clampedProgress, objective))
	-- Cash de la tarea vive en ActionRewards (clave "Daily"..Id) — fuente única
	-- compartida con RewardService en el server.
	_setText(slot.rewardLabel, UIUtils.formatCashAmount(ActionRewards.GetCash("Daily" .. def.Id)))

	if slot.barFill then
		-- Solo escalar el eje X; conservar Y. X.Offset = 0 para evitar que el
		-- fill se salga del Bar (un offset > 0 en el template empujaba el
		-- borde derecho fuera del padre cuando ratio < 1).
		local fillRatio = if claimed then 1 else ratio
		local size = slot.barFill.Size
		slot.barFill.Size = UDim2.new(fillRatio, 0, size.Y.Scale, size.Y.Offset)

		-- Cachear color original la primera vez para poder restaurarlo en el
		-- reset diario (cuando claimed vuelve a false).
		if slot.originalFillColor == nil then
			slot.originalFillColor = slot.barFill.BackgroundColor3
		end
		slot.barFill.BackgroundColor3 = if claimed then COMPLETED_COLOR else slot.originalFillColor :: Color3
	end

	if slot.icon then
		if def.Icon ~= "" then
			slot.icon.Image = def.Icon
		end
		if slot.originalIconColor == nil then
			slot.originalIconColor = slot.icon.ImageColor3
		end
		slot.icon.ImageColor3 = if claimed then COMPLETED_COLOR else slot.originalIconColor :: Color3
	end

	-- Ocultar el frame Reward una vez completada la tarea (el reward ya fue
	-- otorgado; visualmente queda solo el icono+barra en verde).
	if slot.rewardNode then
		slot.rewardNode.Visible = not claimed
	end
end

-- Resuelve los 3 slots dentro de un nodo que contiene Task1/Task2/Task3.
local function _resolveSlotsFromTaskFrame(taskFrame: Instance?, label: string): { Slot }
	local result: { Slot } = {}
	if not taskFrame then return result end

	for _, def in DailyTasks.Tasks do
		local slot = _resolveSlot(taskFrame, def.Id)
		if slot then
			table.insert(result, slot)
		else
			warn(string.format("[DailyTasks] Slot %s no encontrado en %s", def.Id, label))
		end
	end
	return result
end

local function _resolveMatchHudTaskFrame(): Instance?
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local matchHudGui = playerGui:FindFirstChild("MatchHud")
	if not matchHudGui then return nil end
	local leftContainer = matchHudGui:FindFirstChild("LeftContainer")
	return leftContainer and leftContainer:FindFirstChild("TaskFrame")
end

-- Workspace.Lobby.Daily.Board.SurfaceGui.Container.TaskFrame — board físico del lobby.
-- Las mutaciones desde el cliente no replican, así cada jugador pinta sus
-- propios datos sobre el mismo SurfaceGui sin afectar al resto.
local function _resolveLobbyBoardTaskFrame(): Instance?
	local lobby = Workspace:FindFirstChild("Lobby")
	local daily = lobby and lobby:FindFirstChild("Daily")
	local board = daily and daily:FindFirstChild("Board")
	local surfaceGui = board and board:FindFirstChild("SurfaceGui")
	local container = surfaceGui and surfaceGui:FindFirstChild("Container")
	return container and container:FindFirstChild("TaskFrame")
end

local DailyTasksFeature = {}

function DailyTasksFeature.start(_menuController: any): any
	local janitor = Janitor.new()

	local hudSlots = _resolveSlotsFromTaskFrame(
		_resolveMatchHudTaskFrame(),
		"MatchHud.LeftContainer.TaskFrame"
	)
	local lobbySlots = _resolveSlotsFromTaskFrame(
		_resolveLobbyBoardTaskFrame(),
		"Workspace.Lobby.Daily.Board.SurfaceGui.Container.TaskFrame"
	)

	if #hudSlots == 0 and #lobbySlots == 0 then
		return janitor
	end

	local function _paintAll(slots: { Slot }, progress: any, claimed: any)
		for _, slot in slots do
			local def = DailyTasks.GetById(slot.id)
			if def then
				local current = math.max(0, math.floor((progress :: any)[def.Kind] or 0))
				local isClaimed = (claimed :: any)[def.Id] == true
				_paintSlot(slot, def, current, isClaimed)
			end
		end
	end

	local function _render()
		local state = Fusion.peek(DataController.DailyTasks)
		local progress = state and state.Progress or {}
		local claimed = state and state.Claimed or {}
		_paintAll(hudSlots, progress, claimed)
		_paintAll(lobbySlots, progress, claimed)
	end

	DataController:WhenReady():andThen(function()
		_render()
		-- Fusion 0.3 Observer: re-render cuando cambia el Value.
		local scope = Fusion.scoped(Fusion)
		janitor:Add(function()
			Fusion.doCleanup(scope)
		end, true)
		local obs = scope:Observer(DataController.DailyTasks :: any)
		janitor:Add(obs:onBind(_render), true)
	end)

	return janitor
end

return DailyTasksFeature
