--!strict

-- Killcam enfrente del asesino (jugador: userId > 0; bot: FakeUserId negativo en
-- la folder Bots) que lo sigue, con push-in (karma cam) si muere durante la secuencia.
-- Sin asesino (caída al vacío, reset, entorno) especta a un enemigo vivo al azar.
-- Nunca salir sin tomar la cámara: en Custom sobre el propio Humanoid el jugador
-- vería su cuerpo aterrizar en el lobby cuando MatchService lo reubica.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)

local KillCamFollowController = {}
KillCamFollowController.__index = KillCamFollowController

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

-- Cache de la folder de bots; se invalida sola si pierde el Parent (cambio de mapa).
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
	-- Jerarquía real: workspace.ActiveMap → mapModel → Bots (dos niveles). Se busca
	-- hijo y nieto sin descender a la geometría del mapa.
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

local function resolveKillerRoot(killerUserId: number?): (BasePart?, Vector3)
	if not killerUserId then
		return nil, Vector3.zero
	end

	if killerUserId > 0 then
		local player = Players:GetPlayerByUserId(killerUserId)
		if player then
			local root = resolveRootPartFromCharacter(player.Character)
			if root then
				return root, root.Position
			end
		end
		return nil, Vector3.zero
	end

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

	return nil, Vector3.zero
end

-- Bando SIN pasar por el personaje: en una caída al vacío el modelo ya está
-- destruido al llegar DeathScreenShow; Player.Team sobrevive a la muerte.
local function localSide(): string?
	local player = Players.LocalPlayer
	if player.Team then
		return TeamUtils.normalize(player.Team.Name)
	end
	local attr = player:GetAttribute("TeamName")
	if type(attr) == "string" then
		return TeamUtils.normalize(attr)
	end
	return nil
end

-- Root de un personaje VIVO, o nil. La comprobación de salud no sobra: un
-- ragdoll conserva su root, y encuadrarlo sería espectar a un cadáver.
local function aliveRootOf(character: Instance?): BasePart?
	if not character or not character.Parent then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return resolveRootPartFromCharacter(character :: Model)
end

