--!strict

-- Kill effect: ragdoll de Default y el cuerpo arde mientras exista el cadáver. Al limpiarse
-- (o empezar a fundirse) el fuego se apaga con su cierre; las partículas terminan su vida
-- aunque el cuerpo ya no esté.
--
-- Reparto: este módulo sólo hace el ragdoll. Todo el fuego lo pinta cada cliente en
-- visuals/killEffects/Burning a partir de la plantilla del place (arte, Rojo no la
-- sincroniza).
-- Tiene que ser así: `ParticleEmitter:Emit()` desde el servidor no se replica, y
-- los tweens del Highlight y la PointLight a 20 Hz por red se verían a saltos.
--
-- Preview (Locker y pase): allí apply corre en CLIENTE (en partida lo aplica el
-- servidor). El fuego arde PREVIEW_BURN_TIME y se marca ENDED para que el cierre se
-- vea con el cuerpo aún en escena; `previewTime` es cuánto debe mantener el preview
-- el cadáver (lo lee KillEffectsRegistry.previewTime).
--
-- Plantilla: ReplicatedStorage.Burning (o ReplicatedStorage.Templates.Burning).
--   Particles/<Limb>/Main        Fire, Smoke, PointLight (sólo UpperTorso) e Ignite
--                                (Burst, BurstEnd, Remnants, Smoke, Smoke2; sólo UpperTorso)
--   Particles/<Limb>/Embers      Embers
--   Highlight                    en cualquier sitio del modelo
-- con <Limb> = UpperTorso, LeftLowerArm, RightLowerArm, LeftLowerLeg, RightLowerLeg.
-- Si la plantilla trae un Script se ignora: el cliente lo destruye al clonarla.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DefaultKillEffect = require(script.Parent.Default)

local Burning = {}

-- Contrato con el cliente (visuals/killEffects/Burning). Cambiar aquí, no en literales.
Burning.ATTR = table.freeze({
	ENDED = "BurningEnded", -- true = apagar ya con el cierre, aunque el cuerpo siga
})
Burning.TEMPLATE_NAME = "Burning"
-- s desde que empieza el cierre hasta que el brillo y la luz quedan apagados.
Burning.ENDING_TIME = 0.5

-- Preview: s de fuego antes del cierre, y cadáver en escena = fuego + cierre.
Burning.PREVIEW_BURN_TIME = 2.5
Burning.previewTime = Burning.PREVIEW_BURN_TIME + Burning.ENDING_TIME

function Burning.findTemplate(): Model?
	local direct = ReplicatedStorage:FindFirstChild(Burning.TEMPLATE_NAME)
	if direct and direct:IsA("Model") then
		return direct
	end
	local templates = ReplicatedStorage:FindFirstChild("Templates")
	local nested = if templates then templates:FindFirstChild(Burning.TEMPLATE_NAME) else nil
	if nested and nested:IsA("Model") then
		return nested
	end
	return nil
end

function Burning.apply(char: Model): boolean
	-- Default devuelve false en rigs no R15 (no los ragdollea); arden igual.
	DefaultKillEffect.apply(char)
	if RunService:IsClient() then
		task.delay(Burning.PREVIEW_BURN_TIME, function()
			if char.Parent then
				char:SetAttribute(Burning.ATTR.ENDED, true)
			end
		end)
	end
	return true
end

return Burning
