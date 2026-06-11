# AI Bot System Audit

**Scope:** `src/server/AI/` (~3,900 lines: `init.luau`, `BotAI.luau`, `nav/`, `telemetry/`, `debug/`) plus its integration points (`MatchService`, `SpawnService`, `WeaponsSystem`, `BotConfig`/`BotPersonalities`).
**Focus:** performance, scalability, maintainability, code quality, architecture, gameplay logic.
**Operating envelope:** bots fill teams to `TeamSizeTarget = 4` per side → max **8 bots**, ≤6 real players, 240-point rounds with sustained kill chains of 3–5/s (per in-code comments).

Items marked **[FIXED]** (the five P0 correctness/race findings, plus D2) are addressed on this branch. Everything else is a recommendation.

---

## 1. Architecture overview (as audited)

```
ServerBootstrap → MatchService:Start ──(lazy require)──► AIService (AI/init.luau)
                                                          ├─ identity pool + recycle pool (per round)
                                                          ├─ rig pool (per outfit, ServerStorage)
                                                          ├─ alive-targets cache (shared, signal-driven)
                                                          └─ per bot: BotAI
                                                              ├─ FSM loop (PATROL/CHASE/ATTACK, 20Hz in combat)
                                                              ├─ target-eval loop (10Hz)
                                                              ├─ StuckDetector loop (10Hz, 4-level escalation)
                                                              └─ Navigator ──► PathfindingQueue (global,
                                                                  2 ComputeAsync/Heartbeat, ≤4 in flight)
```

Bots are server-owned Humanoid rigs with negative `FakeUserId`s. They **bypass the WeaponsSystem damage pipeline**: an RNG roll decides hits, damage is applied via `Humanoid:TakeDamage`, and the `WeaponFired` remote is fired to clients within 200 studs purely for audio/visuals. Kill attribution flows through `LastAttackerStore` and `MatchService._handleBotDied`.

---

## 2. Findings

### A. Correctness & race conditions

#### A1. Teamless players were valid bot targets — **[FIXED]** · High
`BotAI:_getBestTarget` and `BotAI:_getForcedTarget` only skipped *same-team* candidates. A character whose team resolves to `nil` (lobby, mid-teleport, just-joined) passed the filter and could be chased and shot. `TeamUtils.areEnemies` (`src/shared/utils/TeamUtils.luau`) documents this exact rule ("a teamless/lobby/mid-teleport character must NOT be treated as an enemy") but was not used by the bot targeting path.
**Fix applied:** candidates and forced targets with a `nil` team side are now skipped.

#### A2. Bot-death vs round-end race repopulated cleared pools — **[FIXED]** · High
`handleBotDeath` (in `_spawnOneBot`, `AI/init.luau`) performed round-scoped bookkeeping unconditionally. The deferred death fallback (`_refreshAliveLists` → `task.defer`) can run *after* `OnRoundEnd` cleared every pool, re-inserting a stale identity into `_recycledByTeam`. Since `_fakeUserIdCounter` resets each round, the stale recycled fakeUserId can **collide with a freshly assigned one** → two bots sharing a fakeUserId (kill attribution and roster corruption). A late handler also decremented `_activeBotCount` of the *new* round and could fire `_onBotDied` into the wrong round.
**Fix applied:** `_roundGeneration` counter, bumped in `OnRoundEnd`; each bot captures its spawn generation and the death handler skips all round-scoped bookkeeping when stale (visual cleanup still runs).

#### A3. Concurrent `ComputeAsync` on the same `Path` object — **[FIXED]** · Medium
`PathfindingQueue` capped *total* in-flight computes (≤4) but did not serialize per `Path`. A Navigator can legitimately have two queued entries for its single shared `Path` (e.g., `recomputeLast` enqueues after `MinComputeInterval` while the first entry is still queued during a backlog). Both could dequeue in the same Heartbeat and run `ComputeAsync` concurrently on one `Path` — which is not reentrant — producing a spurious pcall failure and a phantom `onFailed`.
**Fix applied:** per-Path busy set; entries whose Path is mid-compute are requeued to the back (scan-capped so one Heartbeat cannot spin).

#### A4. `WeaponData` remote resolved once at module load — **[FIXED]** · Low
`BotAI.luau` resolved `_weaponDataRemote` in a `do` block at require time with no retry. If the remote didn't exist yet, victim hit-direction indicators (`"HitByOtherPlayer"`) silently never fired for the server's lifetime — inconsistent with `_getWeaponFiredRemote`, which retries lazily.
**Fix applied:** `_getWeaponDataRemote()` lazy getter, mirroring the existing pattern.

