--!strict

-- Kill effect "Pancake": cae un yunque, el cuerpo se aplasta y queda como una pegatina
-- en el suelo. Aquí solo se congela (Utils.freezeCorpse); lo visible lo hace cada
-- cliente en visuals/killEffects/Flattened con una copia local del cuerpo.

local Utils = require(script.Parent.Utils)

local Flattened = {}

-- Caída del yunque, pegatina y un rato con ella a la vista.
Flattened.previewTime = 2.8

function Flattened.apply(char: Model): boolean
	Utils.freezeCorpse(char)
	return true
end

return Flattened
