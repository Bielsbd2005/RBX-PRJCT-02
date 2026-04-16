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