#### A5. Missing dedupe guard on player wiring — **[FIXED]** · Low
`BotAI.luau`'s `_wirePlayerRootCache` repeated the exact module-load race that `AI/init.luau` already guards with `_wiredPlayers`: a player joining between `PlayerAdded:Connect` and the initial `GetPlayers()` catch-up loop was wired twice → duplicate `CharacterAdded` listeners on every respawn, forever.
**Fix applied:** `_rootCacheWiredPlayers` guard + cleanup on `PlayerRemoving`.

---

### B. Performance

#### B1. Rig-pool "async" refill isn't amortized · Medium · *recommendation*
`_refillBotRigPoolAsync` runs its clone loop inside `task.spawn` **with no yields**, so all clones (30+ parts each) still land in a single frame — the spike is moved, not diluted. The module-load warm-up clones 3 rigs × N outfits in one frame.
**Recommend:** `task.wait()` between clones (one-line change).

#### B2. Round-start spawns are fully synchronous · Medium · *recommendation*
`SetBotTargets` → `_setTargetForTeam` spawns up to 8 bots in one frame (pool holds only 3 rigs/outfit, so the burst falls back to synchronous clones, plus appearance, `EquipTool`, and Navigator setup per bot). With 3–5 kills/s of respawn churn this path runs constantly.
**Recommend:** stagger spawns 1–2 per Heartbeat (needs a small pending-target reconciliation so overlapping rebalances don't double-spawn), and pre-warm pools to the expected round size during the Voting phase.

#### B3. PATROL busy-polling · Medium · *recommendation*
`_moveToLocation` polls `task.wait()` at ~60Hz per walking bot while waiting for the Navigator callback. Worse, when pathfinding fails repeatedly (e.g., a map without authored `AINav/RoamPoints`), the failure cooldown defers `onFailed` almost immediately and the PATROL loop respins every ~2 frames, doing an O(roam-points) pick each iteration.
**Recommend:** condition/signal-based completion instead of polling, plus a 0.3–0.5s backoff in PATROL after `onFailed`.

#### B4. Redundant Instance lookups in hot paths · Low · *recommendation*
The fire path does `FindFirstChildOfClass("Humanoid")` per landed shot even though `_evaluateTarget` already caches `_currentTargetHum`; `_getForcedTarget` pays two child lookups per 10Hz evaluation during retaliation.
**Recommend:** reuse the cached refs with lazy re-resolution when stale (resolve hum/root once when the forced target is set).

#### B5. Humanoid state machines never trimmed · Low–Medium · *recommendation*
No `SetStateEnabled` calls exist anywhere in the bot path; every bot Humanoid simulates Climbing, Swimming, Seated, PlatformStanding, FallingDown, Ragdoll, and GettingUp states it can never legitimately enter.
**Recommend:** disable those seven states per bot at spawn; keep Dead/Running/Jumping/Freefall/Landed enabled (movement, animations and the Died signal depend on them). Verified safe: the kill effects (`Default`/`Gravity`) force `ChangeState(Dead)` and manage `GettingUp` themselves — they don't use the Ragdoll/FallingDown states.

#### B6. Rig positioned after parenting · Low · *recommendation*
`_spawnOneBot` parents the rig to Workspace and then sets the root CFrame, allowing one frame of physics/replication at the template's stored position.
**Recommend:** set the root CFrame before parenting (the joined assembly moves together — identical end state, two-line reorder).

#### B7. Per-shot network fan-out · Informational · *acceptable today*
Each bot shot allocates a `fireInfo` table and fires `WeaponFired:FireClient` per player within 200 studs. Theoretical worst case at the real cap (8 bots × 10 shots/s × 6 players) ≈ 480 packets/s; realistic numbers are far lower (mixed FSM states, range filter, pause cycles). **Acceptable at current scale.** If bot count or fire rate grows: batch bot shots per-Heartbeat per-player into one remote payload, or move bot tracer/audio replication to a lightweight unreliable remote.

---

### C. Memory

#### C1. Rig pool grows with the outfit catalog · Low · *recommendation*
`_botRigPoolByKey` parks up to 3 rigs **per outfit** in ServerStorage forever. Memory grows linearly as outfits are added to `ItemsConfig.Outfits`.
**Recommend:** cap total parked rigs and/or trim pools for outfits not used by the current roster at `OnRoundEnd`.

#### C2. No leaks found in the per-bot path · Positive
`BotAI:Stop` disconnects and clears all per-instance state; `LastAttackerStore` is weak-keyed; character-bound connections die with their instances; `_playerRootByPlayer` is cleaned on `PlayerRemoving`; `PathfindingQueue.clear()` at round end deliberately releases closures. The death pipeline is defensively staged (visual cleanup first, each step pcall-isolated, guarded one-shot execution with a deferred fallback). This is solid work.

---

### D. Gameplay logic

#### D1. Personalities are cosmetic-only · High value / low effort · *recommendation*
`BotPersonalities` drives level, historical kills, cosmetic rarity, and hat probability — but **every bot shares identical combat skill** from the global `BotConfig.Combat` (Precision 40, ReactionDelay 0.15–0.35s, same strafe/pause/jump tuning). A "level 80 veteran" aims exactly like a level-2 rookie, which undercuts the identity system the game already pays for.
**Recommend:** add an optional `combat` block per personality (precision, reaction delay range, strafe cadence, jump chance) that overrides the global profile; consider light rubber-banding (nudge precision down vs struggling players) as a second step. This is the highest gameplay value per line of code in this audit.

#### D2. Bots ignore spawn-selection logic; dead config — **[FIXED]** · Medium
Bots spawned at a **pure random** spawn point (`_getRandomSpawnPoint`) while players went through `SpawnSelector` scoring — bots could spawn on top of enemies or into crossfire. Additionally, `BotConfig.Navigation.SpawnMinDist`/`SpawnMaxDist` were defined and typed but **never read anywhere** (dead config implying behavior that doesn't exist).
**Fix applied:** bot spawn-point choice now routes through `SpawnService.SelectBotSpawnPoint` → `SpawnSelector` (same scoring, same combatant scan, same per-map `UseIntelligentSpawning` flag as players); MatchService injects the selector into `AIService:OnRoundStart` so the AI module stays decoupled from match modules, with the old random pick kept as fallback. The dead config keys were deleted. `SpawnSelector` also gained **spawn-uniqueness guards** shared by players and bots: a 2s reuse window stamped at *selection* time (the player body-swap yields, so round-start bursts pick points before any body lands) plus a 6-stud occupancy check against live combatants — no two players/bots receive the same point in a burst, and the occupancy check also stops the ally-proximity *bonus* from favoring points with a teammate standing on top. If every point is filtered out (tiny maps, heavy churn), selection degrades gracefully to the full list rather than failing the spawn.

#### D3. No bot respawn delay · Low · *decision needed*
Bot death → deferred rebalance → respawn on the next frame, vs players' 1s `RespawnCooldown`. Instant bot reappearance affects pacing and makes farming streaks off bots slightly faster. Trivial to add a configurable delay if the design wants parity — flagging for a deliberate choice rather than silently changing feel.

#### D4. Hit model is RNG decoupled from ballistics · Informational / design trade-off
Bot hits are a dice roll (`Precision`) taken before any trajectory exists; damage is instant hitscan based on a ≤100ms-stale LoS check, while clients see a cosmetic projectile. No falloff, no headshots, damage tuned separately (`VsPlayer` 2–5 vs `VsBot` 10–25 — intentional UX asymmetry). This *works* and is cheap, but it is a second weapons implementation to keep in tune with the real one (see E2). One concrete quirk: fresh corpses (3s ragdolls) block LoS raycasts, so bots briefly "stare" at targets behind falling bodies — excluding the RAGDOLL collision group in the bot `RaycastParams` would remove it.

#### D5. Inline tuning magic numbers · Low · *recommendation*
Target-memory grace `now + 3`, retaliation window `+ 4`, range extensions `DetectRange + 20` / `+ 15` live inline in `BotAI.luau` while everything else is centralized in `BotConfig`. Move them next to their siblings so tuning passes don't require code archaeology.

---

### E. Architecture & maintainability

#### E1. `AI/init.luau` is a god module · Medium · *refactor recommendation*
~950 lines carrying ≥6 responsibilities: round lifecycle, identity assignment, identity recycling, rig pooling, the alive-targets registry, the death pipeline, and the roster API. Each is individually well-written, but they share one module-level mutable namespace, which is where bugs like A2 breed.
**Recommend (behavior-preserving split):** `AliveTargetsRegistry.luau`, `BotIdentityPool.luau`, `BotRigPool.luau`, with `init.luau` as the `AIService` facade wiring them. Mechanical extraction; no behavior change.

#### E2. Two parallel weapon systems · High (long-term) · *refactor recommendation*
Bots bypass the WeaponsSystem entirely — own fire loop, own hit model, own damage numbers, own replication call. Every weapon-feel change must be hand-ported to bots; any new weapon type needs a bot-specific reimplementation.
**Recommend:** a server-side fire driver on `BaseWeapon` so a bot can own a *real* weapon instance and share ballistics, damage, falloff, and effects with players (keep the bot-only precision/reaction layer on top as the "aim error" input). This is the biggest long-term maintainability win in the system; medium-large effort, best done after E1.

#### E3. 3 coroutines × N bots scheduling · *only when scaling* 
Each bot runs three `task.wait` loops (FSM, target eval, stuck tick). At 8 bots this is fine — do not refactor for today's scale. The prerequisite for 20+ bots is a centralized `BotManager` Heartbeat tick with per-bot accumulators, staggered evaluation, and a per-frame budget; it also gives one profiling point instead of 24 anonymous coroutines.

#### E4. No automated tests · Medium
The repo has no test infrastructure. Several bot modules are pure or nearly-pure logic and unit-testable with light seams: Navigator throttle/generation rules, StuckDetector escalation, RoamGraph ring-pick, identity pooling/recycling. These are exactly the spots where the audit found races; tests would have caught A2/A3 cheaply.

#### E5. Minor quality items · Low
- `BotRecord.ai: typeof(BotAI.new(({} :: any), "A"))` (init.luau) — use the exported `BotAI.BotAIInstance` type.
- Mixed `time()` / `os.clock()` across modules. Currently consistent within each comparison domain, but it's one refactor away from a subtle bug; document the convention (attributes use `time()`, intra-module timers use `os.clock()`) or standardize.
- Mixed Spanish/English comments — pick one (new comments from this audit are English per project owner's choice).
- `RaycastViz.isEnabled()` reads a workspace attribute per raycast; cache a bool behind `GetAttributeChangedSignal` like `DetectRangeViz` does with `_IS_STUDIO`.

---

### F. What's already healthy (keep doing this)

- **Signal-driven alive-targets cache** with O(1) swap-remove and dedupe-guarded wiring — eliminates per-tick workspace scans.
- **PathfindingQueue** with per-Heartbeat budget + in-flight semaphore + head/tail pointers.
- **Navigator's documented race avoidance**: no `MoveToFinished` dependency, generation tokens, synchronous same-dest throttle, post-`Blocked` cooldown — each with the reasoning written down.
- **Identity & rig recycling** keeping bot look/stats stable across deaths within a round.
- Reused candidate arrays, delta-gated `humanoid:Move`, range-filtered shot replication, LoS raycast cap (`MaxLosChecksPerEval`).
- **Studio-only telemetry/viz** (`NavMetrics`, `RaycastViz`, `DetectRangeViz`) with zero production cost.
- **Server-authoritative damage** — no client trust anywhere in the bot path.
- Spawn protection consistent between bots and players (`SpawnProtectedUntil` attribute + invisible ForceField).

---

## 3. Roadmap

| Priority | Item | Status |
|---|---|---|
| **P0** | A1 teamless targets, A2 round-generation guard, A3 per-Path serialization, A4 lazy WeaponData, A5 wiring dedupe | ✅ done |
| **P1** | B1 amortized refill; B2 staggered spawns + Voting-phase pre-warm; B3 PATROL backoff + signal wait; B4 cached lookups; B5 humanoid states; B6 position-before-parent; C1 rig-pool cap | open |
| **P2** | D2 SpawnSelector routing + spawn-uniqueness + dead config removal | ✅ done |
| **P2** | D1 per-personality combat profiles; D3 respawn-delay decision; D4 corpse-LoS exclusion; D5 magic numbers → BotConfig | open |
| **P3** | E1 split god module; E2 unify bot fire with WeaponsSystem; E3 BotManager tick (only when scaling >2× bot count); E4 test seams | open |

## 4. Verifying the applied fixes (Studio)

1. **A1:** stand a teamless character (no team attr/Team) within 35 studs of a bot — it must be ignored; assign a team — it gets targeted. Retaliation: damage a bot with a teamless character (Command Bar `TakeDamage`) — the bot must not lock onto it.
2. **A2:** force `AIService:OnRoundEnd()` from the Command Bar in the same frame a bot dies; start a new round and confirm `GetBotRoster()` has unique `fakeUserId`s.
3. **A3:** teleport all bots repeatedly to force a repath storm; confirm no `ComputeAsync` pcall failures and `NavMetrics` shows no `queue_depth_high` spam.
4. **A4/A5:** smoke test — getting shot by a bot still shows the hit-direction indicator; player respawns don't accumulate duplicate listeners (no behavioral change expected).
5. **D2:** start a round with full bot teams and confirm every bot/player lands on a **distinct** spawn point (no stacked spawns at round start). Then farm a bot near a group of enemies and confirm it respawns away from them instead of inside the crossfire (all current maps have `UseIntelligentSpawning = true`).
