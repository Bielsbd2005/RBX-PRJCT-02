--!strict
--[[
	Arranca la parte visual de los kill effects en cada cliente. KillEffectsRegistry
	marca todo cadáver con su TAG, el id del efecto y la hora de la muerte; aquí se
	busca el handler de ese id en HANDLERS y se le llama con un contexto que se limpia
	solo. Sirve igual para partida (tag replicado) que para los previews del Locker y
	del pase (allí el registry corre en el cliente y el tag es local).

	Un handler (visuals/killEffects/<id>) exporta cualquiera de:
	  play(char, ctx)  por cada cadáver con ese efecto (una vez por cadáver).
	  start() / stop() estado propio del módulo: pools, carpetas, listeners propios.

	El contexto termina (ctx.finish) cuando el cadáver sale del DataModel, si play
	falla o al parar; lo que el handler deba sobrevivir al cadáver no lo pasa a ctx.add.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local KillEffectsRegistry = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Locker"):WaitForChild("killEffects"):WaitForChild("KillEffectsRegistry")
)
local Types = require(script.Parent.KillEffectTypes)

-- Mismo literal que RagdollCleanup/CharacterHighlightController: el server lo pone
-- en el cadáver al empezar a disolverlo, con la duración del fundido.
local FADE_OUT_ATTR = "KillEffectFadeOut"
local DEFAULT_FRESH_TOLERANCE = 0.5 -- s

type Cleanup = Types.Cleanup
type Ctx = Types.Ctx
type Handler = Types.Handler

local handlers = script.Parent:WaitForChild("killEffects")
-- Clave = id del kill effect (KillEffectsRegistry / ItemsConfig.KillEffects).
local HANDLERS: { [string]: Handler } = {
	Abduction = require(handlers:WaitForChild("Abduction")),
	Balloons = require(handlers:WaitForChild("Balloons")),
	BlockBlast = require(handlers:WaitForChild("BlockBlast")),
	Burning = require(handlers:WaitForChild("Burning")),
	Confetti = require(handlers:WaitForChild("Confetti")),
	Electrocution = require(handlers:WaitForChild("Electrocution")),
	Flattened = require(handlers:WaitForChild("Flattened")),
	GumDrop = require(handlers:WaitForChild("GumDrop")),
	XpOrbs = require(handlers:WaitForChild("XpOrbs")),
}

local KillEffectVisuals = {}

local _addedConn: RBXScriptConnection? = nil
local _contexts: { [Instance]: Ctx } = {}

local function debugWarn(message: string)
	if RunService:IsStudio() then
		warn("[KillEffectVisuals] " .. message)
	end
end

local function cleanup(item: Cleanup)
	local kind = typeof(item)
	if kind == "RBXScriptConnection" then
		(item :: RBXScriptConnection):Disconnect()
	elseif kind == "Instance" then
		(item :: Instance):Destroy()
	elseif kind == "thread" then
		local thread = item :: thread
		if coroutine.status(thread) ~= "dead" and coroutine.running() ~= thread then
			task.cancel(thread)
		end
	elseif kind == "function" then
		local ok, err = pcall(item :: () -> ())
		if not ok then
			debugWarn(tostring(err))
		end
	end
end

local function newContext(char: Model, startedAt: number): Ctx
	local items: { Cleanup } = {}
	local finished = false

	local function age(): number
		return workspace:GetServerTimeNow() - startedAt
	end

	local function add(item: Cleanup)
		if finished then
			cleanup(item)
		else
			table.insert(items, item)
		end
	end

	local function finish()
		if finished then
			return
		end
		finished = true
		if _contexts[char] then
			_contexts[char] = nil
		end
		-- Al revés: lo último creado puede depender de lo primero.
		for i = #items, 1, -1 do
			cleanup(items[i])
		end
		table.clear(items)
	end

	local function onFadeOut(fn: (fadeTime: number) -> ())
		local function check()
			local fadeTime = char:GetAttribute(FADE_OUT_ATTR)
			if type(fadeTime) == "number" and fadeTime > 0 then
				fn(fadeTime)
			end
		end
		add(char:GetAttributeChangedSignal(FADE_OUT_ATTR):Connect(check))
		check()
	end

	return {
		char = char,
		startedAt = startedAt,
		age = age,
		isFresh = function(tolerance: number?): boolean
			return age() <= (tolerance or DEFAULT_FRESH_TOLERANCE)
		end,
		add = add,
		onFadeOut = onFadeOut,
		finish = finish,
	}
end

local function track(instance: Instance)
	if not instance:IsA("Model") or _contexts[instance] or not instance.Parent then
		return
	end
	local char = instance :: Model
	local id = char:GetAttribute(KillEffectsRegistry.ATTR.ID)
	local handler = if type(id) == "string" then HANDLERS[id] else nil
	local play = if handler then handler.play else nil
	if not play then
		return
	end
	local startedAtAttr = char:GetAttribute(KillEffectsRegistry.ATTR.STARTED_AT)
	local startedAt = if type(startedAtAttr) == "number" then startedAtAttr else workspace:GetServerTimeNow()

	local ctx = newContext(char, startedAt)
	_contexts[char] = ctx
	ctx.add(char.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			ctx.finish()
		end
	end))

	local ok, err = pcall(play, char, ctx)
	if not ok then
		debugWarn(`{id}: {err}`)
		ctx.finish()
	end
end

function KillEffectVisuals.start()
	if _addedConn then
		return
	end
	for id, handler in HANDLERS do
		if handler.start then
			local ok, err = pcall(handler.start)
			if not ok then
				debugWarn(`{id}.start: {err}`)
			end
		end
	end
	for _, instance in CollectionService:GetTagged(KillEffectsRegistry.TAG) do
		track(instance)
	end
	_addedConn = CollectionService:GetInstanceAddedSignal(KillEffectsRegistry.TAG):Connect(track)
end

function KillEffectVisuals.stop()
	if _addedConn then
		_addedConn:Disconnect()
		_addedConn = nil
	end
	for _, ctx in table.clone(_contexts) do
		ctx.finish()
	end
	for id, handler in HANDLERS do
		if handler.stop then
			local ok, err = pcall(handler.stop)
			if not ok then
				debugWarn(`{id}.stop: {err}`)
			end
		end
	end
end

return KillEffectVisuals
