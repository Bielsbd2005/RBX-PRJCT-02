--!strict
--[[
	Slots de misiones del HUD de partida (MatchHud.Container.Missions.<N>, N = índice
	en DailyTasks.SlotIds). Los del menú los pinta MenuController.
	La tarea de cada slot sale de la rotación sembrada con el DateKey del propio
	estado, el mismo con el que paga el server.

	Nodos por slot (todos opcionales):
	  <N>.Title / <N>.Value (RichText) / <N>.Bar.Fill / <N>.Icon
	  <N>.Reward         — TextLabel con el cash, o frame con Reward.Value
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

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
local BAR_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local DISMISS_DELAY_SECONDS = 0.5
local DISMISS_TWEEN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local DISMISS_MARGIN = 40
local DISMISS_COLLAPSE_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

type Slot = {
	id: string,
	titleLabel: TextLabel?,
	valueLabel: TextLabel?,
	barFill: GuiObject?,
	rewardNode: GuiObject?,
	rewardLabel: TextLabel?,
	icon: ImageLabel?,
	-- Cacheados al primer paint para restaurarlos en el reinicio diario.
	originalFillColor: Color3?,
	originalIconColor: Color3?,
	painted: boolean,
	fillTween: Tween?,
	node: GuiObject,
	originalParent: Instance,
	originalPosition: UDim2,
	originalSize: UDim2,
	originalAnchor: Vector2,
	holder: Frame?,
	dismiss: "shown" | "leaving" | "gone",
	dismissTween: Tween?,
}

local function _resolveSlot(missionsNode: Instance, nodeName: string, id: string): Slot?
	local node = missionsNode:FindFirstChild(nodeName)
	if not (node and node:IsA("GuiObject")) then return nil end

	local bar = node:FindFirstChild("Bar")
	local reward = node:FindFirstChild("Reward")
	local rewardLabel: TextLabel? = if reward and reward:IsA("TextLabel")
		then reward
		elseif reward then reward:FindFirstChild("Value") :: TextLabel?
		else nil

	return {
		id = id,
		titleLabel = node:FindFirstChild("Title") :: TextLabel?,
		valueLabel = node:FindFirstChild("Value") :: TextLabel?,
		barFill = if bar then bar:FindFirstChild("Fill") :: GuiObject? else nil,
		rewardNode = if reward and reward:IsA("GuiObject") then reward :: GuiObject else nil,
		rewardLabel = rewardLabel,
		icon = node:FindFirstChild("Icon") :: ImageLabel?,
		painted = false,
		fillTween = nil,
		node = node,
		originalParent = missionsNode,
		originalPosition = node.Position,
		originalSize = node.Size,
		originalAnchor = node.AnchorPoint,
		holder = nil,
		dismiss = "shown",
		dismissTween = nil,
	}
end

local function _setText(label: TextLabel?, text: string)
	if label then label.Text = text end
end

-- El UIListLayout de Missions manda sobre la Position de sus hijos: para animar la
-- salida, el slot se mete en un marco que ocupa su hueco y se mueve dentro de él.
local function _wrapInHolder(slot: Slot): Frame
	local node = slot.node
	local holder = Instance.new("Frame")
	holder.Name = node.Name
	holder.LayoutOrder = node.LayoutOrder
	holder.Size = node.Size
	holder.Position = node.Position
	holder.AnchorPoint = node.AnchorPoint
	holder.ZIndex = node.ZIndex
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	for _, child in node:GetChildren() do
		if child:IsA("UIAspectRatioConstraint") or child:IsA("UISizeConstraint") then
			child:Clone().Parent = holder
		end
	end
	holder.Parent = slot.originalParent

	node.AnchorPoint = Vector2.zero
	node.Position = UDim2.new()
	node.Size = UDim2.fromScale(1, 1)
	node.Parent = holder
	return holder
end

local function _unwrapFromHolder(slot: Slot)
	local holder = slot.holder
	if not holder then
		return
	end
	local node = slot.node
	node.Parent = slot.originalParent
	node.AnchorPoint = slot.originalAnchor
	node.Position = slot.originalPosition
	node.Size = slot.originalSize
	holder:Destroy()
	slot.holder = nil
end

local function _collapsedSize(holder: Frame, listParent: Instance): UDim2
	local size = holder.Size
	local layout = listParent:FindFirstChildWhichIsA("UIListLayout")
	if layout and layout.FillDirection == Enum.FillDirection.Horizontal then
		return UDim2.new(0, 0, size.Y.Scale, size.Y.Offset)
	end
	return UDim2.new(size.X.Scale, size.X.Offset, 0, 0)
end

-- Claimed → sale a la izquierda y cierra el hueco (sin animación en el primer pintado).
-- Solo vuelve si Claimed pasa a false (reinicio diario).
local function _updateDismiss(slot: Slot, claimed: boolean)
	local node = slot.node
	if not claimed then
		if slot.dismiss ~= "shown" then
			if slot.dismissTween then
				slot.dismissTween:Cancel()
				slot.dismissTween = nil
			end
			_unwrapFromHolder(slot)
			node.Visible = true
			slot.dismiss = "shown"
		end
		return
	end

	if slot.dismiss ~= "shown" then
		return
	end
	if not slot.painted then
		node.Visible = false
		slot.dismiss = "gone"
		return
	end

	slot.dismiss = "leaving"
	task.delay(BAR_TWEEN_INFO.Time + DISMISS_DELAY_SECONDS, function()
		if slot.dismiss ~= "leaving" then
			return
		end
		-- Medir antes de envolver: tras reparentar, AbsolutePosition no se actualiza
		-- hasta el siguiente pase de layout.
		local travel = math.ceil(node.AbsolutePosition.X + node.AbsoluteSize.X) + DISMISS_MARGIN
		local holder = _wrapInHolder(slot)
		slot.holder = holder

		local slide = TweenService:Create(node, DISMISS_TWEEN_INFO, { Position = UDim2.fromOffset(-travel, 0) })
		slot.dismissTween = slide
		slide.Completed:Once(function(slideState: Enum.PlaybackState)
			if slideState ~= Enum.PlaybackState.Completed or slot.dismiss ~= "leaving" then
				return
			end
			node.Visible = false
			-- Las restricciones clonadas impedirían encoger el hueco.
			for _, child in holder:GetChildren() do
				if child:IsA("UIConstraint") then
					child:Destroy()
				end
			end

			local collapse = TweenService:Create(holder, DISMISS_COLLAPSE_INFO, {
				Size = _collapsedSize(holder, slot.originalParent),
			})
			slot.dismissTween = collapse
			collapse.Completed:Once(function(collapseState: Enum.PlaybackState)
				if collapseState ~= Enum.PlaybackState.Completed or slot.dismiss ~= "leaving" then
					return
				end
				-- Oculto también el hueco para que no cuente el Padding de la lista.
				holder.Visible = false
				slot.dismiss = "gone"
				slot.dismissTween = nil
			end)
			collapse:Play()
		end)
		slide:Play()
	end)
end

local function _paintSlot(slot: Slot, def: any, progress: number, claimed: boolean)
	local objective = math.max(1, def.Objective)
	local clampedProgress = math.clamp(progress, 0, objective)
	local ratio = clampedProgress / objective

	_setText(slot.titleLabel, def.Title)
	if slot.valueLabel then
		slot.valueLabel.RichText = true
		slot.valueLabel.Text = UIUtils.formatProgressValue(clampedProgress, objective)
	end
	-- El cash es de la TAREA, no del slot: misma fuente que usa el server al pagar.
	_setText(slot.rewardLabel, UIUtils.formatCashAmount(ActionRewards.GetCash(DailyTasks.RewardKey(def))))

	if slot.barFill then
		-- X.Offset = 0: un offset del template sacaría el fill fuera del Bar.
		local fillRatio = if claimed then 1 else ratio
		local size = slot.barFill.Size
		local targetSize = UDim2.new(fillRatio, 0, size.Y.Scale, size.Y.Offset)
		if slot.fillTween then
			slot.fillTween:Cancel()
			slot.fillTween = nil
		end
		-- El primer pintado va directo: animar desde el tamaño del template no es progreso.
		if slot.painted then
			local tween = TweenService:Create(slot.barFill, BAR_TWEEN_INFO, { Size = targetSize })
			slot.fillTween = tween
			tween:Play()
		else
			slot.barFill.Size = targetSize
		end

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

	if slot.rewardNode then
		slot.rewardNode.Visible = not claimed
	end

	_updateDismiss(slot, claimed)
	slot.painted = true
end

local function _resolveMissionSlots(missionsNode: Instance?, label: string): { Slot }
	local result: { Slot } = {}
	if not missionsNode then return result end

	for index, slotId in DailyTasks.SlotIds do
		local slot = _resolveSlot(missionsNode, tostring(index), slotId)
		if slot then
			table.insert(result, slot)
		else
			warn(string.format("[DailyTasks] Slot %d no encontrado en %s", index, label))
		end
	end
	return result
end

local function _resolveMatchHudMissions(): Instance?
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local matchHudGui = playerGui:WaitForChild("MatchHud", 30)
	if not matchHudGui then return nil end
	local container = matchHudGui:WaitForChild("Container", 30)
	return container and container:WaitForChild("Missions", 30)
end

local DailyTasksFeature = {}

function DailyTasksFeature.start(_menuController: any): any
	local janitor = Janitor.new()

	DataController:WhenReady():andThen(function()
		local missionsNode = _resolveMatchHudMissions()
		if not missionsNode then
			warn("[DailyTasks] No se encontró MatchHud.Container.Missions — las misiones no se pintarán en partida")
			return
		end

		local hudSlots = _resolveMissionSlots(missionsNode, "MatchHud.Container.Missions")
		if #hudSlots == 0 then
			return
		end

		local function _paintAll(slots: { Slot }, dateKey: string?, progress: any, claimed: any)
			for _, slot in slots do
				local def = DailyTasks.GetForSlot(dateKey, slot.id)
				if def then
					local current = math.max(0, math.floor((progress :: any)[def.Kind] or 0))
					local isClaimed = (claimed :: any)[slot.id] == true
					_paintSlot(slot, def, current, isClaimed)
				end
			end
		end

		local function _render()
			local state = Fusion.peek(DataController.DailyTasks)
			local dateKey = if state and type(state.DateKey) == "string" then state.DateKey else nil
			local progress = state and state.Progress or {}
			local claimed = state and state.Claimed or {}
			_paintAll(hudSlots, dateKey, progress, claimed)
		end

		_render()
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
