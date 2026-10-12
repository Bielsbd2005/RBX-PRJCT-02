--!strict
-- Marcadores que orbitan el centro de la pantalla: DamageIndicator apunta a quien te
-- ha dado y CombatIndicator al tiroteo más cercano. Requiere en Studio las plantillas
-- ScalingElements.DirectionalIndicators.DamageIndicator y .CombatIndicator (Frame con
-- un ImageLabel): ver docs/DIRECTIONAL-INDICATORS.md.

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)

local WeaponsSystemFolder = script.Parent.Parent.Parent
local WeaponData = WeaponsSystemFolder:WaitForChild("WeaponData")

local MAX_DAMAGE_MARKERS = 6
-- Un golpe cuyo origen cae a menos de estos grados de un marcador vivo lo refresca
-- en vez de apilar otro encima (ráfagas del mismo atacante).
local MERGE_ANGLE = 20
local HOLD_TIME = 1
local FADE_TIME = 1
local POP_SCALE = 1.35
local POP_TIME = 0.15

type Marker = {
	frame: Frame,
	image: ImageLabel,
	popScale: UIScale,
	origin: Vector3,
	shownAt: number,
	active: boolean,
	-- Solo CombatIndicator: el arma cuyo disparo señala.
	source: Instance?,
}

type Indicator = {
	template: Frame,
	markers: { Marker },
	-- Escala de la plantilla para WeaponsGui.originalScaleAmounts; nil si mide en offset.
	scaleAmount: Vector2?,
}

local DirectionalIndicators = {}
DirectionalIndicators.__index = DirectionalIndicators

local function loadIndicator(folder: Instance?, name: string): Indicator?
	local template = folder and folder:FindFirstChild(name)
	if not template or not template:IsA("Frame") or not template:FindFirstChildWhichIsA("ImageLabel", true) then
		warn(`[DirectionalIndicators] falta ScalingElements.DirectionalIndicators.{name} (Frame con un ImageLabel): ese marcador no se mostrará`)
		return nil
	end
	template.Visible = false

	local size = template.Size
	return {
		template = template,
		markers = {},
		scaleAmount = if size.X.Scale ~= 0 or size.Y.Scale ~= 0 then Vector2.new(size.X.Scale, size.Y.Scale) else nil,
	}
end

local function angleBetween(a: number, b: number): number
	return math.abs((a - b + 180) % 360 - 180)
end

local function listenerPosition(): Vector3
	local camera = workspace.CurrentCamera
	return if camera then camera.Focus.Position else Vector3.zero
end

-- Convención de los marcadores: dibujados apuntando hacia arriba, Rotation = 0 es
-- un origen de frente.
local function rotationTo(origin: Vector3): number
	local camera = workspace.CurrentCamera
	if not camera then
		return 0
	end

	local look = camera.CFrame.LookVector
	local forward = Vector3.new(look.X, 0, look.Z)
	local focus = camera.Focus.Position
	local toOrigin = Vector3.new(origin.X - focus.X, 0, origin.Z - focus.Z)
	-- Mirando en vertical o con el origen encima no hay dirección en planta.
	if forward.Magnitude < 1e-3 or toOrigin.Magnitude < 1e-3 then
		return 0
	end

	local right = Vector3.new(-forward.Z, 0, forward.X)
	return math.deg(math.atan2(right:Dot(toOrigin), forward:Dot(toOrigin))) % 360
end

local function render(marker: Marker, now: number)
	local age = now - marker.shownAt
	local fade = math.clamp((age - HOLD_TIME) / FADE_TIME, 0, 1)
	local pop = 1 - math.min(age / POP_TIME, 1)

	marker.frame.Rotation = rotationTo(marker.origin)
	marker.image.ImageTransparency = fade
	marker.popScale.Scale = 1 + (POP_SCALE - 1) * pop
end

local function isShowing(indicator: Indicator?): boolean
	if indicator then
		for _, marker in indicator.markers do
			if marker.active then
				return true
			end
		end
	end
	return false
end

local function hide(indicator: Indicator?)
	if indicator then
		for _, marker in indicator.markers do
			marker.active = false
			marker.frame.Visible = false
		end
	end
end

function DirectionalIndicators.new(weaponsGui: any)
	local self = setmetatable({}, DirectionalIndicators)
	self.weaponsGui = weaponsGui
	self._damage = nil :: Indicator?
	self._combat = nil :: Indicator?
	self._hitConn = nil :: RBXScriptConnection?
	self._stepConn = nil :: RBXScriptConnection?

	return self
end

function DirectionalIndicators:setup(gui: ScreenGui)
	local folder = self.weaponsGui.scalingElementsFolder:FindFirstChild("DirectionalIndicators")
	self._damage = loadIndicator(folder, "DamageIndicator")
	self._combat = loadIndicator(folder, "CombatIndicator")

	if folder then
		task.spawn(function()
			ContentProvider:PreloadAsync({ folder })
		end)
	end

	self._hitConn = WeaponData.OnClientEvent:Connect(function(cmd, origin)
		if cmd == "HitByOtherPlayer" and typeof(origin) == "Vector3" then
			self:showDamage(origin)
		end
	end)

	gui.Destroying:Once(function()
		self:Destroy()
	end)
