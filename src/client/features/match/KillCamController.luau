--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local KillCamController = {}
KillCamController.__index = KillCamController

local VEC3_UP = Vector3.new(0, 1, 0)
local VEC3_RIGHT = Vector3.new(1, 0, 0)

local CONFIG = {
	-- Posición inicial: elevada y lejana
	initialHeight = 8,
	initialDistance = 20,
	-- Posición final: cercana y ligeramente elevada, enfrente del killer
	finalHeight = 2.5,
	finalDistance = 12,
	-- Offset lateral sutil para evitar alineación perfecta
	sideOffset = 3,
	-- Altura del punto de mirada relativo al killer
	lookOffsetY = 1.2,
	-- Suavidad del movimiento de cámara
	cameraSmoothness = 0.08,
	-- Duración del acercamiento
	zoomDuration = 5,
	-- Fade cinematica
	fadeToBlackTime = 0.12,
	fadeFromBlackTime = 0.22,
	fadeStopToBlackTime = 0.1,
	fadeStopFromBlackTime = 0.18,
}

local function _createFadeGui(playerGui: PlayerGui): (ScreenGui, Frame)
	local existing = playerGui:FindFirstChild("KillCamFade")
	if existing and existing:IsA("ScreenGui") then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "KillCamFade"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 10001
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Fade"
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.ZIndex = 10001
	frame.Parent = screenGui

	return screenGui, frame
end

local function _resolveRootPartFromCharacter(character: Model?): BasePart?
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Cache de la folder de bots para evitar workspace:GetDescendants() en cada kill.
-- Se invalida automáticamente si el Parent desaparece (cambio de mapa).
-- Exportada como `KillCamController.getBotsFolder` para que otros módulos del
-- feature (init.luau._resolveKillerCharacter) reusen el mismo cache en lugar
-- de hacer su propio escaneo de workspace por cada muerte.
local _botsFolderCache: Instance? = nil

local function _getBotsFolder(): Instance?
	if _botsFolderCache and _botsFolderCache.Parent then
		return _botsFolderCache
	end
	-- Los bots viven típicamente en mapRoot.Bots (hijo directo de algún hijo de workspace).
	for _, child in workspace:GetChildren() do
		local maybeBots = child:FindFirstChild("Bots")
		if maybeBots and maybeBots:IsA("Folder") then
			_botsFolderCache = maybeBots
			return maybeBots
		end
	end
	-- Fallback: tal vez está como hijo directo de workspace.
	local direct = workspace:FindFirstChild("Bots")
	if direct and direct:IsA("Folder") then
		_botsFolderCache = direct
		return direct
	end
	return nil
end

KillCamController.getBotsFolder = _getBotsFolder

local function _resolveKillerRoot(killerUserId: number?, fallbackPosition: Vector3?): (BasePart?, Vector3)
	local fallback = fallbackPosition or Vector3.zero

	if not killerUserId then
		return nil, fallback
	end

	-- Real player (positive userId)
	if killerUserId > 0 then
		local player = Players:GetPlayerByUserId(killerUserId)
		if player then
			local root = _resolveRootPartFromCharacter(player.Character)
			if root then
				return root, root.Position
			end
		end
		return nil, fallback
	end

	-- Bot (negative fakeUserId): buscar primero en la folder cacheada (hijos directos),
	-- evita escanear todo workspace en cada muerte.
	local botsFolder = _getBotsFolder()
	if botsFolder then
		for _, model in botsFolder:GetChildren() do
			if model:IsA("Model") and model:GetAttribute("FakeUserId") == killerUserId then
				local root = _resolveRootPartFromCharacter(model)
				if root then
					return root, root.Position
				end
				return nil, model:GetPivot().Position
			end
		end
	end

	return nil, fallback
end

export type StartData = {
	killerUserId: string,
	killerName: string,
	weaponId: string,
	killerPosition: Vector3?,
}

function KillCamController.new(playerGui: PlayerGui): any
	local self = setmetatable({}, KillCamController)
	self._player = Players.LocalPlayer
	self._playerGui = playerGui
	self._active = false
	self._renderConn = nil :: RBXScriptConnection?
	self._originalCameraType = nil :: Enum.CameraType?
	self._originalCameraSubject = nil :: Instance?
	self._fadeGui = nil :: ScreenGui?
	self._fadeFrame = nil :: Frame?
	return self
end

function KillCamController:_ensureFade()
	if self._fadeGui and self._fadeFrame and self._fadeGui.Parent then
		return
	end
	local gui, frame = _createFadeGui(self._playerGui)
	self._fadeGui = gui
	self._fadeFrame = frame
end

function KillCamController:_playFade(toTransparency: number, duration: number)
	self:_ensureFade()
	if not self._fadeFrame then
		return
	end
	local tween = TweenService:Create(
		self._fadeFrame,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = toTransparency }
	)
	tween:Play()
end

