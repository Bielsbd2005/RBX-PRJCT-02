# RoamViz — visualizador del pool de RoamPoints

Plugin de Roblox Studio para ver **dónde están** los RoamPoints que consumen los
bots y **qué alcance** tienen, fiel al sistema real de navegación
(`src/server/AI/nav/RoamGraph.luau`).

## Qué dibuja (y qué NO)

Tu sistema **no es un grafo de rutas**: `RoamGraph` mantiene un *pool plano* de
`Vector3` sin orden ni conexiones. Los bots piden un punto **aleatorio** en el
anillo `[RoamMinDist, RoamMaxDist]` (`pickRandomNavigablePoint`) y la trayectoria
real la calcula `PathfindingService` en runtime.

Por eso el plugin **no dibuja beams ni conexiones entre puntos** (no existen), ni
la ruta bot→destino (no es una recta). Dibuja:

- **Marcadores**: una esfera sobre cada `BasePart` de `<Mapa>/AINav/RoamPoints/`
  (usa `GetDescendants`, igual que `RoamGraph._readAuthoredPoints`).
- **Anillos de alcance**: dos discos (`RoamMinDist` / `RoamMaxDist`) alrededor del
  RoamPoint que tengas **seleccionado en el Explorer**. La corona entre ambos es
  la zona real de picking.
- **Puntos de spawn + orientación**: una esfera sobre cada `BasePart` de
  `<Mapa>/Spawns` y una **flecha que apunta hacia donde mirará quien aparezca
  ahí** — jugadores y NPCs de IA por igual. **Rotá la part en su eje Y y la flecha
  te dice hacia dónde aparecerá mirando** (autoría con feedback en vivo). Es fiel al
  juego: `SpawnService`/`AIService` colocan el cuerpo en `spawnPoint.CFrame`, y la
  orientación de aparición es el **yaw** de la part — `SpawnService` estampa
  `SpawnYaw = atan2(-look.X, -look.Z)`, que la `ShoulderCamera` del cliente respeta
  (jugadores) y los bots toman vía `PivotTo`. La flecha se aplana al plano XZ (solo
  yaw) porque el personaje aparece erguido. Espeja `SpawnService.GetSpawnPoints`
  (`FindFirstChild("Spawns", true)` + descendientes `BasePart`), se dibuja con
  `LineHandleAdornment` (`AlwaysOnTop`, se lee aunque haya geometría delante).

Render vía `*HandleAdornment` bajo un `Folder` en `CoreGui` → **no ensucia el
DataModel ni el historial de undo**, no es seleccionable y no colisiona.

### Rutas reales (opcional, con pathfinding)

Además puede dibujar el **camino real** que caminaría un bot, corriendo el mismo
`PathfindingService` con los mismos agent params (`AgentRadius=2, AgentHeight=5,
AgentCanJump=true, AgentMaxSlope=45, WaypointSpacing=4`, mirror de
`BotConfig.Pathfinding`). Dos modos:

- **Rutas desde punto seleccionado** — seleccionás un RoamPoint y dibuja las
  rutas a sus vecinos dentro de `[RoamMinDist, RoamMaxDist]` (el anillo de
  picking). Es O(N) por clic, interactivo.
- **Malla de rutas (≤ RoamMax)** — todos los pares con distancia euclídea en
  `[RoamMinDist, RoamMaxDist]`, **con yield** (no congela Studio), **progreso**
  en el status y **tope** `Máx. rutas` (default 500) que avisa si se supera.

Notas importantes:
- La línea es el path real (esquiva geometría), **no** una recta ni una
  "conexión" autoreada — tu sistema no tiene conexiones.
- El anillo `[min, max]` se mide en distancia euclídea, igual que
  `pickRandomNavigablePoint`. Es el caso común: el picking tiene fallbacks que,
  en el límite, hacen alcanzable **cualquier** punto, así que la malla muestra
  las transiciones frecuentes, no las únicas posibles.
- Cada `ComputeAsync` es caro y cede; por eso el tope y el yield. Lanzar *todos*
  los pares sin podar (N²) congelaría el editor.

## Estructura de autoría esperada (la de tu código, sin cambios)

```
Workspace/
└── Maps/
    └── <MapName>/
        └── AINav/
            └── RoamPoints/
                ├── (cualquier) BasePart   ← un destino
                ├── (cualquier) BasePart
                └── ...                     ← nombres y jerarquía interna libres
```

Los nombres no importan. Los atributos `Tags` (string) y `Weight` (number) se
respetan a nivel de datos pero `RoamGraph` los ignora en v1, así que el plugin
tampoco los usa (fácil de añadir en `Scanner.readPoints` si algún día pesan).

## Instalar

Necesitás Rojo (ya está en tu `rokit.toml`, v7.6.1).

