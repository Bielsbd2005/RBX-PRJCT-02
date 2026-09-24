--!strict

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared:WaitForChild("utils"):WaitForChild("TeamUtils"))
local DebugFlags = require(Shared:WaitForChild("utils"):WaitForChild("DebugFlags"))

-- Debug (solo Studio): mismo filtro de táctil que el autoshoot de BaseWeapon.
local forceMobileInput = DebugFlags.bind(ReplicatedStorage, "ForceMobileInput")
-- Diagnóstico del aviso de fuera de rango de la escopeta: BoolValue
-- ReplicatedStorage.Debug.DebugCrosshair = true (fuera de Studio siempre false).
local debugCrosshair = DebugFlags.bind(ReplicatedStorage, "DebugCrosshair")

local WeaponsSystemFolder = script.Parent.Parent.Parent
local Libraries = WeaponsSystemFolder:WaitForChild("Libraries")
local SpringService = require(Libraries:WaitForChild("SpringService"))
local AutoAimSystem = require(Libraries:WaitForChild("AutoAimSystem"))

local CENTER_ANCHOR_V2 = Vector2.new(0.5, 0.5)
local SHOTGUN_RANGE_TICK_INTERVAL = 0.1
-- Alto de viewport al que los valores de spread (px) se ven tal cual.
local SPREAD_REFERENCE_VIEWPORT_HEIGHT = 1080

-- No vale el primer Model ancestro: el arma empuñada (Tool > WeaponModel) es un
-- Model propio sin Humanoid.
local function findCharacterWithHumanoid(instance: Instance): Model?
	local model = instance:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") then
			return model
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

local Crosshair = {}
Crosshair.__index = Crosshair

function Crosshair.new(weaponsGui: any)
	local self = setmetatable({}, Crosshair)
	self.weaponsGui = weaponsGui

	self.dampingRatio = 0.9
	self.frequency = 3
	self.scaleTarget = 1
	self.scale = 1
	self.weaponScale = 1
	self.enabled = true
	self.isShotgun = false
	self.isOutOfRange = false

	self.spread = 0
	self.spreadTarget = 0
	self.spreadBase = 30
	self.spreadAim = 20
	self.spreadFireKick = 3
	-- CrosshairSpread / CrosshairAimSpread del arma (no escopeta).
	self.gapSpread = 0
	self.gapAimSpread = 0
	-- spreadBase/spreadAim/spreadFireKick son píxeles a 1080 de alto; resize()
	-- los adapta a la pantalla con este factor (ver SPREAD_REFERENCE_VIEWPORT_HEIGHT).
	self.spreadScreenFactor = 1

	self._kickCooldownEnd = 0
	self._shotgunRangeLastTickAt = 0

	return self
end

function Crosshair:setup(scalingElementsFolder: Folder)
	self.frame = scalingElementsFolder:WaitForChild("Crosshair") :: GuiObject
	self.bottom = self.frame:WaitForChild("Bottom") :: GuiObject
	self.left = self.frame:WaitForChild("Left") :: GuiObject
	self.right = self.frame:WaitForChild("Right") :: GuiObject
	self.top = self.frame:WaitForChild("Top") :: GuiObject

	self.origScales = {
		[self.bottom] = Vector2.new(self.bottom.Size.X.Scale, self.bottom.Size.Y.Scale),
		[self.left] = Vector2.new(self.left.Size.X.Scale, self.left.Size.Y.Scale),
		[self.right] = Vector2.new(self.right.Size.X.Scale, self.right.Size.Y.Scale),
		[self.top] = Vector2.new(self.top.Size.X.Scale, self.top.Size.Y.Scale),
	}
	self.origPositions = {
		[self.bottom] = self.bottom.Position,
		[self.left] = self.left.Position,
		[self.right] = self.right.Position,
		[self.top] = self.top.Position,
	}
	self.origAnchors = {
		[self.bottom] = self.bottom.AnchorPoint,
		[self.left] = self.left.AnchorPoint,
		[self.right] = self.right.AnchorPoint,
		[self.top] = self.top.AnchorPoint,
	}
	self.normalSize = self.frame.AbsoluteSize

	self.shotgunFrame = scalingElementsFolder:FindFirstChild("CrosshairShotgun") :: GuiObject?
	if self.shotgunFrame then
		self.shotgunTopLeft = self.shotgunFrame:WaitForChild("TopLeft") :: GuiObject
		self.shotgunTopRight = self.shotgunFrame:WaitForChild("TopRight") :: GuiObject
		self.shotgunBottomLeft = self.shotgunFrame:WaitForChild("BottomLeft") :: GuiObject
		self.shotgunBottomRight = self.shotgunFrame:WaitForChild("BottomRight") :: GuiObject
		self.shotgunFrame.Visible = false
	end

	self.outOfRangeFrame = scalingElementsFolder:FindFirstChild("OutOfRange") :: GuiObject?
	if self.outOfRangeFrame then
		self.outOfRangeFrame.Visible = false
		self.outOfRangeDistanceLabel = self.outOfRangeFrame:FindFirstChild("Distance") :: TextLabel?
	end
