# CLAUDE.md

## Comentarios

Solo lo que el código no dice por sí mismo:
- El porqué no obvio de una decisión, trampas y quirks de Roblox/Luau.
- Contratos entre archivos ("debe coincidir con X en Y") y requisitos de Studio (cómo debe llamarse un Instance para que el código lo encuentre).
- TODOs vigentes.

Nunca:
- Historial: fechas, "antes era…", "se cambió", quién lo pidió. Eso va en el mensaje del commit.
- Pasos de migración o de Studio de un solo uso.
- Paráfrasis del código ni banners de sección.
- Cifras que ya viven en config o en `docs/` (precios, recuentos): enlaza el doc.

Breves: 1-3 líneas. Al tocar un comentario existente que incumple esto, recórtalo.

## Docs

`docs/` describe cómo funcionan las cosas HOY (contratos, flujos, setup de Studio).
- No guardar auditorías ni informes en el repo: los hallazgos se arreglan o van a
  `docs/REFACTORS.md`; el informe va en la conversación o en el PR.
- Sin fechas, cifras de LOC ni números de línea: se quedan viejos.
- Al auditar, juzga el código actual; no des por buenos hallazgos de docs antiguos.

## Verificar

- No hay tests ni CI. Tras cambiar código: `selene src` (sin warnings nuevos) y
  `rojo build default.project.json -o /tmp/Shooter.rbxlx`.
- El resto se prueba en Studio: al terminar, di qué probar y cómo.

## Studio vs disco

- Parte del juego solo existe en Studio: GUIs, `ReplicatedFirst.LoadingScreenGui`,
  Accessories de `Shared/Locker/Hats`, Tools de armas. Rojo no los borra por
  `$ignoreUnknownInstances`.
- Si un cambio exige tocar Studio (crear, renombrar o borrar un Instance), dilo
  explícitamente al final: no puedes hacerlo tú.

## Fuentes externas

- `shared/constants/BattlePassSeasons.luau` lo genera el dashboard de Telemetry
  (otro repo): no editar a mano.
- Los docs de diseño de la economía viven en ese repo, no aquí.

## Red y confianza

- Remotes en `shared/networking/Network.luau` (ByteNet). El servidor valida el
  payload con `NetGuards` y revalida catálogo y posesión: nunca confiar en el cliente.
- Assets de lógica (UI, VFX, sonidos) en `AssetIds.luau`; las imágenes de catálogo
  son un campo del ítem en `ItemsConfig`.

## Commits
En español; el título describe el efecto en el juego, no el archivo tocado.
