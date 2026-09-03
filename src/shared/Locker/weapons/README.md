# Locker / weapons

Modelos de display de las armas: `Shared.Locker.weapons.<Category>.<WeaponId>`.
Geometría pura (no Tools) que enseñan el locker (`WeaponWrapPreviewer`, dentro
de un ViewportFrame) y el holster de la espalda (`BackWeaponService`).

**No se autoran aquí.** Se GENERAN desde el `WeaponModel` de la Tool real
(`ServerStorage.WeaponTools.<Category>.<WeaponId>`) ejecutando
`tools/weapons/StudioMigration.luau` en la barra de comandos de Studio. La
geometría del arma se monta una sola vez, en la Tool; tener una segunda copia
autorada a mano era la única pieza duplicada del arma y las dos se
desincronizaban.

Cada modelo generado lleva el atributo `GeneratedFromWeaponTool = true`. El
script reemplaza los suyos sin preguntar y respeta los que no lo llevan (los
autorados a mano antes de la migración): para migrar esos, pon
`OVERWRITE_HANDAUTHORED = true` una vez, tras revisar el listado con `DRY_RUN`.

Rojo crea estas carpetas vacías (`init.meta.json` → `ignoreUnknownInstances`) y
no toca lo que haya dentro, así que lo generado vive en el place — **guárdalo**
después de ejecutar el script. `globIgnorePaths` (`default.project.json`) evita
que un `.rbxm` suelto vuelva a sincronizarse.

Resolución en runtime (`CosmeticsTemplates.findWeaponDisplayTemplate`):
`<WeaponId>` → `Name` del catálogo → `Default`. Nombra siempre por id: el
script avisa de los nodos que no corresponden a ninguna Tool.
