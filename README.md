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
