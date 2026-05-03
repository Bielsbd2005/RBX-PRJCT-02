--!strict

local UIUtils = {}

function UIUtils.findFooterButton(menuGui: ScreenGui, buttonName: string): GuiButton?
	local bottomContainer = menuGui:FindFirstChild("BottomContainer")
	if not bottomContainer then
		return nil
	end

	local footer = bottomContainer:FindFirstChild("Footer")
	if not footer then
		return nil
	end

	local target = footer:FindFirstChild(buttonName)
	if target and target:IsA("GuiButton") then
		return target
	end

	return nil
end

function UIUtils.findCloseButton(root: Instance): GuiButton?
	local candidate = root:FindFirstChild("CloseBtn")
	if candidate and candidate:IsA("GuiButton") then
		return candidate
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
