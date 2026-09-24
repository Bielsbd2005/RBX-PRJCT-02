--!strict
--[[
	Punto único para las vibraciones. Vive en Shared porque lo usan `src/client` y el
	WeaponsSystem (que corre en cliente aunque esté bajo `src/server/WeaponsSystem`).

	Cada patrón de PATTERNS declara motor, intensidad, duración, pulsos, prioridad y
	cooldown. Garantías:

	  • Un solo patrón sonando a la vez: gana el de mayor prioridad y el perdedor se
	    descarta entero (SetMotor es global: si no, el último pisa al anterior y los
	    task.delay se cruzan).
	  • Cooldown por patrón, para que ráfagas de botón o recargas reiniciadas no
	    conviertan el mando en un zumbido.
	  • `burstGuard` para patrones que el jugador provoca a golpe de dedo: en móvil el
	    motor encola pulsos y un cooldown fijo dejaba vibrando el teléfono tras parar.
	    Cada intento reinicia el cooldown, así una ráfaga vibra solo la primera vez y
	    los de menos prioridad (el UITap del botón) callan hasta que el dedo para.
	  • Respeta el ajuste `Vibration` (attribute en el Player, lo escribe
	    features/settings) y el hardware disponible.

	No-op en servidor y sin motores: play() se puede llamar sin guardas.

	TODO: migrar aquí la implementación propia de Gui/HitFeedback.luau (impactos y
	headshots).
]]

