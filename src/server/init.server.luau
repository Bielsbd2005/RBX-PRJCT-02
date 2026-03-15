print("[Server] Init script starting...")
--[[
	Server Entry Point
	Inicializa todos los módulos del servidor.
]]



-- Inicializar sistema de datos
local DataManager = require(game:GetService("ServerScriptService").Server.Systems.Data.DataManager)
DataManager:Start()

print("[Server] Todos los módulos inicializados")
