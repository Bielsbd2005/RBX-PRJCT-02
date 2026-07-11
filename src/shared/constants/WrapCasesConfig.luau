--!strict
--[[
	WrapCasesConfig.luau
	Definición de las cases (cajas) de wraps y su contenido ponderado.
	SINGLE SOURCE OF TRUTH: para añadir/editar una case basta con tocar CASES —
	nombre, precio, botón del Store y items con sus pesos. El resto del juego
	(Store, unboxing server-side, Locker Collection) se deriva de aquí.

	Cada item:
	  WrapId — id dentro de ItemsConfig.WeaponWraps.
	  Weight — peso relativo del roll (probabilidad = Weight / suma de Weights).

	El server (WrapCasesService) rolea wrap por peso y arma UNIFORME entre las
	armas del inventario del jugador, excluyendo combinaciones wrap+arma ya
	poseídas — nunca toca un duplicado.
]]

export type WrapCaseItemDefinition = {
	WrapId: string,
	Weight: number,
}

export type WrapCaseDefinition = {
	Id: string,
	Name: string,
	Price: number, -- Precio en Cash
	ButtonName: string, -- Botón que la abre: Store.Home.Row1.<ButtonName>
	Items: { WrapCaseItemDefinition },
}

local CASES: { WrapCaseDefinition } = table.freeze({
	table.freeze({
		Id = "StarterCase",
		Name = "Starter Case",
		Price = 500,
		ButtonName = "WrapCase1",
		Items = table.freeze({
			table.freeze({ WrapId = "Wrap_Case_Amber", Weight = 60 }),
			table.freeze({ WrapId = "Wrap_Case_Aqua", Weight = 30 }),
			table.freeze({ WrapId = "Wrap_Case_Frost", Weight = 10 }),
		}),
	}),
	table.freeze({
		Id = "MythicCase",
		Name = "Mythic Case",
		Price = 1500,
		ButtonName = "WrapCase2",
		Items = table.freeze({
			table.freeze({ WrapId = "Wrap_Case_Inferno", Weight = 60 }),
			table.freeze({ WrapId = "Wrap_Case_Venom", Weight = 30 }),
			table.freeze({ WrapId = "Wrap_Case_Void", Weight = 10 }),
		}),
	}),
})

-- Lookups derivados (case por id / nombre de case por wrap).
local CASE_BY_ID = {} :: { [string]: WrapCaseDefinition }
local CASE_NAME_BY_WRAP_ID = {} :: { [string]: string }
for _, caseDefinition in CASES do
	CASE_BY_ID[caseDefinition.Id] = caseDefinition
	for _, item in caseDefinition.Items do
		-- Un wrap puede pertenecer a varias cases; se muestra la primera declarada.
		if CASE_NAME_BY_WRAP_ID[item.WrapId] == nil then
			CASE_NAME_BY_WRAP_ID[item.WrapId] = caseDefinition.Name
		end
	end
end

local WrapCasesConfig = {}

WrapCasesConfig.CasesInOrder = CASES

function WrapCasesConfig.GetCaseById(caseId: string): WrapCaseDefinition?
	return CASE_BY_ID[caseId]
end

function WrapCasesConfig.GetTotalWeight(caseDefinition: WrapCaseDefinition): number
	local total = 0
	for _, item in caseDefinition.Items do
		total += math.max(0, item.Weight)
	end
	return total
end

-- Probabilidad (0..100) de que el roll caiga en `wrapId` dentro de la case.
function WrapCasesConfig.GetChancePercent(caseDefinition: WrapCaseDefinition, wrapId: string): number
	local total = WrapCasesConfig.GetTotalWeight(caseDefinition)
	if total <= 0 then
		return 0
	end
	for _, item in caseDefinition.Items do
		if item.WrapId == wrapId then
			return math.max(0, item.Weight) / total * 100
		end
	end
	return 0
end

-- Nombre de la case de la que dropea el wrap (para la vista Collection del Locker).
function WrapCasesConfig.GetCaseNameForWrap(wrapId: string): string?
	return CASE_NAME_BY_WRAP_ID[wrapId]
end

return table.freeze(WrapCasesConfig)
