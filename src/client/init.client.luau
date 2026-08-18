--!strict
-- Bootstrap único del cliente. Centraliza el arranque de controladores core
-- y de los features para evitar autoejecución repartida por carpetas.

local StarterGui = game:GetService("StarterGui")
StarterGui.ResetPlayerGuiOnSpawn = false


local Client = script

local ClientBootstrap = require(Client.bootstrap.ClientBootstrap)

ClientBootstrap.start(Client)
