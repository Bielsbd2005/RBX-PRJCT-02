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

-- "actual/objetivo" para barras de progreso: el actual en blanco y el "/objetivo"
-- en gris y más pequeño. Requiere RichText activado en el TextLabel.
function UIUtils.formatProgressValue(current: number, total: number): string
	return string.format(
		'<font color="#FFFFFF">%d</font><font color="#d6d6d6" size="10">/%d</font>',
		math.max(0, math.floor(current)),
		math.max(0, math.floor(total))
	)
end

-- Formatea segundos restantes como "Ends in 6 weeks, 2 days" (máx 2 unidades)
-- para temporizadores de temporadas / eventos (BattlePass, FamePass, etc.).
function UIUtils.formatTimeLeft(seconds: number): string
	if seconds <= 0 then return "" end

	local function unit(n: number, singular: string): string
		return tostring(n) .. " " .. (if n == 1 then singular else singular .. "s")
	end

	local minutes = math.floor(seconds / 60)
	local hours = math.floor(minutes / 60)
	local days = math.floor(hours / 24)
	local weeks = math.floor(days / 7)

	if weeks >= 1 then
		local remDays = days - weeks * 7
		if remDays > 0 then
			return ("Ends in %s, %s"):format(unit(weeks, "week"), unit(remDays, "day"))
		end
		return ("Ends in %s"):format(unit(weeks, "week"))
	end
	if days >= 1 then
		local remHours = hours - days * 24
		if remHours > 0 then
			return ("Ends in %s, %s"):format(unit(days, "day"), unit(remHours, "hour"))
		end
		return ("Ends in %s"):format(unit(days, "day"))
	end
	if hours >= 1 then
		local remMinutes = minutes - hours * 60
		if remMinutes > 0 then
			return ("Ends in %s, %s"):format(unit(hours, "hour"), unit(remMinutes, "minute"))
		end
		return ("Ends in %s"):format(unit(hours, "hour"))
	end
	if minutes >= 1 then
		return ("Ends in %s"):format(unit(minutes, "minute"))
	end
	return "Ending soon"
end

return UIUtils
