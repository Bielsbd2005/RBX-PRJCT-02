# Refactors pendientes

Cada punto es una PR independiente que necesita prueba en Studio. Antes de empezar uno,
comprobar en el código que sigue aplicando.

## MatchService: extraer el tracking de kills

Recompensas y estadísticas del atacante siguen en `MatchService`: `_registerKillEvent`,
`_grantActionRewardsToAttacker`, `_grantMasteryWrapsIfEligible`, `_persistAttackerKillStats`.
Candidato a un servicio propio, como ya se hizo con `VotingService`, `TeamAssignmentService`
y `KillAttributionService`. Riesgo alto: es el flujo de persistencia de XP/Cash; probar
kill/death/XP/cash en Studio antes de mergear.

`_pickBalancedTeam` también sigue en `MatchService` y encajaría en `TeamAssignmentService`.

## Locker: partir `LockerFeature.start`

`client/features/locker/init.luau` es casi entero una función `start`. Subsistemas separables:
población de tabs, action frame (equip/buy/preview), dummies de kill effects y flujo de compra.
Los helpers de tweens/conexiones duplicados con `WeaponPreviewController` irían a un util común.

## Tipar `dataService` en match

`LoadoutService` y `SpawnService` reciben `dataService: any`. Usar el tipo público:

```lua
local DataServiceMod = require(<ruta a core/data/DataService>)
type DataService = DataServiceMod.DataServiceModule
```

## Menores

- `TeamUtils` acepta cinco atributos de equipo (`Team`, `TeamSide`, `BotTeam`, `Side`,
  `TeamAffinity`): unificar en uno.
- `KillEffectsRegistry` registra los efectos a mano; podría descubrirlos por los hijos de la carpeta.

## Anti-cheat de WeaponsSystem — diferido a propósito

Hoy `WeaponSecurity` valida cono + rango + sids + propiedad del arma y limita la cadencia
(`nextShotAllowedAt`). **No** hace raycast canónico en servidor ni reescribe `hitInfo` en
`NetworkingCallbacks.WeaponHit`.

Un modelo de daño server-authoritative completo ya se implementó y se revirtió: rechazaba hits
legítimos contra NPCs en movimiento y con jitter en armas automáticas, sin exploiters reales que
lo justificaran.

Retomarlo cuando haya exploits reales o métricas de daño anómalo. Al hacerlo:
1. Raycast en servidor desde `data.origin` **con fallback de lag**: si el raycast sale vacío,
   aceptar la part del cliente si pertenece a un humanoid vivo dentro de cono + rango.
   Sin ese fallback se rompe el gameplay (fue la causa del revert).
2. Que el daño downstream use los valores canónicos del raycast (reescribir `hitInfo`).
3. Mejor aún: lag compensation real (rebobinar posiciones al instante del disparo con un
   buffer por personaje de ~200 ms), que elimina la necesidad de fallbacks.
