--!strict

-- Kill effect "XP Drop": el cuerpo desaparece y salen orbes que, si alguien vivo se
-- acerca, vuelan hacia él y se recogen con sonido. No dan XP real.
--
-- Aquí solo se oculta el cuerpo y se marca con `XpOrbs.TAG` + atributos; orbes,
-- atracción y sonido son de XpOrbsVisuals (cliente). Nada viaja por red: el abanico
-- sale de la semilla y cada cliente simula la recogida.
--
-- Los orbes NO cuelgan del cadáver: el jugador respawnea antes de que se apaguen.
-- En preview (apply en CLIENTE) no hay quien los recoja y el cliente los lleva a la cámara.
--
-- El cuerpo se OCULTA, no se destruye: sus dueños (MatchService, AIService, Locker,
-- ScenePreview) lo destruyen, y la cámara de muerte sigue mirando su HumanoidRootPart.
--
-- Plantilla OPCIONAL: ReplicatedStorage.Xp o ReplicatedStorage.Templates.Xp con un
-- BillboardGui y dentro el ImageLabel "Image". Sin ella el cliente pinta un círculo.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Utils = require(script.Parent.Utils)

local XpOrbs = {}

-- Contrato con el cliente (XpOrbsVisuals). Cambiar aquí, no en literales.
XpOrbs.TAG = "KillEffectXpOrbs"
XpOrbs.ATTR = table.freeze({
	STARTED_AT = "XpOrbsStartedAt", -- GetServerTimeNow() al morir: sincroniza a quien llega tarde
	ORIGIN = "XpOrbsOrigin", -- Vector3 del centro del torso al morir
	SCALE = "XpOrbsScale", -- 1 = cuerpo normal (ScenePreview escala el maniquí)
	SEED = "XpOrbsSeed", -- abanico de salida, igual para todos
	LIFETIME = "XpOrbsLifetime", -- s que vive cada orbe desde que sale
	PICKUP = "XpOrbsPickup", -- false = no hay quien los recoja; en el preview se los lleva la cámara
})
XpOrbs.COLORS = table.freeze({
	Color3.fromRGB(251, 235, 85),
	Color3.fromRGB(190, 255, 165),
})
XpOrbs.TEMPLATE_NAME = "Xp"

XpOrbs.MATCH_LIFETIME = 15
XpOrbs.PREVIEW_LIFETIME = 3
XpOrbs.previewTime = XpOrbs.PREVIEW_LIFETIME

function XpOrbs.findTemplate(): BillboardGui?
	local holder = ReplicatedStorage:FindFirstChild(XpOrbs.TEMPLATE_NAME)
	if not holder then
		local templates = ReplicatedStorage:FindFirstChild("Templates")
		holder = if templates then templates:FindFirstChild(XpOrbs.TEMPLATE_NAME) else nil
	end
	if not holder then
		return nil
	end
	if holder:IsA("BillboardGui") then
		return holder
	end
	local direct = holder:FindFirstChild("BillboardGui")
	if direct and direct:IsA("BillboardGui") then
		return direct
	end
	return holder:FindFirstChildWhichIsA("BillboardGui", true) :: BillboardGui?
end

-- Centro del torso al morir (no char:GetPivot(), que en el doble del Locker se queda
-- donde estaba la plantilla).
local function bodyCenter(char: Model): Vector3
	for _, name in { "UpperTorso", "Torso", "HumanoidRootPart", "LowerTorso" } do
		local part = char:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part.Position
		end
	end
	return char:GetPivot().Position
end

-- 1 para un personaje normal (HRP de 2 studs de alto).
local function bodyScale(char: Model): number
	local root = char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return math.max(root.Size.Y / 2, 0.5)
	end
	return 1
end

-- No basta con apagar CanCollide: un Humanoid vivo lo re-enciende cada step y el
-- grupo Characters choca con los vivos. Por eso se congela el Humanoid, se pasa al
-- grupo RAGDOLL (makeCorpseInert) y se reafirma CanCollide un step después.
local function hideCharacter(char: Model)
	local humanoid = char:FindFirstChildWhichIsA("Humanoid", true)
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		Utils.releaseHumanoid(humanoid)
	end

	local parts: { BasePart } = {}
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Transparency = 1
		elseif d:IsA("Decal") then -- Texture hereda de Decal
			d.Transparency = 1
		elseif
			d:IsA("ParticleEmitter")
			or d:IsA("Trail")
			or d:IsA("Beam")
			or d:IsA("Light")
			or d:IsA("Fire")
			or d:IsA("Smoke")
			or d:IsA("Sparkles")
			or d:IsA("LayerCollector")
			or d:IsA("Highlight")
		then
			(d :: any).Enabled = false
		end
	end

	Utils.makeCorpseInert(char)

	RunService.Heartbeat:Once(function()
		for _, part in parts do
			if part.Parent then
				part.CanCollide = false
			end
		end
	end)
end

local rng = Random.new()

function XpOrbs.apply(char: Model): boolean
	-- ANTES de ocultar: dónde estaba el cuerpo y de qué tamaño era.
	local origin = bodyCenter(char)
	local scale = bodyScale(char)
	local isPreview = RunService:IsClient()

	hideCharacter(char)

	-- Atributos antes que el tag: llegan juntos al cliente y track() los lee ya.
	char:SetAttribute(XpOrbs.ATTR.ORIGIN, origin)
	char:SetAttribute(XpOrbs.ATTR.SCALE, scale)
	char:SetAttribute(XpOrbs.ATTR.SEED, rng:NextInteger(1, 2 ^ 30))
	char:SetAttribute(XpOrbs.ATTR.LIFETIME, if isPreview then XpOrbs.PREVIEW_LIFETIME else XpOrbs.MATCH_LIFETIME)
	char:SetAttribute(XpOrbs.ATTR.PICKUP, not isPreview)
	char:SetAttribute(XpOrbs.ATTR.STARTED_AT, workspace:GetServerTimeNow())
	char:AddTag(XpOrbs.TAG)
	return true
end

return XpOrbs
