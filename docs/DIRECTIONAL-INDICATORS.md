# Indicadores de dirección

Marcadores que orbitan el centro de la pantalla y apuntan a un punto del mundo.
Giran con la cámara mientras están vivos, así que siguen señalando el mismo sitio
aunque te des la vuelta.

| Marcador | Señala | Cuántos a la vez |
| --- | --- | --- |
| `DamageIndicator` | Desde dónde te han hecho daño | Uno por dirección |
| `CombatIndicator` | El tiroteo más cercano (sonido visualizado) | Uno |

En los dos, cada golpe o disparo hace un "pop" de escala y reinicia la espera antes
del fundido. Cada uno clona su plantilla de Studio.

## DamageIndicator

- Los golpes que llegan desde casi el mismo ángulo (una ráfaga) refrescan el
  marcador existente y lo mueven al origen nuevo; un atacante en otra dirección saca
  otro marcador.
- El origen es la posición del atacante **en el momento del golpe**: el marcador no
  lo persigue después.

Flujo: `WeaponsSystem.doDamage` (jugadores) y `applyBotDamage` (bots) llaman a
`_notifyVictimHit`, que manda `WeaponData:FireClient(víctima, "HitByOtherPlayer", posición)`.
El daño que no pasa por esas dos funciones (caídas) y el que te haces a ti mismo no
mandan nada. El fuego y las explosiones apuntan a quien los lanzó, no al punto de
impacto.

## CombatIndicator

Apunta al personaje cuyo disparo acaba de sonar en tu cliente, para poder ir al
combate jugando sin sonido.

- Cuentan los disparos de jugadores y bots que no son de tu equipo; los tuyos y los
  de compañeros no.
- Solo hay un marcador. Mientras un tiroteo sigue sonando, otro más lejano no se lo
  quita; uno más cercano sí. Cuando el primero calla durante `HOLD_TIME`, lo toma
  el siguiente que dispare.
- Mientras haya un `DamageIndicator` en pantalla no se muestra: si te están dando ya
  sabes dónde está el combate. El primer golpe lo oculta al instante y vuelve con
  el primer disparo ajeno tras apagarse el último marcador de daño.
- No hay red propia: sale de `BulletWeapon:simulateFire`, el mismo punto que
  reproduce el sonido `Fired`. El alcance es por tanto el del broadcast de disparos
  (`GameConfig.ShotBroadcast*`), incluido su recorte de disparos lejanos de bots.

## Setup de Studio

```
WeaponsSystemGui/
  ScalingElements/
    DirectionalIndicators/     (Folder)
      DamageIndicator          (Frame)  ← plantilla, se clona por marcador
        UIAspectRatioConstraint
        <ImageLabel>
      CombatIndicator          (Frame)  ← misma estructura
```

- Los Frames se llaman EXACTO `DamageIndicator` y `CombatIndicator` y van centrados
  en pantalla: `AnchorPoint = (0.5, 0.5)`, `Position = (0.5, 0, 0.5, 0)`, fondo
  transparente. El código gira el Frame entero, no la imagen.
- El dibujo va **apuntando hacia arriba**: `Rotation = 0` es un origen de frente.
- La `Position` del `ImageLabel` dentro del Frame es el radio de la órbita: cuanto
  más arriba del centro, más lejos de la mira. Su nombre da igual (se usa el primero
  que haya).
- El `Size` del Frame es el tamaño del marcador; en escala se reescala con
  `ScalingElements`, y el `UIAspectRatioConstraint` lo mantiene cuadrado porque ese
  reescalado pesa distinto X e Y.
- `Visible` da igual: el código oculta la plantilla y solo muestra los clones.
- Si falta una plantilla hay un `warn` al crear la GUI y ese marcador no se muestra;
  el otro sigue funcionando.

Tiempos y efecto son constantes de `Gui/DirectionalIndicators.luau`: `HOLD_TIME`,
`FADE_TIME`, `POP_SCALE`, `POP_TIME`, y para el daño `MERGE_ANGLE` y
`MAX_DAMAGE_MARKERS`.

## Archivos

| Archivo | Rol |
| --- | --- |
| `src/server/WeaponsSystem/Libraries/Gui/DirectionalIndicators.luau` | Marcadores, rotación y fundido. |
| `src/server/WeaponsSystem/WeaponsSystem.luau` | `_notifyVictimHit`: aviso de daño a la víctima. |
| `src/server/WeaponsSystem/WeaponTypes/BulletWeapon.luau` | `simulateFire`: aviso de disparo oído. |
