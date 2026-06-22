# VFX de impacto de balas

Sólo **dos efectos**: `Body` (impacto en cuerpo) y `Headshot` (impacto en
cabeza). Los impactos contra el mundo (suelo, metal, ...) no producen nada.

Los efectos viven **siempre en una carpeta de Studio**, nunca en código.

## Montar la carpeta (Studio)

```
ReplicatedStorage/
  HitVFX/                 (Folder)
    Body                  (Attachment o Part)
    Headshot              (Attachment o Part)
```

- La carpeta y los hijos se llaman EXACTO `HitVFX` / `Body` / `Headshot`
  (configurable en `Config.FolderName` / `Config.BodyCategory` / `HeadshotCategory`).
- Dentro de cada plantilla pones tus **`ParticleEmitter`** y **`Sound`** y los
  tuneas en vivo. Como está fuera de los paths de Rojo, **no la borra** al sync.

### Atributos de la plantilla

| Instancia | Atributo | Efecto |
| --- | --- | --- |
| `ParticleEmitter` | `EmitCount` *(number)* | partículas por ráfaga (def. 15; en móvil ×`MobileScale`) |
| `Sound` | — | si hay varios, se elige uno al azar por impacto |

El motor clona la plantilla, la orienta a la normal (las partículas salen "hacia
arriba" del Attachment → `EmissionDirection = Top`), emite la ráfaga y reproduce
el sonido. Reusa todo en pool por categoría → cero `Instance.new` en régimen.

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
