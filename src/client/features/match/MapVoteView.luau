--!strict
--[[
	MapVoteView.luau  (Client)

	Pantalla de votación de mapas, ahora independiente en `UserInterface.Voting`
	(ya no vive dentro del Menu). La visibilidad la gobierna un PanelController
	externo; esta vista solo puebla y anima su contenido.

	Estructura GUI esperada (todos los hijos son opcionales/tolerantes):
	  Voting.Timer                         -- TextLabel (cuenta atrás, opcional)
	  Voting.Random.Percentage / .Votes    -- opción Random: SIN MapName
	  Voting.Option1.MapName/.Percentage/.Votes
	  Voting.Option2.MapName/.Percentage/.Votes
	  Voting.Option3.MapName/.Percentage/.Votes
	  <Option>.Votes.Template              -- icono clonado por cada votante (avatar)

	Cada slot (Random/Option1/2/3) es votable: se clickea el propio contenedor si
	es GuiButton, o un GuiButton hijo. El voto enviado es la `voteKey`: el nombre
	del mapa para Option1/2/3, o RANDOM_VOTE_KEY para Random.
]]

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local Janitor = require(Packages.janitor) :: any
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)

local RANDOM_VOTE_KEY = GameConfig.RandomVoteKey

local MapVoteView = {}
MapVoteView.__index = MapVoteView

export type OptionModel = {
	mapName: string,
	mapImage: string,
}

-- CSV de userIds por slot, tal cual llega del snapshot replicado (Votes1/2/3/Random).
export type VoterData = {
	random: string,
	option1: string,
	option2: string,
	option3: string,
}

type SlotRefs = {
	dataKey: string,            -- "random" | "option1" | "option2" | "option3"
	isRandom: boolean,
	container: GuiObject,
	clickable: GuiButton?,
	mapNameLabel: TextLabel?,
	mapNameDefaultColor: Color3?,
	percentageLabel: TextLabel?,
	imageNode: (ImageLabel | ImageButton)?,
	stroke: UIStroke?,
	shadow: GuiObject?,
	shadowDefaultTransparency: number?,
	votesRoot: Instance?,
	template: GuiObject?,
	spawnedVotes: { GuiObject },
	voteKey: string,            -- qué se envía al votar este slot
}

local DEFAULT_MAP_IMAGE = "rbxasset://textures/ui/GuiImagePlaceholder.png"

-- Estilo de selección del voto propio. El stroke del contenedor y el texto del
-- MapName se resaltan en el slot votado; el resto vuelve a su estado por defecto.
local SELECTED_HIGHLIGHT = Color3.fromRGB(252, 254, 183)
local SELECTED_STROKE_TRANSPARENCY = 0
local UNSELECTED_STROKE_COLOR = Color3.fromRGB(0, 0, 0)
local UNSELECTED_STROKE_TRANSPARENCY = 0.6

-- Animación del ganador. El tamaño se anima con UIScale (no con Visible/Position):
-- UIGridLayout sobrescribe Position y hace reflow al cambiar Visible, lo que hacía
-- "saltar" al ganador. UIScale es invisible al layout → animación estable en grid.
-- Los perdedores NO desaparecen: se encogen un poco y muestran su frame "Shadow".
-- Tweens sutiles y limpios: easing Sine (sin rebote) y magnitudes pequeñas.
local LOSER_RECEDE_SCALE = 0.96       -- los perdedores se encogen a esto (no a 0)
local LOSER_RECEDE_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local LOSER_STAGGER = 0.04            -- escalonado entre perdedores
local WINNER_POP_DELAY = 0.1          -- deja recogerse a los perdedores antes del pop
local WINNER_POP_SCALE = 1.05
local WINNER_POP_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local WINNER_SETTLE_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local WINNER_HOLD_SECONDS = 2.2

