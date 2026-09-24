--!strict
--[[
	Pantalla de Resultados: UI en UserInterface.Results y una réplica 3D por miembro
	del equipo local en las anclas `Results.Player1..4` del mapa.

	El servidor desmonta el mapa con su propio reloj: anclas y cámara se piden a
	ResultsScene (guarda sus CFrames) y las réplicas van a una carpeta propia en
	Workspace. Las réplicas no dependen de los Characters vivos.

	Flujo del caller: fundido a negro → :preload() → :show() (reutiliza las réplicas).
	Nunca antes de acabar la ronda: las anclas están en mitad del mapa.

	UI por slot (opcionales):
	  PlayerN.Container.Kills.Value / Assists.Value / Deaths.Value
	  PlayerN.NameRow.LevelBadge.Value / NameRow.Name
	  PlayerN.MVP   (o MVPRow)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any
local LockerUtils = require(Client.features.locker.LockerUtils)
local FaceApplier = require(Client.features.locker.Appliers.FaceApplier)
local HatApplier = require(Client.features.locker.Appliers.HatApplier)
local DataController = require(Client.core.data.DataController)
local ResultsScene = require(script.Parent.ResultsScene)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local AssetIds = require(Shared.constants.AssetIds)

local SLOT_COUNT = 4
local REPLICA_FOLDER_NAME = "ResultsReplicas"
local IDLE_ANIMATION_ID = AssetIds.Animations.PreviewIdle
local LOCAL_USER_ID = Players.LocalPlayer.UserId

local LOCKED_COLOR = Color3.fromRGB(133, 134, 134)

local HEADER_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Segundos.
local REWARD_START_DELAY = 0.3
local REWARD_STAGGER = 0.26
local REWARD_TWEEN = TweenInfo.new(0.7, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Packet Match.MatchResults: cash e items en una lista con un solo template.
export type DisplayReward = {
	title: string,
	image: string,
	amount: number, -- cash; 0 = item
	locked: boolean, -- bonus VIP no poseído: se muestra como upsell, no se concede
}
export type MatchResults = {
	outcome: string, -- "Victory" | "Defeat"
	rewards: { DisplayReward },
}

export type ResultEntry = {
	userId: number,
	name: string,
	team: string,
	kills: number,
	deaths: number,
	assists: number,
	level: number,
	isBot: boolean,
	outfitId: string,
	faceId: string,
	hatId: string,
}

type UiSlot = {
	frame: GuiObject,
	kills: TextLabel?,
	assists: TextLabel?,
	deaths: TextLabel?,
	level: TextLabel?,
	name: TextLabel?,
	mvp: GuiObject?,
}

local ResultsView = {}
ResultsView.__index = ResultsView

local function _setText(label: TextLabel?, text: string)
	if label then
		label.Text = text
	end
end

local function _optString(value: any): string?
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function _resolveLabel(root: Instance, path: { string }): TextLabel?
	local node: Instance? = root
	for _, name in path do
		if not node then
			return nil
		end
		node = node:FindFirstChild(name)
	end
	return if node and node:IsA("TextLabel") then node :: TextLabel else nil
end

local function _resolveUiSlot(frame: GuiObject): UiSlot
	local mvp = frame:FindFirstChild("MVP") or frame:FindFirstChild("MVPRow")
	return {
		frame = frame,
		kills = _resolveLabel(frame, { "Container", "Kills", "Value" }),
		assists = _resolveLabel(frame, { "Container", "Assists", "Value" }),
		deaths = _resolveLabel(frame, { "Container", "Deaths", "Value" }),
		level = _resolveLabel(frame, { "NameRow", "LevelBadge", "Value" }),
		name = _resolveLabel(frame, { "NameRow", "Name" }),
		mvp = if mvp and mvp:IsA("GuiObject") then mvp :: GuiObject else nil,
	}
end

-- El jugador local siempre es Player1; el resto por kills desc.
local function _teamFromEntries(localTeam: string, entries: { ResultEntry }): { ResultEntry }
	local team = {} :: { ResultEntry }
	for _, entry in entries do
		if entry.team == localTeam then
			table.insert(team, entry)
		end
	end
	table.sort(team, function(a, b)
		local aLocal = a.userId == LOCAL_USER_ID
		local bLocal = b.userId == LOCAL_USER_ID
		if aLocal ~= bLocal then
			return aLocal
		end
		return a.kills > b.kills
	end)
	return team
end

type RewardRefs = {
	valueLabel: TextLabel?,
	rewardsFrame: GuiObject?,
	template: GuiObject?,
}

local function _resolveRewardRefs(resultsFrame: GuiObject): RewardRefs
	local valueNode = resultsFrame:FindFirstChild("Value")
	local rewardsNode = resultsFrame:FindFirstChild("Rewards")
	local rewardsFrame = if rewardsNode and rewardsNode:IsA("GuiObject") then rewardsNode :: GuiObject else nil

	local templateNode = if rewardsFrame then rewardsFrame:FindFirstChild("ItemTemplate") else nil
	if not templateNode then
		templateNode = resultsFrame:FindFirstChild("ItemTemplate")
	end
	local template = if templateNode and templateNode:IsA("GuiObject") then templateNode :: GuiObject else nil
	if template then
		template.Visible = false
	end

	return {
		valueLabel = if valueNode and valueNode:IsA("TextLabel") then valueNode :: TextLabel else nil,
		rewardsFrame = rewardsFrame,
		template = template,
	}
end

local function _findRewardImage(root: Instance): ImageLabel?
	for _, name in { "Viewport", "Image" } do
		local direct = root:FindFirstChild(name)
		if direct and direct:IsA("ImageLabel") then
			return direct :: ImageLabel
		end
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("ImageLabel") and (descendant.Name == "Viewport" or descendant.Name == "Image") then
			return descendant :: ImageLabel
		end
	end
	return nil
end

-- Tolera frame/template nulos: los métodos quedan en no-op.
function ResultsView.new(resultsFrame: GuiObject?): any
	local self = setmetatable({}, ResultsView)
	self._frame = resultsFrame
	self._slots = {} :: { UiSlot }

	if resultsFrame then
		for i = 1, SLOT_COUNT do
			local slotFrame = resultsFrame:FindFirstChild("Player" .. tostring(i))
			self._slots[i] = if slotFrame and slotFrame:IsA("GuiObject")
				then _resolveUiSlot(slotFrame)
				else nil :: any
		end
		resultsFrame.Visible = false
		self._rewards = _resolveRewardRefs(resultsFrame)
	end

	self._rewardClones = {} :: { Instance }
	self._replicaFolder = nil :: Folder?
	self._replicaJanitor = Janitor.new()
	self._preloadedSize = -1 -- tamaño de equipo con el que se construyeron las réplicas
	self._uiWarned = false
	self._showing = false
	self._token = 0
	return self
end

local function _readLoadout(): (string?, string?, string?)
	local loadout = Fusion.peek(DataController.Loadout) :: { [string]: any }
	if type(loadout) ~= "table" then
		return nil, nil, nil
	end
	return _optString(loadout.Outfit), _optString(loadout.Face), _optString(loadout.Hat)
end

function ResultsView:_resolveBodyTemplate(outfitId: string?): Model?
	local folder = Shared:FindFirstChild("Bodies")
	if not folder then
		warn("[ResultsView] No se encontró Shared.Bodies — no se pueden generar las réplicas 3D.")
		return nil
	end
	local byId = if outfitId then folder:FindFirstChild(outfitId) else nil
	if byId and byId:IsA("Model") then
		return byId :: Model
	end
	local default = folder:FindFirstChild("Default")
	return if default and default:IsA("Model") then default :: Model else nil
end

function ResultsView:_spawnReplica(template: Model, anchor: CFrame, parent: Instance, face: string?, hat: string?)
	local clone = template:Clone()
	clone.Name = "ResultReplica"
	for _, desc in clone:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.CanCollide = false
		end
	end
	clone.Parent = parent
	LockerUtils.placePreviewCharacterAtCFrame(clone, anchor)

	local hrp = clone:FindFirstChild("HumanoidRootPart", true)
	if hrp and hrp:IsA("BasePart") then
		hrp.Anchored = true
	end
	LockerUtils.playPreviewIdleAnimation(clone, self._replicaJanitor, IDLE_ANIMATION_ID)

	FaceApplier.new(clone, ItemsConfig):ApplyItemId(face)
	HatApplier.new(clone, ItemsConfig):ApplyItemId(hat)
end

-- El local usa su loadout; el resto, lo que traiga la entrada (roster/TeamCosmetics).
local function _appearanceFor(entry: ResultEntry): (string?, string?, string?)
	if entry.userId == LOCAL_USER_ID then
		return _readLoadout()
	end
	return _optString(entry.outfitId), _optString(entry.faceId), _optString(entry.hatId)
end

function ResultsView:_buildReplicas(team: { ResultEntry })
	self:_clearReplicas()

	local anchors = ResultsScene.getAnchors()
	if next(anchors) == nil then
		warn("[ResultsView] Sin anclas Results.Player1..N del mapa — no se generan las réplicas 3D de jugadores.")
		return
	end

	local folder = self:_ensureReplicaFolder()
	for i = 1, math.min(SLOT_COUNT, #team) do
		local entry = team[i]
		local anchor = anchors[i]
		if anchor then
			local outfit, face, hat = _appearanceFor(entry)
			local template = self:_resolveBodyTemplate(outfit)
			if template then
				self:_spawnReplica(template, anchor, folder, face, hat)
			end
		end
	end
	self._preloadedSize = #team
end

function ResultsView:_ensureReplicaFolder(): Folder
	local folder = Instance.new("Folder")
	folder.Name = REPLICA_FOLDER_NAME
	folder.Parent = workspace
	self._replicaFolder = folder
	return folder
end

function ResultsView:_clearReplicas()
	self._replicaJanitor:Destroy()
	self._replicaJanitor = Janitor.new()
	if self._replicaFolder then
		self._replicaFolder:Destroy()
		self._replicaFolder = nil
	end
	self._preloadedSize = -1
end

function ResultsView:_clearRewardClones()
	for _, clone in self._rewardClones do
		clone:Destroy()
	end
	table.clear(self._rewardClones)
end

function ResultsView:_animateHeader(label: TextLabel, token: number)
	if self._token ~= token then
		return
	end
	local scale = label:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = label
	TweenService:Create(scale, HEADER_TWEEN, { Scale = 1 }):Play()
end

function ResultsView:_renderReward(template: GuiObject, parent: Instance, entry: DisplayReward, order: number, token: number)
	local clone = template:Clone()
	clone.Name = "Reward"
	clone.LayoutOrder = order

	local titleLabel = _resolveLabel(clone, { "Title", "Value" })
	_setText(titleLabel, entry.title)

	local image = _findRewardImage(clone)
	if image and entry.image ~= "" then
		image.Image = entry.image
	end

	local amountNode = clone:FindFirstChild("Amount")
	local amountLabel = if amountNode and amountNode:IsA("TextLabel") then amountNode :: TextLabel else nil
	local isCash = entry.amount > 0
	if amountNode and amountNode:IsA("GuiObject") then
		amountNode.Visible = isCash
	end
	if amountLabel and isCash then
		amountLabel.Text = tostring(math.floor(entry.amount))
	end

	local lockedNode = if amountNode then amountNode:FindFirstChild("Locked") else nil
	local locked = entry.locked == true
	if lockedNode and lockedNode:IsA("GuiObject") then
		lockedNode.Visible = locked
	end
	if locked then
		if image then
			image.ImageColor3 = LOCKED_COLOR
		end
		if amountLabel then
			amountLabel.TextColor3 = LOCKED_COLOR
		end
		if titleLabel then
			titleLabel.TextColor3 = LOCKED_COLOR
		end
	end

	-- Oculta hasta su turno: el UIListLayout ignora los Visible=false y no deja hueco.
	local scale = clone:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = clone

	clone.Visible = false
	clone.Parent = parent
	table.insert(self._rewardClones, clone)

	task.delay(REWARD_START_DELAY + (order - 1) * REWARD_STAGGER, function()
		if self._token ~= token or not clone.Parent then
			return
		end
		clone.Visible = true
		TweenService:Create(scale, REWARD_TWEEN, { Scale = 1 }):Play()
	end)
end

--- Pinta las recompensas sobre la pantalla YA abierta. Existe porque ByteNet vacía
--- la cola broadcast (RoundEnded) antes que la por-jugador (recompensas), así que
--- el paquete llega después de show(). No-op si la pantalla no está abierta.
function ResultsView:applyRewards(rewards: MatchResults?)
	if not self._showing then
		return
	end
	self:_renderRewards(rewards)
end

-- rewards == nil (sin paquete / carrera de red): solo limpia la sección.
function ResultsView:_renderRewards(rewards: MatchResults?)
	self:_clearRewardClones()
	local refs = self._rewards
	if not refs then
		return
	end

	local token = self._token

	if refs.valueLabel and rewards then
		refs.valueLabel.Visible = true
		refs.valueLabel.Text = if rewards.outcome == "Victory" then "VICTORY" else "DEFEAT"
		self:_animateHeader(refs.valueLabel, token)
	end

	if not rewards then
		return
	end

	local parent = refs.rewardsFrame
	local template = refs.template
	if not parent or not template then
		return
	end
	-- En Studio se suele dejar apagado para ver el resto del diseño.
	parent.Visible = true
	for order, entry in rewards.rewards do
		self:_renderReward(template, parent, entry, order, token)
	end
end

function ResultsView:_hideSlot(slot: UiSlot)
	slot.frame.Visible = false
	if slot.mvp then
		slot.mvp.Visible = false
	end
end

-- PlayerGui replica el árbol por partes y `Rewards`/`Value` pueden no existir aún
-- cuando corre el constructor: se reintenta lo que falte en cada show().
function ResultsView:_ensureUiResolved()
	local frame = self._frame
	if not frame then
		return
	end

	for i = 1, SLOT_COUNT do
		if not self._slots[i] then
			local slotFrame = frame:FindFirstChild("Player" .. tostring(i))
			if slotFrame and slotFrame:IsA("GuiObject") then
				self._slots[i] = _resolveUiSlot(slotFrame :: GuiObject)
			end
		end
	end

	local refs = self._rewards
	if not (refs and refs.rewardsFrame and refs.template and refs.valueLabel) then
		refs = _resolveRewardRefs(frame)
		self._rewards = refs
	end

	-- Lo que falte aquí ya no es carrera de replicación: se avisa una vez por sesión.
	if self._uiWarned then
		return
	end
	local missing: { string } = {}
	if next(self._slots) == nil then
		table.insert(missing, `Player1..{SLOT_COUNT}`)
	end
	if not refs.rewardsFrame then
		table.insert(missing, "Rewards")
	elseif not refs.template then
		table.insert(missing, "Rewards.ItemTemplate")
	end
	if not refs.valueLabel then
		table.insert(missing, "Value (header VICTORY/DEFEAT)")
	end
	if #missing > 0 then
		self._uiWarned = true
		warn(`[ResultsView] No se encontró bajo Results: {table.concat(missing, ", ")} — esa parte de la pantalla no se muestra.`)
	end
end

-- Sin UI ni cámara; con la pantalla ya en negro para que :show() no tenga "pop".
function ResultsView:preload(localTeam: string, entries: { ResultEntry })
	self:_buildReplicas(_teamFromEntries(localTeam, entries))
end

-- entries = todos los jugadores de ambos equipos; se filtra a localTeam.
function ResultsView:show(localTeam: string, entries: { ResultEntry }, duration: number, onFinished: (() -> ())?, rewards: MatchResults?)
	self._token += 1
	local token = self._token

	self._showing = true
	self:_ensureUiResolved()
	self:_renderRewards(rewards)

	local team = _teamFromEntries(localTeam, entries)

	-- MVP = más kills del equipo (no el slot 1); sin MVP si nadie mató.
	local mvpIndex = 0
	local maxKills = 0
	for i, entry in team do
		if entry.kills > maxKills then
			maxKills = entry.kills
			mvpIndex = i
		end
	end

	if self._preloadedSize ~= #team then
		self:_buildReplicas(team)
	end

	for i = 1, SLOT_COUNT do
		local slot = self._slots[i]
		if not slot then
			continue
		end
		local entry = team[i]
		if entry then
			slot.frame.Visible = true
			_setText(slot.kills, tostring(entry.kills))
			_setText(slot.assists, tostring(entry.assists))
			_setText(slot.deaths, tostring(entry.deaths))
			_setText(slot.level, tostring(entry.level))
			_setText(slot.name, entry.name)
			if slot.mvp then
				slot.mvp.Visible = i == mvpIndex
			end
		else
			self:_hideSlot(slot)
		end
	end

	if self._frame then
		self._frame.Visible = true
	end

	task.delay(math.max(1, duration), function()
		if self._token ~= token then
			return
		end
		if onFinished then
			onFinished()
		end
	end)
end

function ResultsView:hide()
	self._token += 1
	self._showing = false
	self:_clearReplicas()
	self:_clearRewardClones()
	if self._frame then
		self._frame.Visible = false
	end
	for i = 1, SLOT_COUNT do
		local slot = self._slots[i]
		if slot then
			self:_hideSlot(slot)
		end
	end
end

function ResultsView:Destroy()
	self:hide()
end

return ResultsView
