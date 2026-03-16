--!strict
--[[
	init.client.luau
	Punto de entrada del cliente.
	Inicia DataController, que solicita los datos del servidor y siembra
	los Fusion Values para que la UI pueda observarlos de forma reactiva.

	Otros controladores pueden esperar los datos así:
	  local DataController = require(Client.controllers.DataController)
	  DataController:WhenReady():andThen(function()
	      -- datos disponibles; construir UI, etc.
	  end)

	AdminController se inicia de forma independiente: prueba si el jugador
	es admin enviando un paquete al servidor. Si el servidor responde,
	monta la consola de administración en PlayerGui automáticamente.
	Los jugadores no-admin no cargan ningún componente de UI admin.
]]

local Client = script

local DataController  = require(Client.controllers.DataController)
local AdminController = require(Client.controllers.AdminController)

DataController:Start()
AdminController:Start()