end

function Crosshair:setEnabled(enabled: boolean)
	self.enabled = enabled
	self:refreshVisibility()
end

function Crosshair:refreshVisibility()
	-- La GUI sigue visible sin arma (hotbar), pero el crosshair no.
	local shouldShow = self.enabled and self.weaponsGui.enabled and not self.weaponsGui._isReloadProgressAnimating

	if self.frame then
		self.frame.Visible = shouldShow and not self.isShotgun
	end
	local shotgunInRange = self.isShotgun and not self.isOutOfRange
	if self.shotgunFrame then
		self.shotgunFrame.Visible = shouldShow and shotgunInRange
	end
	if self.outOfRangeFrame then
		self.outOfRangeFrame.Visible = shouldShow and self.isShotgun and self.isOutOfRange
	end
end

function Crosshair:setWeaponScale(scale: number)
	if self.weaponScale == scale then return end
	self.weaponScale = scale
end

function Crosshair:setScaleTarget(target: number, dampingRatio: number?, frequency: number?)
	if typeof(dampingRatio) == "number" then
		self.dampingRatio = dampingRatio
	end
	if typeof(frequency) == "number" then
		self.frequency = frequency
	end
	if self.scaleTarget == target then return end
	self.scaleTarget = target
	SpringService:Target(self, self.dampingRatio, self.frequency, { scale = self.scaleTarget })
end

function Crosshair:setScale(scale: number)
	if self.scale == scale then return end
	self.scale = scale
	SpringService:Target(self, self.dampingRatio, self.frequency, { scale = self.scaleTarget })
end

function Crosshair:setVariant(isShotgun: boolean, gapSpread: number, gapAimSpread: number, hideTop: boolean)
	if debugCrosshair() then
		local weapon = self.weaponsGui.weaponsSystem.currentWeapon
		local tool = weapon and weapon.instance
		warn(string.format(
			"[Crosshair/OutOfRange] arma=%s -> escopeta=%s",
			tool and tool.Name or "nil",
			tostring(isShotgun)
		))
		self._dbgLastRangeKey = nil
	end
	self.isShotgun = isShotgun
	self.gapSpread = if isShotgun then 0 else gapSpread
	self.gapAimSpread = if isShotgun then 0 else gapAimSpread
	self.isOutOfRange = false
	if self.top then
		self.top.Visible = not hideTop
	end
	self:refreshVisibility()
	if self.isShotgun then
		self.weaponScale = 1
	end
	self.spreadTarget = self:_restingSpread()
	SpringService:Target(self, self.dampingRatio, self.frequency, { spread = self.spreadTarget })
end

-- Estado real de la cámara: con Q o L2 (ShoulderCamera.zoomInputs) se apunta sin
-- pasar por WeaponsGui.isZoomed.
function Crosshair:_isAiming(): boolean
	local camera = self.weaponsGui.weaponsSystem.camera
	if camera then
		return camera:isZoomed()
	end
	return self.weaponsGui.isZoomed
