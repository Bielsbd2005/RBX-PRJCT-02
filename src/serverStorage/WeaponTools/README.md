# WeaponTools

Esta carpeta se sincroniza a `ServerStorage.WeaponTools` (ver `default.project.json`).

Estructura recomendada:

- `Main/<WeaponId>`: Tool real para el arma principal.
- `Special/<WeaponId>`: Tool real para el arma secundaria/especial.

`MatchService` clona al Backpack del jugador:

- `Loadout.MainWeapon` desde `Main/<MainWeaponId>`
- `Loadout.SpecialWeapon` desde `Special/<SpecialWeaponId>`

Fallback: si no existe por categoría, busca directamente en `WeaponTools/<WeaponId>`.

Cada Tool clonada se marca con el atributo `MatchLoadoutTool=true` para limpiarla en respawns.

## Configuración de combate

La Tool **no** lleva `Configuration`: daño, cadencia, recoil, VFX, etc. viven en
`src/shared/constants/WeaponsConfig/Definitions/<Category>/<WeaponId>.luau`
(ver el README de esa carpeta). La Tool sólo aporta geometría, sonidos,
animaciones, el tag `WeaponsSystemWeapon` y el atributo `WeaponCategory`
(`tools/weapons/StudioMigration.luau` lo estampa); el id del arma es el NOMBRE
de la Tool. Sin definición, la Tool no se instancia como arma.

`CurrentAmmo` e `IsReloading` los escribe BaseWeapon en runtime, así que no se
autoran en la Tool. `Shotgun` y `OptimalRange` sí son de la Tool: los leen el
crosshair y el auto-aim.
