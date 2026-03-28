# Quality Gates

This project uses process and tooling gates to prevent regressions in memory, performance, and networking.

## Required Checks (CI)

- `selene src`
- `rojo build default.project.json -o /tmp/Shooter.rbxlx`

## Local Developer Workflow

1. `rokit install`
2. `selene src`
3. `rojo build default.project.json -o /tmp/Shooter.rbxlx`
4. Run a Studio smoke test for the touched feature.

## PR Merge Policy

- No direct merges to protected branches.
- At least 1 reviewer approval.
- CI checks green.
- PR template fully completed.

## High-Risk Change Definition

A change is high-risk if it touches one or more of:

- Data/session lifecycle (`DataService`, profile loading/unloading, retries)
- Heartbeat/RenderStepped logic
- Inventory/locker population paths
- Network packet schemas or server handlers

High-risk changes must include:

- A short rollback plan
- A manual validation note with repro steps

## Release Checklist

- CI green on target commit
- Smoke test in Studio on target branch
- Critical gameplay flow test: load profile, buy/equip item, close/rejoin
- No new warnings from Selene

## Incident Follow-Up

For production incidents, add a short postmortem with:

- Timeline
- Root cause
- Corrective action
- Preventive gate added (tooling or process)
