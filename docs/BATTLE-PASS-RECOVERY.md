# Recuperar el Battle Pass

El Battle Pass ("FamePass" en la UI) no está en el juego. Su código completo y
funcionando, integrado con el resto, vive en el tag de git **`battle-pass-final`**.
Esta guía dice qué hay ahí, qué se tocó al quitarlo y cómo volver a montarlo.

> **Regla fija:** los wraps del pase (`Wrap_Pink`, `Wrap_RPG_Blue`, `Wrap_S1_*`)
> se retiraron para siempre y la migración v5 los borró de los perfiles. **No se
> restauran.** Un pase nuevo lleva wraps nuevos con ids nuevos.

## Ver el código archivado

```bash
git show battle-pass-final:src/server/features/battlepass/BattlePassService.luau
```

```bash
git diff battle-pass-final main --stat
```

El primero lee un archivo tal cual estaba. El segundo da la lista exacta de lo
que cambió desde entonces (incluye trabajo posterior, no solo la retirada).

Si el tag no está en el remoto, súbelo: sin eso solo existe en esta máquina.

```bash
git push origin battle-pass-final
```

## Qué se borró entero

Se recuperan con `git checkout battle-pass-final -- <ruta>`.

| Ruta | Qué es |
| --- | --- |
| `src/server/features/battlepass/BattlePassService.luau` | XP por kill, claim de tiers, Premium con Gems, skips con Robux (ProcessReceipt), reset por season, telemetría |
| `src/client/features/battlepass/` | Panel (`init`), casillas (`BattlePassSlots`), lectura de recompensas (`BattlePassRewards`), compras (`BattlePassPurchases`) y escena 3D (`ScenePreview`) |
| `src/shared/constants/BattlePassConfig.luau` | API de seasons/tiers, `IsBPExclusive`, resolución de receipts |
| `src/shared/constants/BattlePassSeasons.luau` | Datos de seasons. Lo **genera el dashboard de Telemetry**: regenerarlo desde allí, no copiar el viejo |

El contrato de nodos de Studio del panel está en la cabecera de
`client/features/battlepass/init.luau` y de `ScenePreview.luau`.

## Qué se desconectó (hay que volver a cablear)

En estos archivos solo se quitó el enganche. Compara cada uno con el tag
(`git diff battle-pass-final main -- <ruta>`) y reintroduce la parte del pase.

**Servidor**
- `server/bootstrap/ServerBootstrap.luau`: `require` + `BattlePassService:Start`,
  el primer paso del dispatcher de `ProcessReceipt` y la inyección en
  `WeaponsSystem.injectServices`.
- `server/WeaponsSystem/WeaponsSystem.luau`: upvalue, autoload y campo
  `BattlePassService` de `injectServices`.
- `server/features/match/KillRewardsService.luau`: `_tryConsumeBattlePassXP`
  (cupo de XP de pase por ronda) y la llamada a `BattlePassService:OnKill`.
- `server/features/match/MatchService.luau`: `bpXpEarnedByUserId` en la ronda.
- `server/features/match/MatchResultsService.luau`: snapshot `bpTier` y los ítems
  `source = "Pass"` en Resultados.
- `server/features/shop/ShopService.luau`: rechazo de ítems exclusivos del pase.
- `server/core/TelemetryService.luau`: bloque `payload.battlePass` y los
  `PurchaseKind` `BattlePassPremium` / `SkipTier`.

**Compartido**
- `shared/networking/Network.luau`: namespace `BattlePass` (`ClaimTier`,
  `BuyPremium`, `Response`) y `ClaimTierPayload`.
- `shared/constants/DataTemplate.luau`: tipo `BattlePassState` y bloque
  `BattlePass` del perfil.
- `shared/constants/ItemsConfig.luau`: campo `isBPExclusive` y los campos
  `Season` / `SeasonTier` de los ítems.
- `shared/constants/AssetIds.luau`: `Images.GemsReward` y `Animations.PreviewIdle`.

**Cliente**
- `client/bootstrap/ClientBootstrap.luau`: `require` y arranque de la feature.
- `client/core/data/DataController.luau`: `DataController.BattlePass` y su listener.
- `client/core/ui/MenuController.luau`: widget `Menu.Container.FamePass`
  (season, timer, nivel, barra) y su hover.
- `client/core/ui/UIUtils.luau`: `formatTimeLeft` (timer de la season).
- `client/core/ui/GameSounds.luau`: sonido `FamePassUp`.
- `tools/audio/SetupSoundService.luau` y `MeasureLoudness.luau`: entradas de `FamePassUp`.
- `client/core/ui/PreviewHighlightPanels.luau`: panel `BattlePass`.
- `client/features/match/`: toast "FAME PASS!" (`MatchNotificationsQueue`,
  `MatchHud`, `MatchProgressionObserver`).
