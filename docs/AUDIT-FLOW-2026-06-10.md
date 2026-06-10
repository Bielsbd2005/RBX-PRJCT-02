# Auditoría de flujo — Lobby · Votación · Partida · Resultados

**Fecha:** 2026-06-10
**Alcance:** ciclo de juego completo: lobby → votación → carga de mapa → ronda → resultados → votación.
Archivos núcleo: `MatchService.luau` (2326 LOC), `VotingService.luau`, `TeamAssignmentService.luau`,
`MatchResultsService.luau`, `KillAttributionService.luau`, `client/features/match/init.luau` (959 LOC),
`MatchState.luau`, `Network.luau` (namespace Match).
**Objetivo pedido:** simplicidad y escalabilidad; migraciones grandes aceptadas.

Esta auditoría es complementaria a `AUDIT-2026-06-10.md` (seguridad/perf) y a `REFACTORS.md`
(splits estructurales). No repite esos hallazgos: se centra en la **forma del flujo** — el modelo
de estados, el protocolo de red y el ownership del estado — que es donde está la complejidad
accidental que queda.

---

## 0. Diagnóstico en una frase

El flujo funciona, pero está construido como **eventos edge-triggered sobre booleanos sueltos**,
y casi toda la complejidad restante (dedupe keys, resyncs, timeouts de recuperación en cliente,
guards `_roundId`, tablas que hay que acordarse de limpiar) es el coste de no tener **una máquina
de estados autoritativa replicada**. La migración que más simplifica no es otro split de módulos:
es cambiar el modelo de "te aviso cuando pasa algo" a "este es el estado, míralo".

---

## 1. Mapa del flujo actual

### Servidor (implícito, no hay FSM real)

```
Start() ─→ StartVoteIfPossible ─→ [Voting 4s] ─→ onVoteFinished
                ▲                                     │
                │ task.delay(EndResultsDuration)      ▼
        _endRoundAndRestartVoting ◄── _finishRound ◄── [InRound 480s / 240 kills]
                                          ▲                  ▲
                                          │            RequestJoinMatch /
                                     muerte → score    RequestRespawn / ReturnToMenu
```

El estado real del servidor es la combinación de:
`_isMapLoading` + `_isPlayEnabled` + `_isRoundActive` + `VotingService:HasActiveVote()` +
`_voteHoldUntil` + `_hasCompletedInitialVote` + `_roundId` (guard anti-huérfanos).

`_setPhase` (`MatchService.luau:204`) escribe un string que **nadie lee** — la máquina de
estados existe como documentación, no como mecanismo.

### Cliente

`MatchState.luau` sí es una FSM real (6 fases), pero se alimenta de ~15 listeners de eventos
edge-triggered y se defiende de pérdidas/carreras con: `JOIN_CONFIRM_TIMEOUT`,
`RESPAWN_REQUEST_TIMEOUT`, `RETURN_TO_MENU_TIMEOUT`, `VOTE_AUTO_TIMEOUT`, `pendingAutoVote`,
reconstrucción de `isVoting` desde `MapLoadState`, y `RequestVoteSync` como red de seguridad.

---

## 2. Hallazgos

### F1 — La FSM del servidor es decorativa; los booleanos sueltos son la fuente de verdad
**Dónde:** `MatchService.luau:60,75-87,204-210`, guards dispersos (`:1039`, `:1677`, `:1695`, `:1955`, `:2010`, `:2046`), `VotingService.luau:399-417`.
**Síntoma:** cada handler re-deriva en qué fase está el juego combinando 4-6 flags; las
transiciones están repartidas entre `_startMapLoadFlow`, `_finishRoundAndScheduleRestart`,
`_endRoundAndRestartVoting` y `VotingService` (con `HoldVotingFor` + `task.delay` + 3
disparadores distintos de `StartVoteIfPossible`: PlayerAdded, RequestVoteSync, fin de Results).
**Propuesta:** una FSM autoritativa con 5 fases — `Idle | Voting | Loading | InRound | Results`
— con transiciones en un único lugar y los booleanos actuales como **derivados**
(`isPlayEnabled = phase == "InRound"`). El hold post-Results deja de ser un time-lock
defensivo (`_voteHoldUntil`) y pasa a ser simplemente "la fase Results dura N segundos y al
salir entra Voting". `_hasCompletedInitialVote` y `ResetCompletedFlag()` desaparecen (su único
propósito es impedir que un disparador externo reabra el voto en fase incorrecta).

