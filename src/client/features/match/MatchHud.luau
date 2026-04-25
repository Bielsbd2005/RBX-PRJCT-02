--!strict
--[[
	MatchHud.luau
	Gestión del HUD de partida: marcador, barras de equipo, filas de jugadores,
	cash/level, y tracking de kills/deaths/bots.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local TeamUtils = require(Shared.utils.TeamUtils)

-- ── Colores ──────────────────────────────────────────────────
local TEAM_A_HUD_COLOR = Color3.fromRGB(0, 161, 251)
local TEAM_B_HUD_COLOR = Color3.fromRGB(246, 82, 71)

-- ── Tipos ────────────────────────────────────────────────────

type HudPlayerRowRefs = {
	root: GuiObject,
	stroke: UIStroke?,
	profile: ImageLabel?,
	totalKillsValue: TextLabel?,
}

type HudRefs = {
	scoreA: TextLabel?,
	scoreB: TextLabel?,
	objective: TextLabel?,
	timer: TextLabel?,
	cashValue: TextLabel?,
	levelValue: TextLabel?,
	levelBarFill: GuiObject?,
	teamABarFill: GuiObject?,
	teamAScore: TextLabel?,
	teamBBarFill: GuiObject?,
	teamBScore: TextLabel?,
	teamAPlayerRows: { HudPlayerRowRefs },
	teamBPlayerRows: { HudPlayerRowRefs },
}

export type BotRosterEntry = {
	displayName: string,
	team: string,
	image: string,
}

export type EndResultsPlayerEntry = {
	userId: number,
	name: string,
	team: "A" | "B",
	kills: number,
	deaths: number,
	level: number,
}

-- ── Helpers de resolución de GUI ─────────────────────────────

local function _findChildGuiObject(parent: Instance?, childName: string): GuiObject?
	if not parent then
		return nil
	end
	local node = parent:FindFirstChild(childName)
	if node and node:IsA("GuiObject") then
		return node
	end
	return nil
end

local function _findDescendant(parent: Instance?, path: { string }): Instance?
	local current = parent
	for _, childName in path do
		if not current then
			return nil
		end
		current = current:FindFirstChild(childName)
	end
	return current
end

local function _findDescendantGuiObject(parent: Instance?, path: { string }): GuiObject?
	local node = _findDescendant(parent, path)
	if node and node:IsA("GuiObject") then
		return node
	end
	return nil
end

local function _findDescendantTextLabel(parent: Instance?, path: { string }): TextLabel?
	local node = _findDescendant(parent, path)
	if node and node:IsA("TextLabel") then
		return node
	end
	return nil
end

-- ── Helpers de llenado de barras ─────────────────────────────

local function _setHorizontalFill(fillNode: GuiObject?, ratio: number)
	if not fillNode then
		return
	end
	local clampedRatio = math.min(1, math.max(0, ratio))
	local baseScale = fillNode:GetAttribute("BaseFillScale")
	local baseOffset = fillNode:GetAttribute("BaseFillOffset")
	local currentSize = fillNode.Size

	if type(baseScale) ~= "number" then
		baseScale = currentSize.X.Scale
		fillNode:SetAttribute("BaseFillScale", baseScale)
	end
	if type(baseOffset) ~= "number" then
		baseOffset = currentSize.X.Offset
		fillNode:SetAttribute("BaseFillOffset", baseOffset)
	end

	local nextScale = baseScale + ((1 - baseScale) * clampedRatio)
	fillNode.Size = UDim2.new(nextScale, baseOffset, currentSize.Y.Scale, currentSize.Y.Offset)
end

local function _setHorizontalFillFromRight(fillNode: GuiObject?, ratio: number)
	if not fillNode then
		return
	end
	local currentPosition = fillNode.Position
	_setHorizontalFill(fillNode, ratio)
	fillNode.AnchorPoint = Vector2.new(1, fillNode.AnchorPoint.Y)
	fillNode.Position = UDim2.new(1, 0, currentPosition.Y.Scale, currentPosition.Y.Offset)
end

local function _alignScoreLabelToFillRight(scoreLabel: TextLabel?, fillNode: GuiObject?)
	if not scoreLabel or not fillNode then
		return
	end
	fillNode.ClipsDescendants = true
	scoreLabel.AnchorPoint = Vector2.new(1, scoreLabel.AnchorPoint.Y)
	scoreLabel.Position = UDim2.new(1, -15, scoreLabel.Position.Y.Scale, scoreLabel.Position.Y.Offset)
	scoreLabel.TextXAlignment = Enum.TextXAlignment.Right
end

local function _alignScoreLabelToFillLeft(scoreLabel: TextLabel?, fillNode: GuiObject?)
	if not scoreLabel or not fillNode then
		return
	end
	fillNode.ClipsDescendants = true
	scoreLabel.AnchorPoint = Vector2.new(0, scoreLabel.AnchorPoint.Y)
	scoreLabel.Position = UDim2.new(0, 15, scoreLabel.Position.Y.Scale, scoreLabel.Position.Y.Offset)
	scoreLabel.TextXAlignment = Enum.TextXAlignment.Left
end

local function _formatMatchTime(timeLeft: number): string
	local totalSeconds = math.max(0, math.floor(timeLeft))
	local minutes = math.floor(totalSeconds / 60)
	local seconds = totalSeconds % 60
	return string.format("%02d:%02d", minutes, seconds)
end

-- ── Resolución de filas de jugadores ─────────────────────────

local function _collectHudPlayerRows(playersContainer: GuiObject?): { HudPlayerRowRefs }
	if not playersContainer then
		return {}
	end

	local indexedRows = {} :: { { index: number, row: HudPlayerRowRefs } }
	for _, child in playersContainer:GetChildren() do
		if not child:IsA("GuiObject") then
			continue
		end
		local index = tonumber(child.Name)
		if not index then
			continue
		end

		local profileNode = child:FindFirstChild("Profile")
		local strokeNode = child:FindFirstChildWhichIsA("UIStroke")
		local totalKillsNode = child:FindFirstChild("Kills")
		local totalKillsValueNode = if totalKillsNode and totalKillsNode:IsA("TextLabel")
			then totalKillsNode
			elseif totalKillsNode and totalKillsNode:IsA("GuiObject")
				then (totalKillsNode:FindFirstChild("Value") or totalKillsNode:FindFirstChild("Kills"))
				else nil
		local totalKillsValue = if totalKillsValueNode and totalKillsValueNode:IsA("TextLabel") then totalKillsValueNode else nil

		table.insert(indexedRows, {
			index = index,
			row = {
				root = child,
				stroke = strokeNode,
				profile = if profileNode and profileNode:IsA("ImageLabel") then profileNode else nil,
				totalKillsValue = totalKillsValue,
			},
		})
	end

	table.sort(indexedRows, function(a, b)
		return a.index < b.index
	end)

	local rows = {} :: { HudPlayerRowRefs }
	for _, entry in indexedRows do
		table.insert(rows, entry.row)
	end
	return rows
end

-- ── Resolución de HUD refs ───────────────────────────────────

local function _resolveHudRefs(matchHudGui: ScreenGui?): HudRefs
	if not matchHudGui then
		return {
			scoreA = nil, scoreB = nil, objective = nil, timer = nil,
			cashValue = nil, levelValue = nil, levelBarFill = nil,
			teamABarFill = nil, teamAScore = nil,
			teamBBarFill = nil, teamBScore = nil,
			teamAPlayerRows = {}, teamBPlayerRows = {},
		}
	end

	local containerNode = _findChildGuiObject(matchHudGui, "Container")
	local matchNode = _findChildGuiObject(containerNode, "Match")
	local statusNode = _findChildGuiObject(matchNode, "Status")
	local cashNode = _findChildGuiObject(containerNode, "Cash")
	local levelNode = _findChildGuiObject(containerNode, "Level")
	local teamABarNode = _findDescendantGuiObject(matchNode, { "TeamA", "BarA", "Bar" })
	local teamAFillNode = _findDescendantGuiObject(teamABarNode, { "Fill" }) or _findDescendantGuiObject(teamABarNode, { "FIll" })
	local teamBBarNode = _findDescendantGuiObject(matchNode, { "TeamB", "BarB", "Bar" })
	local teamBFillNode = _findDescendantGuiObject(teamBBarNode, { "Fill" }) or _findDescendantGuiObject(teamBBarNode, { "FIll" })
	local teamAPlayersNode = _findDescendantGuiObject(matchNode, { "TeamA", "PlayersA" })
	local teamBPlayersNode = _findDescendantGuiObject(matchNode, { "TeamB", "PlayersB" })

	return {
		scoreA = _findDescendantTextLabel(teamAFillNode, { "ScoreA" }),
		scoreB = _findDescendantTextLabel(teamBFillNode, { "ScoreB" }),
		objective = _findDescendantTextLabel(statusNode, { "Objective" }),
		timer = _findDescendantTextLabel(statusNode, { "Timer" }),
		cashValue = _findDescendantTextLabel(cashNode, { "Value" }),
		levelValue = _findDescendantTextLabel(levelNode, { "Value" }),
		levelBarFill = _findDescendantGuiObject(levelNode, { "Fill" }),
		teamABarFill = teamAFillNode,
		teamAScore = _findDescendantTextLabel(teamAFillNode, { "ScoreA" }),
		teamBBarFill = teamBFillNode,
		teamBScore = _findDescendantTextLabel(teamBFillNode, { "ScoreB" }),
		teamAPlayerRows = _collectHudPlayerRows(teamAPlayersNode),
		teamBPlayerRows = _collectHudPlayerRows(teamBPlayersNode),
	}
end

-- ── Módulo MatchHud (OOP) ────────────────────────────────────

local MatchHud = {}
MatchHud.__index = MatchHud

function MatchHud.new(matchHudGui: ScreenGui?): any
	local self = setmetatable({}, MatchHud)
	self._gui = matchHudGui
	self._hudRefs = _resolveHudRefs(matchHudGui)
	self._localUserId = Players.LocalPlayer.UserId

	-- Tracking de partida
	self._killsByUserId = {} :: { [number]: number }
	self._deathsByUserId = {} :: { [number]: number }
	self._streakByUserId = {} :: { [number]: number }
	self._botRoster = {} :: { [number]: BotRosterEntry }

	-- Thumbnails
	self._thumbnailByUserId = {} :: { [number]: string }
	self._thumbnailRequestInFlight = {} :: { [number]: boolean }

	-- Filas del HUD
	self._rowUserIdByKey = {} :: { [string]: number? }
	self._updateQueued = false

	-- Inicializar filas vacías
	for _, rowRef in self._hudRefs.teamAPlayerRows do
		self:_setRowStats(rowRef, 0)
	end
	for _, rowRef in self._hudRefs.teamBPlayerRows do
		self:_setRowStats(rowRef, 0)
	end

	if matchHudGui then
		matchHudGui.Enabled = false
	end

	self:resetMatchState()

	return self
end

-- ── API pública ──────────────────────────────────────────────

function MatchHud:setEnabled(enabled: boolean)
	if self._gui then
		self._gui.Enabled = enabled
	end
end

function MatchHud:setScores(scoreA: number, scoreB: number, timeLeft: number)
	local refs = self._hudRefs
	local clampedA = math.max(0, scoreA)
	local clampedB = math.max(0, scoreB)
	local objectiveScore = math.max(1, GameConfig.WinScoreLimit)

	if refs.scoreA then
		refs.scoreA.Text = tostring(clampedA)
	end
	if refs.scoreB then
		refs.scoreB.Text = tostring(clampedB)
	end
	if refs.objective then
		refs.objective.Text = tostring(objectiveScore)
	end
	if refs.timer then
		refs.timer.Text = _formatMatchTime(timeLeft)
	end

	_setHorizontalFill(refs.teamABarFill, clampedA / objectiveScore)
	_alignScoreLabelToFillRight(refs.teamAScore, refs.teamABarFill)
	_setHorizontalFillFromRight(refs.teamBBarFill, clampedB / objectiveScore)
	_alignScoreLabelToFillLeft(refs.teamBScore, refs.teamBBarFill)
end

function MatchHud:updateCashLevel(stats: any)
	local refs = self._hudRefs

	if refs.cashValue then
		local cash = if stats and type(stats.Cash) == "number" then stats.Cash else 0
		refs.cashValue.Text = tostring(math.max(0, cash))
	end

	if refs.levelValue then
		local level = if stats and type(stats.Level) == "number" then stats.Level else 0
		refs.levelValue.Text = string.format("Lvl %d", level)
	end

	if refs.levelBarFill then
		local currentXP = if stats and type(stats.XP) == "number" then stats.XP else 0
		local xpToNext = if stats and type(stats.XPToNextLevel) == "number" then stats.XPToNextLevel else 1
		local fillRatio = math.min(1, math.max(0, currentXP / xpToNext))
		_setHorizontalFill(refs.levelBarFill, fillRatio)
	end
end

function MatchHud:resetMatchState()
	table.clear(self._killsByUserId)
	table.clear(self._deathsByUserId)
	table.clear(self._streakByUserId)
	-- NOTE: _botRoster no se limpia aquí porque el servidor lo envía
	-- de forma asíncrona vía Network.Match.BotRoster y puede llegar
	-- antes de JoinMatchSpawned. Se reemplaza completamente cada vez
	-- que llega un BotRoster nuevo desde el servidor.
	self._killsByUserId[self._localUserId] = 0
	self._deathsByUserId[self._localUserId] = 0
	self:queuePlayerRowsUpdate()
end

function MatchHud:applyPlayerState(userId: number, kills: number, deaths: number?, streak: number?)
	self._killsByUserId[userId] = math.max(0, kills)
	if deaths ~= nil then
		if userId < 0 then
			self._deathsByUserId[userId] = math.max(0, deaths)
		end
	end
	if streak ~= nil then
		self._streakByUserId[userId] = math.max(0, streak)
	end
	self:queuePlayerRowsUpdate()
end

function MatchHud:incrementLocalDeaths()
	self._deathsByUserId[self._localUserId] = (self._deathsByUserId[self._localUserId] or 0) + 1
end

function MatchHud:setBotRoster(roster: { [number]: BotRosterEntry })
	self._botRoster = roster
	self:queuePlayerRowsUpdate()
end

function MatchHud:onPlayerRemoved(userId: number)
	self._killsByUserId[userId] = nil
	self:queuePlayerRowsUpdate()
end

--- Captura datos para EndResultsView antes de resetear el roster.
function MatchHud:captureEndResultsData(): (string, { EndResultsPlayerEntry })
	local localTeam = TeamUtils.getSide(Players.LocalPlayer.Character) or ""
	local entries = {} :: { EndResultsPlayerEntry }

	for _, player in Players:GetPlayers() do
		local side = TeamUtils.getSide(player.Character) or ""
		if side == "" then
			continue
		end

		local level = 0
		local leaderstats = player:FindFirstChild("leaderstats")
		if leaderstats then
			local levelNode = leaderstats:FindFirstChild("Level")
			if levelNode and (levelNode:IsA("IntValue") or levelNode:IsA("NumberValue")) then
				level = (levelNode :: IntValue).Value
			end
		end

		table.insert(entries, {
			userId = player.UserId,
			name = player.Name,
			team = side :: "A" | "B",
			kills = self._killsByUserId[player.UserId] or 0,
			deaths = self._deathsByUserId[player.UserId] or 0,
			level = level,
		})
	end

	for fakeUserId, entry in pairs(self._botRoster) do
		table.insert(entries, {
			userId = fakeUserId,
			name = entry.displayName,
			team = entry.team :: "A" | "B",
			kills = self._killsByUserId[fakeUserId] or 0,
			deaths = self._deathsByUserId[fakeUserId] or 0,
			level = 0,
		})
	end

	return localTeam, entries
end

-- ── Player rows internos ─────────────────────────────────────

function MatchHud:_setRowStats(rowRef: HudPlayerRowRefs, totalKills: number)
	if rowRef.totalKillsValue then
		rowRef.totalKillsValue.Text = tostring(math.max(0, totalKills))
	end
end

function MatchHud:_setRowTeamColor(rowRef: HudPlayerRowRefs, teamSide: string?)
	local color = if teamSide == "A" then TEAM_A_HUD_COLOR
		elseif teamSide == "B" then TEAM_B_HUD_COLOR
		else nil
	if not color then
		return
	end
	rowRef.root.BackgroundColor3 = color
	if rowRef.stroke then
		rowRef.stroke.Color = color
	end
end

function MatchHud:_clearRow(rowRef: HudPlayerRowRefs, rowKey: string)
	rowRef.root.Visible = false
	self._rowUserIdByKey[rowKey] = nil
	if rowRef.profile then
		rowRef.profile.Image = ""
	end
	self:_setRowStats(rowRef, 0)
end

function MatchHud:_applyCachedOrFetchThumbnail(rowKey: string, userId: number, profileRef: ImageLabel)
	local cached = self._thumbnailByUserId[userId]
	if cached then
		profileRef.Image = cached
		return
	end

	profileRef.Image = ""
	if self._thumbnailRequestInFlight[userId] then
		return
	end

	self._thumbnailRequestInFlight[userId] = true
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		self._thumbnailRequestInFlight[userId] = nil
		if not ok or type(content) ~= "string" or content == "" then
			return
		end
		self._thumbnailByUserId[userId] = content
		if self._rowUserIdByKey[rowKey] ~= userId then
			return
		end
		profileRef.Image = content
	end)
end

function MatchHud:_applyRowEntry(
	rowRef: HudPlayerRowRefs,
	rowKey: string,
	entry: { userId: number, image: string?, isBot: boolean, team: string? }?
)
	rowRef.root.Visible = entry ~= nil
	if not entry then
		self:_clearRow(rowRef, rowKey)
		return
	end

	self._rowUserIdByKey[rowKey] = entry.userId
	self:_setRowTeamColor(rowRef, entry.team)
	if rowRef.profile then
		if entry.isBot then
			rowRef.profile.Image = entry.image or ""
		else
			self:_applyCachedOrFetchThumbnail(rowKey, entry.userId, rowRef.profile)
		end
	end
	self:_setRowStats(rowRef, self._killsByUserId[entry.userId] or 0)
end

function MatchHud:_updatePlayerRows()
	type RowEntry = { userId: number, name: string, image: string?, isBot: boolean, team: string? }
	local entriesByTeam = {
		A = {} :: { RowEntry },
		B = {} :: { RowEntry },
	}

	for _, p in Players:GetPlayers() do
		local side = TeamUtils.getSide(p.Character)
		if not side and p.Team then
			side = TeamUtils.normalize(p.Team.Name)
		end
		if side == "A" or side == "B" then
			table.insert(entriesByTeam[side], { userId = p.UserId, name = p.Name, image = nil, isBot = false, team = side })
		end
	end

	for fakeUserId, entry in pairs(self._botRoster) do
		if entry.team == "A" or entry.team == "B" then
			table.insert(entriesByTeam[entry.team], { userId = fakeUserId, name = entry.displayName, image = entry.image, isBot = true, team = entry.team })
		end
	end

	local function sortEntries(entries: { RowEntry })
		table.sort(entries, function(a, b)
			local killsA = self._killsByUserId[a.userId] or 0
			local killsB = self._killsByUserId[b.userId] or 0
			if killsA ~= killsB then
				return killsA > killsB
			end
			if a.name ~= b.name then
				return a.name < b.name
			end
			return a.userId < b.userId
		end)
	end

	sortEntries(entriesByTeam.A)
	sortEntries(entriesByTeam.B)

	for index, rowRef in ipairs(self._hudRefs.teamAPlayerRows) do
		self:_applyRowEntry(rowRef, string.format("A%d", index), entriesByTeam.A[index])
	end

	for index, rowRef in ipairs(self._hudRefs.teamBPlayerRows) do
		local reverseIndex = (#entriesByTeam.B - index) + 1
		local entry = if reverseIndex >= 1 then entriesByTeam.B[reverseIndex] else nil
		self:_applyRowEntry(rowRef, string.format("B%d", index), entry)
	end
end

function MatchHud:queuePlayerRowsUpdate()
	if self._updateQueued then
		return
	end
	self._updateQueued = true
	task.defer(function()
		self._updateQueued = false
		self:_updatePlayerRows()
	end)
end

return MatchHud
