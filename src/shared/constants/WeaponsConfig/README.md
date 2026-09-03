# WeaponsConfig

Fuente única de verdad de la configuración de **combate** de cada arma. Se
sincroniza a `ReplicatedStorage.Shared.constants.WeaponsConfig`, así que la leen
por igual servidor, cliente y bots.

```
WeaponsConfig/
  init.luau          registro: carga, valida y expone las definiciones
  Types.luau         tipos por WeaponType (BaseWeaponConfig, BulletWeaponConfig…)
  Schema.luau        claves válidas, tipo y default POR TIPO DE ARMA
  DisplayStats.luau  stats derivados para UI (locker)
  Definitions/
    Main/<Id>.luau      una definición por arma principal
    Special/<Id>.luau   una definición por arma especial
```

## Añadir o balancear un arma

1. Crea o edita `Definitions/<Category>/<Id>.luau`. `<Id>` es el mismo id de
   `ItemsConfig` y el nombre del Tool en `ServerStorage.WeaponTools.<Category>`.
2. Declara `WeaponType` (`BulletWeapon` | `BowWeapon`) y en `Config` sólo las
   claves que difieran del default. Claves y defaults: `Schema.luau`.
3. El Tool de Studio ya no lleva `Configuration`; sólo necesita el atributo
   `WeaponCategory` (lo estampa `tools/weapons/StudioMigration.luau`, y de nuevo
   `LoadoutService` en cada clon). El id es el NOMBRE del Tool. `CurrentAmmo` e
   `IsReloading` tampoco se autoran: los escribe BaseWeapon al instanciar el arma.

Una clave mal escrita o con tipo incorrecto **falla en Studio** al arrancar
(en producción es un `warn`). Un Tool sin definición **no se instancia** como
arma: WeaponsSystem avisa y la ignora.

## Runtime

- `BaseWeapon:loadConfigFromDefinition()` vuelca `Config` en `configValues`;
  `getConfigValue(key, default)` y el escalado por nivel (`WeaponLevelConfig`)
  no cambian.
- El servidor arranca el arma con el cargador lleno (`CurrentAmmo` =
  `AmmoCapacity` de la definición, escalado por nivel) y replica el atributo al
  cliente para el hotbar.
- Los Tools que viven en un almacén (`ServerStorage`, `ReplicatedStorage`) son
  templates: `WeaponsSystem.onWeaponAdded` los ignora aunque lleven el tag.
- `WeaponsSystem.createWeaponForInstance` toma `WeaponType` de la definición;
  el Tool ya no necesita ese atributo.
- `Hotbar` y `BotAI` leen `AmmoCapacity` / `ShotCooldown` vía
  `WeaponsConfig.GetValueForTool(tool, key)`.
- El locker pinta stats con `DisplayStats` en local; ya no existe
  `Network.WeaponStats` ni `WeaponStatsService`.
