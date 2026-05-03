--!strict
-- Bootstrap único del cliente. Centraliza el arranque de controladores core
-- y de los features para evitar autoejecución repartida por carpetas.

local StarterGui = game:GetService("StarterGui")
StarterGui.ResetPlayerGuiOnSpawn = false

-- SetCore puede fallar si los CoreScripts aún no están listos al arrancar.
task.spawn(function()
	local ok = false
	repeat
		ok = pcall(function()
			StarterGui:SetCore("ResetButtonCallback", false)
		end)
		if not ok then
			task.wait()
		end
	until ok
end)

local Client = script

local ClientBootstrap = require(Client.bootstrap.ClientBootstrap)

ClientBootstrap.start(Client)