--[[
	AL AZAR y no "el más cercano": en una caída al vacío el más cercano suele ser
	quien te empujó, y encuadrarlo parecería una killcam de una kill que el servidor
	no le ha contado. TeamUtils.getSide resuelve jugadores (Player.Team) y bots
	(atributos que estampa AIService).
]]
local function pickRandomEnemyRoot(): BasePart?
	local side = localSide()
	if not side then
		return nil
	end

	local candidates: { BasePart } = {}

	for _, other in Players:GetPlayers() do
		if other ~= Players.LocalPlayer then
			local root = aliveRootOf(other.Character)
			local otherSide = TeamUtils.getSide(other.Character)
			if root and otherSide and otherSide ~= side then
				table.insert(candidates, root)
			end
		end
	end

	local botsFolder = getBotsFolder()
	if botsFolder then
		for _, model in botsFolder:GetChildren() do
			if model:IsA("Model") then
				local root = aliveRootOf(model)
				local botSide = TeamUtils.getSide(model)
				if root and botSide and botSide ~= side then
					table.insert(candidates, root)
				end
			end
		end
	end

	if #candidates == 0 then
		return nil
	end
	return candidates[math.random(1, #candidates)]
end

local VEC3_UP = Vector3.new(0, 1, 0)
local VEC3_RIGHT = Vector3.new(1, 0, 0)

-- Conducimos la cámara DESPUÉS de la ShoulderCamera (prioridad Camera-1) para que
-- nuestra escritura de CFrame gane si la ShoulderCamera sigue activa un frame.
local RENDER_STEP_NAME = "KillCamFollow"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

local CONFIG = {
	-- Dolly-in desde start* hasta end* en dollyDuration.
	startDistance = 22,
	endDistance = 17,
	startHeight = 4,
	endHeight = 3,
	dollyDuration = 4.5, -- segundos del acercamiento
	lookHeight = 2,
	sideOffset = 0.6,
	-- Vaivén orbital sutil (parallax) aunque el killer esté quieto.
	swayAmplitude = 0.1, -- radianes (~5.7°)
	swaySpeed = 0.55, -- rad/s
	fieldOfView = 55,
	fovSmoothness = 2.5,
	-- Suavizados exponenciales independientes de FPS (menor = más flotante).
	positionSmoothness = 5,
	lookSmoothness = 8,
	directionSmoothness = 3, -- orientación del killer (evita latigazos)
	-- Re-resolución del root cuando el ragdoll se destruye o el killer respawnea.
	resolveInterval = 0.1,
	-- Si el killer respawnea lejos, no saltamos a su nuevo spawn de golpe.
	maxFollowSnap = 40,
	-- Margen antes de rendirse con un asesino que no se resuelve (desconectado,
	-- fuera de replicación) y espectar. Un respawn normal se recupera muy por debajo.
	spectateFallbackDelay = 1,
	-- Oclusión: con geometría entre killer y cámara, snap-in hasta delante del
	-- obstáculo; al despejarse la devuelve el lerp de posición. 1 raycast/frame.
	wallBuffer = 0.6, -- separación de la pared para que el plano cercano no la cruce
	minOccludedDistance = 2, -- distancia mínima al killer al pegarse a una pared
	-- Karma cam: si el asesino seguido muere, se deja de re-resolver y se hace un
	-- push-in lento sobre su cuerpo.
	karmaDuration = 2, -- segundos del push-in dramático
	karmaEndDistance = 12,
	karmaEndHeight = 2.6,
	karmaLookHeight = 1.6,
	karmaSwayScale = 0.25,
	karmaPositionSmoothness = 2.5,
	karmaLookSmoothness = 4,
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

local function _computeCameraPos(pivot: Vector3, dir: Vector3, distance: number, height: number): Vector3
	local rightRaw = dir:Cross(VEC3_UP)
	local right = if rightRaw.Magnitude > 0.001 then rightRaw.Unit else VEC3_RIGHT
	return pivot + dir * distance + right * CONFIG.sideOffset + Vector3.new(0, height, 0)
end

local function _swayDir(dir: Vector3, angle: number): Vector3
	return CFrame.fromAxisAngle(VEC3_UP, angle):VectorToWorldSpace(dir)
end

export type StartData = {
	killerUserId: string,
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
	local tween = TweenService:Create(
		self._fadeFrame,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = toTransparency }
	)
	tween:Play()
end

function KillCamFollowController:start(data: StartData)
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

	local killerUserId = if data.killerUserId ~= "" then tonumber(data.killerUserId) else nil

	local focusRoot, lastKnownPosition = resolveKillerRoot(killerUserId)

	--[[
		Espectador SOLO si no hay asesino. Si lo hay pero no se resuelve ahora
		(respawneando, ragdoll recién destruido), el bucle de re-resolución lo
		recupera sin perder killcam ni karma cam, y si no aparece nunca cae a
		espectador tras spectateFallbackDelay.
	]]
	local spectating = false
	if killerUserId == nil then
		local enemyRoot = pickRandomEnemyRoot()
		if enemyRoot then
			spectating = true
			focusRoot = enemyRoot
			lastKnownPosition = enemyRoot.Position
		end
	end

	--[[
		Sin asesino ni enemigos vivos se sostiene el punto de muerte. Sin salida
		temprana: la limpieza de armas (MatchWeapons → ShoulderCamera:setEnabled(false))
		reafirma Custom con reintentos, y solo este render step la devuelve a Scriptable.
	]]
	if not focusRoot and lastKnownPosition == Vector3.zero then
		local localRoot = resolveRootPartFromCharacter(self._player.Character)
		if localRoot then
			lastKnownPosition = localRoot.Position
		else
			-- Sin cuerpo (FallenPartsDestroyHeight): delante de donde miraba la cámara.
			local current = camera.CFrame
			lastKnownPosition = current.Position + current.LookVector * CONFIG.endDistance
		end
	end

	camera.CameraType = Enum.CameraType.Scriptable

	self:_playFade(0, CONFIG.fadeToBlackTime)
	task.delay(CONFIG.fadeToBlackTime, function()
		self:_playFade(1, CONFIG.fadeFromBlackTime)
	end)

	-- Encarar al killer desde el primer frame, sin lerp inicial.
	local smoothedDir = if focusRoot then _flatLook(focusRoot) else VEC3_RIGHT
	local camPos = _computeCameraPos(lastKnownPosition, smoothedDir, CONFIG.startDistance, CONFIG.startHeight)
	local lookAtPos = lastKnownPosition + Vector3.new(0, CONFIG.lookHeight, 0)

	local startAt = time()
	local lastResolveAt = 0
	-- Instante del primer intento fallido de resolver al asesino (0 = ninguno).
	local unresolvedSince = 0

	local killerHumanoid: Humanoid? = if focusRoot and focusRoot.Parent
		then focusRoot.Parent:FindFirstChildOfClass("Humanoid") :: Humanoid?
		else nil
	local killerDead = false
	local karmaStartAt = 0
	local karmaFromDistance = CONFIG.startDistance
	local karmaFromHeight = CONFIG.startHeight
	local lastDistance = CONFIG.startDistance
	local lastHeight = CONFIG.startHeight

	-- RespectCanCollide ignora decoración no colisionable (follaje, VFX).
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.IgnoreWater = true
	raycastParams.RespectCanCollide = true
	local filteredKillerChar: Instance? = nil
	-- Se excluyen TODOS los cuerpos para no dar tirones cuando uno cruza por
	-- delante. Se reconstruye solo al cambiar de killer.
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

		-- Espectando, si el enemigo muere se suelta para elegir otro. Con un asesino
		-- real no: su muerte dispara la karma cam.
		if spectating and focusRoot then
			local targetHumanoid = if focusRoot.Parent
				then focusRoot.Parent:FindFirstChildOfClass("Humanoid") :: Humanoid?
				else nil
			if not targetHumanoid or targetHumanoid.Health <= 0 then
				focusRoot = nil
			end
		end

		-- Re-resolución a 10 Hz si el ragdoll se destruyó o el killer respawneó.
		-- En karma cam NO se lee el root: el ragdoll cae erráticamente.
		if focusRoot and focusRoot.Parent and not killerDead then
			lastKnownPosition = focusRoot.Position
			if not killerHumanoid then
				killerHumanoid = focusRoot.Parent:FindFirstChildOfClass("Humanoid") :: Humanoid?
			end
			if focusRoot.Parent ~= filteredKillerChar then
				_refreshOcclusionFilter(focusRoot.Parent)
			end
		elseif not killerDead then
			focusRoot = nil
			local now = time()
			if now - lastResolveAt >= CONFIG.resolveInterval then
				lastResolveAt = now

				--[[
					`hunting` incluye `killerUserId == nil` y no solo `spectating`: al
					morir podía no quedar enemigo vivo, y sin esto la cámara no se
					engancharía al primero que respawnee.
				]]
				local hunting = spectating or killerUserId == nil

				local newRoot: BasePart? = nil
				if hunting then
					newRoot = pickRandomEnemyRoot()
				else
					newRoot = resolveKillerRoot(killerUserId)
				end

				-- maxFollowSnap evita teleportar la cámara al respawn lejano del
				-- asesino. Cambiar de objetivo espectado es un corte deliberado: ahí no
				-- aplica, o casi ningún enemigo lejano pasaría el filtro.
				local accept = newRoot ~= nil
					and (hunting or (newRoot.Position - lastKnownPosition).Magnitude < CONFIG.maxFollowSnap)

				if accept and newRoot then
					unresolvedSince = 0
					spectating = hunting
					focusRoot = newRoot
					lastKnownPosition = newRoot.Position
					killerHumanoid = if newRoot.Parent
						then newRoot.Parent:FindFirstChildOfClass("Humanoid") :: Humanoid?
						else nil
					_refreshOcclusionFilter(newRoot.Parent)

					-- Corte limpio al nuevo objetivo en vez de arrastrar el lerp por el mapa.
					if hunting then
						smoothedDir = _flatLook(newRoot)
						camPos = _computeCameraPos(lastKnownPosition, smoothedDir, lastDistance, lastHeight)
						lookAtPos = lastKnownPosition + Vector3.new(0, CONFIG.lookHeight, 0)
					end
				elseif not hunting then
						-- El asesino no aparece (desconectado, fuera de replicación):
						-- pasado el margen, espectar a un enemigo vivo.
					if unresolvedSince == 0 then
						unresolvedSince = now
					elseif now - unresolvedSince >= CONFIG.spectateFallbackDelay then
						local enemyRoot = pickRandomEnemyRoot()
						if enemyRoot then
							spectating = true
							focusRoot = enemyRoot
							lastKnownPosition = enemyRoot.Position
							killerHumanoid = if enemyRoot.Parent
								then enemyRoot.Parent:FindFirstChildOfClass("Humanoid") :: Humanoid?
								else nil
							_refreshOcclusionFilter(enemyRoot.Parent)
							smoothedDir = _flatLook(enemyRoot)
							camPos = _computeCameraPos(lastKnownPosition, smoothedDir, lastDistance, lastHeight)
							lookAtPos = lastKnownPosition + Vector3.new(0, CONFIG.lookHeight, 0)
						end
					end
				end
			end
		end

		-- Solo con un asesino real: la muerte de un enemigo espectado no es karma de
		-- nadie (arriba se salta a otro).
		if not spectating and not killerDead and killerHumanoid and killerHumanoid.Health <= 0 then
			killerDead = true
			karmaStartAt = time()
			karmaFromDistance = lastDistance
			karmaFromHeight = lastHeight
		end

		-- Tras la muerte se congela: el ragdoll tumba el root y giraría la cámara.
		if focusRoot and not killerDead then
			local dirAlpha = 1 - math.exp(-CONFIG.directionSmoothness * dt)
			local blended = smoothedDir:Lerp(_flatLook(focusRoot), dirAlpha)
			if blended.Magnitude > 0.001 then
				smoothedDir = blended.Unit
			end
		end

		local elapsed = time() - startAt
		local distance, height, lookH, swayScale, posSmooth, lookSmooth
		if killerDead then
			local kT = math.clamp((time() - karmaStartAt) / CONFIG.karmaDuration, 0, 1)
			local kE = 1 - (1 - kT) ^ 3
			distance = karmaFromDistance + (CONFIG.karmaEndDistance - karmaFromDistance) * kE
			height = karmaFromHeight + (CONFIG.karmaEndHeight - karmaFromHeight) * kE
			lookH = CONFIG.lookHeight + (CONFIG.karmaLookHeight - CONFIG.lookHeight) * kE
			swayScale = CONFIG.karmaSwayScale
			posSmooth = CONFIG.karmaPositionSmoothness
			lookSmooth = CONFIG.karmaLookSmoothness
		else
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

		local swayAngle = math.sin(elapsed * CONFIG.swaySpeed) * CONFIG.swayAmplitude * swayScale
		local swayedDir = _swayDir(smoothedDir, swayAngle)

		local pivot = lastKnownPosition
		local targetCamPos = _computeCameraPos(pivot, swayedDir, distance, height)
		local targetLook = pivot + Vector3.new(0, lookH, 0)

		local posAlpha = 1 - math.exp(-posSmooth * dt)
		local lookAlpha = 1 - math.exp(-lookSmooth * dt)
		camPos = camPos:Lerp(targetCamPos, posAlpha)
		lookAtPos = lookAtPos:Lerp(targetLook, lookAlpha)

		local fovAlpha = 1 - math.exp(-CONFIG.fovSmoothness * dt)
		camera.FieldOfView = camera.FieldOfView + (CONFIG.fieldOfView - camera.FieldOfView) * fovAlpha

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

function KillCamFollowController:Destroy()
	self:stop()
	if self._fadeGui then
		self._fadeGui:Destroy()
		self._fadeGui = nil
		self._fadeFrame = nil
	end
end

return KillCamFollowController
