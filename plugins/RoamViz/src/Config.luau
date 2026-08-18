--!strict
--[[
	Config — estado FUNCIONAL del plugin RoamViz + persistencia entre sesiones
	(plugin:SetSetting / GetSetting).

	Acá vive solo lo que cambia el RESULTADO: qué se muestra (anillos, dummies) y
	los parámetros de picking/rutas. La APARIENCIA (colores, grosores,
	transparencias) se movió a Style.luau porque configurarla no aportaba nada.

	Los defaults de RoamMinDist/RoamMaxDist están HARDCODEADOS a producción
	(src/shared/constants/BotConfig.luau · Navigation.RoamMinDist=20 /
	RoamMaxDist=80). Si cambian ahí, actualizá acá: el plugin corre en el editor y
	no puede requireear BotConfig.
]]

local Config = {}

export type State = {
	-- Qué se dibuja
	showRings: boolean, -- anillos de alcance sobre el RoamPoint seleccionado
	showSpawns: boolean, -- puntos de spawn (jugadores/NPCs) + flecha de orientación
	-- Parámetros del picking (espejan BotConfig.Navigation)
	roamMinDist: number,
	roamMaxDist: number,
	-- Tope de rutas para la malla podada (anti-freeze)
	maxPaths: number,
}

local DEFAULTS: State = {
	showRings = true,
	showSpawns = true,
	roamMinDist = 20, -- BotConfig.Navigation.RoamMinDist
	roamMaxDist = 80, -- BotConfig.Navigation.RoamMaxDist
	maxPaths = 500,
}

local SETTING_KEY = "RoamViz_State_v1"

-- SetSetting solo acepta tipos JSON-safe; el estado ya lo es (bools/numbers).
local function encode(state: State): { [string]: any }
	return {
		showRings = state.showRings,
		showSpawns = state.showSpawns,
		roamMinDist = state.roamMinDist,
		roamMaxDist = state.roamMaxDist,
		maxPaths = state.maxPaths,
	}
end

local function decode(raw: any): State
	if typeof(raw) ~= "table" then
		return table.clone(DEFAULTS)
	end
	local ok, state = pcall(function(): State
		return {
			-- booleans: default true cuando el campo falta (nil ~= false)
			showRings = raw.showRings ~= false,
			showSpawns = raw.showSpawns ~= false,
			roamMinDist = tonumber(raw.roamMinDist) or DEFAULTS.roamMinDist,
			roamMaxDist = tonumber(raw.roamMaxDist) or DEFAULTS.roamMaxDist,
			maxPaths = tonumber(raw.maxPaths) or DEFAULTS.maxPaths,
		}
	end)
	if ok then
		return state
	end
	return table.clone(DEFAULTS)
end

function Config.load(plugin: Plugin): State
	return decode(plugin:GetSetting(SETTING_KEY))
end

function Config.save(plugin: Plugin, state: State)
	plugin:SetSetting(SETTING_KEY, encode(state))
end

function Config.defaults(): State
	return table.clone(DEFAULTS)
end

return Config
