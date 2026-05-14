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

return UIUtils