-- Orden fijo de slots. Random primero; Option1/2/3 mapean a los datos del packet.
local SLOT_SPECS: { { name: string, dataKey: string, isRandom: boolean } } = {
	{ name = "Random", dataKey = "random", isRandom = true },
	{ name = "Option1", dataKey = "option1", isRandom = false },
	{ name = "Option2", dataKey = "option2", isRandom = false },
	{ name = "Option3", dataKey = "option3", isRandom = false },
}

-- ── Helpers ──────────────────────────────────────────────────

local function _getHeadshotUrl(userId: number): string
	return "rbxthumb://type=AvatarHeadShot&id=" .. tostring(userId) .. "&w=48&h=48"
end

local function _parseVoterIds(raw: string): { number }
	if raw == "" then return {} end
	local ids = {}
	for idStr in string.gmatch(raw, "[^,]+") do
		local id = tonumber(idStr)
		if id then
			table.insert(ids, id)
		end
	end
	return ids
end

local function _ensureAvatarImage(icon: GuiObject): ImageLabel
	if icon:IsA("ImageLabel") then
		return icon :: ImageLabel
	end
	local existing = icon:FindFirstChildWhichIsA("ImageLabel")
	if existing then
		return existing :: ImageLabel
	end
	local img = Instance.new("ImageLabel")
	img.Name = "Avatar"
	img.Size = UDim2.fromScale(1, 1)
	img.BackgroundTransparency = 1
	img.ScaleType = Enum.ScaleType.Crop
	img.Parent = icon
	local corner = icon:FindFirstChildWhichIsA("UICorner")
	if corner then
		corner:Clone().Parent = img
	end
	return img
end

-- Elemento clickeable del slot: el propio contenedor si es botón, o un GuiButton
-- hijo ("Button" preferente). Sin botón → el slot no es votable (no-op tolerante).
local function _resolveClickable(container: GuiObject): GuiButton?
	if container:IsA("GuiButton") then
		return container
	end
	local named = container:FindFirstChild("Button")
	if named and named:IsA("GuiButton") then
		return named
	end
	return container:FindFirstChildWhichIsA("GuiButton")
end

-- Nodo de imagen opcional para la miniatura del mapa. Solo lo usamos si existe
-- un hijo dedicado — no pintamos el fondo del botón por accidente.
local function _resolveImageNode(container: GuiObject): (ImageLabel | ImageButton)?
	for _, name in { "Image", "Thumbnail", "Map" } do
		local node = container:FindFirstChild(name)
		if node and (node:IsA("ImageLabel") or node:IsA("ImageButton")) then
			return node :: any
		end
	end
	return nil
end

-- Reutiliza el mismo nodo "InteractiveScale" que InteractiveScaleTween: así el
-- hover/click y el pop del ganador comparten un único UIScale (dos UIScale en el
-- mismo objeto se pisarían, solo uno se aplica).
local function _ensureScale(container: GuiObject): UIScale
	local existing = container:FindFirstChild("InteractiveScale")
	if existing and existing:IsA("UIScale") then
		return existing
	end
	local scale = Instance.new("UIScale")
	scale.Name = "InteractiveScale"
	scale.Parent = container
	return scale
end

-- UIStroke a resaltar: el del contenedor preferente, o el del clickeable.
local function _resolveStroke(container: GuiObject, clickable: GuiButton?): UIStroke?
	local direct = container:FindFirstChildWhichIsA("UIStroke")
	if direct then
		return direct
	end
	if clickable then
		return clickable:FindFirstChildWhichIsA("UIStroke")
	end
	return nil
end

