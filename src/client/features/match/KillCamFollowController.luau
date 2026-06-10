--!strict

-- KillCamFollowController
-- Sistema de killcam que se sitúa ENFRENTE del jugador (o bot) que te mató,
-- mirándolo a la cara, y lo SIGUE de forma fluida mientras se mueve, con un
-- push-in dramático (karma cam) si el asesino muere durante la secuencia.
--
-- Funciona igual con bots y jugadores reales: la resolución del root distingue
-- userId positivo → jugador, FakeUserId negativo → bot en mapRoot.Bots.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local KillCamFollowController = {}
KillCamFollowController.__index = KillCamFollowController

-- ── Resolución del killer (jugador o bot) ────────────────────
-- (Antes vivían en KillCamController, ya eliminado; aquí son autónomas.)

local function resolveRootPartFromCharacter(character: Model?): BasePart?
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Cache de la folder de bots para no escanear workspace en cada muerte. Se invalida
-- sola si su Parent desaparece (cambio de mapa).
local _botsFolderCache: Instance? = nil

local function _asBotsFolder(node: Instance?): Folder?
	if node and node:IsA("Folder") and node.Name == "Bots" then
		return node
	end
	return nil
end

local function getBotsFolder(): Instance?
	if _botsFolderCache and _botsFolderCache.Parent then
		return _botsFolderCache
	end
	-- Jerarquía real: workspace.ActiveMap (Part contenedor) → mapModel → Bots, es
	-- decir DOS niveles por debajo de workspace. Buscamos hijo directo y nieto sin
	-- descender a la geometría del mapa, y cacheamos.
	for _, child in workspace:GetChildren() do
		local direct = _asBotsFolder(child:FindFirstChild("Bots"))
		if direct then
			_botsFolderCache = direct
			return direct
		end
		for _, grandChild in child:GetChildren() do
			local nested = _asBotsFolder(grandChild:FindFirstChild("Bots"))
			if nested then
				_botsFolderCache = nested
				return nested
			end
		end
	end
	local workspaceDirect = _asBotsFolder(workspace:FindFirstChild("Bots"))
	if workspaceDirect then
		_botsFolderCache = workspaceDirect
		return workspaceDirect
	end
	return nil
end

-- Exportada para que init.luau._resolveKillerCharacter reuse el mismo cache.
KillCamFollowController.getBotsFolder = getBotsFolder

local function resolveKillerRoot(killerUserId: number?, fallbackPosition: Vector3?): (BasePart?, Vector3)
	local fallback = fallbackPosition or Vector3.zero
	if not killerUserId then
		return nil, fallback
	end

	-- Jugador real (userId positivo).
	if killerUserId > 0 then
		local player = Players:GetPlayerByUserId(killerUserId)
		if player then
			local root = resolveRootPartFromCharacter(player.Character)
			if root then
				return root, root.Position
			end
		end
		return nil, fallback
	end

	-- Bot (FakeUserId negativo): buscar en la folder cacheada de bots.
	local botsFolder = getBotsFolder()
	if botsFolder then
		for _, model in botsFolder:GetChildren() do
			if model:IsA("Model") and model:GetAttribute("FakeUserId") == killerUserId then
				local root = resolveRootPartFromCharacter(model)
				if root then
					return root, root.Position
				end
				return nil, model:GetPivot().Position
			end
		end
	end

	return nil, fallback
end

local VEC3_UP = Vector3.new(0, 1, 0)
local VEC3_RIGHT = Vector3.new(1, 0, 0)

-- Conducimos la cámara DESPUÉS de la ShoulderCamera (prioridad Camera-1) para que
-- nuestra escritura de CFrame gane si la ShoulderCamera sigue activa un frame.
local RENDER_STEP_NAME = "KillCamFollow"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

