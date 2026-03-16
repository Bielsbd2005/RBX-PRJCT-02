--!strict
--[[
	init.server.luau
	Punto de entrada del servidor.
	Inicializa los servicios en el orden correcto de dependencias:
	  1. DataService  — debe arrancar primero para preparar los hooks de PlayerAdded
	                    antes de que llegue cualquier jugador.
	  2. ShopService  — recibe DataService como dependencia explícita para evitar
	                    requires circulares.
	  3. AdminService — recibe DataService para gestionar datos de admin.
	                    Arrancar al final: no tiene dependencias de tiempo de inicio.
]]

local Server = script

local DataService  = require(Server.services.DataService)
local ShopService  = require(Server.services.ShopService)
local AdminService = require(Server.services.AdminService)

DataService:Start()
ShopService:Start(DataService)
AdminService:Start(DataService)