local HapticService = game:GetService("HapticService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local IS_SERVER = RunService:IsServer()

local DebugFlags = require(script.Parent:WaitForChild("DebugFlags"))

-- Debug (solo Studio): ReplicatedStorage.Debug.HapticsDebug = true traza cada play()
-- y por qué NO ha sonado (dispositivo, ajuste, cooldown o prioridad).
local hapticsDebug = if IS_SERVER then nil else DebugFlags.bind(ReplicatedStorage, "HapticsDebug")

local function trace(message: string)
	if hapticsDebug and hapticsDebug() then
		print(`[Haptics] {message}`)
	end
end

export type Pattern = {
	-- "Small" (agudo y seco: ticks, impactos) | "Large" (grave y pesado:
	-- errores, golpes fuertes) | "Both" (cuerpo completo).
	motor: string,
	intensity: number, -- 0..1
	duration: number,  -- segundos de cada pulso
	pulses: number?,   -- default 1
	gap: number?,      -- silencio entre pulsos (default GAP_DEFAULT)
	priority: number,  -- a mayor número, más manda sobre lo que ya suena
	cooldown: number,  -- segundos mínimos entre dos usos del mismo patrón
	-- true = el cooldown cuenta desde el último INTENTO, no desde la última
	-- vez que sonó, y mientras dura silencia a los de menos prioridad.
	burstGuard: boolean?,
}

export type PlayOptions = {
	scale: number?, -- multiplicador de intensidad (0..1 recorta, >1 sube)
}

local GAP_DEFAULT = 0.04

local PATTERNS: { [string]: Pattern } = table.freeze({
	-- Tick apenas perceptible: por encima de ~0.15 cansa al navegar menús un rato largo.
	UITap = {
		motor = "Small", intensity = 0.12, duration = 0.015,
		priority = 1, cooldown = 0.05,
	},
	-- Dos toques cortos: el patrón que la gente asocia a "hecho".
	UISuccess = {
		motor = "Small", intensity = 0.22, duration = 0.03,
		pulses = 2, gap = 0.05,
		priority = 2, cooldown = 0.25,
	},
	-- Uno solo, grave y más largo: se lee como negación sin mirar la pantalla. Sale al
	-- spamear un botón que no puedes usar (de ahí burstGuard).
	UIWarning = {
		motor = "Large", intensity = 0.35, duration = 0.09,
		priority = 2, cooldown = 0.4, burstGuard = true,
	},

	-- Acuse de recibo del input: confirma que la recarga arrancó.
	ReloadStart = {
		motor = "Small", intensity = 0.22, duration = 0.04,
		priority = 3, cooldown = 0.08,
	},
	-- Más cuerpo que ReloadStart para distinguirlos sin mirar el HUD, pero por debajo
	-- del headshot de HitFeedback: la recarga es rutina, no un evento.
	ReloadEnd = {
		motor = "Both", intensity = 0.32, duration = 0.06,
		priority = 3, cooldown = 0.08,
	},

	-- Muy corto y flojo: suenan varios seguidos por kill. El cooldown va justo por
	-- debajo del stagger entre monedas (0.05) para que cada una tenga el suyo.
	CoinLand = {
		motor = "Small", intensity = 0.10, duration = 0.02,
		priority = 1, cooldown = 0.045,
	},
})

local Haptics = {}

type Target = { inputType: Enum.UserInputType, motor: Enum.VibrationMotor }

local INPUT_TYPES = { Enum.UserInputType.Touch, Enum.UserInputType.Gamepad1 }
local MOTORS = { Enum.VibrationMotor.Small, Enum.VibrationMotor.Large }

local _targets: { Target }? = nil
local _generation = 0
-- Motores del patrón que suena ahora; nil cuando ninguno está en el aire.
local _activeTargets: { Target }? = nil
local _activeUntil = 0
local _activePriority = 0
local _lastPlayedAt: { [string]: number } = {}
local _burstUntil = 0
local _burstPriority = 0
local _warnedUnavailable = false

-- El caché se invalida al (des)conectar un mando para no dejar mudo al que
-- enchufa el pad a mitad de partida.
if not IS_SERVER then
	UserInputService.GamepadConnected:Connect(function()
		_targets = nil
		_warnedUnavailable = false
	end)
	UserInputService.GamepadDisconnected:Connect(function()
		local active = _activeTargets
		_activeTargets = nil
		if active then
			pcall(function()
				for _, target in active do
					HapticService:SetMotor(target.inputType, target.motor, 0)
				end
			end)
		end
		_targets = nil
	end)
end

local function getTargets(): { Target }
	local cached = _targets
	if cached then
		return cached
	end

	local found: { Target } = {}
	for _, inputType in INPUT_TYPES do
		for _, motor in MOTORS do
			local ok, supported = pcall(function()
				return HapticService:IsMotorSupported(inputType, motor)
			end)
			if ok and supported then
				table.insert(found, { inputType = inputType, motor = motor })
			end
		end
	end

	_targets = found
	return found
end

-- Táctil y mando son los dos únicos inputs con motor. En PC con teclado y
-- ratón nos ahorramos incluso el pcall de IsMotorSupported.
local function hasHapticInput(): boolean
	return UserInputService.TouchEnabled or UserInputService.GamepadEnabled
end

local function availability(): (boolean, string?)
	if IS_SERVER then
		return false, "corriendo en servidor"
	end

	local player = Players.LocalPlayer
	if not player then
		return false, "sin LocalPlayer"
	end

	-- nil = activado (default de DataTemplate); solo `false` apaga.
	if player:GetAttribute("Vibration") == false then
		return false, "el ajuste Vibration está desactivado"
	end

	if not hasHapticInput() then
		return false, "dispositivo sin táctil ni mando (un PC con teclado y ratón no tiene motor)"
	end

	if #getTargets() == 0 then
		return false, "HapticService no reporta motores soportados en este dispositivo"
	end

	return true, nil
end

local function targetsForMotor(motorKind: string): { Target }
	local all = getTargets()
	if motorKind == "Both" then
		return all
	end

	local wanted = if motorKind == "Large" then Enum.VibrationMotor.Large else Enum.VibrationMotor.Small
	local filtered: { Target } = {}
	for _, target in all do
		if target.motor == wanted then
			table.insert(filtered, target)
		end
	end

	-- Un dispositivo que solo expone uno de los dos motores (típico en móvil)
	-- se quedaría mudo al filtrar. Mejor el motor equivocado que ninguno.
	if #filtered == 0 then
		return all
	end
	return filtered
end

local function setMotors(targets: { Target }, value: number)
	pcall(function()
		for _, target in targets do
			HapticService:SetMotor(target.inputType, target.motor, value)
		end
	end)
end

function Haptics.play(patternName: string, options: PlayOptions?)
	if IS_SERVER then
		return
	end

	local pattern = PATTERNS[patternName]
	if not pattern then
		warn(`[Haptics] Patrón desconocido: {patternName}`)
		return
	end

	local available, reason = availability()
	if not available then
		-- Un único warn por sesión: en un móvil real no hay consola delante,
		-- pero el log del cliente sí queda.
		if not _warnedUnavailable then
			_warnedUnavailable = true
			warn(`[Haptics] Vibración no disponible: {reason}`)
		end
		trace(`{patternName} descartado — {reason}`)
		return
	end

	local now = os.clock()

	-- Una ráfaga sigue viva: lo de menos peso no suena. Va antes que el propio
	-- burstGuard porque el UITap del botón llega antes que el warning.
	if now < _burstUntil and pattern.priority < _burstPriority then
		trace(`{patternName} descartado — ráfaga en curso (prioridad {_burstPriority})`)
		return
	end

	local inCooldown = now - (_lastPlayedAt[patternName] or 0) < pattern.cooldown

	-- Cada intento, suene o no, reinicia la ventana: spamear la mantiene cerrada.
	if pattern.burstGuard then
		_burstPriority = if now < _burstUntil then math.max(_burstPriority, pattern.priority) else pattern.priority
		_burstUntil = now + pattern.cooldown
		_lastPlayedAt[patternName] = now
	end

	if inCooldown then
		trace(`{patternName} descartado — en cooldown ({pattern.cooldown}s)`)
		return
	end

	-- Otro patrón sigue en el aire: solo lo interrumpe algo de más peso.
	if now < _activeUntil and pattern.priority < _activePriority then
		trace(`{patternName} descartado — suena algo de más prioridad ({_activePriority})`)
		return
	end

	local pulses = math.max(pattern.pulses or 1, 1)
	local gap = pattern.gap or GAP_DEFAULT
	local intensity = math.clamp(pattern.intensity * ((options and options.scale) or 1), 0, 1)
	local targets = targetsForMotor(pattern.motor)

	_lastPlayedAt[patternName] = now
	_activeUntil = now + pattern.duration * pulses + gap * (pulses - 1)
	_activePriority = pattern.priority

	-- El patrón interrumpido sale sin tocar motores (para no cortar el pulso del nuevo),
	-- así que los que él usaba y el nuevo no, se apagan aquí o vibrarían sin fin.
	local previousTargets = _activeTargets
	if previousTargets then
		local orphaned: { Target } = {}
		for _, old in previousTargets do
			local shared = false
			for _, new in targets do
				if new.inputType == old.inputType and new.motor == old.motor then
					shared = true
					break
				end
			end
			if not shared then
				table.insert(orphaned, old)
			end
		end
		setMotors(orphaned, 0)
	end
	_activeTargets = targets

	_generation += 1
	local generation = _generation

	trace(`{patternName} → motor {pattern.motor}, intensidad {intensity}, {pulses} pulso(s)`)

	task.spawn(function()
		for i = 1, pulses do
			-- Si otro play() ganó mientras dormíamos, él es quien manda sobre
			-- los motores ahora: salimos sin tocarlos (incluido el SetMotor 0,
			-- que cortaría su pulso).
			if _generation ~= generation then
				return
			end
			setMotors(targets, intensity)

			task.wait(pattern.duration)
			if _generation ~= generation then
				return
			end
			setMotors(targets, 0)

			if i < pulses then
				task.wait(gap)
			end
		end

		if _generation == generation then
			_activeUntil = 0
			_activePriority = 0
			_activeTargets = nil
		end
	end)
end

return Haptics