local CONFIG = {
	-- Encuadre frontal del killer: la cámara arranca lejos/alta y hace un dolly-in
	-- suave hacia un plano cercano, dando tensión cinematográfica.
	startDistance = 22,
	endDistance = 17,
	startHeight = 4,
	endHeight = 3,
	dollyDuration = 4.5, -- segundos del acercamiento
	-- Altura del punto de mira: centro del cuerpo, con poco picado para ver el
	-- cuerpo entero (cabeza y pies en cuadro).
	lookHeight = 2,
	-- Offset lateral mínimo: encuadre prácticamente centrado/frontal.
	sideOffset = 0.6,
	-- Vaivén orbital sutil (parallax): hace que el plano "respire" aunque el killer
	-- esté quieto, sin perder la vista frontal.
	swayAmplitude = 0.1, -- radianes (~5.7°)
	swaySpeed = 0.55, -- rad/s
	-- FOV cinemático (compresión). Se aproxima suave y se restaura al parar.
	fieldOfView = 55,
	fovSmoothness = 2.5,
	-- Suavizados exponenciales independientes de FPS (menor = más flotante/cinemático).
	positionSmoothness = 5, -- seguimiento de la posición de cámara
	lookSmoothness = 8, -- seguimiento del punto de mira
	directionSmoothness = 3, -- suavizado de la orientación del killer (evita latigazos)
	-- Re-resolución del root cuando el ragdoll se destruye o el killer respawnea.
	resolveInterval = 0.1,
	-- Si el killer respawnea lejos, no saltamos a su nuevo spawn de golpe.
	maxFollowSnap = 40,
	-- ── Anti-clipping / oclusión ──────────────────────────────
	-- La cámara no atraviesa paredes: si hay geometría entre el killer y la cámara,
	-- se acerca hasta justo delante del obstáculo. Snap-in inmediato (no clipa) y
	-- ease-out al despejarse (el propio lerp de posición la devuelve hacia fuera).
	-- 1 solo raycast/frame + RaycastParams reutilizado → barato en móvil.
	occlusionEnabled = true,
	wallBuffer = 0.6, -- separación de la pared para que el plano cercano no la cruce
	minOccludedDistance = 2, -- distancia mínima al killer al pegarse a una pared
	-- ── Karma cam ─────────────────────────────────────────────
	-- Si el asesino al que seguimos muere durante la killcam, dejamos de re-
	-- resolver, hacemos un push-in lento y flotante sobre su cuerpo y aguantamos.
	karmaDuration = 2, -- segundos del push-in dramático
	karmaEndDistance = 12, -- plano algo más cercano, sin cortar el cuerpo
	karmaEndHeight = 2.6,
	karmaLookHeight = 1.6, -- bajamos un poco la mirada hacia el cuerpo caído
	karmaSwayScale = 0.25, -- vaivén casi detenido para un hold sereno
	karmaPositionSmoothness = 2.5, -- más flotante/lento que el seguimiento normal
	karmaLookSmoothness = 4,
	-- Fades cinemáticos para suavizar el corte de cámara.
	fadeToBlackTime = 0.12,
	fadeFromBlackTime = 0.22,
	fadeStopToBlackTime = 0.1,
	fadeStopFromBlackTime = 0.18,
}

local function _createFadeGui(playerGui: PlayerGui): (ScreenGui, Frame)
	local existing = playerGui:FindFirstChild("KillCamFollowFade")
	if existing and existing:IsA("ScreenGui") then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "KillCamFollowFade"
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

-- Dirección "frontal" del killer proyectada al plano horizontal (ignora pitch del
-- ragdoll/animaciones para que la cámara no cabecee).
local function _flatLook(root: BasePart): Vector3
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude > 0.001 then
		return flat.Unit
	end
	return VEC3_RIGHT
end

-- Posición de cámara enfrente del killer, con offset lateral y altura.
local function _computeCameraPos(pivot: Vector3, dir: Vector3, distance: number, height: number): Vector3
	local rightRaw = dir:Cross(VEC3_UP)
	local right = if rightRaw.Magnitude > 0.001 then rightRaw.Unit else VEC3_RIGHT
	return pivot + dir * distance + right * CONFIG.sideOffset + Vector3.new(0, height, 0)
end

