## Summary

- What changed?
- Why was it needed?

## Risk Review

- [ ] Memory impact reviewed (instances, connections, janitors, loops)
- [ ] Performance impact reviewed (frame work, heavy loops, UI churn)
- [ ] Network impact reviewed (packet frequency/payload size)
- [ ] Data safety reviewed (profile/session lifecycle, retries, failure paths)

## Validation

- [ ] `rokit install`
- [ ] `selene src`
- [ ] `rojo build default.project.json -o /tmp/Shooter.rbxlx`
- [ ] Manual smoke test in Studio

## Rollback Plan

- [ ] Safe rollback path described for this change
