--!strict
--[[
	Fundido de un árbol de GUI entero. Guarda las transparencias de Studio para volver
	a ellas (no asume que todo estaba a 0). Un CanvasGroup se funde con GroupTransparency.
]]

local TweenService = game:GetService("TweenService")

export type FadeTarget = {
	object: Instance,
	property: string,
	original: number,
}

local UIFade = {}

function UIFade.collect(root: GuiObject): { FadeTarget }
	local targets: { FadeTarget } = {}
	local function add(object: Instance, property: string)
		table.insert(targets, { object = object, property = property, original = (object :: any)[property] })
	end

	if root:IsA("CanvasGroup") then
		add(root, "GroupTransparency")
		return targets
	end

	add(root, "BackgroundTransparency")
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiObject") then
			add(descendant, "BackgroundTransparency")
		end
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			add(descendant, "TextTransparency")
			add(descendant, "TextStrokeTransparency")
		elseif descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			add(descendant, "ImageTransparency")
		elseif descendant:IsA("UIStroke") then
			add(descendant, "Transparency")
		end
	end
	return targets
end

function UIFade.set(targets: { FadeTarget }, hidden: boolean)
	for _, target in targets do
		(target.object :: any)[target.property] = if hidden then 1 else target.original
	end
end

-- Devuelve los tweens para que el caller pueda cancelarlos si encadena otro fundido.
function UIFade.tween(targets: { FadeTarget }, info: TweenInfo, hidden: boolean): { Tween }
	local tweens = table.create(#targets)
	for _, target in targets do
		local tween = TweenService:Create(target.object, info, {
			[target.property] = if hidden then 1 else target.original,
		})
		tween:Play()
		table.insert(tweens, tween)
	end
	return tweens
end

return UIFade
