--!strict

local UIUtils = {}

function UIUtils.findBottomButton(menuGui: ScreenGui, buttonName: string): GuiButton?
	local bottom = menuGui:FindFirstChild("Bottom")
	if not bottom then
		return nil
	end

	local target = bottom:FindFirstChild(buttonName)
	if target and target:IsA("GuiButton") then
		return target
	end

	return nil
end

function UIUtils.formatCashAmount(amount: number): string
	local formatted = tostring(math.max(0, math.floor(amount)))
	local withSeparators = string.reverse(formatted):gsub("(%d%d%d)", "%1.")
	withSeparators = string.reverse(withSeparators)
	if string.sub(withSeparators, 1, 1) == "." then
		withSeparators = string.sub(withSeparators, 2)
	end
	return withSeparators
end

-- Formato corto para contadores: a partir de mil usa sufijo "k" (1000 → "1k",
-- 1500 → "1.5k"). Por debajo de mil se muestra el número tal cual (999 → "999").
function UIUtils.formatCountShort(amount: number): string
	local n = math.max(0, math.floor(amount))
	if n < 1000 then
		return tostring(n)
	end
	local thousands = n / 1000
	if thousands == math.floor(thousands) then
		return string.format("%dk", thousands)
	end
	return string.format("%.1fk", thousands)
end

return UIUtils