end

function DirectionalIndicators:_newMarker(indicator: Indicator): Marker
	local frame = indicator.template:Clone()
	local image = frame:FindFirstChildWhichIsA("ImageLabel", true) :: ImageLabel
	local popScale = image:FindFirstChildOfClass("UIScale")
	if not popScale then
		popScale = Instance.new("UIScale")
		popScale.Parent = image
	end

	-- Con la escala de la plantilla, no la del clon: la plantilla ya puede venir
	-- reescalada por WeaponsGui, que tomaría ese Size como original y lo escalaría
	-- dos veces.
	if indicator.scaleAmount then
		self.weaponsGui.originalScaleAmounts[frame] = indicator.scaleAmount
		local camera = workspace.CurrentCamera
		if camera then
			self.weaponsGui:updateScale(frame, camera.ViewportSize)
		end
	end
	frame.Parent = indicator.template.Parent

	local marker: Marker = {
		frame = frame,
		image = image,
		popScale = popScale :: UIScale,
		origin = Vector3.zero,
		shownAt = 0,
		active = false,
	}
	table.insert(indicator.markers, marker)
	return marker
end

function DirectionalIndicators:_show(marker: Marker, origin: Vector3)
	local now = os.clock()
	marker.origin = origin
	marker.shownAt = now
	marker.active = true
	render(marker, now)
	marker.frame.Visible = true

	if not self._stepConn then
		self._stepConn = RunService.RenderStepped:Connect(function()
			self:_step()
		end)
	end
end

function DirectionalIndicators:_stepIndicator(indicator: Indicator?, now: number): boolean
	if not indicator then
		return false
	end

	local anyActive = false
	for _, marker in indicator.markers do
		if not marker.active then
			continue
		end
		if now - marker.shownAt >= HOLD_TIME + FADE_TIME then
			marker.active = false
			marker.frame.Visible = false
		else
			anyActive = true
			render(marker, now)
		end
	end
	return anyActive
end

function DirectionalIndicators:_step()
	local now = os.clock()
	local damageActive = self:_stepIndicator(self._damage, now)
	local combatActive = self:_stepIndicator(self._combat, now)

	if not damageActive and not combatActive and self._stepConn then
		self._stepConn:Disconnect()
		self._stepConn = nil
	end
end

-- Marcador vivo que ya apunta hacia el origen; si no, uno libre, uno nuevo o, con el
-- pool lleno, el del golpe más antiguo.
function DirectionalIndicators:showDamage(origin: Vector3)
	local indicator = self._damage
	if not indicator then
		return
	end

	local rotation = rotationTo(origin)
	local merged: Marker? = nil
	local free: Marker? = nil
	local oldest: Marker? = nil
	for _, marker in indicator.markers do
		if not marker.active then
			free = free or marker
		elseif angleBetween(marker.frame.Rotation, rotation) <= MERGE_ANGLE then
			merged = marker
			break
		elseif not oldest or marker.shownAt < oldest.shownAt then
			oldest = marker
		end
	end

	local recycled = if #indicator.markers >= MAX_DAMAGE_MARKERS then oldest else nil
	self:_show(merged or free or recycled or self:_newMarker(indicator), origin)
	hide(self._combat)
end

-- `weapon` es el Tool que acaba de disparar en este cliente. Un único marcador: lo
-- conserva el tiroteo más cercano mientras siga sonando; al callar (HOLD_TIME) lo
-- toma el siguiente que dispare. Con un DamageIndicator vivo no sale: ya sabes
-- dónde está el combate.
function DirectionalIndicators:showGunfire(weapon: Instance)
	local indicator = self._combat
	local shooter = weapon.Parent
	if not indicator or not shooter or not shooter:IsA("Model") or isShowing(self._damage) then
		return
	end
	if TeamUtils.isSameTeam(shooter, LocalPlayer.Character) then
		return
	end

	local origin = shooter:GetPivot().Position
	local marker = indicator.markers[1] or self:_newMarker(indicator)
	if marker.active and marker.source ~= weapon and os.clock() - marker.shownAt < HOLD_TIME then
		local listener = listenerPosition()
		if (origin - listener).Magnitude > (marker.origin - listener).Magnitude then
			return
		end
	end

	marker.source = weapon
	self:_show(marker, origin)
end

function DirectionalIndicators:_destroyIndicator(indicator: Indicator?)
	if not indicator then
		return
	end
	for _, marker in indicator.markers do
		self.weaponsGui.originalScaleAmounts[marker.frame] = nil
		marker.frame:Destroy()
	end
	table.clear(indicator.markers)
end

function DirectionalIndicators:Destroy()
	if self._hitConn then
		self._hitConn:Disconnect()
		self._hitConn = nil
	end
	if self._stepConn then
		self._stepConn:Disconnect()
		self._stepConn = nil
	end
	self:_destroyIndicator(self._damage)
	self:_destroyIndicator(self._combat)
	self._damage = nil
	self._combat = nil
end

return DirectionalIndicators