-- Rota la dirección frontal alrededor del eje vertical (vaivén orbital/parallax).
local function _swayDir(dir: Vector3, angle: number): Vector3
	return CFrame.fromAxisAngle(VEC3_UP, angle):VectorToWorldSpace(dir)
end

export type StartData = {
	killerUserId: string,
	killerName: string,
	weaponId: string,
	killerPosition: Vector3?,
}

function KillCamFollowController.new(playerGui: PlayerGui): any
	local self = setmetatable({}, KillCamFollowController)
	self._player = Players.LocalPlayer
	self._playerGui = playerGui
	self._active = false
	self._renderBound = false
	self._originalCameraType = nil :: Enum.CameraType?
	self._originalCameraSubject = nil :: Instance?
	self._originalFov = nil :: number?
	self._fadeGui = nil :: ScreenGui?
	self._fadeFrame = nil :: Frame?
	return self
end

function KillCamFollowController:_ensureFade()
	if self._fadeGui and self._fadeFrame and self._fadeGui.Parent then
		return
	end
	local gui, frame = _createFadeGui(self._playerGui)
	self._fadeGui = gui
	self._fadeFrame = frame
end

function KillCamFollowController:_playFade(toTransparency: number, duration: number)
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

function KillCamFollowController:start(data: StartData?)
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
	self._originalFov = camera.FieldOfView

	local killerUserId = if data and data.killerUserId ~= "" then tonumber(data.killerUserId) else nil
	local serverFallbackPos = if data then data.killerPosition else nil

	local focusRoot, lastKnownPosition = resolveKillerRoot(killerUserId, serverFallbackPos)

	-- Sin info del killer: encuadramos la posición de muerte local como respaldo.
	if not focusRoot and lastKnownPosition == Vector3.zero then
		local localRoot = resolveRootPartFromCharacter(self._player.Character)
		if localRoot then
			lastKnownPosition = localRoot.Position
		else
			self._active = false
			return
		end
	end

	camera.CameraType = Enum.CameraType.Scriptable

	self:_playFade(0, CONFIG.fadeToBlackTime)
	task.delay(CONFIG.fadeToBlackTime, function()
		self:_playFade(1, CONFIG.fadeFromBlackTime)
	end)

	-- Orientación inicial: encaramos al killer ya desde el primer frame (sin lerp
	-- inicial) para evitar un "viaje" de la cámara al arrancar.
	local smoothedDir = if focusRoot then _flatLook(focusRoot) else VEC3_RIGHT
	local camPos = _computeCameraPos(lastKnownPosition, smoothedDir, CONFIG.startDistance, CONFIG.startHeight)
	local lookAtPos = lastKnownPosition + Vector3.new(0, CONFIG.lookHeight, 0)

	local startAt = time()
	local lastResolveAt = 0

	-- Estado de la "karma cam": se activa si el killer seguido muere.
	local killerHumanoid: Humanoid? = if focusRoot and focusRoot.Parent
		then focusRoot.Parent:FindFirstChildOfClass("Humanoid") :: Humanoid?
		else nil
	local killerDead = false
	local karmaStartAt = 0
	local karmaFromDistance = CONFIG.startDistance
	local karmaFromHeight = CONFIG.startHeight
	local lastDistance = CONFIG.startDistance
	local lastHeight = CONFIG.startHeight

	-- Oclusión: RaycastParams reutilizado (sin allocs por frame). Excluimos al
	-- killer y al jugador local para que el rayo solo choque con el escenario;
	-- RespectCanCollide ignora decoración no colisionable (follaje, VFX).
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.IgnoreWater = true
	raycastParams.RespectCanCollide = true
	local filteredKillerChar: Instance? = nil
	-- Excluimos TODOS los cuerpos (killer, jugador local, bots y jugadores) para que
	-- la cámara solo colisione con el escenario y no dé tirones cuando un cuerpo
	-- cruza por delante. Se reconstruye solo al cambiar de killer (poco frecuente).
	local function _refreshOcclusionFilter(killerChar: Instance?)
		filteredKillerChar = killerChar
		local filter: { Instance } = {}
		if killerChar then
			table.insert(filter, killerChar)
		end
		local localChar = self._player.Character
		if localChar then
			table.insert(filter, localChar)
		end
		local bots = getBotsFolder()
		if bots then
			table.insert(filter, bots)
		end
		for _, other in Players:GetPlayers() do
			if other.Character then
				table.insert(filter, other.Character)
			end
		end
		raycastParams.FilterDescendantsInstances = filter
	end
	_refreshOcclusionFilter(if focusRoot then focusRoot.Parent else nil)

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function(dt)
		if not self._active then
			return
		end

		-- Reafirmar Scriptable por si la ShoulderCamera u otro sistema lo cambió.
		if camera.CameraType ~= Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Scriptable
		end

		-- Mantener vivo el root: seguir su posición real, o re-resolver si el ragdoll
		-- fue destruido / el killer respawneó (a 10 Hz, no cada frame).
		-- Tras la muerte (karma cam) NO leemos el root: el cuerpo entra en ragdoll y
		-- su root tumbla/cae erráticamente; congelamos pivote y dirección.
		if focusRoot and focusRoot.Parent and not killerDead then
			lastKnownPosition = focusRoot.Position
			if not killerHumanoid then
				killerHumanoid = focusRoot.Parent:FindFirstChildOfClass("Humanoid") :: Humanoid?
			end
			if focusRoot.Parent ~= filteredKillerChar then
				_refreshOcclusionFilter(focusRoot.Parent)
			end
		elseif not killerDead then
			-- Solo re-resolvemos si el killer sigue vivo. Si ya murió (karma cam),
			-- aguantamos sobre el sitio de la muerte y NO saltamos a su respawn.
			focusRoot = nil
			local now = time()
			if killerUserId and now - lastResolveAt >= CONFIG.resolveInterval then
				lastResolveAt = now
				local newRoot = resolveKillerRoot(killerUserId, nil)
				if newRoot and (newRoot.Position - lastKnownPosition).Magnitude < CONFIG.maxFollowSnap then
					focusRoot = newRoot
					lastKnownPosition = newRoot.Position
					killerHumanoid = if newRoot.Parent
						then newRoot.Parent:FindFirstChildOfClass("Humanoid") :: Humanoid?
						else nil
					_refreshOcclusionFilter(newRoot.Parent)
				end
			end
		end

		-- Karma cam: el asesino al que seguimos acaba de morir → enganchamos el
		-- push-in dramático desde el encuadre actual.
		if not killerDead and killerHumanoid and killerHumanoid.Health <= 0 then
			killerDead = true
			karmaStartAt = time()
			karmaFromDistance = lastDistance
			karmaFromHeight = lastHeight
		end

		-- Suavizar la dirección frontal del killer para que la cámara no dé
		-- latigazos cuando gira bruscamente. Tras la muerte se congela (el ragdoll
		-- tumba el root y giraría la cámara sin control).
		if focusRoot and not killerDead then
			local dirAlpha = 1 - math.exp(-CONFIG.directionSmoothness * dt)
			local blended = smoothedDir:Lerp(_flatLook(focusRoot), dirAlpha)
			if blended.Magnitude > 0.001 then
				smoothedDir = blended.Unit
			end
		end

		-- Encuadre según el modo: dolly-in normal, o push-in dramático tras la muerte.
		local elapsed = time() - startAt
		local distance, height, lookH, swayScale, posSmooth, lookSmooth
		if killerDead then
			-- Karma cam: push-in lento desde el encuadre que había al morir → hold.
			local kT = math.clamp((time() - karmaStartAt) / CONFIG.karmaDuration, 0, 1)
			local kE = 1 - (1 - kT) ^ 3
			distance = karmaFromDistance + (CONFIG.karmaEndDistance - karmaFromDistance) * kE
			height = karmaFromHeight + (CONFIG.karmaEndHeight - karmaFromHeight) * kE
			lookH = CONFIG.lookHeight + (CONFIG.karmaLookHeight - CONFIG.lookHeight) * kE
			swayScale = CONFIG.karmaSwayScale
			posSmooth = CONFIG.karmaPositionSmoothness
			lookSmooth = CONFIG.karmaLookSmoothness
		else
			-- Dolly-in cinemático: de lejos/alto a cerca/bajo con ease-out cúbico.
			local dollyT = math.clamp(elapsed / CONFIG.dollyDuration, 0, 1)
			local eased = 1 - (1 - dollyT) ^ 3
			distance = CONFIG.startDistance + (CONFIG.endDistance - CONFIG.startDistance) * eased
			height = CONFIG.startHeight + (CONFIG.endHeight - CONFIG.startHeight) * eased
			lookH = CONFIG.lookHeight
			swayScale = 1
			posSmooth = CONFIG.positionSmoothness
			lookSmooth = CONFIG.lookSmoothness
		end
		lastDistance = distance
		lastHeight = height

		-- Vaivén orbital sutil alrededor del killer (parallax que da vida al plano).
		local swayAngle = math.sin(elapsed * CONFIG.swaySpeed) * CONFIG.swayAmplitude * swayScale
		local swayedDir = _swayDir(smoothedDir, swayAngle)

		local pivot = lastKnownPosition
		local targetCamPos = _computeCameraPos(pivot, swayedDir, distance, height)
		local targetLook = pivot + Vector3.new(0, lookH, 0)

		-- Lerp exponencial dependiente de dt → suavizado consistente a cualquier FPS.
		local posAlpha = 1 - math.exp(-posSmooth * dt)
		local lookAlpha = 1 - math.exp(-lookSmooth * dt)
		camPos = camPos:Lerp(targetCamPos, posAlpha)
		lookAtPos = lookAtPos:Lerp(targetLook, lookAlpha)

		-- Compresión de FOV cinemática, aproximada suavemente.
		local fovAlpha = 1 - math.exp(-CONFIG.fovSmoothness * dt)
		camera.FieldOfView = camera.FieldOfView + (CONFIG.fieldOfView - camera.FieldOfView) * fovAlpha

		-- Oclusión: si hay pared entre el killer (lookAtPos) y la cámara, acercamos la
		-- cámara hasta justo delante del obstáculo. Snap-in inmediato (no clipa); al
		-- despejarse, el lerp de posición la devuelve hacia fuera (ease-out natural).
		if CONFIG.occlusionEnabled then
			local toCam = camPos - lookAtPos
			local dist = toCam.Magnitude
			if dist > 0.001 then
				local hit = workspace:Raycast(lookAtPos, toCam, raycastParams)
				if hit then
					local dir = toCam / dist
					local safeDist = math.clamp((hit.Position - lookAtPos).Magnitude - CONFIG.wallBuffer, CONFIG.minOccludedDistance, dist)
					camPos = lookAtPos + dir * safeDist
				end
			end
		end

		camera.CFrame = CFrame.lookAt(camPos, lookAtPos)
	end)
	self._renderBound = true
end

function KillCamFollowController:stop()
	if not self._active then
		return
	end

	self._active = false
	self:_playFade(0, CONFIG.fadeStopToBlackTime)
	task.delay(CONFIG.fadeStopToBlackTime, function()
		self:_playFade(1, CONFIG.fadeStopFromBlackTime)
	end)

	if self._renderBound then
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		self._renderBound = false
	end

	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = self._originalCameraType or Enum.CameraType.Custom
		camera.FieldOfView = self._originalFov or 70
		local character = self._player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid then
			camera.CameraSubject = humanoid
		elseif self._originalCameraSubject then
			camera.CameraSubject = self._originalCameraSubject
		end
	end
end

function KillCamFollowController:isActive(): boolean
	return self._active
end

function KillCamFollowController:Destroy()
	self:stop()
	if self._fadeGui then
		self._fadeGui:Destroy()
		self._fadeGui = nil
		self._fadeFrame = nil
	end
end

return KillCamFollowController
