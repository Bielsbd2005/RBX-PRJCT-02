--!strict

local StarterGui = game:GetService("StarterGui")
-- Evita recreacion de ScreenGuis en respawn (rompe bindings de botones si cambia la instancia).
StarterGui.ResetPlayerGuiOnSpawn = false


local Client = script

local ClientBootstrap = require(Client.bootstrap.ClientBootstrap)

ClientBootstrap.start(Client)
