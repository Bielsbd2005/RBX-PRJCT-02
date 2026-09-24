# Piezas móviles de las armas (Bolt, Pump y SniperBolt)

`WeaponsSystem/Libraries/WeaponBolt.luau`, invocado desde `BulletWeapon`. En cada
disparo las piezas móviles se desplazan y vuelven. Hay tres grupos, cada uno con su config:

- **`Bolt`** (cerrojo, corredera): movimiento corto e inmediato. Con el cargador vacío
  se queda abierto hasta que termina la recarga.
- **`Pump`** (corredera de escopeta): empieza un poco después del disparo y hace un
  recorrido más largo y lento.
- **`SniperBolt`** (cerrojo de sniper de cerrojo): va **hacia delante** (hacia la boca)
  un poco después del disparo y vuelve, con un ciclo lento. Los snipers cuyo cerrojo
  va hacia atrás usan `Bolt` normal.

## Setup en Studio

1. La pieza móvil debe ser una `BasePart` separada, dentro del Tool, llamada
   exactamente **`Bolt`**, **`Pump`** o **`SniperBolt`**. Puede haber varias de cada una.
2. Tiene que estar unida a otra parte del arma con un `Weld`, `Motor6D` o
   `WeldConstraint`. No puede ser el `PrimaryPart` del Model ni el `Handle`.
3. El arma necesita su `TipAttachment` (el que ya usa el disparo).

El eje de movimiento es el eje local de la pieza más alineado con la dirección
boca → `Handle` (`Handle` → boca en `SniperBolt`). Si la pieza está rotada y se mueve
en una dirección rara, ponle un atributo `BoltAxis` (Vector3, espacio local de la parte)
con la dirección de ida.

`Pump` y `Barrel` también reciben el wrap del arma (`Shared/Locker/WeaponWrapParts.luau`).

## Config (`WeaponsConfig`)

Por grupo, con prefijo `Bolt`, `Pump` o `SniperBolt`:

- `…Travel`: recorrido en studs.
- `…CycleTime`: duración de ida y vuelta. Por defecto se deriva del cooldown.
- `…Delay`: segundos entre el disparo y el inicio del movimiento.
- `…LockOnEmpty`: si se queda en el tope de ida con el cargador vacío.

Defaults en `WeaponsConfig/Schema.luau`. En una escopeta de bombeo el cerrojo va unido
al Pump: pon a `Bolt` el mismo `Delay` y `CycleTime` que al `Pump` para que se muevan juntos.

## Apertura al recargar (`ReloadHinge.luau`)

Aparte de los grupos anteriores, la pieza llamada **`Barrel`** gira sobre su **eje Z local**
al empezar la recarga (como el tambor de un revólver al abrirse para sacar el casquillo),
se queda abierta mientras dura y vuelve con un tween al terminar.

- `ReloadHingeAngle`: grados. 0 desactiva la apertura, que es el default; un valor negativo
  la abre hacia el otro lado.
- `ReloadHingeOpenTime` / `ReloadHingeCloseTime`: segundos de ida y de vuelta.

Studio: un `Attachment` llamado `Hinge` hijo de la pieza marca dónde está la bisagra; sin
él la pieza gira sobre su propio centro. Para girar sobre otro eje, ponle a la pieza un
atributo `HingeAxis` (Vector3, espacio local de la parte). La pieza `Barrel` no puede ser el `PrimaryPart` del
Model ni el `Handle`: girarlos movería el arma entera.

## Notas

- Todo pasa en cliente y no replica: cada cliente anima las armas de todos desde
  `simulateFire`.
- Un `WeldConstraint` no admite offset, así que en cliente se desactiva y se sustituye
  por un `Weld` local (`BoltClientWeld`).
