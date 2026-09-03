--!strict
-- StaggerReveal: revela una lista ordenada de GuiObjects con un pop escalonado
-- (UIScale startScale → 1, con un delay incremental). Pensado para la entrada de
-- una página (p.ej. los packs de Store.CashPage al abrir el panel).
--
-- El retardo se cuenta por GRUPO, no por item: `setItems` mete cada item en su
-- propio grupo (cascada de uno en uno, el caso normal) y `setGroups` deja meter
-- varios en el mismo, que entran a la vez. Eso es lo que permite cascadear varias
-- filas en paralelo pasando columnas en vez de items.
--
-- Reutiliza el nodo "InteractiveScale" que crea InteractiveScaleTween para no
-- meter una segunda UIScale en conflicto (Roblox solo aplica una UIScale por
-- instancia). Si no existe ninguna, la crea con ese mismo nombre para que el
-- hover/click posterior comparta el nodo.

local TweenService = game:GetService("TweenService")

export type RevealOptions = {
	staggerDelay: number?,
	tweenInfo: TweenInfo?,
	startScale: number?,
}

export type StaggerReveal = {
	_staggerDelay: number,
	_tweenInfo: TweenInfo,
	_startScale: number,
	_groups: { { GuiObject } },
	_scales: { [GuiObject]: UIScale },
	_tweens: { [GuiObject]: Tween },
	setItems: (self: StaggerReveal, items: { GuiObject }) -> (),
	setGroups: (self: StaggerReveal, groups: { { GuiObject } }) -> (),
	play: (self: StaggerReveal) -> (),
	Destroy: (self: StaggerReveal) -> (),
}

local DEFAULT_STAGGER_DELAY = 0.06
local DEFAULT_TWEEN_INFO = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local DEFAULT_START_SCALE = 0

local StaggerReveal = {}
StaggerReveal.__index = StaggerReveal

local function ensureScale(target: GuiObject): UIScale
	local named = target:FindFirstChild("InteractiveScale")
	if named and named:IsA("UIScale") then
		return named
	end
	-- Cualquier UIScale existente sirve; compartimos para no duplicar.
	local anyScale = target:FindFirstChildOfClass("UIScale")
	if anyScale then
		return anyScale
	end
	local created = Instance.new("UIScale")
	created.Name = "InteractiveScale"
	created.Scale = 1
	created.Parent = target
	return created
end

function StaggerReveal.new(options: RevealOptions?): StaggerReveal
	local self = setmetatable({}, StaggerReveal) :: any
	self._staggerDelay = (options and options.staggerDelay) or DEFAULT_STAGGER_DELAY
	self._tweenInfo = (options and options.tweenInfo) or DEFAULT_TWEEN_INFO
	self._startScale = if options and options.startScale ~= nil then options.startScale else DEFAULT_START_SCALE
	self._groups = {}
	self._scales = {}
	self._tweens = {}
	return self
end

-- Cascada de uno en uno: cada item es su propio grupo.
function StaggerReveal:setItems(items: { GuiObject })
	local groups = table.create(#items)
	for i, item in items do
		groups[i] = { item }
	end
	self._groups = groups
end

-- Cascada por grupos: los items de un mismo grupo entran a la vez, y el retardo
-- separa un grupo del siguiente.
function StaggerReveal:setGroups(groups: { { GuiObject } })
	self._groups = groups
end

function StaggerReveal:play()
	for _, tween in self._tweens do
		tween:Cancel()
	end
	table.clear(self._tweens)
	-- Los items pueden haberse recreado entre plays; reconstruimos las refs.
	table.clear(self._scales)

	-- `step` avanza por grupo REVELADO, no por grupo recorrido: un grupo entero
	-- cuyos items ya no están en el árbol no debe dejar un hueco en la cascada.
	local step = 0
	for _, group in self._groups do
		local delay = step * self._staggerDelay
		local revealed = false
		for _, item in group do
			if item.Parent == nil then
				continue
			end
			revealed = true
			local scale = ensureScale(item)
			self._scales[item] = scale
			scale.Scale = self._startScale
			local tween = TweenService:Create(scale, self._tweenInfo, { Scale = 1 })
			self._tweens[item] = tween
			local thisTween = tween
			local thisItem = item
			task.delay(delay, function()
				-- Si otro play reemplazó el tween de este item, no lo arranques.
				if self._tweens[thisItem] ~= thisTween then
					return
				end
				thisTween:Play()
			end)
		end
		if revealed then
			step += 1
		end
	end
end

function StaggerReveal:Destroy()
	for _, tween in self._tweens do
		tween:Cancel()
	end
	table.clear(self._tweens)
	-- Restaurar scale = 1 por si nos destruyen mid-reveal; sin esto los items
	-- quedarían invisibles para la próxima vida (hot reload).
	for _, scale in self._scales do
		if scale.Parent ~= nil then
			scale.Scale = 1
		end
	end
	table.clear(self._scales)
end

return StaggerReveal
