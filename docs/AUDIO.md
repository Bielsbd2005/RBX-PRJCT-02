# Audio — estructura de SoundService

Todo el audio autorado del juego vive bajo `SoundService.Audio`. La estructura
la monta el script de consola **`tools/audio/SetupSoundService.luau`**: pégalo en
la Command Bar de Studio y pulsa Enter. Es idempotente, no borra nada (lo que no
reconoce lo aparca en `Audio/_Unsorted`) y se puede deshacer con Ctrl+Z.

```
SoundService
├─ Master (SoundGroup)        ← bus de mezcla general
│   ├─ Music    (SoundGroup)
│   ├─ UI       (SoundGroup)
│   └─ Gameplay (SoundGroup)
├─ Audio (Folder)             ← ÚNICO sitio donde autorar
│   ├─ Music/
│   │   └─ Lobby
│   ├─ UI/
│   │   ├─ Click
│   │   ├─ Open
│   │   ├─ OpenStore
│   │   ├─ Close
│   │   ├─ Error
│   │   ├─ Toggle
│   │   ├─ Notification
│   │   ├─ Purchase
│   │   ├─ Coin
│   │   ├─ LevelUp
│   │   └─ FamePassUp
│   └─ Gameplay/
│       ├─ Hit
│       ├─ Headshot
│       ├─ Elimination
│       ├─ Health
│       ├─ BalloonPop
│       ├─ XpOrb
│       ├─ Confetti
│       ├─ Electrocution
│       └─ Explosion
└─ Runtime (Folder)           ← clones del juego; no autorar aquí
```

Las tres carpetas de `Audio` son espejo de los tres buses: cada `Sound` sale
ruteado al `SoundGroup` de su categoría por su propiedad `SoundGroup`, y los
tres buses cuelgan de `Master` **por parentesco**. Un `SoundGroup` no tiene
propiedad `SoundGroup`: no se rutea a otro bus, se mete dentro de él. Así bajar
`UI.Volume` baja solo la interfaz y bajar `Master.Volume` baja todo.

Para comprobar que la cascada de `Master` funciona en tu versión de Studio, pon
`Master.Volume` a 0 y reproduce cualquier sonido: si se oye, la cascada no está
aplicando y hay que ajustar los tres buses por separado.

## Qué dispara cada sonido

| Sonido | Cuándo suena | Dueño |
| --- | --- | --- |
| `UI/Click` | Click en cualquier `GuiButton` | `UISoundsController` |
| `UI/Open` | Se abre un panel o el Locker | `PanelController`, `locker`, `GiftFlow` |
| `UI/OpenStore` | Se abre la tienda, y solo la tienda | `features/store` |
| `UI/Close` | Se cierra un panel o el Locker | idem |
| `UI/Error` | Cada `Notify.warning(...)` | `NotificationController` |
| `UI/Toggle` | Un toggle de Settings cambia de estado | `ToggleController` |
| `UI/Notification` | Desafío diario completado o hito de maestría de wraps | `MatchNotificationsQueue` |
| `UI/Purchase` | El server confirma una compra del Locker | `features/locker` |
| `UI/Coin` | Cada moneda que aterriza en el frame de Stats | `StatsCoinsPopup` |
| `UI/LevelUp` | Subes de nivel de cuenta en partida | `MatchNotificationsQueue` |
| `UI/FamePassUp` | Subes de nivel del FamePass en partida | `MatchNotificationsQueue` |
| `Gameplay/Hit` | Impacto de bala a un jugador | `DamageBillboardHandler` |
| `Gameplay/Headshot` | Impacto a la cabeza | `DamageBillboardHandler` |
| `Gameplay/Elimination` | Matas o asistes a un jugador | `NetworkingCallbacks` |
| `Gameplay/Health` | Recoges el orbe de vida | `PickupDropEffect` |
| `Gameplay/BalloonPop` | Revienta cada globo del kill effect Balloons (3D, tono ascendente por globo) | `visuals/killEffects/Balloons` |
| `Gameplay/XpOrb` | Recoges un orbe del kill effect XpOrbs (3D, tono aleatorio, uno tras otro) | `visuals/killEffects/XpOrbs` |
| `Gameplay/Confetti` | Muere alguien con el kill effect Confetti (3D en el punto de muerte, tono aleatorio) | `visuals/killEffects/Confetti` |
| `Gameplay/Electrocution` | Muere alguien con el kill effect Electrocution (3D en el cadáver, tono aleatorio) | `visuals/killEffects/Electrocution` |
| `Gameplay/Explosion` | Impacto de un proyectil explosivo, p. ej. el RPG (3D en el punto de impacto) | `NetworkingCallbacks` |
| `Music/Lobby` | Música del lobby (loop, con EQ de muffle) | `features/music` |