```bash
cd plugins/RoamViz
rojo build RoamViz.project.json -o RoamViz.rbxm
```

Copiá `RoamViz.rbxm` a la carpeta local de plugins de Studio:

- macOS: `~/Documents/Roblox/Plugins/`
- Windows: `%LOCALAPPDATA%\Roblox\Plugins\`

O desde Studio: **Plugins ▸ Plugins Folder**, y arrastrá el `.rbxm` ahí. Reiniciá
Studio (o *Manage Plugins ▸ recargar*). Aparece la toolbar **RoamViz**.

> Atajo durante desarrollo: en Studio, botón derecho sobre el `.rbxm` importado →
> *Save as Local Plugin*.

## Uso

1. Abrí el panel con el botón **RoamViz** de la toolbar.
2. **Refrescar mapas** → elegí tu mapa en la lista (solo aparecen los que tienen
   `AINav/RoamPoints`).
3. **Generar / Actualizar** dibuja los marcadores.
4. Para ver los **anillos de alcance**: seleccioná un RoamPoint en el Explorer
   (con el toggle *Anillos* activo se redibujan al cambiar la selección).
5. Para ver los **puntos de spawn**: activá el toggle *Puntos de spawn +
   orientación*. Dibuja una esfera y una flecha sobre cada `BasePart` de
   `<Mapa>/Spawns`, apuntando hacia donde mirará quien aparezca ahí (jugadores y
   NPCs de IA). Para **ajustar la orientación**, rotá la part en su eje Y y regenerá:
   la flecha refleja hacia dónde aparecerá mirando el personaje (y así es en el juego).
6. **Rutas reales** (opcional): seleccioná un RoamPoint y **Rutas desde punto
   seleccionado**, o corré la **Malla de rutas** para el mapa entero (acotada).
   **Limpiar solo rutas** las borra sin tocar marcadores/anillos.
7. **Limpiar** borra todos los adornments.

Los **parámetros funcionales** (`RoamMinDist`, `RoamMaxDist`, `Máx. rutas`) y los
toggles persisten entre sesiones (`plugin:SetSetting`). La **apariencia del render
3D** (colores/grosores de marcadores, anillos y flechas) vive hardcodeada en
`Style.luau` — un único lugar si algún día querés retocar un color.

El **panel sigue el tema de Studio** (claro/oscuro) vía `StudioTheme` y se
re-colorea en vivo al cambiarlo (`Studio.ThemeChanged`); su fondo es transparente,
así se ve el fondo temeado nativo del DockWidget.

Regeneración **manual** (un clic) por diseño — nada en tiempo real salvo el
redibujo barato de los 2 discos de anillo al cambiar selección.

## Archivos

| Archivo | Rol |
|---|---|
| `src/init.server.luau` | Entry: toolbar, dock widget, pipeline de render, limpieza |
| `src/Config.luau` | Estado **funcional** + persistencia. **Espeja `RoamMinDist=20`/`RoamMaxDist=80` de `BotConfig`** |
| `src/Style.luau` | Apariencia centralizada (colores/tamaños). Antes editable en la UI; ahora hardcodeada acá |
| `src/Scanner.luau` | Descubre mapas, lee RoamPoints y puntos de spawn (`<Mapa>/Spawns`) |
| `src/Renderer.luau` | Dibuja marcadores, anillos y puntos de spawn (esfera + flecha) con adornments |
| `src/PathViz.luau` | Preview de rutas reales con `PathfindingService` (mirror de `BotConfig.Pathfinding`) |
| `src/UI.luau` | Panel del DockWidget (sin dependencias externas); sigue el tema de Studio, fondo transparente |

## Mantenimiento

Si en `src/shared/constants/BotConfig.luau` cambian `Navigation.RoamMinDist` o
`RoamMaxDist`, actualizá los defaults en `Config.luau` (el plugin corre en el
editor y no puede `require` de `BotConfig`). Si cambia la ruta de autoría
(`AINav/RoamPoints`), `Scanner.luau` es el único punto a tocar.

Si cambia la carpeta de spawns (`SpawnService.GetSpawnPoints` busca
`FindFirstChild("Spawns", true)`), actualizá `SPAWNS_NAME` en `Scanner.luau`. Para
retocar cualquier color/tamaño del render, `Style.luau` es el único lugar.

La flecha de spawn representa el **yaw** con el que aparece el personaje. Esa
orientación la fija `SpawnService._teleportCharacterToSpawn` (atributo
`SpawnYaw = atan2(-look.X, -look.Z)`), respetada por `ShoulderCamera` (jugadores)
y por `AIService`/`PivotTo` (bots). Si esa fórmula cambia, ajustá el aplanado en
`Renderer.drawSpawnPoints`/`_drawArrow` para que la flecha siga cuadrando.
