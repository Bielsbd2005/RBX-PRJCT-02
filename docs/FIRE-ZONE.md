# Zona de fuego (flare gun)

Un arma con `FireZoneOnImpact = true` (hoy `Special/Flare`) deja, al impactar, una zona
de fuego en el suelo que daña a los enemigos que haya dentro. Código:
`WeaponsSystem/Libraries/FireZone.luau`, invocado desde `BulletWeapon:onHit` en el servidor.

## Cómo funciona

- El servidor crea la zona a partir del impacto ya validado por `WeaponSecurity`. Con un
  raycast hacia abajo la apoya en el primer suelo.
- Impacto directo a un enemigo: se le prende al instante (`FireZone.ignite`) y la zona se
  apoya bajo su HumanoidRootPart, no bajo el punto del cuerpo donde entró la bengala.
- Cada 0,5 s aplica `FireZoneDamage × 0,5` a los enemigos (`TeamUtils.areEnemies`) cuyo
  HumanoidRootPart esté dentro del círculo. Nunca daña al tirador.
- Quedarse dentro prende al personaje: el fuego del cuerpo y el daño siguen 2 s tras salir
  de la zona y se refrescan mientras siga dentro. El estado es por humanoid, así que dos
  zonas del mismo tirador no apilan daño.
- Cada tick avisa al cliente del tirador por el remote `DamageOverTimeVFX`, que reproduce
  el mismo feedback que un disparo (marcador, contorno sobre la víctima y número de daño).
  El cliente solo predice el feedback de sus propios impactos, de ahí el remote.
- El daño pasa por `WeaponsSystem.doDamage` con `damageData.Name` = id del arma. Cuenta
  para kills, asistencias, kill feed y kills por arma aunque el tirador haya cambiado de arma.
- La zona se apaga si el tirador muere o sale del juego: `doDamage` no aplica daño sin un
  dealer con Character.
- Cada jugador tiene como mucho 3 zonas activas; al crear la cuarta se apaga la más antigua.
- El fuego no usa remotes: la Part de la zona y el efecto del cuerpo se crean en el
  servidor y replican solos. El único remote es el feedback del tirador.

Config: `FireZoneRadius`, `FireZoneDuration`, `FireZoneDamage` (defaults en `Schema.luau`).

## Setup en Studio

- `ReplicatedStorage.WeaponsSystem.Assets.Effects.FireZoneBody` (opcional): el efecto que
  se cuelga del HumanoidRootPart mientras el cuerpo arde. Sin él se usa un `Fire` básico.
- `ReplicatedStorage.WeaponsSystem.Assets.Effects.FireZone`: el efecto. Si es un Folder o
  un Model se clonan sus hijos (ParticleEmitters, PointLight, Sound…) dentro del disco de
  la zona; si no, se clona él mismo. El disco es invisible y mide 2·radio de diámetro, así
  que un emitter en modo Box o Cylinder cubre toda la zona. Sin el asset la zona quema pero
  no se ve, y avisa por consola.
- `Assets.Effects.Shots.Flare`: el proyectil. Si no existe, el arma usa `Bullet` y lo
  avisa con un warning.
- Tool `ServerStorage.WeaponTools.Special.Flare`, con la misma estructura que el resto de
  armas especiales (ver `WeaponsConfig/README.md`).
