--!strict

local UIUtils = {}


function UIUtils.formatCashAmount(amount: number): string
	local formatted = tostring(math.max(0, math.floor(amount)))
	local withSeparators = string.reverse(formatted):gsub("(%d%d%d)", "%1.")
	withSeparators = string.reverse(withSeparators)
	if string.sub(withSeparators, 1, 1) == "." then
		withSeparators = string.sub(withSeparators, 2)
	end
	return withSeparators
end

-- 999 → "999", 1000 → "1k", 1500 → "1.5k".
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

-- El "/objetivo" va en gris y más pequeño. Requiere RichText en el TextLabel.
function UIUtils.formatProgressValue(current: number, total: number): string
	return string.format(
		'<font color="#FFFFFF">%d</font><font color="#d6d6d6" size="10">/%d</font>',
		math.max(0, math.floor(current)),
		math.max(0, math.floor(total))
	)
end

return UIUtils
