--!strict
-- DirectionalIndicators.luau (Client/Server Library)
-- Enruta las notificaciones de daño recibido para mostrar indicadores de dirección de ataque.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WeaponsSystemFolder = script.Parent.Parent.Parent
local WeaponData = WeaponsSystemFolder:WaitForChild("WeaponData")
local Libraries = WeaponsSystemFolder:WaitForChild("Libraries")
local DirectionalIndicatorGuiManager = require(Libraries:WaitForChild("DirectionalIndicatorGuiManager"))

local DirectionalIndicators = {}
DirectionalIndicators.__index = DirectionalIndicators

function DirectionalIndicators.new(weaponsGui: any)
	local self = setmetatable({}, DirectionalIndicators)
	self.weaponsGui = weaponsGui
	self.manager = nil
	self._conn = nil

	return self
end

function DirectionalIndicators:setup(gui: ScreenGui)
	self.manager = DirectionalIndicatorGuiManager.new(self.weaponsGui)

	-- Conectar evento para recibir daño de otros jugadores
	self._conn = WeaponData.OnClientEvent:Connect(function(cmd, otherPlayerPosition)
		if cmd == "HitByOtherPlayer" and self.manager then
			self.manager:ActivateDirectionalIndicator("DamageIndicator", otherPlayerPosition)
		end
	end)
end

function DirectionalIndicators:activate(otherPlayerPosition: Vector3)
	if self.manager then
		self.manager:ActivateDirectionalIndicator("DamageIndicator", otherPlayerPosition)
	end
end

function DirectionalIndicators:Destroy()
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
	self.manager = nil
end

return DirectionalIndicators
