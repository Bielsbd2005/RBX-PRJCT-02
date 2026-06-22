-- DamageBillboardHandler.module.lua (Client)
-- High-RPM optimized floating damage + hit FX (single desktop profile: no mobile distinctions).
-- UIStroke always enabled with desktop-grade settings.

--// Services (cached)
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local SoundService      = game:GetService("SoundService")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Abort on server
if RunService:IsServer() then
	return {}
end

--// Config (cached references)
local cfgRoot             = script.Parent.Parent.Configuration
local HeadshotMultiplier  = cfgRoot:WaitForChild("HeadshotMultiplier")  -- NumberValue

--// LocalPlayer safe fetch
local localPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

--// Cached PlayerGui (avoids WaitForChild on every new billboard)
local playerGui = localPlayer:WaitForChild("PlayerGui")

--// Cached camera (avoids property lookup on every hit)
local currentCamera = Workspace.CurrentCamera
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	currentCamera = Workspace.CurrentCamera
end)

--// Team resolution via shared TeamUtils
local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)

--// Cached attacker side (avoids recomputing on every hit)
local attackerSide: string? = TeamUtils.getSide(localPlayer.Character)
local function refreshAttackerTeam()
	attackerSide = TeamUtils.getSide(localPlayer.Character)
end
localPlayer:GetPropertyChangedSignal("Team"):Connect(refreshAttackerTeam)
localPlayer.CharacterAdded:Connect(function()
	task.defer(refreshAttackerTeam)
end)
localPlayer.AttributeChanged:Connect(function(attr)
	if attr == "TeamName" then
		refreshAttackerTeam()
	end
end)

--// isCoreModel cache (avoids repeated string ops per model)
local coreModelCache = setmetatable({}, { __mode = "k" }) -- model -> bool

local function isCoreModel(model: Model?): boolean
	if not model then
		return false
	end

	local cached = coreModelCache[model]
	if cached ~= nil then
		return cached
	end

	local result = false
	repeat
		if model:GetAttribute("IsCore") == true or model:GetAttribute("IsBaseCore") == true then
			result = true
			break
		end

		if model:GetAttribute("CoreType") ~= nil or model:GetAttribute("CoreOwner") ~= nil then
			result = true
			break
		end

		if string.find(string.lower(model.Name), "core", 1, true) then
			result = true
			break
		end

		if (model:GetAttribute("TeamName") or model:FindFirstChild("Team")) and not model:FindFirstChildWhichIsA("Humanoid") then
			result = true
			break
		end
	until true

	coreModelCache[model] = result
	return result
end

local function shouldSkipFriendlyTargetFx(adornee: Instance?): boolean
	if not adornee then
		return false
	end

	-- Fast-path: if attacker has no team, never skip
	if not attackerSide then
		return false
	end

	local targetModel: Model?
	if adornee:IsA("Model") then
		targetModel = adornee
	else
		targetModel = adornee:FindFirstAncestorOfClass("Model")
	end

	if not targetModel then
		return false
	end

	-- Solo bloqueamos FX para entidades de combate (jugadores/bots con Humanoid).
	if not targetModel:FindFirstChildOfClass("Humanoid") then
		return false
	end

	local targetSide = TeamUtils.getSide(targetModel)
	if not targetSide then
		return false
	end

	return attackerSide == targetSide
end

--// Cached folders
local UIFolder = SoundService:WaitForChild("Audio"):WaitForChild("Gameplay")
--// Constants
local V3_BILLBOARD_OFFSET = Vector3.new(0, 5, 0)

-- Colors
local COLOR_NORMAL_TEXT   = Color3.fromRGB(255, 255, 255)  -- normal hits text
local COLOR_NORMAL_STROKE = Color3.fromRGB(0, 0, 0)        -- normal hits stroke
local COLOR_HEADSHOT_TEXT = Color3.fromRGB(255, 210, 70)   -- headshot text (dorado)
local COLOR_HEADSHOT_STROKE = Color3.fromRGB(92, 56, 12)   -- headshot stroke (marrón oscuro)

