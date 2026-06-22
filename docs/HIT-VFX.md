# VFX de impacto de balas

Feedback de impacto **a jugador**, dividido en dos responsabilidades que no se
solapan:

| Efecto | Dueño | Disparado desde |
| --- | --- | --- |
| **Partículas** (Body / Headshot) | carpeta `ReplicatedStorage.HitVFX` (Studio) | `HitVFX.play` en `BulletWeapon` |
| **Sonido** hit/headshot | `SoundService.Audio.Gameplay.HitSound`/`Headshot` | `DamageBillboardHandler` (2D, pitch progresivo) |
| **Números** de daño | `DamageBillboardHandler` | — |

Sólo **dos categorías de partícula**: `Body` y `Headshot`. Los impactos contra el
mundo (suelo, metal, ...) no producen partículas.

## Partículas — montar la carpeta (Studio)

```
ReplicatedStorage/
  HitVFX/                 (Folder)
    Body                  (Attachment o Part)  ← sólo ParticleEmitters
    Headshot              (Attachment o Part)  ← sólo ParticleEmitters
```

- La carpeta y los hijos se llaman EXACTO `HitVFX` / `Body` / `Headshot`
  (configurable en `Config.FolderName` / `Config.BodyCategory` / `HeadshotCategory`).
- Dentro de cada plantilla pones tus **`ParticleEmitter`** y los tuneas en vivo.
  Como está fuera de los paths de Rojo, **no la borra** al sync.
- **NO pongas `Sound`** dentro: el motor lo ignora (el audio va en SoundService,
  ver abajo). Así nunca suena doble.

### Atributo de la plantilla

| Instancia | Atributo | Efecto |
| --- | --- | --- |
| `ParticleEmitter` | `EmitCount` *(number)* | partículas por ráfaga (def. 15; en móvil ×`MobileScale`) |

El motor clona la plantilla, la orienta a la normal (las partículas salen "hacia
arriba" del Attachment → `EmissionDirection = Top`) y emite la ráfaga. Reusa todo
en pool por categoría → cero `Instance.new` en régimen.

> **Migración:** los emitters de headshot que tenías en el `HeadShotAttachment`
> de las cabezas (`Shared.Bodies.*`) cópialos dentro de `HitVFX/Headshot`. Antes
> los emitía `DamageBillboardHandler`; ahora los emite HitVFX.

## Sonido — vive en SoundService

El sonido de hit/headshot **no** se toca en HitVFX. Está en
`SoundService.Audio.Gameplay.HitSound` / `Headshot` y lo reproduce
`DamageBillboardHandler` (pooled ×5, con **pitch progresivo de combo** y
distance-aware). Para cambiarlo: sustituye esos dos `Sound` en Studio.

## Archivos

| Archivo | Rol |
| --- | --- |
| `src/server/WeaponsSystem/Libraries/HitVFX/Config.luau` | Ajustes (flags, nombres). |
| `src/server/WeaponsSystem/Libraries/HitVFX/init.luau` | Motor (clasificar + pool + play). |

Integrado en `WeaponTypes/BulletWeapon.luau`. Por arma: `ModularHitVFX = false`
desactiva el sistema en esa arma (vuelve al VFX heredado).

## Ajustes (`Config.luau`)

- `Enabled` — interruptor maestro.
- `LocalPlayerOnly` *(def. true)* — cada cliente sólo ve SUS impactos (lo más
  ligero). `false` = ver también los de otros jugadores.
- `MobileScale` *(def. 0.5)* — escala el `EmitCount` en táctil.
- `MaxConcurrent` *(def. 16)* — techo de efectos simultáneos.

## Opcional: precarga

```lua
require(ReplicatedStorage.WeaponsSystem.Libraries.HitVFX).preload()
```
