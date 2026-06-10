--!strict
-- Bootstrap único del cliente. Centraliza el arranque de controladores core
-- y de los features para evitar autoejecución repartida por carpetas.

local StarterGui = game:GetService("StarterGui")
StarterGui.ResetPlayerGuiOnSpawn = false

-- SetCore puede fallar si los CoreScripts aún no están listos al arrancar.
-- Reintentamos con tope (50 × 0.2s ≈ 10s) para no dejar un loop infinito si los
-- CoreScripts nunca quedan listos.
task.spawn(function()
	local ok = false
	local attempts = 0
	repeat
		ok = pcall(function()
			StarterGui:SetCore("ResetButtonCallback", false)
		end)
		attempts += 1
		if not ok then
			task.wait(0.2)
		end
	until ok or attempts >= 50
	if not ok then
		warn("[Client] SetCore('ResetButtonCallback') falló tras 50 intentos — abandono")
	end
end)

local Client = script

local ClientBootstrap = require(Client.bootstrap.ClientBootstrap)

ClientBootstrap.start(Client)