end

function Crosshair:_restingSpread(): number
	local zoomed = self:_isAiming()
	if self.isShotgun then
		return if zoomed then self.spreadAim else self.spreadBase
	end
	return if zoomed then self.gapAimSpread else self.gapSpread
end

-- Con CrosshairSpread > 0 cada brazo se coloca desde el centro del frame: la
-- separación es la distancia real al centro y no depende de dónde estén en Studio.
-- Sin él vuelven a su Position y AnchorPoint de Studio.
function Crosshair:layoutArmsGap()
	if self.gapSpread <= 0 then
		if self._lastArmsGap == false then return end
		self._lastArmsGap = false
		for arm, position in self.origPositions do
			arm.Position = position
			arm.AnchorPoint = self.origAnchors[arm]
		end
		return
	end

	local s = math.round(self.spread * self.scale * self.weaponScale * self.spreadScreenFactor)
	if s == self._lastArmsGap then return end
	self._lastArmsGap = s
	-- Size en Offset: lo fija resize() (que invalida _lastArmsGap al cambiarlo).
	local halfLeft = self.left.Size.X.Offset / 2
	local halfRight = self.right.Size.X.Offset / 2
	local halfBottom = self.bottom.Size.Y.Offset / 2
	local halfTop = self.top.Size.Y.Offset / 2
	for arm in self.origPositions do
		arm.AnchorPoint = CENTER_ANCHOR_V2
	end
	self.left.Position = UDim2.new(0.5, -math.round(s + halfLeft), 0.5, 0)
	self.right.Position = UDim2.new(0.5, math.round(s + halfRight), 0.5, 0)
	self.bottom.Position = UDim2.new(0.5, 0, 0.5, math.round(s + halfBottom))
	self.top.Position = UDim2.new(0.5, 0, 0.5, -math.round(s + halfTop))
end

function Crosshair:layoutShotgunCorners()
	if not (self.shotgunFrame and self.isShotgun) then return end
	local compScale = self.scale * self.weaponScale
	local s = self.spread * compScale * self.spreadScreenFactor
	local size = math.floor(self.normalSize.Y * 0.45 * compScale)
	if not self._shotgunAnchorsSet then
		self.shotgunTopLeft.AnchorPoint = CENTER_ANCHOR_V2
		self.shotgunTopRight.AnchorPoint = CENTER_ANCHOR_V2
		self.shotgunBottomLeft.AnchorPoint = CENTER_ANCHOR_V2
		self.shotgunBottomRight.AnchorPoint = CENTER_ANCHOR_V2
		self._shotgunAnchorsSet = true
	end
	self.shotgunTopLeft.Position = UDim2.new(0.5, -s, 0.5, -s)
	self.shotgunTopLeft.Size = UDim2.new(0, size, 0, size)
	self.shotgunTopRight.Position = UDim2.new(0.5, s, 0.5, -s)
	self.shotgunTopRight.Size = UDim2.new(0, size, 0, size)
	self.shotgunBottomLeft.Position = UDim2.new(0.5, -s, 0.5, s)
	self.shotgunBottomLeft.Size = UDim2.new(0, size, 0, size)
	self.shotgunBottomRight.Position = UDim2.new(0.5, s, 0.5, s)
	self.shotgunBottomRight.Size = UDim2.new(0, size, 0, size)
end

function Crosshair:kickShotgunSpread()
	if not self.isShotgun then return end
	local kick = self.spreadBase + self.spreadFireKick
	self.spreadTarget = kick
	SpringService:Target(self, 0.6, 5, { spread = self.spreadTarget })
	self._kickCooldownEnd = os.clock() + 0.12
	task.delay(0.06, function()
		self.spreadTarget = self:_restingSpread()
		SpringService:Target(self, 0.85, 4, { spread = self.spreadTarget })
	end)
end