local function _resolveSlots(frame: GuiObject): { SlotRefs }
	local slots = {} :: { SlotRefs }
	for _, spec in SLOT_SPECS do
		local container = frame:FindFirstChild(spec.name)
		if not (container and container:IsA("GuiObject")) then
			continue
		end

		local votesRoot = container:FindFirstChild("Votes")
		local template = if votesRoot then votesRoot:FindFirstChild("Template") :: GuiObject? else nil
		if template then
			template.Visible = false
		end

		local clickable = _resolveClickable(container)
		-- "Shadow": overlay negro semitransparente que se muestra al perder.
		local shadowNode = container:FindFirstChild("Shadow")
		local shadow = if shadowNode and shadowNode:IsA("GuiObject") then shadowNode else nil
		-- MapName se resuelve para todos los slots (incluido Random, si lo tiene)
		-- porque su color también cambia al estar seleccionado.
		local mapNameNode = container:FindFirstChild("MapName")
		local mapNameLabel = if mapNameNode and mapNameNode:IsA("TextLabel") then mapNameNode else nil

		table.insert(slots, {
			dataKey = spec.dataKey,
			isRandom = spec.isRandom,
			container = container,
			clickable = clickable,
			mapNameLabel = mapNameLabel,
			mapNameDefaultColor = if mapNameLabel then mapNameLabel.TextColor3 else nil,
			percentageLabel = container:FindFirstChild("Percentage") :: TextLabel?,
			imageNode = _resolveImageNode(container),
			stroke = _resolveStroke(container, clickable),
			shadow = shadow,
			shadowDefaultTransparency = if shadow then shadow.BackgroundTransparency else nil,
			votesRoot = votesRoot,
			template = template,
			spawnedVotes = {},
			-- Random tiene voteKey fija; los Option se asignan en :show().
			voteKey = if spec.isRandom then RANDOM_VOTE_KEY else "",
		})
	end
	return slots
end

local function _hideVoteIcons(slot: SlotRefs)
	for _, icon in slot.spawnedVotes do
		icon.Visible = false
	end
end

-- Estilo de selección de un slot. Seleccionado: stroke + MapName en el color de
-- resalte (252,254,183), stroke opaco. No seleccionado: stroke negro a 0.6 y el
-- MapName de vuelta a su color original.
local function _applySlotSelection(slot: SlotRefs, selected: boolean)
	if slot.stroke then
		slot.stroke.Color = if selected then SELECTED_HIGHLIGHT else UNSELECTED_STROKE_COLOR
		slot.stroke.Transparency = if selected then SELECTED_STROKE_TRANSPARENCY else UNSELECTED_STROKE_TRANSPARENCY
	end
	if slot.mapNameLabel then
		slot.mapNameLabel.TextColor3 = if selected
			then SELECTED_HIGHLIGHT
			else (slot.mapNameDefaultColor or slot.mapNameLabel.TextColor3)
	end
end

-- Muestra/oculta el overlay "Shadow" del slot. Un perdedor lo muestra (fade suave
-- desde transparente hasta su transparencia autorada) para marcar que ha perdido.
local function _setShadow(slot: SlotRefs, shown: boolean)
	local shadow = slot.shadow
	if not shadow then
		return
	end
	if shown then
		local target = slot.shadowDefaultTransparency or 0.5
		shadow.BackgroundTransparency = 1
		shadow.Visible = true
		TweenService:Create(shadow, LOSER_RECEDE_INFO, { BackgroundTransparency = target }):Play()
	else
		shadow.Visible = false
		if slot.shadowDefaultTransparency ~= nil then
			shadow.BackgroundTransparency = slot.shadowDefaultTransparency
		end
	end
end

-- ── Constructor ──────────────────────────────────────────────