Los botones llamados `CloseBtn` **no** reproducen `Click`: el panel que cierran
ya reproduce `Close`, y sonar los dos a la vez se oye como un doble click. Por
lo mismo, el `HitArea` de un toggle lleva el atributo `NoClickSound`: su sonido
es `Toggle`, no `Click`.

Las dos subidas de nivel comparten el mismo frame del HUD pero **no** el mismo
sonido, que es lo que permite distinguir de cuál vienes sin mirar la pantalla.

Los sonidos de notificación suenan dentro de la cola, cuando el frame entra de
verdad, no cuando se pide. Si hay otra notificación en curso la siguiente puede
esperar segundos, y el sonido tiene que ir con la imagen.

Las aperturas automáticas (la pantalla de votación al acabar la ronda) y los
saltos entre paneles hermanos (Settings ⇄ Credits) pasan `silent = true` a
`PanelController:open()` / `:close()` para no sonar.

Un panel puede pedir su propio sonido con las opciones `openSound` / `closeSound`
de `PanelController`. Hoy solo lo usa la tienda, con `OpenStore`; el resto se
quedan con los genéricos.

## El balance — dónde vive y cómo se ajusta

Todo el balance está en **una sola tabla**: `LAYOUT` en
[SetupSoundService.luau](../tools/audio/SetupSoundService.luau). Ese script
escribe el `Volume` de cada `Sound` en Studio cada vez que se ejecuta, así que
tocar un volumen a mano en el Explorer no sirve de nada: se sobrescribe. Cambia
la tabla y vuelve a ejecutarlo.

Los cuatro `SoundGroup` se quedan **a 1.0**, a ganancia unidad. No son para
balancear: son para que el jugador pueda bajar música o efectos por separado. Si
se usan para balancear —Master a 0.5 y cada bus a 0.5, que es como estaba— todo
sale al 25% y acabas subiendo algún `Sound` a 5 para compensar. A partir de ahí
ya no se sabe qué está alto de verdad, y eso es exactamente lo que rompe la
consistencia.

El volumen que acaba en Studio es el producto de dos factores separados:

    volume = role × gain

**`role`** es cuánto debe sonar ese efecto dentro del juego. Lo decides tú, y la
regla es que cuanto más suena algo, más bajo va.

| Nivel | Rol | Sonidos |
| --- | --- | --- |
| 0.20 – 0.30 | Continuo | `Music/Lobby` 0.30 · `UI/Click` 0.25 · `UI/Coin` 0.22 · `Gameplay/Hit` 0.30 |
| 0.40 – 0.50 | Ocasional | `UI/Open` 0.40 · `UI/Close` 0.40 · `Gameplay/Health` 0.40 · `Gameplay/Headshot` 0.45 · `UI/Error` 0.50 |
| 0.50 – 0.60 | Puntual | `UI/Purchase` 0.55 · `Gameplay/Elimination` 0.60 |

El click dispara en cada botón y la moneda hasta diez veces seguidas: si están
al nivel de una eliminación, se comen el resto del mix. El headshot va por
encima del hit a propósito, que es lo que lo hace distinguible.

**`gain`** es cuánto hay que compensar ese archivo concreto, y no se opina: se
mide (ver más abajo). Por encima de 1 el asset está grabado flojo, por debajo
está grabado fuerte. Los valores actuales van de 0.32 en la música a 2.26 en el
click, o sea que entre el archivo más fuerte y el más flojo hay 17 dB.

Están separados a propósito. Si los fundes en un solo número, cambiar el reparto
del juego te obliga a volver a medir, y cambiar un archivo te obliga a rehacer
el reparto.

Para fijar un volumen tuyo en un `Sound` concreto, ponle el atributo
`MixLocked = true` en Studio y el script lo respetará.

### Afinar de oído

La tabla reparte por rol, pero no puede corregir que un asset esté grabado más
fuerte que otro. Eso solo se arregla escuchándolos seguidos, y para eso está
[AuditMix.luau](../tools/audio/AuditMix.luau): otro script de consola que los
reproduce en fila, dice cuál suena y a qué nivel efectivo, y pone la música por
debajo para que oigas qué tapa a qué. Al final reproduce los dos peores casos de
solapamiento reales del juego: diez monedas de un multi-kill y una ráfaga
automática a bocajarro.

El ciclo es: ejecutar `AuditMix`, apuntar el que se salga, corregirlo en
`LAYOUT`, ejecutar `SetupSoundService`, repetir.

### Medir en vez de adivinar