-- Solo escribe cuando cambia el motivo, para no llenar la consola a 10 Hz.
function Crosshair:_debugRange(key: string, detail: string)
	if not debugCrosshair() or key == self._dbgLastRangeKey then return end
	self._dbgLastRangeKey = key
	warn("[Crosshair/OutOfRange] " .. detail)
end

function Crosshair:updateShotgunRangeState()
	if not self.isShotgun then return end
	if not self.outOfRangeFrame then
		self:_debugRange("sin-frame", "la GUI no tiene ScalingElements.OutOfRange: el aviso no puede mostrarse")
		return
	end

	if not (forceMobileInput() or (UserInputService.TouchEnabled and not UserInputService.MouseEnabled)) then
		self:_debugRange("no-tactil", string.format(
			"desactivado, no es táctil puro (TouchEnabled=%s MouseEnabled=%s)",
			tostring(UserInputService.TouchEnabled),
			tostring(UserInputService.MouseEnabled)
		))
		if self.isOutOfRange then
			self.isOutOfRange = false
			self:refreshVisibility()
		end
		return
	end

	local now = os.clock()
	if now - self._shotgunRangeLastTickAt < SHOTGUN_RANGE_TICK_INTERVAL then return end
	self._shotgunRangeLastTickAt = now

	local camera = workspace.CurrentCamera
	if not camera then return end

	local weapon = self.weaponsGui.weaponsSystem.currentWeapon
	local tool = weapon and weapon.instance
	if not weapon then return end
	local optimalRange = weapon:getConfigValue("OptimalRange")

	local outOfRange = false
	local distance: number? = nil

	local cameraCFrame = camera.CFrame
	local cameraOrigin = cameraCFrame.Position
	local cameraDir = cameraCFrame.LookVector

	local rayParams = self.weaponsGui._shotgunRangeParams
	if not rayParams then
		rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.IgnoreWater = true
		self.weaponsGui._shotgunRangeParams = rayParams
	end
	local filter = self.weaponsGui._shotgunRangeFilter
	if not filter then
		filter = table.create(2)
		self.weaponsGui._shotgunRangeFilter = filter
	end
	local n = 0
	local localPlayer = Players.LocalPlayer
	if localPlayer and localPlayer.Character then
		n += 1
		filter[n] = localPlayer.Character
	end
	if tool then
		n += 1
		filter[n] = tool
	end
	for i = n + 1, #filter do
		filter[i] = nil
	end
	rayParams.FilterDescendantsInstances = filter

	local maxRay = AutoAimSystem.MAX_DISTANCE or 300
	local localChar = localPlayer and localPlayer.Character
	local result = workspace:Raycast(cameraOrigin, cameraDir * maxRay, rayParams)
	local hitChar = result and findCharacterWithHumanoid(result.Instance)
	local hitHum = hitChar and hitChar:FindFirstChildOfClass("Humanoid")
	if result and hitChar and hitHum and hitHum.Health > 0 and hitChar ~= localChar
		and not (localChar and TeamUtils.isSameTeam(localChar, hitChar))
	then
		distance = (result.Position - cameraOrigin).Magnitude
	else
		-- El rayo es de un píxel y a distancia pasa entre brazos y piernas. El
		-- autoshoot fija objetivo por radio en pantalla y no dispara fuera de
		-- OptimalRange (BaseWeapon:onStepped): sin este fallback no dispararía
		-- ni saldría el aviso.
		local targetPart, targetPos = AutoAimSystem.findBestTarget(self.weaponsGui.weaponsSystem)
		if targetPart and targetPos and AutoAimSystem.isTargetVisible(cameraOrigin, targetPart) then
			distance = (targetPos - cameraOrigin).Magnitude
		end
	end
	if distance then
		outOfRange = distance > optimalRange
	end

	if outOfRange ~= self.isOutOfRange then
		self.isOutOfRange = outOfRange
		self:refreshVisibility()
	end

	if debugCrosshair() then
		if not distance then
			self:_debugRange("sin-enemigo", "sin enemigo detectado (ni el rayo ni el autoaim)")
		else
			self:_debugRange(if outOfRange then "fuera" else "dentro", string.format(
				"%s: distancia=%.1f OptimalRange=%s | frame.Visible=%s enabled=%s recargando=%s",
				if outOfRange then "FUERA de rango" else "dentro de rango",
				distance,
				tostring(optimalRange),
				tostring(self.outOfRangeFrame.Visible),
				tostring(self.enabled),
				tostring(self.weaponsGui._isReloadProgressAnimating)
			))
		end
	end

	if outOfRange and distance and self.outOfRangeDistanceLabel then
		local remaining = math.max(0, distance - optimalRange)
		local text = tostring(math.floor(remaining + 0.5))
		if text ~= self._lastOutOfRangeDistanceText then
			self._lastOutOfRangeDistanceText = text
			self.outOfRangeDistanceLabel.Text = text
		end
	end
