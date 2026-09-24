# Kill effects

Lo que le pasa al cadáver de quien muere, según el kill effect equipado por quien lo mata
(o el que se previsualiza en el Locker y el pase).

## Piezas

| Pieza | Dónde | Qué hace |
| --- | --- | --- |
| Catálogo | `shared/constants/ItemsConfig.luau` → `KillEffects` | Nombre, precio, rareza. La clave es el **id** del efecto. |
| Parte de servidor | `shared/Locker/killEffects/<Id>.luau` | `apply(char): boolean`: ragdoll, ocultar, física… Lo igual para todos. |
| Registro | `shared/Locker/killEffects/KillEffectsRegistry.luau` | Mapa id → módulo. Un id sin módulo cae al `Default`. |
| Parte de cliente | `client/core/visuals/killEffects/<Id>.luau` | Lo cosmético: VFX, sonido, animaciones suaves. Opcional. |
| Runner de cliente | `client/core/visuals/KillEffectVisuals.luau` | Mapa id → handler; arranca la parte de cliente de cada cadáver. |

`apply` corre en el **servidor** en partida (MatchService, AIService) y en el **cliente**
en los previews (Locker, pase). Por eso la parte de cliente no distingue: en los previews
el registry corre en local y el tag es local.

## Contrato servidor → cliente

Tras `apply`, `KillEffectsRegistry` pone en el cadáver:

- el tag `KillEffectsRegistry.TAG`,
- `ATTR.ID`: id del efecto aplicado (ya resuelto),
- `ATTR.STARTED_AT`: `GetServerTimeNow()` de la muerte.

Si el efecto necesita más datos en el cliente (semilla, origen…), los pone como atributos
dentro de su `apply`: llegan antes que el tag.

## Parte de cliente

Un handler exporta cualquiera de:

- `play(char, ctx)`: una vez por cadáver con ese id.
- `start()` / `stop()`: estado propio del módulo (pools, carpetas, listeners propios).

El `ctx` (tipos en `KillEffectTypes.luau`):

- `ctx.startedAt`, `ctx.age()`.
- `ctx.isFresh(tolerancia?)`: si llega a tiempo de lo puntual (sonido, ráfagas); quien
  entra tarde o recibe el cadáver por streaming no lo repite.
- `ctx.add(x)`: Instance, conexión, thread o función que se limpia al terminar.
- `ctx.onFadeOut(fn)`: el cadáver empieza a fundirse (`RagdollCleanup`).
- `ctx.finish()`.

El contexto termina cuando el cadáver sale del DataModel. Lo que deba sobrevivirle
(confeti en el aire, el OVNI que se va, las partículas del cierre del fuego) no se pasa a
`ctx.add`.

## Añadir uno

1. Entrada en `ItemsConfig.KillEffects` (o sustituir un `KE_Pxx` con su precio, nivel y rareza).
2. Módulo en `shared/Locker/killEffects/` y su línea en `KillEffectsRegistry`. Si solo es
   el ragdoll de Default, reutilizar `DefaultKillEffect` en el registro.
3. Si tiene parte de cliente: módulo en `client/core/visuals/killEffects/` y su línea en
   `HANDLERS` de `KillEffectVisuals`.
4. Sonido de `SoundService.Audio.Gameplay`: clave en `GameSounds` y en
   `tools/audio/SetupSoundService.luau` (ver `AUDIO.md`).

## Reglas del cadáver

- Ocultar, no destruir: lo destruyen sus dueños (MatchService, AIService, Locker,
  ScenePreview) y la KillCam sigue leyendo su `HumanoidRootPart`.
- El `HumanoidRootPart` se queda anclado en el punto de muerte.
- `Utils.makeCorpseInert`: sin query (no para balas) y en el grupo de colisión RAGDOLL.
- La ropa y los accesorios cuelgan de su parte del cuerpo: `Utils.ownerBodyPart`.
