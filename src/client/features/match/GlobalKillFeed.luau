--!strict
--[[
	GlobalKillFeed.luau
	Manejador del feed de muertes global (jugadores y bots).
	Usa la estructura "Template" pre-creada dentro de "GlobalKillFeedContainer".
	Se alinea y anima desde la izquierda de la pantalla.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig)
local TeamUtils = require(Shared.utils.TeamUtils)

local GlobalKillFeed = {}
local GlobalKillFeed_mt = { __index = GlobalKillFeed }

type GlobalKillFeedItem = {
	wrapper: Frame,
	content: Frame,
	isDestroying: boolean,
}

local MAX_ITEMS = 5
local DISPLAY_TIME = 6

-- Colores del HUD
local TEAM_A_COLOR = Color3.fromRGB(0, 161, 251)
local TEAM_B_COLOR = Color3.fromRGB(246, 82, 71)
local NEUTRAL_COLOR = Color3.fromRGB(220, 220, 220)

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

	-- Buscar la plantilla "Template"
	local template = container:FindFirstChild("Template")
	if not template or not template:IsA("Frame") then
		warn("[GlobalKillFeed] No se encontro la plantilla 'Template' dentro de GlobalKillFeedContainer!")
		return self
	end
	self._template = template
	template.Visible = false

	-- Sincronizar el layout para alinear a la izquierda
	local listLayout = container:FindFirstChildOfClass("UIListLayout")
	if listLayout then
		listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
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
		return "rbxassetid://130437553674754" -- Fallback calavera
	end

	local mainItem = ItemsConfig.Main[weaponId]
	if mainItem and mainItem.Image then
		return mainItem.Image
	end

	local specialItem = ItemsConfig.Special[weaponId]
	if specialItem and specialItem.Image then
		return specialItem.Image
	end

	return "rbxassetid://130437553674754"
end

function GlobalKillFeed:pushKill(killerName: string, victimName: string, weaponId: string)
	if self._destroyed or not self._container or not self._template then
		return
	end

	local killerColor = self:_getParticipantTeamColor(killerName)
	local victimColor = self:_getParticipantTeamColor(victimName)

	-- Clonar la plantilla completa
	local item = self._template:Clone()
	item.Name = "KillItem"
	
	-- Obtener el Content interno (Template.Content)
	local content = item:FindFirstChild("Content")
	if not content or not content:IsA("Frame") then
		content = item -- Fallback si el Content no está separado
	end

	-- Configurar la alineación a la izquierda para el deslizamiento horizontal
	content.AnchorPoint = Vector2.new(0, 0)
	-- Comienza fuera de pantalla a la izquierda
	content.Position = UDim2.new(0, -320, 0, 0)

	-- Guardar el alto objetivo del diseño del usuario
	local targetHeight = self._template.Size.Y.Offset
	if targetHeight <= 0 then
		targetHeight = 28
	end
	
	-- Inicializar el wrapper (item principal) con altura 0 para el despliegue vertical
	item.Size = UDim2.new(self._template.Size.X.Scale, self._template.Size.X.Offset, 0, 0)
	item.ClipsDescendants = true
	item.Visible = true

	-- Referenciar y configurar los elementos del Content
	local killerLabel = content:FindFirstChild("Killer") :: TextLabel?
	local weaponImage = content:FindFirstChild("Weapon") :: ImageLabel?
	local victimLabel = content:FindFirstChild("Victim") :: TextLabel?
	local selfElimLabel = content:FindFirstChild("SelfEliminated") :: TextLabel?
	local skullIcon = content:FindFirstChild("Skull") :: ImageLabel?

	-- Si hay un eliminador
	if killerName and killerName ~= "" then
		if killerLabel then
			killerLabel.Text = killerName
			killerLabel.TextColor3 = killerColor
			killerLabel.Visible = true
		end
		if weaponImage then
			weaponImage.Image = self:_getWeaponImage(weaponId)
			weaponImage.Visible = true
		end
		if selfElimLabel then
			selfElimLabel.Visible = false
		end
		if skullIcon then
			skullIcon.Visible = false
		end
	else
		-- Suicidio / Caída
		if killerLabel then
			killerLabel.Visible = false
		end
		if weaponImage then
			weaponImage.Visible = false
		end
		if selfElimLabel then
			selfElimLabel.Visible = true
		end
		if skullIcon then
			skullIcon.Visible = true
		end
	end

	-- Configurar víctima
	if victimLabel then
		victimLabel.Text = victimName
		victimLabel.TextColor3 = victimColor
		victimLabel.Visible = true
	end

	item.Parent = self._container

	local feedItem: GlobalKillFeedItem = {
		wrapper = item,
		content = content,
		isDestroying = false,
	}

	table.insert(self._activeItems, feedItem)

	-- Animación de entrada: expandir alto vertical + deslizar horizontalmente desde la izquierda
	TweenService:Create(item, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(self._template.Size.X.Scale, self._template.Size.X.Offset, 0, targetHeight),
	}):Play()

	TweenService:Create(content, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.new(0, 0, 0, 0),
	}):Play()

	-- Limitar cantidad
	if #self._activeItems > MAX_ITEMS then
		local oldest = table.remove(self._activeItems, 1)
		if oldest then
			self:_removeItem(oldest)
		end
	end

	-- Tiempo de descarte
	task.delay(DISPLAY_TIME, function()
		if self._destroyed then return end
		local idx = table.find(self._activeItems, feedItem)
		if idx then
			table.remove(self._activeItems, idx)
			self:_removeItem(feedItem)
		end
	end)
end

function GlobalKillFeed:_removeItem(item: GlobalKillFeedItem)
	if item.isDestroying then return end
	item.isDestroying = true

	-- Animación de salida: deslizar hacia la izquierda + desvanecer
	local exitTween = TweenService:Create(item.content, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = UDim2.new(0, -320, 0, 0),
	})

	TweenService:Create(item.content, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		BackgroundTransparency = 1,
	}):Play()

	local stroke = item.content:FindFirstChildOfClass("UIStroke")
	if stroke then
		TweenService:Create(stroke, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Transparency = 1,
		}):Play()
	end
	for _, child in ipairs(item.content:GetChildren()) do
		if child:IsA("TextLabel") then
			TweenService:Create(child, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				TextTransparency = 1,
			}):Play()
		elseif child:IsA("ImageLabel") then
			TweenService:Create(child, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				ImageTransparency = 1,
			}):Play()
		end
	end

	exitTween:Play()

	exitTween.Completed:Once(function()
		-- Colapsar alto vertical del wrapper
		local collapseTween = TweenService:Create(item.wrapper, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Size = UDim2.new(item.wrapper.Size.X.Scale, item.wrapper.Size.X.Offset, 0, 0),
		})
		collapseTween:Play()
		collapseTween.Completed:Once(function()
			item.wrapper:Destroy()
		end)
	end)
end

function GlobalKillFeed:Destroy()
	if self._destroyed then return end
	self._destroyed = true

	if self._connection then
		self._connection.Disconnect()
		self._connection = nil
	end

	for _, item in ipairs(self._activeItems) do
		item.wrapper:Destroy()
	end
	table.clear(self._activeItems)
end

return GlobalKillFeed
