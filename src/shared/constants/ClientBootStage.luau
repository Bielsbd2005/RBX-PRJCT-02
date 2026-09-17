--!strict
--[[
	Nombres de los atributos que coordinan el arranque del cliente.

	  • BOOT_STAGE_ATTRIBUTE — lo escribe el CLIENTE sobre LocalPlayer. Los
	    atributos puestos por el cliente NO replican al servidor, pero sí los
	    ve el LocalScript de ReplicatedFirst (LoadingScreen.client), que es su
	    único consumidor: la pantalla de carga no se abre hasta MENU_READY.
	    Ese script no puede requerir este módulo (corre antes de que
	    ReplicatedStorage replique), así que repite los literales con un
	    comentario cruzado — mantener ambos sincronizados.

	  • JOIN_STATE_ATTRIBUTE — lo escribe el SERVIDOR sobre el Player (replica).
	    Hace de ACK del packet Network.Match.ClientReady: Loading → Ready.
]]

return {
	BOOT_STAGE_ATTRIBUTE = "ClientBootStage",
	MENU_READY = "MenuReady",

	JOIN_STATE_ATTRIBUTE = "JoinState",
	JOIN_LOADING = "Loading",
	JOIN_READY = "Ready",
}