### F2 — Protocolo edge-triggered → migrar a replicación de snapshot
**Dónde:** `Network.luau:176-370` (20 paquetes en Match), `MatchService.luau:1849-1863`
(`_onRequestVoteSync` con 5 SendTo), dedupe keys (`_lastMapLoadStateBroadcastKey`,
`_lastRoundStateBroadcastKey`, `_lastVoteBroadcastKey`, `_lastBotRosterJsonBroadcast`),
cliente `init.luau:438-467` (recuperar voting desde MapLoadState), `:815-829` (`pendingAutoVote` + timeout).
**Síntoma:** los eventos se pierden (late join, carreras al arrancar), así que el sistema ha ido
acumulando parches: resync bajo demanda, dedupe manual de broadcasts, y timeouts de
recuperación en el cliente. Es el patrón clásico de "eventos donde debía haber estado".
**Propuesta (la migración grande):** un único **MatchSnapshot replicado** — vía ReplicaService
(ya es dependencia y ya replica los datos de jugador) o un paquete `MatchSnapshot` que se
reenvía completo en cada cambio de fase:

```luau
{
  phase: "Idle" | "Voting" | "Loading" | "InRound" | "Results",
  phaseEndsAt: number,          -- GetServerTimeNow(); 0 si no aplica
  mapName: string,
  vote: { options: {…}, votesByUserId: {…} }?,   -- solo en Voting
  score: { a: number, b: number }?,              -- solo en InRound
  winnerTeam: string?,                           -- solo en Results
}
```

El cliente deriva su `MatchState` del snapshot (con sus fases locales Joining/Dying como
sub-estados de UI). Quedan como eventos solo lo genuinamente one-shot: `KillFeed`,
`DeathScreenShow/Hide`, `MatchResults`.
**Se elimina:** `RequestVoteSync`, `MapLoadState`, `StartVote`/`VoteState`/`EndVote` (el voto
vive en el snapshot), `RoundState`, los 4 dedupe keys, la lógica de recuperación del cliente y
`VOTE_AUTO_TIMEOUT`/`pendingAutoVote`. Un late-joiner no necesita ningún resync: lee el snapshot.
**Escalabilidad:** añadir un dato nuevo al estado de partida = añadir un campo al snapshot, no
un paquete nuevo + resync + dedupe + handler de recuperación.

### F3 — Countdowns por broadcast de ticks → timestamps
**Dónde:** `_runRoundTimer` (`MatchService.luau:1676-1687`), `_runVoteTimer`
(`VotingService.luau:262-307`): bucles `task.wait(1)` que emiten `timeLeft` a todos cada segundo.
**Propuesta:** enviar `endAt` (con `Workspace:GetServerTimeNow()`) una vez; el cliente cuenta
atrás localmente. Los bucles del servidor quedan reducidos a un único `task.delay` que dispara
la transición de fase (con el guard de generación que ya existe). Esto elimina el tráfico
periódico de `RoundState`/`VoteState` (el score sí se emite, pero solo cuando cambia) y los
dedupe keys de tiempo. Encaja directamente con el snapshot de F2 (`phaseEndsAt`).

### F4 — 20+ tablas paralelas por userId → un registro `PlayerSession` con sub-FSM
**Dónde:** `MatchService.luau:91-122,140,180-189,440` y el cleanup de 25 líneas en
`PlayerRemoving` (`:2216-2258`). Ya señalado en `REFACTORS.md` §5; esta auditoría lo eleva de
P2 a estructural.
**Síntoma adicional:** el estado de un jugador es a la vez 5 flags/timestamps
(`_isInMenuByUserId`, `_pendingSpawnByUserId`, `_respawnDebounceByUserId`,
`_respawningByUserId`, `_deathAtByUserId`) que codifican una FSM implícita con carreras
documentadas en comentarios ("carrera #1", debounce anti-bucle del lobby…).
**Propuesta:**

