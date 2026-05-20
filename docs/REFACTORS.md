# Refactors diferidos

Splits de god-modules pendientes tras la auditoría AAA. Ordenados por
impacto/esfuerzo. Cada uno es una PR independiente — no se hicieron en
batch porque cada split necesita testing dedicado en Studio.

---

## 1. MatchService (server) — 2114 LOC restantes

`src/server/features/match/MatchService.luau` ya tuvo dos extractions:
- `LoadoutService.luau` (Sprint pre-auditoría)
- `HealthPickupService.luau` (Sprint 4)

Quedan 4 subsistemas que pueden seguir el mismo patrón.

### 1.1 `MapVotingService` — extract candidato mejor aislado
**Estado actual**: vote logic acoplado al phase machine de MatchService.

**Code a mover**:
- `_activeVote: ActiveVoteState?`
- `_voteCooldownsByUserId`, `VOTE_CHANGE_COOLDOWN`, `_isVoteChangeAllowed`,
  `_disconnectVoteForPlayer`
- `_runVoteTimer`, `_broadcastVoteState`, `_resolveWinner`,
  `_isValidOption`, `_lastVoteBroadcastKey`
- `_onCastVote`, `_onRequestVoteSync`, `_sendActiveVoteToPlayer`
- Network listeners: `Network.Match.CastVote`, `Network.Match.RequestVoteSync`

**Interfaz pública sugerida**:
```lua
MapVotingService:Start({ onVoteEnded = function(winnerMapName) end })
MapVotingService:StartVote(options: { MapDefinition })  -- llama desde MatchService
MapVotingService:CancelVote()
MapVotingService:HasActiveVote(): boolean
```

**Coupling restante**: MatchService consume `onVoteEnded` callback y dispara
`MapVotingService:StartVote(...)` cuando arranca un nuevo ciclo. Sin
acoplamiento estructural.

**Esfuerzo**: 1-2 días. **Riesgo**: Medio — el phase machine asume estado
del vote.

### 1.2 `KillFeedService` (o `CombatTrackingService`)
**Code a mover**:
- `_registerKillEvent`, `_persistAttackerKillStats`,
  `_grantActionRewardsToAttacker`, `_grantMasteryWrapsIfEligible`,
  `_registerWeaponKillForAttacker`, `_resolveWeaponItem`
- `_killStreakByUserId`, `_killStreakTimeoutByUserId`,
  `_lastBroadcastStreakKeyByUserId`, `_setupStreakTimeout`,
  `_resetStreakTimeout`
- `_pendingProfileActionsByUserId`, `_deferUntilProfile` (ya extraídos
  conceptualmente)
