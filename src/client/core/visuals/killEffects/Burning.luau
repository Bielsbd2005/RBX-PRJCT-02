--!strict
--[[
	Kill effect Burning, parte de cliente (Shared.Locker.killEffects.Burning solo hace
	el ragdoll): se clona la plantilla del place y se suelda a las extremidades.

	El fuego se apaga (cierre completo) cuando el cadáver se destruye, empieza a
	fundirse (KillEffectFadeOut) o se marca Burning.ATTR.ENDED. La plantilla vive
	fuera del cadáver y fuera del contexto: las partículas del cierre no se cortan.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Burning = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Locker"):WaitForChild("killEffects"):WaitForChild("Burning")
)
local Types = require(script.Parent.Parent.KillEffectTypes)

local ATTR = Burning.ATTR

-- Mismo literal que RagdollCleanup/CharacterHighlightController: el server lo pone
-- en el cadáver al empezar a disolverlo, con la duración del fundido.
local FADE_OUT_ATTR = "KillEffectFadeOut"

local CONFIG = {
	IGNITE_AT = 0.075,
	GLOW_AT = 0.125,
	GLOW_IN_TIME = 0.25,
	GLOW_FILL = -1, -- <0 a propósito: el fill satura antes de acabar el tween
	GLOW_OUTLINE = 0.75,
	LIGHT_BRIGHTNESS = 7,
	GLOW_OUT_TIME = 0.375,
	SMOKE_AFTER_END = 0.2,
	LATE_TOLERANCE = 0.25, -- s de retraso máximo con el que aún se dispara un Emit
	CULL_DISTANCE = 300, -- studs desde la cámara

	-- name: pieza en Particles de la plantilla; r6Offset solo se aplica en R6.
	LIMBS = {
		{ name = "UpperTorso", r15 = "UpperTorso", r6 = "Torso", r6Offset = CFrame.new(0, 0.334, 0) },
		{ name = "LeftLowerArm", r15 = "LeftLowerArm", r6 = "Left Arm", r6Offset = CFrame.new(0, -0.5, 0) },
		{ name = "RightLowerArm", r15 = "RightLowerArm", r6 = "Right Arm", r6Offset = CFrame.new(0, -0.5, 0) },
		{ name = "LeftLowerLeg", r15 = "LeftLowerLeg", r6 = "Left Leg", r6Offset = CFrame.new(0, -0.5, 0) },
		{ name = "RightLowerLeg", r15 = "RightLowerLeg", r6 = "Right Leg", r6Offset = CFrame.new(0, -0.5, 0) },
	},
	LOOP_EMITTERS = { { "Main", "Fire" }, { "Main", "Smoke" }, { "Embers", "Embers" } },
}

type Burn = {
	clone: Model,
	loops: { ParticleEmitter },
	ignite: Instance?,
	light: PointLight?,
	highlight: Highlight?,
	igniteThread: thread?,
	endThread: thread?,
	ending: boolean,
	conns: { RBXScriptConnection },
}

local BurningVisuals = {}

local _burns: { [Instance]: Burn } = {}
local _folder: Folder? = nil
local _warnedMissing = false

local function debugWarn(message: string)
	if RunService:IsStudio() then
		warn("[BurningVisuals] " .. message)
	end
end

local function getFolder(): Folder
	if _folder and _folder.Parent then
		return _folder
	end
	local folder = Instance.new("Folder")
	folder.Name = "BurningVisuals"
	folder.Parent = workspace
	_folder = folder
	return folder
end

local function findPath(root: Instance, path: { string }): Instance?
	local node: Instance? = root
	for _, childName in path do
		if not node then
			return nil
		end
		node = node:FindFirstChild(childName)
	end
	return node
end

local function emit(parent: Instance?, emitterName: string)
	local emitter = if parent then parent:FindFirstChild(emitterName) else nil
	if emitter and emitter:IsA("ParticleEmitter") then
		emitter:Emit(1)
	end
end

local function tween(instance: Instance, time: number, goal: { [string]: any })
	TweenService:Create(instance, TweenInfo.new(time, Enum.EasingStyle.Linear), goal):Play()
end

local function setAnchored(root: Instance, anchored: boolean)
	for _, desc in root:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = anchored
		end
	end
end

local function maxParticleLifetime(root: Instance): number
	local longest = 0
	for _, desc in root:GetDescendants() do
		if desc:IsA("ParticleEmitter") then
			longest = math.max(longest, desc.Lifetime.Max)
		end
	end
	return longest
end

local function cancelThread(thread: thread?)
	if thread and coroutine.status(thread) ~= "dead" and coroutine.running() ~= thread then
		task.cancel(thread)
	end
end

local function buildClone(template: Model, char: Model): (Model, { ParticleEmitter })
	local clone = template:Clone()
	for _, desc in clone:GetDescendants() do
		if desc:IsA("BaseScript") then
			-- El Highlight de la plantilla original cuelga del Script: rescatarlo.
			for _, child in desc:GetChildren() do
				child.Parent = clone
			end
			desc:Destroy()
		end
	end

	local particles = clone:FindFirstChild("Particles")
	local loops: { ParticleEmitter } = {}

	for _, limb in CONFIG.LIMBS do
		local piece = if particles then particles:FindFirstChild(limb.name) else nil
		if not piece then
			continue
		end
		local target = char:FindFirstChild(limb.r15)
		local offset = CFrame.identity
		if not (target and target:IsA("BasePart")) then
			target = char:FindFirstChild(limb.r6)
			offset = limb.r6Offset
		end
		if not (target and target:IsA("BasePart")) then
			-- Sin extremidad (streaming, rig raro): la pieza sobra.
			piece:Destroy()
			continue
		end
		local targetPart = target :: BasePart

		if piece:IsA("PVInstance") then
			piece:PivotTo(targetPart.CFrame * offset)
		end
		for _, desc in piece:GetDescendants() do
			if desc:IsA("BasePart") then
				desc.CanCollide = false
				desc.CanQuery = false
				desc.CanTouch = false
				desc.Massless = true
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = desc
				weld.Part1 = targetPart
				weld.Parent = desc
			end
		end
		for _, path in CONFIG.LOOP_EMITTERS do
			local emitter = findPath(piece, path)
			if emitter and emitter:IsA("ParticleEmitter") then
				emitter.Enabled = false
				table.insert(loops, emitter)
			end
		end
	end

	return clone, loops
end

local function finish(char: Instance)
	local burn = _burns[char]
	if not burn then
		return
	end
	_burns[char] = nil
	for _, conn in burn.conns do
		conn:Disconnect()
	end
	cancelThread(burn.igniteThread)
	cancelThread(burn.endThread)
	burn.clone:Destroy()
end

local function startEnding(char: Model, burn: Burn, glowOutTime: number)
	if burn.ending then
		return
	end
	burn.ending = true
	cancelThread(burn.igniteThread)

	for _, emitter in burn.loops do
		emitter.Enabled = false
	end
	emit(burn.ignite, "BurstEnd")
	emit(burn.ignite, "Remnants")
	if burn.highlight then
		tween(burn.highlight, glowOutTime, { FillTransparency = 1, OutlineTransparency = 1 })
	end
	if burn.light then
		tween(burn.light, glowOutTime, { Brightness = 0 })
	end

	burn.endThread = task.spawn(function()
		task.wait(CONFIG.SMOKE_AFTER_END)
		emit(burn.ignite, "Smoke")
		emit(burn.ignite, "Smoke2")
		task.wait(Burning.ENDING_TIME - CONFIG.SMOKE_AFTER_END)
		if burn.highlight then
			burn.highlight.Enabled = false
		end
		if burn.light then
			burn.light.Enabled = false
		end
		-- Las partículas del cierre viven su Lifetime entero antes de retirar la plantilla.
		task.wait(maxParticleLifetime(burn.clone))
		finish(char)
	end)
end

-- Espera hasta `at` s desde la muerte. false = ese momento pasó hace más de
-- LATE_TOLERANCE (para saltarse los Emit puntuales).
local function reach(startedAt: number, at: number): boolean
	local remaining = at - (workspace:GetServerTimeNow() - startedAt)
	if remaining > 0 then
		task.wait(remaining)
		return true
	end
	return remaining > -CONFIG.LATE_TOLERANCE
end

local function igniteSequence(burn: Burn, startedAt: number)
	if reach(startedAt, CONFIG.IGNITE_AT) then
		emit(burn.ignite, "Burst")
	end
	reach(startedAt, CONFIG.GLOW_AT)
	local highlight = burn.highlight
	if highlight then
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 1
		highlight.Enabled = true
		tween(highlight, CONFIG.GLOW_IN_TIME, { FillTransparency = CONFIG.GLOW_FILL, OutlineTransparency = CONFIG.GLOW_OUTLINE })
	end
	local light = burn.light
	if light then
		light.Brightness = 0
		light.Enabled = true
		tween(light, CONFIG.GLOW_IN_TIME, { Brightness = CONFIG.LIGHT_BRIGHTNESS })
	end
end

local function begin(char: Model, startedAt: number)
	local template = Burning.findTemplate()
	if not template then
		if not _warnedMissing then
			_warnedMissing = true
			debugWarn("no hay plantilla ReplicatedStorage." .. Burning.TEMPLATE_NAME .. " (ni en Templates): el fuego no se ve")
		end
		return
	end

	local clone, loops = buildClone(template, char)
	local main = findPath(clone, { "Particles", "UpperTorso", "Main" })
	local lightInstance = if main then main:FindFirstChildWhichIsA("PointLight") else nil
	local highlightInstance = clone:FindFirstChildWhichIsA("Highlight", true)

	local burn: Burn = {
		clone = clone,
		loops = loops,
		ignite = if main then main:FindFirstChild("Ignite") else nil,
		light = if lightInstance then lightInstance :: PointLight else nil,
		highlight = if highlightInstance then highlightInstance :: Highlight else nil,
		igniteThread = nil,
		endThread = nil,
		ending = false,
		conns = {},
	}
	_burns[char] = burn

	if burn.highlight then
		burn.highlight.Enabled = false
		-- Fuera del cadáver no abarcaría el cuerpo: apuntarlo explícitamente.
		burn.highlight.Adornee = char
	end
	if burn.light then
		burn.light.Enabled = false
	end

	clone.Parent = getFolder()
	setAnchored(clone, false)
	for _, emitter in loops do
		emitter.Enabled = true
	end

	-- Síncrono dentro del Destroy, antes del step de física: anclar ya o la
	-- plantilla cae un frame al romperse las soldaduras.
	table.insert(burn.conns, char.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			setAnchored(clone, true)
			if burn.highlight then
				burn.highlight.Enabled = false
			end
			startEnding(char, burn, CONFIG.GLOW_OUT_TIME)
		end
	end))
	table.insert(burn.conns, char:GetAttributeChangedSignal(FADE_OUT_ATTR):Connect(function()
		local fadeTime = char:GetAttribute(FADE_OUT_ATTR)
		if type(fadeTime) == "number" and fadeTime > 0 then
			startEnding(char, burn, fadeTime)
		end
	end))
	table.insert(burn.conns, char:GetAttributeChangedSignal(ATTR.ENDED):Connect(function()
		if char:GetAttribute(ATTR.ENDED) == true then
			startEnding(char, burn, CONFIG.GLOW_OUT_TIME)
		end
	end))

	burn.igniteThread = task.spawn(igniteSequence, burn, startedAt)
end

function BurningVisuals.play(char: Model, ctx: Types.Ctx)
	if _burns[char] then
		return
	end
	-- Llega tarde a un fuego que ya se estaba apagando: no pintar solo el final.
	if char:GetAttribute(ATTR.ENDED) == true or char:GetAttribute(FADE_OUT_ATTR) ~= nil then
		return
	end

	local camera = workspace.CurrentCamera
	if camera and (camera.CFrame.Position - char:GetPivot().Position).Magnitude > CONFIG.CULL_DISTANCE then
		return
	end

	local ok, err = pcall(begin, char, ctx.startedAt)
	if not ok then
		debugWarn(tostring(err))
		finish(char)
	end
end

function BurningVisuals.stop()
	for instance in table.clone(_burns) do
		finish(instance)
	end
	if _folder then
		_folder:Destroy()
		_folder = nil
	end
end

return BurningVisuals