-- Tolera frame nulo (GUI en migración): sin frame, todos los métodos son no-op.
-- Estructura: Voting.Timer (cuenta atrás) + Voting.OptionsFrame.{Random,Option1/2/3}.
-- Los slots se resuelven bajo OptionsFrame (donde vive el UIGridLayout).
function MapVoteView.new(votingFrame: GuiObject?): any
	local self = setmetatable({}, MapVoteView)
	self._frame = votingFrame
	self._timerLabel = if votingFrame then votingFrame:FindFirstChild("Timer") :: TextLabel? else nil

	local optionsRoot = if votingFrame then votingFrame:FindFirstChild("OptionsFrame") else nil
	self._slots = if optionsRoot and optionsRoot:IsA("GuiObject") then _resolveSlots(optionsRoot) else {}

	self._selectedKey = ""
	self._duration = 1
	self._onVote = nil :: ((string) -> ())?
	-- Token de generación: un show()/hide()/showWinner() nuevo lo bumpea para que
	-- un task.delay tardío de un showWinner viejo no oculte una votación fresca.
	self._voteToken = 0
	self._connections = {} :: { RBXScriptConnection }
	self._janitor = Janitor.new()

	-- Hover/click en cada slot (escala el contenedor vía el nodo "InteractiveScale",
	-- el mismo que usa el pop del ganador → un único UIScale por slot).
	-- Hover/click sutiles (escalas pequeñas, más limpias que los valores por
	-- defecto de UITheme que se usan en botones más grandes).
	local canHover = UserInputService.MouseEnabled and not UserInputService.TouchEnabled
	for _, slot in self._slots do
		if slot.clickable then
			InteractiveScaleTween.bindButton(slot.clickable, self._janitor, {
				scaleTarget = slot.container,
				enableHover = canHover,
				hoverScale = 1.02,
				clickScale = 0.98,
			})
		end
	end

	return self
end

function MapVoteView:bindVoteHandler(onVote: (string) -> ())
	self._onVote = onVote
	for _, slot in self._slots do
		local clickable = slot.clickable
		if not clickable then continue end
		local conn = clickable.Activated:Connect(function()
			if slot.voteKey ~= "" and self._onVote then
				self._onVote(slot.voteKey)
			end
		end)
		table.insert(self._connections, conn)
	end
end

-- ── Poblar / reset ───────────────────────────────────────────

function MapVoteView:show(options: { option1: OptionModel, option2: OptionModel, option3: OptionModel }, duration: number)
	self._voteToken += 1
	self._duration = math.max(1, duration)
	self._selectedKey = ""

	for _, slot in self._slots do
		slot.container.Visible = true
		_ensureScale(slot.container).Scale = 1
		_applySlotSelection(slot, false)
		_setShadow(slot, false)
		_hideVoteIcons(slot)
		if slot.percentageLabel then slot.percentageLabel.Text = "0%" end

		if not slot.isRandom then
			local model = options[slot.dataKey :: any] :: OptionModel?
			if model then
				slot.voteKey = model.mapName
				if slot.mapNameLabel then slot.mapNameLabel.Text = model.mapName end
				if slot.imageNode then
					slot.imageNode.Image = if model.mapImage ~= "" then model.mapImage else DEFAULT_MAP_IMAGE
				end
			else
				-- Sin modelo para este slot (no debería pasar con 3 opciones fijas).
				slot.voteKey = ""
				slot.container.Visible = false
			end
		end
	end

	self:updateTimer(duration)
	self:updateVotes({ random = "", option1 = "", option2 = "", option3 = "" })
end

function MapVoteView:hide()
	self._voteToken += 1
	self._selectedKey = ""
	if self._timerLabel then self._timerLabel.Visible = true end
	for _, slot in self._slots do
		slot.container.Visible = true
		_ensureScale(slot.container).Scale = 1
		_applySlotSelection(slot, false)
		_setShadow(slot, false)
		if slot.percentageLabel then slot.percentageLabel.Text = "0%" end
		_hideVoteIcons(slot)
	end
end

-- ── Selección local (feedback inmediato del voto propio) ─────

function MapVoteView:setSelectedMap(voteKey: string)
	self._selectedKey = voteKey
	for _, slot in self._slots do
		_applySlotSelection(slot, voteKey ~= "" and slot.voteKey == voteKey)
	end
end

-- ── Votos + porcentajes ──────────────────────────────────────