```luau
type PlayerSession = {
  state: "Lobby" | "WaitingSpawn" | "Alive" | "Dead" | "Respawning",
  team: ("A" | "B")?,
  diedAt: number,
  stats: { kills: number, deaths: number, assists: number,
           cashEarned: number, xpEarned: number },
  pickupCredits: { number },
  connections: { RBXScriptConnection },
}
local sessions: { [number]: PlayerSession } = {}
```

Cleanup atómico (`sessions[userId] = nil` + desconectar `connections`), y las transiciones
ilegales (respawn estando en menú, lobby-spawn pisando un respawn) se vuelven imposibles por
construcción en vez de estar parcheadas con debounces.

### F5 — Estado round-scoped global → objeto `Round` por ronda
**Dónde:** `_resetMatchScopedState` (`MatchService.luau:380-407`, "cualquier tabla nueva debe
agregarse acá"), guard `_roundId` (`:1803-1807,1677`), doble call-site de limpieza
(`_endRoundAndRestartVoting` y `_startMapLoadFlow`).
**Propuesta:** crear un objeto `Round` nuevo en cada `Loading→InRound` que **posea** score,
`endAt`, stats de combate por jugador, caches de spawn points y la carpeta de bots. Al terminar
la ronda se tira el objeto entero: la clase de bugs "tabla del round anterior no limpiada"
desaparece estructuralmente, igual que el checklist manual del comentario. Los timers capturan
el objeto `Round` y comprueban `round.active` — `_roundId` sobra. Esto también colapsa la
duplicación entre `_finishRoundAndScheduleRestart` y `_endRoundAndRestartVoting` (hoy ambos
apagan flags, despawnean bots y limpian) en `Round:finish(winner)` + la transición de la FSM.

### F6 — Camino de kill duplicado PvP/PvE
**Dónde:** `_registerKillEvent` (`MatchService.luau:667-757`) vs `_handleBotDied` (`:1694-1774`).
Ambos repiten: ventana de atribución, kill feed, contadores, streak, rewards
(Kill/Headshot/Streak3/Streak5), crédito de pickup, persistencia de stats, score, win-check.
~70 líneas duplicadas con divergencias sutiles (el path PvE no respeta `OnPlayerFirstKill` ni
multikills; el H5 fix solo está comentado en uno).
**Propuesta:** un único `_creditKill(victim: VictimDescriptor, attacker: AttackerDescriptor)`
donde víctima/atacante son `{ userId, isBot, team, humanoid }`. Los dos listeners (Died de
jugador, onBotDied) solo construyen los descriptores. Menos LOC, y cualquier regla nueva de
recompensa se escribe una vez.

### F7 — El timeout de carga de mapa es maquinaria muerta
**Dónde:** `_loadMapCloneWithTimeout` (`MatchService.luau:1400-1460`) + `GameConfig.MapLoadTimeout`.
**Hallazgo:** `Instance:Clone()` no hace yield. El hilo de `task.spawn` ejecuta el clone
completo de forma síncrona antes de devolver el control, así que `isDone` ya es `true` cuando
el bucle de polling (`task.wait(0.05)`) arranca: **el timeout no puede dispararse nunca**.
Las ~45 líneas de cancelación/polling equivalen a `local ok, clone = pcall(mapTemplate.Clone, mapTemplate)`.
**Propuesta:** sustituir por el pcall directo y eliminar `MapLoadTimeout` de GameConfig.
(Si algún día el clone es realmente pesado, la solución sería streaming/pre-parenting por lotes,
no un timeout que no aplica.)

### F8 — Lógica de spawn repartida en tres sitios → `SpawnService`
**Dónde:** `_teleportCharacterToSpawn`, `_spawnPlayerAtLobby`, `_spawnPlayerOnAssignedTeam`,
`_ensureLobbySpawnLocation`, `_findLobbySpawn` (`MatchService.luau:1173-1357`), más
`LoadoutService.loadCharacterWithBody/applyCosmetics/grantWeaponsWithRetry` y `SpawnSelector`.
Los workarounds de carreras del body-swap (anchor + `task.defer`, `WaitForChild` con timeout,
reintentos 3×0.15s en `_onRequestRespawn`) están duplicados en cada camino.
**Propuesta:** un `SpawnService` que posea **todos** los caminos de aparición con dos entradas:
`SpawnService.toLobby(player)` y `SpawnService.toMatch(player, side, round)`. Toda la
robustez anti-carrera vive una vez ahí dentro; MatchService deja de saber qué es un
HumanoidRootPart. Encaja con la sub-FSM de F4 (el spawn es la transición
`WaitingSpawn/Dead → Alive`).

### F9 — Inyección por tablas mutables compartidas → ownership claro
**Dónde:** `TeamAssignmentService:Start` recibe `teamByUserId`/`isInMenuByUserId`/
`pendingSpawnByUserId` **por referencia y escribe en ellas** (`MatchService.luau:2306-2313`,
`TeamAssignmentService.luau:25-36`); `KillAttributionService:Start` recibe refs a las tablas
de kills/deaths/assists (`:2267-2271`).
**Síntoma:** ownership partido — dos módulos mutan la misma tabla, y el contrato ("yield-free
o se rompe el debounce") vive en comentarios. Es el estado intermedio de un split a medias.
**Propuesta:** con F4/F5, estos services se vuelven **funciones puras sobre el estado** que les
pasa el orquestador (`TeamAssignment.pick(sessions, score, cap)`) o métodos del objeto `Round`.
Los singletons con `_started` y `Deps` desaparecen para los que no tienen estado propio real.

### F10 — JSON dentro de ByteNet y structs aplanados
**Dónde:** `BotRoster`/`TeamCosmetics`/`MatchResults` mandan `{ json = ByteNet.String }`
(`Network.luau:255-285`); `StartVote`/`VoteState` aplanan `option1*/option2*/option3*` y CSV
de voter ids (`:180-194,340-352`).
**Síntoma:** doble serialización (JSONEncode + ByteNet) anula el propósito de ByteNet y obliga
a validar el decode a mano en cada listener del cliente. Los structs aplanados fijan N=3
opciones en el protocolo (cambiar a 4 opciones toca 6 archivos).
**Propuesta:** con F2 la mayoría de estos paquetes muere dentro del snapshot. Para lo que quede
(roster, cosméticos), o ByteNet con arrays tipados si la versión vendorizada los soporta, o
asumir Remote/Replica normal para payloads infrecuentes — JSON-en-ByteNet es el peor de ambos
mundos.

### F11 — El sistema de Modes es vestigial
**Dónde:** `GameConfig.GameMode` (un solo valor), `Modes = { "TeamDeathmatch" }` ×3 mapas,
`_collectCompatibleMaps("TeamDeathmatch")` hardcodeado (`VotingService.luau:419`), `optionNMode`
viajando en 2 paquetes y pintándose en la UI.
**Propuesta:** decisión explícita: o se elimina (borrar `Modes`, los campos `optionNMode` y
`_containsMode` — menos protocolo y menos UI), o se hace real (el modo ganador de la votación
parametriza la ronda: score limit, duración, spawning). Mantenerlo a medias es coste sin valor.
Si el roadmap contempla más modos, la FSM de F1 + snapshot de F2 son el prerequisito natural
(la fase `InRound` lleva `mode` en el snapshot).

### F12 — Menores (quick wins)
- `_finishRoundAndScheduleRestart` hace `SendTo` en bucle para `DeathScreenHide` y `RoundEnded`
  (`MatchService.luau:1531-1533,1582-1588`) → `SendToAll`.
- `VoteDuration = 4` y `MinPlayersToStart = 1` (`GameConfig.luau:51,60`) parecen valores de
  testing; confirmar antes de lanzar (4s de votación apenas da tiempo a abrir la pantalla).
- `_phase`/`_setPhase` write-only: se resuelve con F1; si F1 se pospone, borrar.
- `LOCAL_VOTE_COOLDOWN` cliente (0.3s) duplica el `VOTE_CHANGE_COOLDOWN` servidor (0.3s);
  con snapshot el cooldown local sobra (la UI refleja el estado replicado).
- Comentario desactualizado en `VotingService.luau:57-58` ("0.5s permite ~2 cambios/seg" pero
  la constante es 0.3).

---

## 3. Arquitectura objetivo

```
SERVIDOR
MatchFlowController            ← FSM autoritativa (única fuente de fase) + MatchSnapshot replicado
 ├─ VotingService              ← ya existe; pierde HoldVotingFor/ResetCompletedFlag (timing = FSM)
 ├─ MapService                 ← clone/destroy + caches de spawns (hoy dentro de MatchService)
 ├─ Round (objeto por ronda)   ← score, endAt, stats por jugador, bots; muere con la ronda
 ├─ SpawnService               ← todos los caminos de spawn (lobby/equipo/loadout/protección)
 ├─ CombatCredit               ← _creditKill unificado (rewards, streaks, stats, pickups)
 └─ sessions[userId]           ← PlayerSession con sub-FSM Lobby/WaitingSpawn/Alive/Dead/Respawning

CLIENTE
MatchState                     ← derivado del MatchSnapshot + sub-fases de UI (Joining/Dying)
 └─ vistas suscritas a fase    ← HUD, MapVoteView, DeathScreen, Results: show/hide declarativo
Eventos one-shot restantes     ← KillFeed, DeathScreenShow/Hide, MatchResults
```

MatchService queda como el `MatchFlowController` de ~400-600 LOC que ya anticipaba
`REFACTORS.md` §1.4 — pero la palanca para llegar no es seguir extrayendo módulos, es F1+F2:
sin FSM autoritativa y snapshot, cada extracción arrastra los mismos flags compartidos.

---

## 4. Plan de migración propuesto

**Fase 0 — Quick wins sin riesgo (horas):** F7 (clone directo), F12 (SendToAll, comentarios,
constantes), decisión F11 (probablemente: borrar Modes).

**Fase 1 — FSM servidor (1-2 días):** F1. Introducir el enum de fase autoritativo y derivar
los booleanos existentes de él *sin tocar el protocolo todavía*. Los paquetes actuales se
emiten desde las transiciones. Riesgo bajo: el comportamiento observable no cambia, pero las
carreras pasan a tener un solo punto de verdad.

**Fase 2 — MatchSnapshot (2-4 días, la migración grande):** F2+F3. Reemplazar
MapLoadState/StartVote/VoteState/EndVote/RoundState/RequestVoteSync por el snapshot replicado
con `phaseEndsAt`. Reescribir los listeners del cliente como derivación del snapshot y borrar
los timeouts de recuperación. Es el cambio con mejor ratio LOC-borradas/LOC-escritas de todo
el repo (estimo −600/−800 LOC netas entre servidor y cliente).

**Fase 3 — Sessions + Round (2-3 días):** F4+F5. Consolidar tablas por-userId en
`PlayerSession`, crear el objeto `Round`, borrar `_resetMatchScopedState`, `_roundId` y el
cleanup-checklist de `PlayerRemoving`. F9 cae solo: TeamAssignment/KillAttribution pasan a
operar sobre sessions/round.

**Fase 4 — SpawnService + CombatCredit (1-2 días):** F8+F6. Mover y unificar; aquí es donde
los reintentos/anclajes anti-carrera quedan escritos una sola vez.

Cada fase es shippeable por separado y testeable con `TEST-CHECKLIST.md`. El orden importa:
hacer la fase 3 antes que la 1-2 obligaría a re-tocar todo al introducir el snapshot.

---

## 5. Nota de escalabilidad

El diseño actual — un match por servidor, lobby físico en el mismo place, 6 jugadores reales +
relleno de bots — es correcto y estándar para este tipo de juego; no se recomienda matchmaking
cross-server por ahora. Los límites reales de escala hoy son de **mantenibilidad**, no de
runtime: con 6-16 participantes ningún broadcast actual es un problema de red. Lo que sí
escala mal es añadir features sobre el flujo actual (cada una necesita paquete + resync +
dedupe + recovery). Tras F1-F3, añadir un modo nuevo, una fase nueva (warmup, overtime) o un
dato nuevo de HUD es un campo más en el snapshot y un case más en la FSM.
