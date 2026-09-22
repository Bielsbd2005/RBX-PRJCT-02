# Zona de fuego (flare gun)

Un arma con `FireZoneOnImpact = true` (hoy `Special/Flare`) deja, al impactar, una zona
de fuego en el suelo que daña a los enemigos que haya dentro. Código:
`WeaponsSystem/Libraries/FireZone.luau`, invocado desde `BulletWeapon:onHit` en el servidor.

## Cómo funciona

- El servidor crea la zona a partir del impacto ya validado por `WeaponSecurity`. Con un
  raycast hacia abajo la apoya en el primer suelo, así que si el flare da a un jugador,
  arde a sus pies.
- Cada 0,5 s aplica `FireZoneDamage × 0,5` a los enemigos (`TeamUtils.areEnemies`) cuyo
  HumanoidRootPart esté dentro del círculo. Nunca daña al tirador, y cada jugador recibe
  como mucho un tick por tirador aunque pise varias zonas suyas.
- El daño pasa por `WeaponsSystem.doDamage` con `damageData.Name` = id del arma. Cuenta
  para kills, asistencias, kill feed y kills por arma aunque el tirador haya cambiado de arma.
- La zona se apaga si el tirador muere o sale del juego: `doDamage` no aplica daño sin un
  dealer con Character.
- Cada jugador tiene como mucho 3 zonas activas; al crear la cuarta se apaga la más antigua.
- Sin remotes: la Part de la zona se crea en Workspace y replica sola.

Config: `FireZoneRadius`, `FireZoneDuration`, `FireZoneDamage` (defaults en `Schema.luau`).

## Setup en Studio

- `ReplicatedStorage.WeaponsSystem.Assets.Effects.FireZone` (opcional): un Folder cuyos
  hijos (ParticleEmitters, PointLight, Sound…) se clonan dentro del disco de la zona.
  El disco mide 2·radio de diámetro, así que un emitter en modo Box o Cylinder cubre
  toda la zona. Sin el Folder se usa un `Fire` básico y un disco naranja semitransparente.
- `Assets.Effects.Shots.Flare`: el proyectil. Si no existe, el arma usa `Bullet` y lo
  avisa con un warning.
- Tool `ServerStorage.WeaponTools.Special.Flare`, con la misma estructura que el resto de
  armas especiales (ver `WeaponsConfig/README.md`).
