# Shooter

Proyecto Roblox estructurado con Rojo/Wally y organizado por `bootstrap`, `core`
y `features` para separar arranque, infraestructura compartida y slices de juego.

## Estructura

```text
src/
  client/
    bootstrap/
    core/
    features/
  server/
    bootstrap/
    core/
    features/
  shared/
    constants/
    networking/
```

## Getting Started

To build the place from scratch, use:

```bash
rojo build -o "Shooter.rbxlx"
```

Next, open `Shooter.rbxlx` in Roblox Studio and start the Rojo server:

```bash
rojo serve
```

For more help, check out [the Rojo documentation](https://rojo.space/docs).

## Quality Workflow

This project enforces quality gates for static analysis and build validity.

Install the local toolchain:

```bash
rokit install
```

Run Luau lint:

```bash
selene src
```

Validate the Rojo build:

```bash
rojo build default.project.json -o /tmp/Shooter.rbxlx
```

CI runs these same checks on pull requests and protected branches.
See `docs/engineering/quality-gates.md` for merge policy and release checklist.

## Convenciones de naming

Verbos de prefijo en nombres de función:

- `get*` — accesor de propósito general. Cubre lookups O(1), reads directos
  de campo, y lookups con fallback trivial (`or default`, nil-check simple).
  Es el verbo por defecto.

- `resolve*` — compone un valor con lógica no trivial. Úsalo cuando hay
  fallback chains de varios pasos, decision trees, normalización entre
  formatos, o cuando quieras comunicar al lector "esta función hace trabajo
  real, no solo un lookup". Es decisión del autor, no algoritmo.

- `fetch*` — operaciones que tocan IO async (DataStore, red, llamadas que
  pueden timeout). Actualmente sin uso en el repo; reservar para cuando
  aparezca el primer caso.

Cuando el caso es ambiguo entre `get` y `resolve`, prefiere `get`. El idiom
Roblox/Lua trata `get*` como vocabulario amplio.
