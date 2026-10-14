# Locker / wraps

SurfaceAppearance de los wraps de arma: `Shared.Locker.wraps.<Name>`.
Contenido gestionado en Studio, NO por Rojo (`init.meta.json` →
`ignoreUnknownInstances`; `globIgnorePaths` evita que un `.rbxm` suelto vuelva a
sincronizarse). **Guarda el place** después de añadir o editar uno.

## Dar de alta un wrap con SurfaceAppearance

1. Entrada normal en `ItemsConfig.WeaponWraps` (`shared/constants/ItemsConfig.luau`).
2. Un `SurfaceAppearance` en esta carpeta que se llame como el `Name` del wrap
   en el catálogo ("Damascus") o como su id (`Mastery_Damascus`). Si existen
   los dos, gana el id.

No hay campo que declarar en el catálogo: `WeaponWrapPainter` empareja por
nombre. En Studio avisa en el Output de los que no corresponden a ningún wrap y
de los nombres duplicados. Al cambiar el `Name` de un wrap en el catálogo,
renombra también su SurfaceAppearance.

## Orden

Las subcarpetas son libres y solo sirven para ordenar (por origen…): se busca
a cualquier profundidad y solo cuenta el nombre.

    wraps
    └── Mastery
        └── Damascus

## Qué se pinta

- El mismo SurfaceAppearance se clona en cada pieza pintable del arma
  (`WeaponWrapParts`) y usa los UV de esa malla: tiene que ser una textura que
  aguante en todas las armas.
- Solo actúa sobre `MeshPart`. Una pieza que no lo sea (el bloque genérico
  `ReplicatedStorage.Templates.Wrap` si es un `Part`) se queda con `BaseColor` y
  `Material` del catálogo: decláralos como aproximación del wrap.
- Una `TextureID` animada (`isAnimated`) del catálogo se sigue pintando por
  encima, así que un wrap puede combinar base PBR y textura animada. Una fija va
  en `MeshPart.TextureID` y el SurfaceAppearance la tapa: no declares las dos.
- Si el arma trae su propio SurfaceAppearance, el painter lo aparta mientras
  dure el wrap y lo devuelve al quitarlo.