function MapVoteView:updateVotes(voterData: VoterData)
	-- Conteos por slot y total, para los porcentajes.
	local countsByKey: { [string]: number } = {}
	local total = 0
	for _, slot in self._slots do
		local n = #_parseVoterIds(voterData[slot.dataKey :: any] or "")
		countsByKey[slot.dataKey] = n
		total += n
	end

	for _, slot in self._slots do
		-- Porcentaje.
		if slot.percentageLabel then
			local count = countsByKey[slot.dataKey] or 0
			local pct = if total > 0 then math.floor((count / total) * 100 + 0.5) else 0
			slot.percentageLabel.Text = tostring(pct) .. "%"
		end

		-- Avatares de los votantes.
		_hideVoteIcons(slot)
		if not slot.votesRoot or not slot.template then continue end

		local voterIds = _parseVoterIds(voterData[slot.dataKey :: any] or "")
		local pool = slot.spawnedVotes
		for i, userId in voterIds do
			local icon = pool[i]
			if not icon then
				icon = (slot.template :: GuiObject):Clone()
				icon.Name = "Voter_" .. tostring(i)
				icon.Parent = slot.votesRoot
				pool[i] = icon
			end
			icon.Visible = true
			_ensureAvatarImage(icon).Image = _getHeadshotUrl(userId)
		end
	end
end

-- ── Ganador ──────────────────────────────────────────────────

-- winnerMapName es siempre un mapa concreto (el servidor ya resolvió Random).
-- Animación 100% UIScale para no pelear con el UIGridLayout (ver constantes):
-- los perdedores se encogen escalonados en su celda (sin reflow) y el ganador
-- se resalta y hace un pop con rebote.
function MapVoteView:showWinner(winnerMapName: string, onDone: (() -> ())?)
	self._voteToken += 1
	local token = self._voteToken
	if self._timerLabel then self._timerLabel.Visible = false end

	local winnerSlot: SlotRefs? = nil
	for _, slot in self._slots do
		if not slot.isRandom and slot.voteKey == winnerMapName then
			winnerSlot = slot
		end
	end

	-- Perdedores (y Random): NO desaparecen. Se encogen un poco (UIScale, sin tocar
	-- Visible → la grid no hace reflow) y muestran su overlay "Shadow" para marcar
	-- la derrota. Escalonado para un cierre más vivo.
	local loserIndex = 0
	for _, slot in self._slots do
		if slot == winnerSlot then
			continue
		end
		_applySlotSelection(slot, false)
		local scale = _ensureScale(slot.container)
		scale.Scale = 1
		local delaySec = loserIndex * LOSER_STAGGER
		loserIndex += 1
		task.delay(delaySec, function()
			if scale.Parent == nil then return end
			_setShadow(slot, true)
			TweenService:Create(scale, LOSER_RECEDE_INFO, { Scale = LOSER_RECEDE_SCALE }):Play()
		end)
	end

	-- Ganador: sin sombra, resalte (stroke + MapName) y pop con rebote.
	if winnerSlot then
		local w = winnerSlot :: SlotRefs
		_setShadow(w, false)
		_applySlotSelection(w, true)
		local scale = _ensureScale(w.container)
		scale.Scale = 1
		task.delay(WINNER_POP_DELAY, function()
			if scale.Parent == nil then return end
			local pop = TweenService:Create(scale, WINNER_POP_INFO, { Scale = WINNER_POP_SCALE })
			pop:Play()
			pop.Completed:Connect(function()
				if scale.Parent ~= nil then
					TweenService:Create(scale, WINNER_SETTLE_INFO, { Scale = 1 }):Play()
				end
			end)
		end)
	end

	local total = WINNER_POP_DELAY + WINNER_POP_INFO.Time + WINNER_SETTLE_INFO.Time + WINNER_HOLD_SECONDS
	task.delay(total, function()
		-- Si entró una votación nueva (show/hide/otro showWinner) durante el hold,
		-- el token cambió y este callback obsoleto no debe disparar onDone.
		if self._voteToken ~= token then return end
		if onDone then onDone() end
	end)
end

-- ── Timer ────────────────────────────────────────────────────

function MapVoteView:updateTimer(timeLeft: number)
	if self._timerLabel then
		self._timerLabel.Text = tostring(math.max(0, timeLeft))
	end
end

function MapVoteView:Destroy()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
	if self._janitor then
		self._janitor:Destroy()
	end
	self:hide()
end

return MapVoteView
