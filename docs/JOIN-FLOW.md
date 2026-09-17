# Join — contrato de carga inicial

Problema que resuelve: con latencia alta el personaje aparecía en el lobby, caía y se podía
mover antes de que el cliente fijara la cámara Scriptable del menú.

## Restricción de la que depende todo

`Players.CharacterAutoLoads = false` (`MatchService:Start`), y con eso Roblox **no copia
StarterGui a PlayerGui hasta el primer spawn**. El primer `SpawnAtLobby` es lo que dispara
todas las GUIs (Menu, HUD…). Por eso el spawn de join **debe ser inmediato**: un handshake
que lo retrasara hasta "menú listo" se bloquearía a sí mismo. Lo que se controla es lo que el
jugador *ve* y si el cuerpo *puede moverse*, no cuándo existe.

## Contrato

- **Cuerpo de lobby anclado y sin equipo** (`SpawnService._teleportCharacterToSpawn(…, keepAnchored=true)`):
  server-authoritative, a altura de pie (`_standingRootCFrame`), `Team = nil` + `Neutral`.
  Nunca se desancla; todo spawn posterior (`SpawnOnAssignedTeam`, vuelta a menú, muerte fuera
  de ronda) crea cuerpo nuevo con `LoadCharacter`.
- **Loading screen en ReplicatedFirst** (`ReplicatedFirst.LoadingScreenGui` + `LoadingScreen.client`):
  tapa el mundo desde el frame 0, sin depender de StarterGui. Se abre solo cuando hay assets
  precargados AND `MIN_LOAD_TIME` AND `LocalPlayer.ClientBootStage == "MenuReady"` (atributo
  local que pone `ClientBootstrap` tras fijar cámara y construir `MenuController`), acotado por
  `HARD_TIMEOUT`.
  - `LoadingScreenGui` se edita en Studio, no en disco: el nodo ReplicatedFirst de
    `default.project.json` lleva `$ignoreUnknownInstances: true` para que Rojo no la borre al
    sincronizar (mismo patrón que `Shared/Bodies`).
  - No puede llamarse `LoadingScreen`: ese nombre ya lo usa el LocalScript `LoadingScreen.client.luau`.
- **Cámara de lobby re-afirmada**: `ClientBootstrap.applyLobbyCameraIfInMenu` llama a
  `MatchCamera.forceLobbyWithRetries` al arrancar y en cada `CharacterAdded` mientras
  `MatchState.getPhase() == "Lobby"` (el motor re-engancha la cámara al Humanoid en cada spawn).
- **Handshake informativo `ClientReady`** (`Network.Match.ClientReady`, C→S, idempotente):
  el servidor marca `session.clientReady`, pone `Player.JoinState = "Ready"` (ACK replicado;
  `"Loading"` desde `_initJoinedPlayerState`) y encola telemetría `CLIENT_READY` con los ms
  desde `PlayerAdded`. El cliente reintenta cada 2 s hasta ver el ACK (máx. 8). **Nada en el
  servidor depende de él**: un cliente que no lo envíe tiene cuerpo y GUIs igualmente.
  Nombres de atributos en `Shared/constants/ClientBootStage.luau`.
