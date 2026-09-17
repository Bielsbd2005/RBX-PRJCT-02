--!strict
-- Destruye el cadáver cuando el ragdoll se asienta (no tras un delay fijo, que
-- deja ver el cuerpo tieso). Un único Heartbeat compartido; se desconecta al vaciarse.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local RagdollCleanup = {}

export type Options = {
	minTime: number?, -- s mínimo visible antes de permitir destruir
	maxTime: number?, -- s tope duro si nunca se asienta
	settleSpeed: number?, -- studs/s (y rad/s) por debajo de los cuales se da por quieto
	settleHold: number?, -- s que debe mantenerse quieto para confirmar asentado
	fadeTime: number?, -- s de fundido final (0 = corte seco)
}

local DEFAULT_MIN = 4
local DEFAULT_MAX = 5
local DEFAULT_SETTLE_SPEED = 3
local DEFAULT_SETTLE_HOLD = 0.2
local DEFAULT_FADE = 0.4
local TICK = 0.08 -- s entre chequeos del Heartbeat compartido

type Entry = {
	model: Model,
	ref: BasePart,
	startAt: number,
	calmSince: number?,
	minTime: number,
	maxTime: number,
	settleSpeed: number,
	settleHold: number,
	fadeTime: number,
}

local _entries: { Entry } = {}
local _conn: RBXScriptConnection? = nil
local _accum = 0

local _fadeInfoCache: { [number]: TweenInfo } = {}
local function fadeInfo(t: number): TweenInfo
	local info = _fadeInfoCache[t]
	if not info then
		info = TweenInfo.new(t, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
		_fadeInfoCache[t] = info
	end
	return info
end

-- AssemblyLinearVelocity mide todo el assembly: cualquier parte sirve, el torso
-- por estabilidad.
local function pickRef(model: Model): BasePart?
	for _, name in { "LowerTorso", "UpperTorso", "Torso", "HumanoidRootPart" } do
		local p = model:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	return model:FindFirstChildWhichIsA("BasePart", true) :: BasePart?
end

local function fadeAndDestroy(model: Model, fadeTime: number)
	if fadeTime <= 0 then
		model:Destroy()
		return
	end
	-- Los overlays client-side (Highlight local de CharacterHighlightController)
	-- escuchan este atributo para desvanecerse con la misma duración. El nombre
	-- debe coincidir con CharacterHighlightController.FADE_OUT_ATTR.
	model:SetAttribute("KillEffectFadeOut", fadeTime)
	local info = fadeInfo(fadeTime)
	for _, d in model:GetDescendants() do
		local fadeable = d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture")
		if fadeable and (d :: any).Transparency < 1 then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		end
	end
	task.delay(fadeTime, function()
		if model.Parent ~= nil then
			model:Destroy()
		end
	end)
end

-- Swap-remove O(1): el orden de _entries no importa.
local function removeAt(i: number)
	local n = #_entries
	_entries[i] = _entries[n]
	_entries[n] = nil
end

local function step()
	local now = os.clock()
	for i = #_entries, 1, -1 do
		local e = _entries[i]
		local model = e.model
		local ref = e.ref
		if model.Parent == nil or ref.Parent == nil then
			removeAt(i)
		else
			local elapsed = now - e.startAt
			local settled = false
			if elapsed >= e.maxTime then
				settled = true
			elseif elapsed >= e.minTime then
				local speed = ref.AssemblyLinearVelocity.Magnitude
				local spin = ref.AssemblyAngularVelocity.Magnitude
				if speed <= e.settleSpeed and spin <= e.settleSpeed then
					if not e.calmSince then
						e.calmSince = now
					elseif now - (e.calmSince :: number) >= e.settleHold then
						settled = true
					end
				else
					e.calmSince = nil
				end
			end
			if settled then
				removeAt(i)
				fadeAndDestroy(model, e.fadeTime)
			end
		end
	end

	if #_entries == 0 and _conn then
		_conn:Disconnect()
		_conn = nil
	end
end

local function ensureLoop()
	if _conn then
		return
	end
	_accum = 0
	_conn = RunService.Heartbeat:Connect(function(dt: number)
		_accum += dt
		if _accum < TICK then
			return
		end
		_accum = 0
		step()
	end)
end

-- Idempotente por modelo. Sin BasePart de referencia degrada a destruir tras maxTime.
function RagdollCleanup.scheduleDestroy(model: Model, opts: Options?)
	local o: Options = opts or {}

	for _, e in _entries do
		if e.model == model then
			return
		end
	end

	local maxTime = o.maxTime or DEFAULT_MAX
	local fadeTime = o.fadeTime or DEFAULT_FADE

	local ref = pickRef(model)
	if not ref then
		task.delay(maxTime, function()
			if model.Parent ~= nil then
				fadeAndDestroy(model, fadeTime)
			end
		end)
		return
	end

	table.insert(_entries, {
		model = model,
		ref = ref,
		startAt = os.clock(),
		calmSince = nil,
		minTime = o.minTime or DEFAULT_MIN,
		maxTime = maxTime,
		settleSpeed = o.settleSpeed or DEFAULT_SETTLE_SPEED,
		settleHold = o.settleHold or DEFAULT_SETTLE_HOLD,
		fadeTime = fadeTime,
	})
	ensureLoop()
end

return RagdollCleanup