function KillCamController:start(data: StartData?)
	if self._active then
		self:stop()
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	self._active = true
	self._originalCameraType = camera.CameraType
	self._originalCameraSubject = camera.CameraSubject

	local killerUserId = if data and data.killerUserId ~= "" then tonumber(data.killerUserId) else nil
	local serverFallbackPos = if data then data.killerPosition else nil

	local focusRoot, lastKnownPosition = _resolveKillerRoot(killerUserId, serverFallbackPos)

	-- If no killer info at all, fall back to local player's death position.
	-- Do NOT track the root as focusRoot — the ragdoll sets it to CanCollide=false
	-- and it free-falls through the floor. We only capture the static position.
	if not focusRoot and lastKnownPosition == Vector3.zero then
		local localRoot = _resolveRootPartFromCharacter(self._player.Character)
		if localRoot then
			lastKnownPosition = localRoot.Position
		else
			self._active = false
			return
		end
	end

	camera.CameraType = Enum.CameraType.Scriptable

	-- Fade a negro breve para suavizar el corte de cámara.
	self:_playFade(0, CONFIG.fadeToBlackTime)
	task.delay(CONFIG.fadeToBlackTime, function()
		self:_playFade(1, CONFIG.fadeFromBlackTime)
	end)

	local startAt = time()
	local currentCameraPos = camera.CFrame.Position
	-- Throttle del re-resolve cuando el focusRoot está destruido: iterar
	-- botsFolder:GetChildren() cada RenderStepped es desperdicio (60 Hz). Re-
	-- intentamos cada 100 ms (10 Hz) que es más que suficiente para captar el
	-- respawn del killer durante el zoom de 5s.
	local RESOLVE_INTERVAL = 0.1
	local lastResolveAt = 0

	self._renderConn = RunService.RenderStepped:Connect(function(dt)
		if not self._active then
			return
		end

		-- Try to re-resolve the focus root if it was destroyed (ragdoll cleanup)
		if focusRoot and focusRoot.Parent then
			lastKnownPosition = focusRoot.Position
		else
			-- Root is gone — try to re-resolve from killer's character (they may have respawned)
			-- But we prefer lastKnownPosition (where they died/were) to avoid snapping to their new spawn
			focusRoot = nil
			local now = time()
			if killerUserId and now - lastResolveAt >= RESOLVE_INTERVAL then
				lastResolveAt = now
				local newRoot, _ = _resolveKillerRoot(killerUserId, nil)
				-- Only use new root if it's near the last known position (same ragdoll area)
				if newRoot and (newRoot.Position - lastKnownPosition).Magnitude < 20 then
					focusRoot = newRoot
					lastKnownPosition = newRoot.Position
				end
			end
		end

		local elapsed = time() - startAt
		local progress = math.clamp(elapsed / CONFIG.zoomDuration, 0, 1)

		-- Easing suave: comienza lento, acelera, y desacelera al final (ease in-out cubic)
		local easedProgress = if progress < 0.5
			then 4 * progress * progress * progress
			else 1 - math.pow(-2 * progress + 2, 3) / 2

		local currentHeight = CONFIG.initialHeight + (CONFIG.finalHeight - CONFIG.initialHeight) * easedProgress
		local currentDistance = CONFIG.initialDistance + (CONFIG.finalDistance - CONFIG.initialDistance) * easedProgress

		local pivot = lastKnownPosition

		-- Determinar dirección hacia dónde "mira" el killer
		-- Si el killer está mirando a una dirección específica, usarla; de lo contrario, usar dirección arbitraria
		local killerDirection = VEC3_RIGHT
		if focusRoot then
			-- Intentar obtener orientación del killer
			local killerCFrame = focusRoot.CFrame
			killerDirection = killerCFrame.LookVector
		end

		-- Posición de cámara: enfrente del killer (con offset lateral sutil)
		-- Usar cross product para obtener vector perpendicular
		local rightRaw = killerDirection:Cross(VEC3_UP)
		local rightVector = if rightRaw.Magnitude > 0.001 then rightRaw.Unit else VEC3_RIGHT

		local targetPos = pivot
			+ killerDirection * currentDistance          -- Distancia enfrente
			+ rightVector * CONFIG.sideOffset            -- Offset lateral
			+ Vector3.new(0, currentHeight, 0)           -- Altura

		currentCameraPos = currentCameraPos:Lerp(targetPos, CONFIG.cameraSmoothness)

		-- Mirar hacia el killer con un pequeño offset de altura
		local lookTarget = pivot + Vector3.new(0, CONFIG.lookOffsetY, 0)
		camera.CFrame = CFrame.lookAt(currentCameraPos, lookTarget)
	end)
end

function KillCamController:stop()
	if not self._active then
		return
	end

	self._active = false
	self:_playFade(0, CONFIG.fadeStopToBlackTime)
	task.delay(CONFIG.fadeStopToBlackTime, function()
		self:_playFade(1, CONFIG.fadeStopFromBlackTime)
	end)

	if self._renderConn then
		self._renderConn:Disconnect()
		self._renderConn = nil
	end

	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = self._originalCameraType or Enum.CameraType.Custom
		local character = self._player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid then
			camera.CameraSubject = humanoid
		elseif self._originalCameraSubject then
			camera.CameraSubject = self._originalCameraSubject
		end
	end
end

function KillCamController:isActive(): boolean
	return self._active
end

function KillCamController:Destroy()
	self:stop()
	if self._fadeGui then
		self._fadeGui:Destroy()
		self._fadeGui = nil
		self._fadeFrame = nil
	end
end

return KillCamController