- Hooks ya conectados desde `WeaponsSystem.Killed.Event` (Sprint 4 P2 #21)

**Esfuerzo**: 2 días. **Riesgo**: Alto — toca el flujo critical de XP/Cash
persistence. Tests obligatorios de kill/death/XP/cash en Studio antes de
mergear.

### 1.3 `TeamAssignmentService`
**Code a mover**: `_pickBalancedTeam`, `_countActiveRealAssignments`,
`_collectCombatantDataForSide`, `_teamByUserId`, `_pendingSpawnByUserId`,
`_assignPlayerToTeamForRound`, `_releaseTeamAssignment`.

**Esfuerzo**: 1-2 días. **Riesgo**: Medio.

### 1.4 Resultado final esperado
`MatchService` queda como orquestador puro (~400-600 LOC):
- Phase machine (Idle / Voting / Loading / InRound / ShowingResults).
- `Players.PlayerAdded`/`Removing` cleanup central.
- Llamadas coordinadas a los sub-services.

---

## 2. WeaponsGui (server/WeaponsSystem/Libraries) — 1829 LOC

`src/server/WeaponsSystem/Libraries/WeaponsGui.luau` maneja crosshair,
hotbar, fire-buttons mobile, reload progress, hit highlights, damage numbers
callbacks, scope, vignette, kill container, directional indicators, hotbar
selection, ammo display, scope animation, haptic feedback. **Imposible
testear en aislado.**

### Split sugerido
Crear carpeta `Libraries/Gui/` con un módulo por subsistema:
- `Gui/Crosshair.luau` — el crosshair en sí + animation states.
- `Gui/Hotbar.luau` — slot selection + ammo count.
- `Gui/MobileControls.luau` — fire/reload buttons en touch.
- `Gui/HitFeedback.luau` — damage numbers callback + hit markers.
- `Gui/Scope.luau` — overlay de mira + vignette.
- `Gui/KillFeed.luau` — kill container.
- `Gui/DirectionalIndicators.luau` — daño recibido directional.

`WeaponsGui.luau` quedaría como compositor (~200 LOC).

**Esfuerzo**: 3-5 días. **Riesgo**: Alto en UI — cualquier breakage es
visible en cliente.

---

## 3. client/features/locker/init.luau — 1614 LOC

Una sola función `LockerFeature.start` con ~1500 LOC. Mezcla:
- Camera + preview models
- Hover binding + FaceApplier + HatApplier
- Kill-effect dummies
- Navigation + action frame tweens
- Payment + confetti + observer wiring

### Split sugerido
- `NavTabPopulator.luau` — populate y bind de los tabs del locker.
- `ActionFrameController.luau` — tweens y estados del action frame
  (equip / buy / preview).
- `KillEffectsDummyController.luau` — dummies y preview de kill effects.
- `PurchaseFlowController.luau` — flujo de compra (Robux + Cash).

Más helpers compartidos (`cancelTween`, `cancelTweenMap`, `disconnectFromMap`,
`getOptionalString`) que están duplicados con `WeaponPreviewController.luau`
— mover a `core/utils/` o similar.

**Esfuerzo**: 3-5 días. **Riesgo**: Alto — toca varios paneles UX.

---

## 4. Restantes services con `_dataService: any`

Sprint 4 migró Shop/BattlePass/Match a tipos públicos.
Quedan por migrar al patrón `local DataService = require(...).DataServiceModule`:
- `RewardsService` (P2)
- `LockerService` (P2)
- `SettingsService` (P2)
- `StoreService` (P2)
- `DailyTasksService` (P2)
- `ClearDataCommandService` (P3)

**Patrón a aplicar** (copy/paste-able):
```lua
local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

local _dataService: DataService = nil :: any

function MyService:Start(dataService: DataService): ()
    -- ...
end
```

**Esfuerzo**: 1 día total para los 6 archivos.

---

## 5. Otros findings P2/P3 sin tocar

- **`MatchService` con 12+ tablas keyed por userId** → consolidar a
  `_playerState[userId] = {...}` para cleanup atómico (P2 #10).
- **TeamUtils acepta 5 nombres de attribute distintos** — migrar a uno
  solo (`TeamSide`) y eliminar el resto (P2 #19).
- **`KillEffectsRegistry` auto-discovery** sobre folder children en lugar
  de table literal manual (P2 #15).
- **Default.luau y Gravity.luau** duplican R15_JOINTS/R15_WELDS y
  buildRagdoll (~80% código). Extraer `RagdollBase` (P2 #16).
- **PanelController vs FeaturePanelController** — unificar con container
  adapter (P2 #17).
- **UI element name strings hardcoded** en 10+ archivos. Centralizar en
  `UINames.luau` (P2 #19).
- **Per-bullet Heartbeat → global pump** (`BulletWeapon.luau:647`) —
  decenas de connections vivas. Refactor invasivo (P1 #15).
- **Tween caching para hover** (`MenuHover`, `LockerGrid`, etc.) —
  cachear `Tween` por `(instance, target-state)` (P1 #7).
- **PreloadAsync warmup pass** al boot para iconos/rarezas/maps (P1 #13).

Cada item tiene un finding correspondiente en el reporte original con
file:line concretos.

---

## 6. Anti-cheat AAA en WeaponsSystem (Cluster A) — DIFERIDO

El Sprint 1 implementó el server-authoritative damage model recomendado
por la auditoría (Cluster A: A1 falloff bypass, A2 wallhack, A3 headshot
bypass, A4 ROF spam, A5 explosion sin LoS). Se **revirtió** porque
introducía friction de gameplay (rejects en hits legítimos contra NPCs en
movimiento + jitter de red en armas automáticas) sin un threat model real
— el juego está en desarrollo, no hay exploiters activos.

**Estado actual** de `WeaponSecurity.luau`:
- Validación cone+range+sid tracking (estaba en el fork original).
- Bloquea exploits genéricos casuales (auto-aim, hits >maxRange, sids
  fabricados, ownership de arma).
- NO tiene server-side raycast canónico, ROF check, ni reescritura de
  hitInfo en `NetworkingCallbacks.WeaponHit`.

**Cuándo retomar**:
- El juego se lanza y empiezan reportes de exploit reales.
- Aparecen scripts de exploit específicos para tu juego (no genéricos).
- Tenés métricas de damage anómalo en logs (e.g., kill rate por player
  fuera de la distribución esperada).

**Cuando llegue ese momento**:
1. Reimplementar `validateHit` con server raycast desde `data.origin`,
   pero con **fallback de lag** (raycast vacío → validar contra el part
   del cliente si pertenece a humanoid vivo en cone+range). Sin este
   fallback, NPCs en movimiento + jitter rompen gameplay (lección
   aprendida del Sprint 1).
2. Reimplementar reescritura de `hitInfo` en `NetworkingCallbacks.WeaponHit`
   para que el damage downstream use los valores canónicos del raycast.
3. Considerar **lag compensation real** (server rewinds positions a la vista
   del cliente al momento del shot) — es el approach AAA estándar y
   elimina la necesidad de fallbacks. Implementación: ~500 LOC, requiere
   buffer de positions por character con rolling window de ~200ms.
4. ROF check server-side con tolerancia GENEROSA (≥ 50% jitter) — bloquea
   spam pero no friccionar jitter normal.

Referencia: ver el commit del Sprint 1 (revertido en commit posterior)
para el código completo de la implementación previa.
