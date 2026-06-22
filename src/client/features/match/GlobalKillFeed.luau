--!strict
--[[
	GlobalKillFeed.luau
	Manejador del feed de muertes global (jugadores y bots).
	Usa la estructura "Template" pre-creada dentro de "GlobalKillFeedContainer".

	Estructura nueva del Template (hijos directos, ordenados por su propio
	UIListLayout horizontal):
		Template (Frame) [UICorner, UIListLayout, UIPadding, UIStroke]
		├─ Killer  (TextLabel)
		├─ Weapon  (ImageLabel)
		└─ Victim  (TextLabel)

	Como tanto el contenedor como el Template usan UIListLayout, no podemos
	deslizar los items por Position (el layout controla la posición). La entrada
	se anima expandiendo el alto + fade-in; la salida hace fade-out + colapso.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig)
local TeamUtils = require(Shared.utils.TeamUtils)

local GlobalKillFeed = {}
local GlobalKillFeed_mt = { __index = GlobalKillFeed }

type FadeTarget = {
	object: Instance,
	property: string,
	original: number,
}

type GlobalKillFeedItem = {
	frame: GuiObject,
	fadeTargets: { FadeTarget },
	targetHeight: number,
	animateHeight: boolean,
	isDestroying: boolean,
}

local MAX_ITEMS = 5
local DISPLAY_TIME = 6
local SKULL_ICON = "rbxassetid://130437553674754"

-- Colores del HUD
local TEAM_A_COLOR = Color3.fromRGB(0, 161, 251)
local TEAM_B_COLOR = Color3.fromRGB(246, 82, 71)
local NEUTRAL_COLOR = Color3.fromRGB(220, 220, 220)

local ENTER_TWEEN = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local EXIT_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

function GlobalKillFeed.new(matchHudGui: ScreenGui, matchHudInstance: any): any
	local self = setmetatable({}, GlobalKillFeed_mt)
	self._matchHudInstance = matchHudInstance
	self._activeItems = {} :: { GlobalKillFeedItem }
	self._destroyed = false

	-- Buscar el contenedor pre-creado en la interfaz
	local container = matchHudGui:FindFirstChild("GlobalKillFeedContainer", true)
	if not container then
		warn("[GlobalKillFeed] No se encontro GlobalKillFeedContainer en la GUI!")
		return self
	end
	self._container = container

	-- Buscar la plantilla "Template". Aceptamos cualquier GuiObject porque el
	-- diseño usa un CanvasGroup (para poder hacer fade del grupo completo via
	-- GroupTransparency), no necesariamente un Frame.
	local template = container:FindFirstChild("Template")
	if not template or not template:IsA("GuiObject") then
		warn("[GlobalKillFeed] No se encontro la plantilla 'Template' dentro de GlobalKillFeedContainer!")
		return self
	end
	self._template = template
	template.Visible = false

	-- Alinear el feed a la derecha de la pantalla (los items salen por la derecha,
	-- creciendo de derecha a izquierda).
	local listLayout = container:FindFirstChildOfClass("UIListLayout")
	if listLayout then
		listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	end

	-- Escuchar el evento de KillFeed
	local Network = require(Shared.networking.Network)
	self._connection = Network.Combat.KillFeed.Listen(function(data)
		self:pushKill(data.killerName, data.victimName, data.weaponId)
	end)

	return self
end

function GlobalKillFeed:_getParticipantTeamColor(name: string): Color3
	if not name or name == "" then
		return NEUTRAL_COLOR
	end

	-- 1. Buscar en jugadores reales conectados
	local player = Players:FindFirstChild(name)
	if player then
		local side = if player.Character then TeamUtils.getSide(player.Character) else nil
		if not side then
			local attr = player:GetAttribute("TeamName")
			side = if typeof(attr) == "string" then TeamUtils.normalize(attr) else nil
		end
		if side == "A" then
			return TEAM_A_COLOR
		elseif side == "B" then
			return TEAM_B_COLOR
		end
	end

	-- 2. Buscar en el roster de bots activo
	if self._matchHudInstance and self._matchHudInstance._botRoster then
		for _, bot in pairs(self._matchHudInstance._botRoster) do
			if bot.displayName == name then
				if bot.team == "A" then
					return TEAM_A_COLOR
				elseif bot.team == "B" then
					return TEAM_B_COLOR
				end
			end
		end
	end

	return NEUTRAL_COLOR
end

function GlobalKillFeed:_getWeaponImage(weaponId: string): string
	if not weaponId or weaponId == "" then
		return SKULL_ICON -- Fallback calavera
	end

	local mainItem = ItemsConfig.Main[weaponId]
	if mainItem and mainItem.Image then
		return mainItem.Image
	end

	local specialItem = ItemsConfig.Special[weaponId]
	if specialItem and specialItem.Image then
		return specialItem.Image
	end

	return SKULL_ICON
end

-- Recolecta las propiedades de transparencia (con su valor autorizado) de todos
-- los elementos visibles del item para animar fade-in/out sin asumir que el
-- diseñador dejó todo en 0.
function GlobalKillFeed:_collectFadeTargets(item: GuiObject): { FadeTarget }
	local targets = {} :: { FadeTarget }

	local function add(object: Instance, property: string)
		targets[#targets + 1] = {
			object = object,
			property = property,
			original = (object :: any)[property],
		}
	end

	-- CanvasGroup: fade del grupo completo con una sola propiedad (más barato y
	-- es justo para lo que el diseñador puso el CanvasGroup).
	if item:IsA("CanvasGroup") then
		add(item, "GroupTransparency")
		return targets
	end

	add(item, "BackgroundTransparency")
	for _, child in ipairs(item:GetDescendants()) do
		if child:IsA("TextLabel") or child:IsA("TextButton") then
			add(child, "TextTransparency")
			add(child, "BackgroundTransparency")
		elseif child:IsA("ImageLabel") or child:IsA("ImageButton") then
			add(child, "ImageTransparency")
			add(child, "BackgroundTransparency")
		elseif child:IsA("UIStroke") then
			add(child, "Transparency")
		end
	end

	return targets
end

function GlobalKillFeed:pushKill(killerName: string, victimName: string, weaponId: string)
	if self._destroyed or not self._container or not self._template then
		return
	end

	local killerColor = self:_getParticipantTeamColor(killerName)
	local victimColor = self:_getParticipantTeamColor(victimName)

	-- Clonar la plantilla completa (Killer / Weapon / Victim son hijos directos)
	local item = self._template:Clone()
	item.Name = "KillItem"

	local killerLabel = item:FindFirstChild("Killer") :: TextLabel?
	local weaponImage = item:FindFirstChild("Weapon") :: ImageLabel?
	local victimLabel = item:FindFirstChild("Victim") :: TextLabel?

	local hasKiller = killerName ~= nil and killerName ~= ""

	-- Eliminador (oculto en suicidios/caídas; el arma muestra la calavera)
	if killerLabel then
		killerLabel.Text = hasKiller and killerName or ""
		killerLabel.TextColor3 = killerColor
		killerLabel.Visible = hasKiller
	end

	-- Arma: icono del arma usada, o calavera en autoeliminación
	if weaponImage then
		weaponImage.Image = if hasKiller then self:_getWeaponImage(weaponId) else SKULL_ICON
		weaponImage.Visible = true
	end

	-- Víctima
	if victimLabel then
		victimLabel.Text = victimName
		victimLabel.TextColor3 = victimColor
		victimLabel.Visible = true
	end

	-- Capturar las transparencias autorizadas antes de iniciarlas en 1 (oculto)
	local fadeTargets = self:_collectFadeTargets(item)
	for _, target in ipairs(fadeTargets) do
		(target.object :: any)[target.property] = 1
	end

	-- Si el Template se auto-dimensiona en alto no podemos animar Size.Y
	-- manualmente (el AutomaticSize lo sobreescribe): caemos a fade puro.
	local animateHeight = item.AutomaticSize == Enum.AutomaticSize.None
		or item.AutomaticSize == Enum.AutomaticSize.X
	local targetHeight = item.Size.Y.Offset
	if targetHeight <= 0 then
		targetHeight = 28
		animateHeight = false
	end

	if animateHeight then
		item.ClipsDescendants = true
		item.Size = UDim2.new(item.Size.X.Scale, item.Size.X.Offset, item.Size.Y.Scale, 0)
	end

	item.Visible = true
	item.Parent = self._container

	local feedItem: GlobalKillFeedItem = {
		frame = item,
		fadeTargets = fadeTargets,
		targetHeight = targetHeight,
		animateHeight = animateHeight,
		isDestroying = false,
	}

	table.insert(self._activeItems, feedItem)

	-- Animación de entrada: expandir alto (si aplica) + fade-in
	if animateHeight then
		TweenService:Create(item, ENTER_TWEEN, {
			Size = UDim2.new(item.Size.X.Scale, item.Size.X.Offset, item.Size.Y.Scale, targetHeight),
		}):Play()
	end
	for _, target in ipairs(fadeTargets) do
		TweenService:Create(target.object, ENTER_TWEEN, { [target.property] = target.original }):Play()
	end

	-- Limitar cantidad
	if #self._activeItems > MAX_ITEMS then
		local oldest = table.remove(self._activeItems, 1)
		if oldest then
			self:_removeItem(oldest)
		end
	end

	-- Tiempo de descarte
	task.delay(DISPLAY_TIME, function()
		if self._destroyed then
			return
		end
		local idx = table.find(self._activeItems, feedItem)
		if idx then
			table.remove(self._activeItems, idx)
			self:_removeItem(feedItem)
		end
	end)
end

function GlobalKillFeed:_removeItem(item: GlobalKillFeedItem)
	if item.isDestroying then
		return
	end
	item.isDestroying = true

	-- Animación de salida: fade-out de todos los elementos
	local lastTween: Tween? = nil
	for _, target in ipairs(item.fadeTargets) do
		local tween = TweenService:Create(target.object, EXIT_TWEEN, { [target.property] = 1 })
		tween:Play()
		lastTween = tween
	end

	local function collapseAndDestroy()
		if item.animateHeight and item.frame.Parent then
			local collapse = TweenService:Create(item.frame, EXIT_TWEEN, {
				Size = UDim2.new(item.frame.Size.X.Scale, item.frame.Size.X.Offset, item.frame.Size.Y.Scale, 0),
			})
			collapse:Play()
			collapse.Completed:Once(function()
				item.frame:Destroy()
			end)
		else
			item.frame:Destroy()
		end
	end

	if lastTween then
		lastTween.Completed:Once(collapseAndDestroy)
	else
		collapseAndDestroy()
	end
end

function GlobalKillFeed:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	if self._connection then
		self._connection() -- ByteNet Listen returns a disconnect function
		self._connection = nil
	end

	for _, item in ipairs(self._activeItems) do
		item.frame:Destroy()
	end
	table.clear(self._activeItems)
end

return GlobalKillFeed
