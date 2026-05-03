--!strict
--[[
	DailyTasksFeature  (Client)
	Pinta los slots Task1/Task2/Task3 en DOS sitios — el menú y el HUD de
	partida — usando la misma fuente de datos:
	  Menu.LeftContainer.TaskFrame.Task1/2/3       (lobby)
	  MatchHud.LeftContainer.TaskFrame.Task1/2/3   (durante la partida)
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

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any

local DailyTasks = require(Shared.constants.DailyTasks)
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
	_setText(slot.rewardLabel, UIUtils.formatCashAmount(def.Cash))

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

-- Resuelve los 3 slots dentro de un GUI dado (Menu o MatchHud).
local function _resolveSlotsForGui(rootGui: Instance?, label: string): { Slot }
	local result: { Slot } = {}
	if not rootGui then return result end

	local leftContainer = rootGui:FindFirstChild("LeftContainer")
	local taskFrame = leftContainer and leftContainer:FindFirstChild("TaskFrame")
	if not taskFrame then
		-- No es un error: el HUD puede no tener TaskFrame; el Menu suele tenerlo.
		-- Solo avisamos si el GUI existe pero le falta el contenedor.
		warn(string.format("[DailyTasks] No se encontró %s.LeftContainer.TaskFrame", label))
		return result
	end

	for _, def in DailyTasks.Tasks do
		local slot = _resolveSlot(taskFrame, def.Id)
		if slot then
			table.insert(result, slot)
		else
			warn(string.format("[DailyTasks] Slot %s no encontrado en %s.TaskFrame", def.Id, label))
		end
	end
	return result
end

local DailyTasksFeature = {}

function DailyTasksFeature.start(menuController: any): any
	local janitor = Janitor.new()

	local menuGui = menuController:getGui()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local matchHudGui = playerGui:FindFirstChild("MatchHud")

	-- Slots de ambos sitios. Cada lista es independiente; si uno falta, el
	-- otro sigue funcionando.
	local menuSlots = _resolveSlotsForGui(menuGui, "Menu")
	local hudSlots = _resolveSlotsForGui(matchHudGui, "MatchHud")

	if #menuSlots == 0 and #hudSlots == 0 then
		return janitor
	end

	-- Suscripción reactiva a DataController.DailyTasks. Cada cambio del
	-- replicador (incremento de progreso o reset diario) re-pinta ambos sets.
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
		_paintAll(menuSlots, progress, claimed)
		_paintAll(hudSlots, progress, claimed)
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
