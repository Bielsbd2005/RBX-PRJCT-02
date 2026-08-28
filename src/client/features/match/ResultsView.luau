--!strict
--[[
	ResultsView.luau  (Client)

	Pantalla de Resultados de fin de partida. Sustituye al antiguo EndResultsView.
	  • Cámara → Workspace.Cameras.results (la pone el caller vía MatchCamera).
	  • UI     → UserInterface.Results.Player1..4
	  • 3D     → una réplica por cada miembro de MI equipo (jugadores + bots),
	             colocada en Workspace.Results.Player1..4.

	Las réplicas se generan igual que el preview del locker/lobby: clonan el body
	equipado (`Shared.Bodies[Outfit]`, fallback `Default`) y aplican la cara
	y el hat equipados del loadout local (FaceApplier/HatApplier) + idle. No
	dependen de los Characters vivos ni del teardown del mapa/bots.

	Para evitar el "pop" al cambiar de cámara, el caller llama a :preload() un poco
	antes de que acabe la ronda; :show() reutiliza las réplicas ya creadas.

	Solo se muestra mi equipo, ordenado por kills (desc): Player1 = más kills. El
	MVPRow se muestra en el de más eliminaciones. Auto-cierre tras `duration`s.

	UI por slot (todos opcionales/tolerantes):
	  PlayerN.Container.Kills.Value / Assists.Value / Deaths.Value
	  PlayerN.NameRow.LevelBadge.Value / NameRow.Name
	  PlayerN.MVPRow                    (Visible si es el MVP del equipo)
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
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local AssetIds = require(Shared.constants.AssetIds)

local SLOT_COUNT = 4
-- Mismo idle que el preview del locker.
local IDLE_ANIMATION_ID = AssetIds.Animations.PreviewIdle
local LOCAL_USER_ID = Players.LocalPlayer and Players.LocalPlayer.UserId

-- Gris para los bonus bloqueados (no-VIP): Image/Amount/Title + chip "Locked".
local LOCKED_COLOR = Color3.fromRGB(133, 134, 134)

-- Entrada del header (Results.Value: VICTORY/DEFEAT): "pop" propio, primero.
local HEADER_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Entrada escalonada de las recompensas: cada una aparece a su turno con un
-- "pop" (UIScale 0 → 1, Back Out). REWARD_STAGGER = segundos entre cada una.
-- REWARD_START_DELAY las arranca un poco después del header para que se lea primero.
local REWARD_START_DELAY = 0.3
local REWARD_STAGGER = 0.26
local REWARD_TWEEN = TweenInfo.new(0.7, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Forma de las recompensas que llega del server (packet Match.MatchResults).
-- Lista aplanada (cash + items) renderizada con UN solo template. `amount > 0`
-- → es cash (se muestra Amount); `amount == 0` → es item (se oculta Amount).
export type DisplayReward = {
	title: string, -- texto de Title.Value
	image: string, -- Viewport (ImageLabel).Image
	amount: number, -- monto de cash (0 = item)
	locked: boolean, -- bonus VIP no poseído → gris + Locked
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
	-- Apariencia para la réplica (bots: del roster; jugadores reales: vacía).
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
	mvpRow: GuiObject?,
}

local ResultsView = {}
ResultsView.__index = ResultsView

-- ── Helpers de resolución ────────────────────────────────────

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
	local mvp = frame:FindFirstChild("MVPRow")
	return {
		frame = frame,
		kills = _resolveLabel(frame, { "Container", "Kills", "Value" }),
		assists = _resolveLabel(frame, { "Container", "Assists", "Value" }),
		deaths = _resolveLabel(frame, { "Container", "Deaths", "Value" }),
		level = _resolveLabel(frame, { "NameRow", "LevelBadge", "Value" }),
		name = _resolveLabel(frame, { "NameRow", "Name" }),
		mvpRow = if mvp and mvp:IsA("GuiObject") then mvp :: GuiObject else nil,
	}
end

-- Mi equipo. El jugador local SIEMPRE va primero (Player1); el resto por kills desc.
local function _teamFromEntries(localTeam: string, entries: { ResultEntry }): { ResultEntry }
	local team = {} :: { ResultEntry }
	for _, entry in entries do
		if entry.team == localTeam then
			table.insert(team, entry)
		end
	end
	table.sort(team, function(a, b)
		local aLocal = LOCAL_USER_ID ~= nil and a.userId == LOCAL_USER_ID
		local bLocal = LOCAL_USER_ID ~= nil and b.userId == LOCAL_USER_ID
		if aLocal ~= bLocal then
			return aLocal
		end
		return a.kills > b.kills
	end)
	return team
end

-- ── Resolución de la sección de Recompensas ──────────────────

type RewardRefs = {
	valueLabel: TextLabel?,
	rewardsFrame: GuiObject?,
	template: GuiObject?,
}

-- Resuelve el header (Results.Value), el frame Rewards y el ÚNICO template
-- (ItemTemplate), tolerando que el template viva bajo Rewards o bajo Results.
local function _resolveRewardRefs(resultsFrame: GuiObject): RewardRefs
	local valueNode = resultsFrame:FindFirstChild("Value")
	local rewardsNode = resultsFrame:FindFirstChild("Rewards")
	local rewardsFrame = if rewardsNode and rewardsNode:IsA("GuiObject") then rewardsNode :: GuiObject else nil

	local templateNode = if rewardsFrame then rewardsFrame:FindFirstChild("ItemTemplate") else nil
	if not templateNode then
		templateNode = resultsFrame:FindFirstChild("ItemTemplate")
	end
	local template = if templateNode and templateNode:IsA("GuiObject") then templateNode :: GuiObject else nil
	-- El template es un molde para clonar: no se muestra.
	if template then
		template.Visible = false
	end

	if not rewardsFrame then
		warn("[ResultsView] No se encontró Results.Rewards — no se mostrarán recompensas.")
	elseif not template then
		warn("[ResultsView] No se encontró ItemTemplate (bajo Rewards o Results) — no se pueden clonar recompensas.")
	end

	return {
		valueLabel = if valueNode and valueNode:IsA("TextLabel") then valueNode :: TextLabel else nil,
		rewardsFrame = rewardsFrame,
		template = template,
	}
end

-- Busca una TextLabel descendiente por path (igual patrón que _resolveLabel).
local function _findLabel(root: Instance, path: { string }): TextLabel?
	return _resolveLabel(root, path)
end

-- Primer ImageLabel del clon cuyo nombre sea "Viewport" o "Image" (la imagen del
-- premio). Escanea descendientes para tolerar que esté anidado.
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

-- ── Constructor ──────────────────────────────────────────────

-- Tolera frame/template nulos (GUI en migración): los métodos quedan en no-op.
function ResultsView.new(resultsFrame: GuiObject?): any
	local self = setmetatable({}, ResultsView)
	self._frame = resultsFrame
	self._slots = {} :: { UiSlot }

	if resultsFrame then
		local resolvedSlots = 0
		for i = 1, SLOT_COUNT do
			local slotFrame = resultsFrame:FindFirstChild("Player" .. tostring(i))
			self._slots[i] = if slotFrame and slotFrame:IsA("GuiObject")
				then _resolveUiSlot(slotFrame)
				else nil :: any
			if self._slots[i] then
				resolvedSlots += 1
			end
		end
		if resolvedSlots == 0 then
			warn("[ResultsView] Results existe pero no se encontró ningún Player1.." .. tostring(SLOT_COUNT) .. " — revisa los nombres de los frames de jugador.")
		end
		resultsFrame.Visible = false
		self._rewards = _resolveRewardRefs(resultsFrame)
	end

	self._rewardClones = {} :: { Instance }
	self._replicas = {} :: { Model }
	self._replicaJanitor = Janitor.new()
	self._preloadedSize = -1 -- tamaño de equipo con el que se construyeron las réplicas
	self._token = 0
	return self
end

-- ── Réplicas 3D ──────────────────────────────────────────────

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

-- Crea una réplica con la cara/hat equipados, anclada al ancla y con idle.
function ResultsView:_spawnReplica(template: Model, anchor: Instance, parent: Instance, face: string?, hat: string?)
	local clone = template:Clone()
	clone.Name = "ResultReplica"
	for _, desc in clone:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.CanCollide = false
		end
	end
	clone.Parent = parent
	LockerUtils.placePreviewCharacter(clone, anchor)

	-- Ancla el HRP para que no caiga/derive; el idle anima las extremidades.
	local hrp = clone:FindFirstChild("HumanoidRootPart", true)
	if hrp and hrp:IsA("BasePart") then
		hrp.Anchored = true
	end
	LockerUtils.playPreviewIdleAnimation(clone, self._replicaJanitor, IDLE_ANIMATION_ID)

	-- Cara y hat equipados (mismo patrón que el lobby/locker).
	FaceApplier.new(clone, ItemsConfig):ApplyItemId(face)
	HatApplier.new(clone, ItemsConfig):ApplyItemId(hat)

	table.insert(self._replicas, clone)
end

-- Apariencia (outfit/face/hat) de una entrada: el jugador local usa su loadout;
-- los bots (y cualquier entrada con apariencia) usan la suya del roster; otros
-- jugadores reales no la tenemos → Default sin cosméticos.
local function _appearanceFor(entry: ResultEntry): (string?, string?, string?)
	if LOCAL_USER_ID and entry.userId == LOCAL_USER_ID then
		return _readLoadout()
	end
	return _optString(entry.outfitId), _optString(entry.faceId), _optString(entry.hatId)
end

-- Construye una réplica por miembro del equipo (hasta SLOT_COUNT) en el podio,
-- cada una con su propia apariencia (consistente con la de partida en los bots).
function ResultsView:_buildReplicas(team: { ResultEntry })
	self:_clearReplicas()

	local resultsFolder = workspace:FindFirstChild("Results")
	if not resultsFolder then
		warn("[ResultsView] No se encontró workspace.Results (anclas Player1..N) — no se generan las réplicas 3D de jugadores.")
		return
	end

	for i = 1, math.min(SLOT_COUNT, #team) do
		local entry = team[i]
		local anchor = resultsFolder:FindFirstChild("Player" .. tostring(i))
		if anchor then
			local outfit, face, hat = _appearanceFor(entry)
			local template = self:_resolveBodyTemplate(outfit)
			if template then
				self:_spawnReplica(template, anchor, resultsFolder, face, hat)
			end
		end
	end
	self._preloadedSize = #team
end

function ResultsView:_clearReplicas()
	self._replicaJanitor:Destroy()
	self._replicaJanitor = Janitor.new()
	for _, replica in self._replicas do
		replica:Destroy()
	end
	table.clear(self._replicas)
	self._preloadedSize = -1
end

-- ── Recompensas (cash + items) ───────────────────────────────

function ResultsView:_clearRewardClones()
	for _, clone in self._rewardClones do
		clone:Destroy()
	end
	table.clear(self._rewardClones)
end

-- "Pop" del header VICTORY/DEFEAT (UIScale 0 → 1, Back Out). Arranca de inmediato,
-- antes de la cascada de recompensas. Reusa la UIScale del label si ya tiene una.
function ResultsView:_animateHeader(label: TextLabel, token: number)
	if self._token ~= token then
		return
	end
	local scale = label:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = label
	TweenService:Create(scale, HEADER_TWEEN, { Scale = 1 }):Play()
end

-- Clona el ÚNICO template (ItemTemplate) para UNA recompensa.
--   • amount > 0  → cash: se muestra Amount con el monto.
--   • amount == 0 → item: se oculta Amount (el título dice UNLOCKED/PASS).
--   • locked      → bonus VIP no poseído: gris (Image/Amount/Title) + chip
--                   Amount.Locked visible (upsell — no se concede).
function ResultsView:_renderReward(template: GuiObject, parent: Instance, entry: DisplayReward, order: number, token: number)
	local clone = template:Clone()
	clone.Name = "Reward"
	clone.LayoutOrder = order

	local titleLabel = _findLabel(clone, { "Title", "Value" })
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

	-- Locked vive dentro de Amount; solo aplica a bonus de cash VIP no poseídos.
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

	-- Entrada escalonada: oculta hasta su turno (UIListLayout ignora los
	-- Visible=false, así no deja hueco), luego "pop" con Back Out. Reusa la
	-- UIScale del template si existe; si no, crea una.
	local scale = clone:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = clone

	clone.Visible = false
	clone.Parent = parent
	table.insert(self._rewardClones, clone)

	task.delay(REWARD_START_DELAY + (order - 1) * REWARD_STAGGER, function()
		-- El token invalida pops viejos si la pantalla se cerró/reabrió; el guard
		-- de Parent evita tocar un clon ya destruido por _clearRewardClones.
		if self._token ~= token or not clone.Parent then
			return
		end
		clone.Visible = true
		TweenService:Create(scale, REWARD_TWEEN, { Scale = 1 }):Play()
	end)
end

-- Pinta el header (VICTORY/DEFEAT) y clona cada recompensa (cash + items) con el
-- mismo template. Tolera rewards == nil (jugador sin paquete / carrera de red):
-- solo limpia la sección.
function ResultsView:_renderRewards(rewards: MatchResults?)
	self:_clearRewardClones()
	local refs = self._rewards
	if not refs then
		return
	end

	-- Token actual (show() lo acaba de incrementar): los pops lo chequean para
	-- abortar si la pantalla se cierra antes de terminar.
	local token = self._token

	if refs.valueLabel and rewards then
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
	for order, entry in rewards.rewards do
		self:_renderReward(template, parent, entry, order, token)
	end
end

function ResultsView:_hideSlot(slot: UiSlot)
	slot.frame.Visible = false
	if slot.mvpRow then
		slot.mvpRow.Visible = false
	end
end

-- ── Preload / mostrar / ocultar ──────────────────────────────

-- Crea las réplicas en el podio sin mostrar UI ni tocar la cámara. Se llama un
-- poco antes de que acabe la ronda para que :show() no tenga "pop".
function ResultsView:preload(localTeam: string, entries: { ResultEntry })
	self:_buildReplicas(_teamFromEntries(localTeam, entries))
end

-- entries = TODOS los jugadores (ambos equipos). Filtramos a localTeam.
-- rewards = paquete Match.MatchResults del jugador (header + cash + items); nil
-- si no llegó (no elegible / carrera de red) → la sección de recompensas se vacía.
function ResultsView:show(localTeam: string, entries: { ResultEntry }, duration: number, onFinished: (() -> ())?, rewards: MatchResults?)
	self._token += 1
	local token = self._token

	self:_renderRewards(rewards)

	local team = _teamFromEntries(localTeam, entries)

	-- MVP = el de MÁS kills del equipo (no el slot 1, que ahora es el local).
	-- Primera ocurrencia del máximo; sin MVP si nadie mató.
	local mvpIndex = 0
	local maxKills = 0
	for i, entry in team do
		if entry.kills > maxKills then
			maxKills = entry.kills
			mvpIndex = i
		end
	end

	-- Reutiliza las réplicas precargadas si coinciden en tamaño; si no, reconstruye.
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
			if slot.mvpRow then
				slot.mvpRow.Visible = i == mvpIndex
			end
		else
			self:_hideSlot(slot)
		end
	end

	if self._frame then
		self._frame.Visible = true
	end

	-- Auto-cierre tras `duration`s (no hay botón). El token invalida cierres viejos.
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
