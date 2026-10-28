--!strict
--[[
	Tarjeta de jugador en el mundo: <escena>.Banner.Part.BillboardGui.Card, con la
	misma estructura que la tarjeta de la pantalla de muerte (ver PlayerCard).
	Escena: Workspace.Locker.Banner.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PlayerCard = require(script.Parent.Parent.Parent.Parent.core.ui.PlayerCard)
local VipTag = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("utils"):WaitForChild("VipTag"))

-- Vaivén: amplitudes en studs y velocidades en rad/s. El segundo seno, de periodo
-- no múltiplo, rompe la regularidad del primero.
local BOB_AMPLITUDE_PRIMARY = 0.18
local BOB_SPEED_PRIMARY = 1.6
local BOB_AMPLITUDE_SECONDARY = 0.07
local BOB_SPEED_SECONDARY = 0.9
local BOB_PHASE_SECONDARY = 1.3

local PlayerCardPreviewer = {}
PlayerCardPreviewer.__index = PlayerCardPreviewer

function PlayerCardPreviewer.new(sceneFolder: Instance?)
	local self = setmetatable({}, PlayerCardPreviewer)
	self._part = nil :: BasePart?
	self._gui = nil :: LayerCollector?
	self._refs = nil :: PlayerCard.Refs?
	self._bobConnection = nil :: any
	self._visible = false

	local partNode = if sceneFolder then sceneFolder:FindFirstChild("Part") else nil
	-- La Card cuelga del BillboardGui de la Part, no de la Part directamente.
	local cardNode = if partNode then partNode:FindFirstChild("Card", true) else nil
	if not (partNode and partNode:IsA("BasePart") and cardNode) then
		local path = if sceneFolder then sceneFolder:GetFullName() else "<escena>.Banner"
		warn(`[PlayerCardPreviewer] Tarjeta de jugador no encontrada: {path}.Part.BillboardGui.Card`)
		return self
	end

	local gui: LayerCollector? = if cardNode:IsA("LayerCollector")
		then cardNode
		else cardNode:FindFirstAncestorWhichIsA("LayerCollector")
	self._part = partNode
	self._baseCFrame = partNode.CFrame
	self._gui = gui
	self._refs = PlayerCard.resolve(cardNode)
	if gui then
		gui.Enabled = false
	end
	return self
end

function PlayerCardPreviewer:_startBob()
	local part = self._part
	if not part or self._bobConnection then
		return
	end
	local baseCFrame: CFrame = self._baseCFrame
	local startedAt = os.clock()
	self._bobConnection = RunService.RenderStepped:Connect(function()
		local t = os.clock() - startedAt
		local offset = math.sin(t * BOB_SPEED_PRIMARY) * BOB_AMPLITUDE_PRIMARY
			+ math.sin(t * BOB_SPEED_SECONDARY + BOB_PHASE_SECONDARY) * BOB_AMPLITUDE_SECONDARY
		part.CFrame = baseCFrame + Vector3.new(0, offset, 0)
	end)
end

function PlayerCardPreviewer:_stopBob()
	local connection: RBXScriptConnection? = self._bobConnection
	if connection then
		connection:Disconnect()
		self._bobConnection = nil
	end
	if self._part then
		self._part.CFrame = self._baseCFrame
	end
end

function PlayerCardPreviewer:isVisible(): boolean
	return self._visible
end

function PlayerCardPreviewer:setVisible(visible: boolean)
	self._visible = visible
	if self._gui then
		self._gui.Enabled = visible
	end
	if visible then
		self:_startBob()
	else
		self:_stopBob()
	end
end

-- Siempre es la tarjeta del jugador local: con su foto y su tag VIP, como la ven sus víctimas.
function PlayerCardPreviewer:setContent(level: number, borderId: string?)
	if self._refs then
		local player = Players.LocalPlayer
		PlayerCard.populate(self._refs, {
			name = player.Name,
			level = level,
			userId = player.UserId,
			isVIP = VipTag.isVIP(player),
			borderId = borderId,
		})
	end
end

function PlayerCardPreviewer:Destroy()
	self:setVisible(false)
end

return PlayerCardPreviewer
