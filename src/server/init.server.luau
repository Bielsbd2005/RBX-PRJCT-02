--!strict
-- Bootstrap único del servidor. El orden sigue siendo:
--   1. DataService
--   2. ShopService
--   3. SettingsService

local Server = script

local ServerBootstrap = require(Server.bootstrap.ServerBootstrap)

ServerBootstrap.start(Server)