-- TweenInfos
local TI_NUM_APPEAR   = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Flotación: sube y se desvanece en un único gesto, desacelerando (Out). Sin
-- tramo de caída — el descenso de vuelta al origen era lo que hacía parecer que
-- el número "desaparecía y reaparecía".
local TI_NUM_FLOAT    = TweenInfo.new(1.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Geometría de la flotación (en scale del billboard)
local FLOAT_RISE      = 1.1  -- cuánto sube en total
local FLOAT_DRIFT_X   = 0.4  -- deriva horizontal máxima (±), da un toque orgánico
local FLOAT_MAX_ROT   = 14   -- rotación final (±)

-- Desktop-only profile (no mobile distinctions)
local MAX_UI_DISTANCE     = 200
local MAX_ACTIVE_LABELS   = 10
-- MERGE_WINDOW removed: each hit renders its own number immediately.
-- MAX_ACTIVE_LABELS caps simultaneous labels per target to stay readable.

-- Rendering knobs (desktop)
local NORMAL_STROKE_THICK = 2
local HEAD_STROKE_THICK   = 3

-- RNG
local RNG = Random.new()

--// Progressive pitch
local SoundProgression = {
	hitCount = 0,
	lastHitTime = 0,
	resetDelay = 0.20,
	basePitch = 0.95,
	pitchIncrement = 0.14,
	maxPitch = 2.6,
}
local function getCurrentPitch()
	local t = time()
	if (t - SoundProgression.lastHitTime) > SoundProgression.resetDelay then
		SoundProgression.hitCount = 0
	end
	SoundProgression.lastHitTime = t
	SoundProgression.hitCount += 1
	local pitch = SoundProgression.basePitch + (SoundProgression.hitCount - 1) * SoundProgression.pitchIncrement
	return (pitch < SoundProgression.maxPitch) and pitch or SoundProgression.maxPitch
end

--// Audio pooling
local soundPools = {}  -- name -> { items = {Sound,...}, idx = 1 }
local function getPooledSound(name: string)
	local pool = soundPools[name]
	if not pool then
		pool = { items = {}, idx = 1 }
		local template = UIFolder:FindFirstChild(name)
		if template then
			for i = 1, 5 do
				local s = template:Clone()
				s.Parent = UIFolder
				pool.items[i] = s
			end
		end
		soundPools[name] = pool
	end
	local items = pool.items
	if #items == 0 then return nil end
	local s = items[pool.idx]
	pool.idx = (pool.idx % #items) + 1
	return s
end

local function setPitchGeneric(audioObj: Sound, value: number)
	audioObj.PlaybackSpeed = value
	local pitchShift = audioObj:FindFirstChildOfClass("PitchShiftSoundEffect")
	if pitchShift then
		pitchShift.Octave = value
	end
end

local function playUIAudio(name: string, pitch: number)
	local inst = getPooledSound(name)
	if not inst then return end
	local jitter = RNG:NextNumber(-0.05, 0.05)
	setPitchGeneric(inst, math.max(0.2, pitch + jitter))
	inst.TimePosition = 0
	inst:Play()
end

--// Billboard pools per adornee
local adorneeToBillboardGui = setmetatable({}, { __mode = "k" })
local billboardLabelPool    = setmetatable({}, { __mode = "k" }) -- billboard -> {labels}
local billboardActiveCount  = setmetatable({}, { __mode = "k" }) -- billboard -> int

local UDim2_CENTER       = UDim2.fromScale(0.5, 0.5)
local UDim2_APPEAR_START = UDim2.fromScale(0.48, 0.48)
local UDim2_APPEAR_END   = UDim2.fromScale(0.66, 0.66)

--// UIStroke cache per label (avoids FindFirstChildOfClass on every render)
local labelStrokes = setmetatable({}, { __mode = "k" }) -- label -> UIStroke

local function ensureStroke(label: TextLabel): UIStroke
	local cached = labelStrokes[label]
	if cached then return cached end

	local stroke = label:FindFirstChildOfClass("UIStroke")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Name = "Outline"
		stroke.LineJoinMode = Enum.LineJoinMode.Round
		stroke.Color = COLOR_NORMAL_STROKE
		stroke.Thickness = NORMAL_STROKE_THICK
		stroke.Transparency = 0
		stroke.Parent = label
	end
	labelStrokes[label] = stroke
	return stroke
end

local function resetLabelVisual(label: TextLabel, isHeadshot: boolean?)
	label.Visible = true
	label.Size = UDim2_APPEAR_START
	label.TextTransparency = 0
	label.Position = UDim2_CENTER
	label.Rotation = 0

	-- Number color
	label.TextColor3 = isHeadshot and COLOR_HEADSHOT_TEXT or COLOR_NORMAL_TEXT

	-- UIStroke (outline thickness) — use cache
	local stroke = ensureStroke(label)
	stroke.Color = isHeadshot and COLOR_HEADSHOT_STROKE or COLOR_NORMAL_STROKE
	stroke.Thickness = isHeadshot and HEAD_STROKE_THICK or NORMAL_STROKE_THICK
	stroke.Transparency = isHeadshot and 0 or 0.8
end

local function getBillboardLabel(billboard: BillboardGui, isHeadshot: boolean): TextLabel?
	local active = billboardActiveCount[billboard] or 0
	if active >= MAX_ACTIVE_LABELS then
		return nil -- throttle when crowded
	end

	local pool = billboardLabelPool[billboard]
	if pool and #pool > 0 then
		local lbl = pool[#pool]
		pool[#pool] = nil
		resetLabelVisual(lbl, isHeadshot)
		billboardActiveCount[billboard] = active + 1
		return lbl
	end

	-- Create new label (configured once)
	local damageNumber = Instance.new("TextLabel")
	damageNumber.Name = "DamageNumber"
	damageNumber.AnchorPoint = Vector2.new(0.5, 0.5)
	damageNumber.BackgroundTransparency = 1
	damageNumber.BorderSizePixel = 0
	damageNumber.Position = UDim2_CENTER
	damageNumber.Size = UDim2_APPEAR_START
	damageNumber.Font = Enum.Font.GothamBlack
	damageNumber.TextScaled = true
	damageNumber.TextXAlignment = Enum.TextXAlignment.Center
	damageNumber.TextYAlignment = Enum.TextYAlignment.Center
	damageNumber.Parent = billboard

	-- Attach UIStroke & reset visuals (ensureStroke populates cache)
	ensureStroke(damageNumber)
	resetLabelVisual(damageNumber, isHeadshot)

	billboardActiveCount[billboard] = active + 1
	return damageNumber
end

local function releaseBillboardLabel(billboard: BillboardGui, label: TextLabel)
	label.Visible = false
	local count = billboardActiveCount[billboard]
	if count and count > 0 then
		billboardActiveCount[billboard] = count - 1
	end
	local pool = billboardLabelPool[billboard]
	if not pool then
		pool = {}
		billboardLabelPool[billboard] = pool
	end
	pool[#pool + 1] = label
end

--// Utils
local function getHeadFromAdornee(adornee: Instance?): BasePart?
	if not adornee then return nil end
	if adornee:IsA("BasePart") and adornee.Name == "Head" then
		return adornee
	end
	local parent = adornee.Parent
	if parent and parent:IsA("Model") then
		return parent:FindFirstChild("Head")
	end
	return nil
end

local function getWorldPos(adornee: Instance?): Vector3?
	if not adornee or not adornee.Parent then return nil end
	if adornee:IsA("BasePart") then
		return adornee.Position
	end
	local head = getHeadFromAdornee(adornee)
	if head then return head.Position end
	local parent = adornee.Parent
	if parent and parent:IsA("Model") and parent.PrimaryPart then
		return parent.PrimaryPart.Position
	end
	return nil
end

-- Create Billboard
local function createBillboard(adornee: Instance): BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DamageBillboardGui"
	billboard.Adornee = adornee
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.ExtentsOffsetWorldSpace = V3_BILLBOARD_OFFSET
	billboard.Size = UDim2.new(3, 0, 3, 0)
	billboard.ResetOnSpawn = false
	billboard.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	billboard.MaxDistance = MAX_UI_DISTANCE
	billboard.Parent = playerGui  -- cached; no WaitForChild overhead
	return billboard
end

local DamageBillboardHandler = {}

function DamageBillboardHandler:CreateBillboardForAdornee(adornee: Instance): BillboardGui
	local billboard = adorneeToBillboardGui[adornee]
	if billboard then return billboard end

	billboard = createBillboard(adornee)
	adorneeToBillboardGui[adornee] = billboard

	-- Auto-cleanup on adornee removal
	local ancestorCon
	ancestorCon = adornee.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			ancestorCon:Disconnect()
			local bb = adorneeToBillboardGui[adornee]
			if bb then
				adorneeToBillboardGui[adornee] = nil
				billboardLabelPool[bb] = nil
				billboardActiveCount[bb] = nil
				bb:Destroy()
			end
		end
	end)

	return billboard
end

-- Render a single number con trayectoria en arco (sube a un ápex y cae con gravedad)
local function renderNumber(billboard: BillboardGui, value: number, isHeadshot: boolean)
	local label = getBillboardLabel(billboard, isHeadshot)
	if not label then return end

	label.Text = tostring(value)

	-- Pequeño jitter de spawn alrededor del centro
	local startX = 0.5 + RNG:NextNumber(-0.04, 0.04)
	local startY = 0.5 + RNG:NextNumber(-0.04, 0.04)
	label.Position = UDim2.fromScale(startX, startY)

	-- Use cached stroke (already guaranteed to exist via ensureStroke)
	local stroke = labelStrokes[label]
	if stroke then
		stroke.Color = isHeadshot and COLOR_HEADSHOT_STROKE or COLOR_NORMAL_STROKE
		stroke.Thickness = isHeadshot and HEAD_STROKE_THICK or NORMAL_STROKE_THICK
		stroke.Transparency = isHeadshot and 0 or 0.8
	end

	-- Destino: sube con una pequeña deriva horizontal (un solo gesto, sin bajar).
	local driftX = RNG:NextNumber(-FLOAT_DRIFT_X, FLOAT_DRIFT_X)
	local endX = startX + driftX
	local endY = startY - FLOAT_RISE

	-- Pop de aparición (tamaño), en paralelo a la flotación.
	local appearTween = TweenService:Create(label, TI_NUM_APPEAR, {
		Size = UDim2_APPEAR_END,
	})

	-- Sube y se desvanece. El stroke se desvanece a la vez (mismo TweenInfo, así
	-- termina a la par que floatTween, justo cuando se libera el label → sin
	-- conflicto con el reuso del pool).
	local floatTween = TweenService:Create(label, TI_NUM_FLOAT, {
		Position = UDim2.fromScale(endX, endY),
		Rotation = RNG:NextNumber(-FLOAT_MAX_ROT, FLOAT_MAX_ROT),
		TextTransparency = 1,
	})
	if stroke then
		TweenService:Create(stroke, TI_NUM_FLOAT, { Transparency = 1 }):Play()
	end

	-- Cleanup al terminar. Audit mobile: :Once auto-disconnect (Completed dispara
	-- una vez, tanto en finalización como en cancel).
	floatTween.Completed:Once(function()
		if stroke then
			stroke.Transparency = 1
		end
		releaseBillboardLabel(billboard, label)
	end)

	appearTween:Play()
	floatTween:Play()
end

--// Public API
function DamageBillboardHandler:ShowDamageBillboard(damageAmount: number, adornee: Instance, isHeadshot: boolean?)
	if shouldSkipFriendlyTargetFx(adornee) then
		return
	end

	local headshot = isHeadshot == true

	local pos = getWorldPos(adornee)
	if pos then
		local cam = currentCamera
		if cam and (pos - cam.CFrame.Position).Magnitude > MAX_UI_DISTANCE then
			local progressivePitch_far = getCurrentPitch()
			playUIAudio(headshot and "Headshot" or "HitSound", progressivePitch_far)
			return
		end
	end

	local mult = (HeadshotMultiplier and HeadshotMultiplier.Value) or 1
	local shownDamage = headshot and math.ceil(damageAmount * mult) or math.ceil(damageAmount)

	local progressivePitch = getCurrentPitch()
	playUIAudio(headshot and "Headshot" or "HitSound", progressivePitch)

	local billboard = self:CreateBillboardForAdornee(adornee)

	-- Las partículas de headshot/body las gestiona ahora HitVFX (plantillas en
	-- ReplicatedStorage.HitVFX, disparadas desde BulletWeapon). Aquí sólo quedan
	-- el sonido (SoundService.Audio.Gameplay, arriba) y los números de daño, para
	-- no gestionar el mismo efecto en dos sitios.
	renderNumber(billboard, shownDamage, headshot)
end

return DamageBillboardHandler