Afinar de oído corrige el reparto, pero no sabe cuánto trae dentro cada asset:
`Volume` es un multiplicador sobre lo fuerte que se grabó el archivo, así que
dos sonidos al mismo valor pueden llevarse 20 dB.

[MeasureLoudness.luau](../tools/audio/MeasureLoudness.luau) lo mide. Monta un
medidor temporal con el API nuevo de audio (`AudioPlayer` → `AudioAnalyzer` →
`AudioDeviceOutput`), reproduce cada asset a ganancia 1, muestrea su nivel RMS y
calcula el volumen que iguala a todos a una referencia común:

    volume final = nivel de rol × (referencia / sonoridad medida)

La referencia es la mediana de lo medido, así las correcciones se reparten
arriba y abajo y los volúmenes se quedan cerca de los niveles de rol. El
resultado se aplica en Studio y se imprime listo para pegar en `LAYOUT` — hay
que pegarlo, o la siguiente pasada de `SetupSoundService` lo revierte.

El RMS no es sonoridad percibida: eso sería LUFS, con ponderación de frecuencia.
Un sonido agudo y uno grave con el mismo RMS no se perciben igual de fuertes.
Esto elimina las diferencias gordas y deja solo el retoque fino para el oído.

### Apilado

Un sonido repetido muy rápido no suena más veces: suma amplitud y se convierte
en un muro que tapa todo lo demás. `GameSounds` lleva un `minInterval` por
sonido como red de seguridad. Cada valor va justo por debajo del ritmo natural
de ese sonido, así que una ráfaga legítima suena entera y lo que se corta es el
caso patológico: dos fuentes disparando a la vez, o un botón que emite doble
`Activated`.

Los sonidos de combate no pasan por `GameSounds` —los dispara el WeaponsSystem—
pero ya están limitados por el tamaño de su pool: 5 voces para `Hit` y
`Headshot`, 3 para `Elimination`.

## `Sound`, no el API nuevo de audio

Roblox tiene dos sistemas de audio. El juego usa el clásico: `Sound` +
`SoundGroup` + `SoundService:PlayLocalSound`. **No** usa el nuevo
(`AudioPlayer` + `Wire` + `AudioFader` + `AudioDeviceOutput`).

No mezcles los dos. Un `AudioPlayer` no suena solo —hay que cablearlo con un
`Wire` hasta una salida—, y si le pones el mismo nombre que a un `Sound`
hermano, un `FindFirstChild` puede devolver el que no es y el sonido queda mudo
sin dar ningún error. Por eso los resolvers buscan por nombre **y clase** vía
`AudioRuntime.findSound`.

Si alguna vez quieres migrar al API nuevo, es un cambio de sistema completo
(los pools, `PlayLocalSound` y los `SoundGroup` se van con él), no algo que se
haga sonido a sonido.

## Añadir un sonido nuevo

1. Añade la entrada a `SPECS` en
   [GameSounds.luau](../src/client/core/ui/GameSounds.luau) y su clave pública.
2. Añade la misma entrada a `LAYOUT` en
   [SetupSoundService.luau](../tools/audio/SetupSoundService.luau).
3. Ejecuta el script en Studio y pega la ID en el `Sound` que te crea vacío.
4. Llama a `GameSounds.play(GameSounds.LoQueSea)` donde toque.

`GameSounds` resuelve el `Sound` en cada llamada, así que puedes tocar
`SoundId`, `Volume` o `PlaybackSpeed` en Studio con el juego corriendo. Si un
sonido falta o no tiene `SoundId`, la llamada es no-op y avisa **una vez** en el
Output.

## La carpeta `Runtime`

Los sistemas de combate no reproducen el `Sound` autorado: clonan un pool de 3-5
copias para poder solapar impactos a cadencia alta. Esas copias van a
`SoundService.Runtime` vía [AudioRuntime](../src/shared/utils/AudioRuntime.luau).

Antes iban dentro de la propia carpeta autorada, así que a los pocos minutos de
partida convivían cinco `Hit` idénticos junto al original y no se sabía cuál
era el bueno. No autores nada en `Runtime`: el script de setup la vacía.

## Lo que NO está aquí

Los sonidos de **arma** (disparo, recarga, equip) viven dentro de cada `Tool` en
`ServerStorage.WeaponTools`, no en `SoundService`. Los reproduce
`BaseWeapon:tryPlaySound`, que también hace pool, pero parentando las copias
junto al template dentro del Tool — se destruyen solas al desequipar.

Las partículas de impacto son otra cosa y viven en
`ReplicatedStorage.Templates.HitVFX`. Ver [HIT-VFX.md](HIT-VFX.md).