- `client/features/locker/LockerCatalog.luau`: `isBPExclusive`, ocultar exclusivos
  no poseídos y badge de season ("S1").

## Datos de jugadores

- La migración **v5** (`server/core/data/DataMigrations.luau`) borró
  `data.BattlePass` y los wraps del pase de inventario, metadata y loadout.
  Es forward-only: lo borrado no vuelve.
- Al restaurar `DataTemplate.BattlePass`, `Reconcile` lo rellena con valores por
  defecto y `SeasonId = ""` fuerza el reset de season: todos empiezan de cero.
  No hace falta otra migración salvo que cambie la forma.
- Los ítems no-wrap del pase S1 se quedaron en el inventario de quien los tenía.

## Ítems que pasaron al Locker

Sin el pase, estos ítems se compran en el Locker (precios provisionales en
`ItemsConfig`, a calibrar en el dashboard):

| Categoría | Ítems |
| --- | --- |
| KillEffects | `Gravity`, `Abduction` |
| Faces | `Blep`, `Derp`, `Scream` |
| Hats | `Snorkel` |
| Outfits | `Ducky` (Gems) |
| Banners | `Banner1`, `Banner2` |

Si un pase nuevo quiere alguno como exclusivo, hay que volver a ponerle
`CanPurchase = false` y decidir qué pasa con quien ya lo compró.

Los banners eran solo del pase: la vista de banners del Locker
(`LockerBanners`) ahora muestra también los comprables y se compran desde el
ActionFrame.

## Studio

Los Instances del pase están en **`DependenciasBattepass.rbxl`**, guardado en
el tag (no en `main`). Para sacarlo:

```bash
git show battle-pass-final:DependenciasBattepass.rbxl > /tmp/DependenciasBattepass.rbxl
```

Ábrelo en Studio y copia cada Instance a su mismo sitio en el place del juego:

- `StarterGui.UserInterface.BattlePass`: el panel. El `UserInterface` del archivo
  trae también el resto de paneles tal como estaban: copia solo `BattlePass`.
- `StarterGui.Menu.Container.FamePass`: botón y widget del menú.
- `Workspace.BattlePass`: peanas de la escena 3D (`HeadSpawn`, `WrapSpawn`,
  `DummySpawn`, `PileSpawn`, `Banner`).
- `Workspace.Scenes.BattlePass`: decorado de la escena.
- `Workspace.Cameras.battlepass`: cámara del panel (atributo `LightingPreset`).
- `ReplicatedStorage.LightingPresets.Battlepass`: el preset de luz de esa cámara.
- `ReplicatedStorage.Templates.HeadTemplate`, `CoinPile`, `GemPile`.

No están en el archivo:

- El sonido `SoundService.Audio.UI.FamePassUp` (ver `docs/AUDIO.md`): hay que
  volver a subirlo y añadir su entrada en `tools/audio/SetupSoundService.luau`
  y `tools/audio/MeasureLoudness.luau`.
- `Shared.Locker.wraps.S1`: los SurfaceAppearances de los wraps del pase. No
  se recuperan (regla de arriba).

## Fuera de este repo

- **Dashboard de Telemetry:** genera `BattlePassSeasons.luau` y lee
  `payload.battlePass` y las compras `BattlePassPremium` / `SkipTier`.
- **Developer products de Roblox:** los skips (+1 y +5 niveles) siguen creados
  en el panel; sus ids están en `BattlePassSeasons.luau` del tag. Mientras el
  pase no esté, deben estar fuera de venta: sin `BattlePassService`, un receipt
  suyo no lo procesa nadie.

## Orden sugerido para reintegrarlo

1. Restaurar los módulos borrados y regenerar `BattlePassSeasons.luau` desde el
   dashboard, con recompensas que existan en `ItemsConfig` hoy.
2. Restaurar `DataTemplate.BattlePass` y `Network.BattlePass`.
3. Recablear servidor (bootstrap, receipts, XP por kill, Resultados, tienda).
4. Recablear cliente (bootstrap, DataController, menú, toast, Locker).
5. Reimportar los Instances de Studio desde `DependenciasBattepass.rbxl`.
6. Decidir la exclusividad de los ítems que ahora se venden en el Locker.
7. `selene src` y `rojo build`, y probar en Studio: XP por kill, claim free/premium,
   compra de Premium con Gems, skip con Robux y reset al cambiar `ActiveSeasonId`.
