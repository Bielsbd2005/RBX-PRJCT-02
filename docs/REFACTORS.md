# Refactors pendientes

Cada punto es una PR independiente que necesita prueba en Studio. Antes de empezar uno,
comprobar en el código que sigue aplicando.

## MatchService: subsistemas separables

El pago de las kills ya vive en `KillRewardsService`. Quedan en `MatchService`: la tarjeta
de muerte (`_registerDeathListener`, `_resolveEquippedBanner`, `_applyKillEffect`), el reparto
de resultados (el bloque de `_enterResults` que calcula MVP y persiste partidas; encaja en
`MatchResultsService`) y el puente de roster con AI (`_broadcastBotRoster`, `_doRebalanceNow`).

## WeaponsSystem

- Los 23 archivos que pasaron a `--!strict` sin un type checker a mano (casi todo el
  WeaponsSystem, más `LoadingScreen.client`) tendrán errores en el Script Analysis de Studio.
  No afectan a la ejecución; corregirlos archivo a archivo, empezando por `NetworkingCallbacks`
  y `WeaponSecurity` (tipar `fireInfo`/`hitInfo` como `export type`).
- Archivos gigantes: `BulletWeapon` (pool de balas, simulador de proyectil, marcas de impacto,
  view kick, y la parte de servidor `onHit`/daño/explosión/FireZone), `ShoulderCamera`
  (oclusión, shake/recoil, input táctil/gamepad, transparencia; y la rama de sprint, que no
  activa nadie), `BotAI` (targeting, disparo, rig; el FSM de `Start` partido por estado).

## Tipar `dataService` en match

`LoadoutService` y `SpawnService` reciben `dataService: any`. Usar el tipo público:

```lua
local DataServiceMod = require(<ruta a core/data/DataService>)
type DataService = DataServiceMod.DataServiceModule
```

## Menores

- Ítems con `Image = "rbxassetid://0"` siguen con `CanPurchase = true` (se cobran y no se
  ven). Decidir si se ocultan hasta tener arte y validarlo al cargar `ItemsConfig`.
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