end

function Crosshair:resize(viewportSize: Vector2)
	if not self.frame then return end

	-- Las esquinas escalan con normalSize (WeaponsGui:updateScale); el spread en
	-- píxeles fijos no, y en móvil quedaría el doble de abierto. Mismo peso que
	-- updateScale, normalizado a factor 1 en 1080 de alto.
	local gui = self.weaponsGui
	local refHeight = gui.referenceViewportSize.Y
	if viewportSize.Y > 0 then
		self.spreadScreenFactor =
			gui:getWeightedScaleAmount(1, viewportSize.Y, refHeight) * viewportSize.Y
			/ (gui:getWeightedScaleAmount(1, SPREAD_REFERENCE_VIEWPORT_HEIGHT, refHeight) * SPREAD_REFERENCE_VIEWPORT_HEIGHT)
	end

	local crosshairAbsoluteSize = self.frame.AbsoluteSize
	if crosshairAbsoluteSize.X <= 0 or crosshairAbsoluteSize.Y <= 0 then
		return
	end

	self.normalSize = crosshairAbsoluteSize
	self.bottom.Size = UDim2.new(0, self.origScales[self.bottom].X * self.normalSize.X, 0, self.origScales[self.bottom].Y * self.normalSize.Y)
	self.left.Size = UDim2.new(0, self.origScales[self.left].X * self.normalSize.X, 0, self.origScales[self.left].Y * self.normalSize.Y)
	self.right.Size = UDim2.new(0, self.origScales[self.right].X * self.normalSize.X, 0, self.origScales[self.right].Y * self.normalSize.Y)
	self.top.Size = UDim2.new(0, self.origScales[self.top].X * self.normalSize.X, 0, self.origScales[self.top].Y * self.normalSize.Y)
	self._lastArmsGap = nil
	
	if self.shotgunFrame then
		self:layoutShotgunCorners()
	end
end

function Crosshair:update(dt: number)
	if os.clock() >= self._kickCooldownEnd then
		local want = self:_restingSpread()
		if math.abs(self.spreadTarget - want) > 0.1 then
			self.spreadTarget = want
			SpringService:Target(self, self.dampingRatio, self.frequency, { spread = want })
		end
	end
	if self.isShotgun then
		if self.shotgunFrame and self.enabled then
			local s = self.spread
			local cs = self.scale
			if s ~= self._lastShotgunSpread or cs ~= self._lastShotgunScale then
				self._lastShotgunSpread = s
				self._lastShotgunScale = cs
				self:layoutShotgunCorners()
			end
		end
		self:updateShotgunRangeState()
	else
		if self.frame and self.enabled then
			-- Comparar contra frame.Size, no contra una caché: WeaponsGui:updateScale
			-- devuelve el frame a su tamaño base por su cuenta y la caché no lo
			-- detectaría. Redondeado porque Offset es entero.
			local crosshairSize = self.normalSize * (self.scale * self.weaponScale)
			local targetSize = UDim2.fromOffset(math.round(crosshairSize.X), math.round(crosshairSize.Y))
			local currentSize = self.frame.Size
			if currentSize ~= targetSize then
				self.frame.Size = targetSize
			end
			self:layoutArmsGap()
		end
	end
end

return Crosshair
