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
local COLOR_HEADSHOT_TEXT = Color3.fromRGB(235, 71, 62)    -- headshot text
local COLOR_HEADSHOT_STROKE = Color3.fromRGB(118, 35, 32)  -- headshot stroke

-- TweenInfos
local TI_NUM_APPEAR   = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TI_NUM_MOVE     = TweenInfo.new(1.40, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Desktop-only profile (no mobile distinctions)
local MAX_UI_DISTANCE     = 200
local MAX_ACTIVE_LABELS   = 7         -- fixed desktop value
local MERGE_WINDOW        = 0.12
local MERGE_MAX_HOLD      = 0.18
local PARTICLES_PER_HEAD  = 25        -- fixed desktop value

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

--// Cached head emitters
local headEmitters = setmetatable({}, { __mode = "k" }) -- head -> {emitters}
local function emitHeadshotParticles(head: BasePart)
	local list = headEmitters[head]
	if not list then
		list = {}
		local att = head:FindFirstChild("HeadShotAttachment")
		if att then
			for _, p in ipairs(att:GetChildren()) do
				if p:IsA("ParticleEmitter") then
					list[#list+1] = p
				end
			end
		end
		headEmitters[head] = list
	end
	for _, p in ipairs(list) do
		p:Emit(PARTICLES_PER_HEAD)
	end
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

-- Merge buffer per billboard
-- mergeState[billboard] = { sum=0, headshot=false, deadline=0, scheduled=false, adornee=Instance }
local mergeState = setmetatable({}, { __mode = "k" })

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
				mergeState[bb] = nil
				bb:Destroy()
			end
		end
	end)

	return billboard
end

-- Dispersed motion (wide upward cone)
local function randomDispersedOffset()
	local angleDeg = RNG:NextNumber(-140, -40)
	local angleRad = math.rad(angleDeg)
	local dist = RNG:NextNumber(1.3, 2.8)
	local dx = math.cos(angleRad) * dist
	local dy = math.sin(angleRad) * dist
	return dx, dy
end

-- Render a single number
local function renderNumber(billboard: BillboardGui, value: number, isHeadshot: boolean)
	local label = getBillboardLabel(billboard, isHeadshot)
	if not label then return end

	label.Text = tostring(value)

	-- Small spawn jitter
	local jitterX = RNG:NextNumber(-0.04, 0.04)
	local jitterY = RNG:NextNumber(-0.04, 0.04)
	label.Position = UDim2.fromScale(0.5 + jitterX, 0.5 + jitterY)

	-- Use cached stroke (already guaranteed to exist via ensureStroke)
	local stroke = labelStrokes[label]
	if stroke then
		stroke.Color = isHeadshot and COLOR_HEADSHOT_STROKE or COLOR_NORMAL_STROKE
		stroke.Thickness = isHeadshot and HEAD_STROKE_THICK or NORMAL_STROKE_THICK
		stroke.Transparency = isHeadshot and 0 or 0.8
	end

	local moveX, moveY = randomDispersedOffset()

	local appearTween = TweenService:Create(label, TI_NUM_APPEAR, {
		Size = UDim2_APPEAR_END,
	})

	-- Headshot stays fully opaque; normal fades a bit
	local moveProps = {
		Position = UDim2.fromScale(0.5 + moveX, 0.5 + moveY),
		Rotation = RNG:NextNumber(-40, 40),
		TextTransparency = isHeadshot and 0 or 0.55,
	}

	local moveTween = TweenService:Create(label, TI_NUM_MOVE, moveProps)

	-- Cleanup + reduce overdraw at end. Audit mobile: :Once auto-disconnect
	-- (Completed dispara una sola vez por tween, tanto en finalización como
	-- en cancel). Elimina la conn local + el disconnect manual.
	moveTween.Completed:Once(function()
		if stroke then
			stroke.Transparency = 1
		end
		releaseBillboardLabel(billboard, label)
	end)

	appearTween:Play()
	moveTween:Play()
end

-- Flush scheduler
local scheduleFlush  -- forward declaration for recursion
scheduleFlush = function(billboard: BillboardGui)
	local state = mergeState[billboard]
	if not state or state.scheduled then return end
	state.scheduled = true

	task.delay(MERGE_WINDOW, function()
		local s = mergeState[billboard]
		if not s then return end

		s.scheduled = false

		if time() >= s.deadline then
			local value    = s.sum
			local headshot = s.headshot
			local adornee  = s.adornee

			if adornee and adornee.Parent then
				if headshot then
					local head = getHeadFromAdornee(adornee)
					if head then
						emitHeadshotParticles(head)
					end
				end
			end

			if value > 0 then
				renderNumber(billboard, value, headshot)
			end

			s.sum = 0
			s.headshot = false
		elseif s.sum > 0 then
			-- Deadline was extended by a late hit; re-schedule to catch it
			scheduleFlush(billboard)
		end
	end)
end

--// Public API
function DamageBillboardHandler:ShowDamageBillboard(damageAmount: number, adornee: Instance, isHeadshot: boolean?)
	if shouldSkipFriendlyTargetFx(adornee) then
		return
	end

	-- Headshot flag llega como parámetro desde el caller (que sabe qué part
	-- hiteó). Antes leíamos de un BoolValue global mutable que era racy entre
	-- hits concurrentes; ahora es un valor inmutable por llamada.
	local headshot = isHeadshot == true

	-- Distance culling: keep audio (use cached camera)
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

	-- Progressive audio
	local progressivePitch = getCurrentPitch()
	playUIAudio(headshot and "Headshot" or "HitSound", progressivePitch)

	-- Billboard
	local billboard = self:CreateBillboardForAdornee(adornee)

	-- Merge window accumulation with max hold time so SMGs produce a
	-- steady stream of numbers instead of one big number when you stop firing.
	local state = mergeState[billboard]
	local now = time()
	if not state then
		state = { sum = 0, headshot = false, deadline = 0, scheduled = false, adornee = adornee, firstHitAt = 0 }
		mergeState[billboard] = state
	end

	if state.sum == 0 then
		state.firstHitAt = now
	end

	-- If we've been holding hits longer than MERGE_MAX_HOLD, flush now
	-- and start a new accumulation window. This creates the rapid stream.
	if state.sum > 0 and (now - state.firstHitAt) >= MERGE_MAX_HOLD then
		local flushValue = state.sum
		local flushHeadshot = state.headshot
		local flushAdornee = state.adornee
		if flushAdornee and flushAdornee.Parent then
			if flushHeadshot then
				local head = getHeadFromAdornee(flushAdornee)
				if head then
					emitHeadshotParticles(head)
				end
			end
		end
		if flushValue > 0 then
			renderNumber(billboard, flushValue, flushHeadshot)
		end
		state.sum = 0
		state.headshot = false
		state.firstHitAt = now
	end

	state.sum += shownDamage
	state.headshot = state.headshot or headshot
	state.adornee = adornee
	state.deadline = now + MERGE_WINDOW
	scheduleFlush(billboard)
end

return DamageBillboardHandler
