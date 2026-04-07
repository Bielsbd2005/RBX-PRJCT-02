--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any

local MenuAnimator = require(script.Parent.animators.MenuAnimator)
local MenuHover = require(script.Parent.MenuHover)
local DataController = require(script.Parent.Parent.data.DataController)
type StatsData = {
	Level: number,
	XP: number,
	XPToNextLevel: number,
	Cash: number,
}

type HudRefs = {
	cashValue: TextLabel?,
	xpFill: Frame?,
	xpLabel: TextLabel?,
	actualLabel: TextLabel?,
	nextLabel: TextLabel?,
}

export type MenuController = {
	_gui: ScreenGui,
	_animator: any,
	_hover: any,
	_janitor: any,
	_fusionScope: any,
	_hudRefs: HudRefs,
	getGui: (self: MenuController) -> ScreenGui,
	hide: (self: MenuController) -> (),
	show: (self: MenuController) -> (),
	Destroy: (self: MenuController) -> (),
}

local MenuController = {}
MenuController.__index = MenuController

local function setText(label: TextLabel?, value: string): ()
	if label then
		label.Text = value
	end
end

local function findDescendantByName(root: Instance, names: { string }): Instance?
	for _, descendant in ipairs(root:GetDescendants()) do
		for _, candidate in ipairs(names) do
			if descendant.Name == candidate then
				return descendant
			end
		end
	end

	return nil
end

local function findTextLabel(root: Instance, names: { string }): TextLabel?
	local node = findDescendantByName(root, names)
	if node and node:IsA("TextLabel") then
		return node
	end

	return nil
end

local function resolveHudRefs(menuGui: ScreenGui): HudRefs
	local upper = menuGui:FindFirstChild("UpperContainer")
	if not upper then
		return {
			cashValue = nil,
			xpFill = nil,
			xpLabel = nil,
			actualLabel = nil,
			nextLabel = nil,
		}
	end

	local cashNode = upper:FindFirstChild("Cash")
	local cashValueNode = if cashNode then cashNode:FindFirstChild("Value") else nil
	local cashValue = if cashValueNode and cashValueNode:IsA("TextLabel") then cashValueNode else nil

	local xpNode = upper:FindFirstChild("XP")
	if not xpNode then
		return {
			cashValue = cashValue,
			xpFill = nil,
			xpLabel = nil,
			actualLabel = nil,
			nextLabel = nil,
		}
	end

	local xpContainer = xpNode:FindFirstChild("Container")
	local xpFillNode = if xpContainer then findDescendantByName(xpContainer, { "Fill" }) else nil
	local xpFill = if xpFillNode and xpFillNode:IsA("Frame") then xpFillNode else nil
	local xpLabel = if xpContainer then findTextLabel(xpContainer, { "XP", "Value" }) else nil

	return {
		cashValue = cashValue,
		xpFill = xpFill,
		xpLabel = xpLabel,
		actualLabel = findTextLabel(xpNode, { "Actual", "Current", "NivelActual" }),
		nextLabel = findTextLabel(xpNode, { "Proximo", "Próximo", "Next", "Siguiente" }),
	}
end

local function updateTopHud(hudRefs: HudRefs, stats: StatsData): ()
	if not hudRefs.cashValue and not hudRefs.xpFill and not hudRefs.xpLabel and not hudRefs.actualLabel and not hudRefs.nextLabel then
		return
	end

	setText(hudRefs.cashValue, tostring(stats.Cash))

	if hudRefs.xpFill then
		local ratio = 0
		if stats.XPToNextLevel > 0 then
			ratio = math.clamp(stats.XP / stats.XPToNextLevel, 0, 1)
		end
		hudRefs.xpFill.Size = UDim2.new(ratio, 0, 1, 0)
	end

	if hudRefs.xpLabel then
		hudRefs.xpLabel.Text = string.format("%d / %d", stats.XP, stats.XPToNextLevel)
	end

	setText(hudRefs.actualLabel, tostring(stats.Level))
	setText(hudRefs.nextLabel, tostring(stats.Level + 1))
end

function MenuController.new(): MenuController
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = playerGui:WaitForChild("Menu") :: ScreenGui

	local self = setmetatable({}, MenuController) :: any

	self._gui = menuGui
	self._janitor = Janitor.new()
	self._fusionScope = Fusion.scoped(Fusion)
	self._animator = MenuAnimator.new(menuGui)
	self._hover = MenuHover.new(menuGui)
	self._hudRefs = resolveHudRefs(menuGui)

	self._janitor:Add(self._animator, "Destroy")
	self._janitor:Add(self._hover, "Destroy")
	self._janitor:Add(function()
		Fusion.doCleanup(self._fusionScope)
	end, true)

	DataController:WhenReady():andThen(function()
		local function updateHudFromState()
			local stats = Fusion.peek(DataController.Stats) :: StatsData
			updateTopHud(self._hudRefs, stats)
		end

		local statsObserver = self._fusionScope:Observer(DataController.Stats)
		self._janitor:Add(statsObserver:onBind(updateHudFromState), true)
	end)

	return self
end

function MenuController:getGui(): ScreenGui
	return self._gui
end

function MenuController:hide(): ()
	self._animator:hide()
end

function MenuController:show(): ()
	self._animator:show()
end

function MenuController:Destroy(): ()
	self._janitor:Destroy()
end

return MenuController
