# AI Bot System Audit

**Scope:** `src/server/AI/` (~3,900 lines: `init.luau`, `BotAI.luau`, `nav/`, `telemetry/`, `debug/`) plus its integration points (`MatchService`, `SpawnService`, `WeaponsSystem`, `BotConfig`/`BotPersonalities`).
**Focus:** performance, scalability, maintainability, code quality, architecture, gameplay logic.
**Operating envelope:** bots fill teams to `TeamSizeTarget = 4` per side → max **8 bots**, ≤6 real players, 240-point rounds with sustained kill chains of 3–5/s (per in-code comments).

Items marked **[FIXED]** are addressed on this branch (the five P0 correctness/race findings, the P1 performance batch B1–B6/C1, and the P2 gameplay batch D1–D5). Everything else is a recommendation.

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

#### B1. Rig-pool "async" refill isn't amortized — **[FIXED]** · Medium
`_refillBotRigPoolAsync` ran its clone loop inside `task.spawn` **with no yields**, so all clones (30+ parts each) still landed in a single frame — the spike was moved, not diluted.
**Fix applied:** `task.wait()` between clones; one rig per frame.

#### B2. Round-start spawns are fully synchronous — **[FIXED]** · Medium
`SetBotTargets` → `_setTargetForTeam` spawned up to 8 bots in one frame (pool holds only 3 rigs/outfit, so the burst fell back to synchronous clones, plus appearance, `EquipTool`, and Navigator setup per bot). With 3–5 kills/s of respawn churn this path runs constantly.
**Fix applied:** spawn pump — `SetBotTargets` now records desired team sizes and wakes a single pump coroutine that spawns ≤2 bots per step, re-reading desired targets and live counts each iteration so overlapping rebalances reconcile instead of double-spawning (removals stay synchronous; the pump's first step runs synchronously inside `SetBotTargets`, so the common 1-respawn case is unchanged). Because `SetBotTargets` now returns before the roster is complete, AIService fires an `onRosterChanged` callback when the pump finishes, wired to MatchService's roster broadcast. Pools are also pre-warmed during the Voting phase via `AIService:PrewarmRigPools()` — serialized (~1 clone/frame), rebuilding what the round-end trim (C1) released.

#### B3. PATROL busy-polling — **[FIXED]** · Medium
`_moveToLocation` polled `task.wait()` at ~60Hz per walking bot while waiting for the Navigator callback. Worse, when pathfinding failed repeatedly (e.g., a map without authored `AINav/RoamPoints`), the failure cooldown deferred `onFailed` almost immediately and the PATROL loop respun every ~2 frames, doing an O(roam-points) pick each iteration.
**Fix applied:** the wait now runs at 10Hz — the stop condition's inputs (target acquisition, death) are produced by the 10Hz eval loop, so waking faster than the source gained no latency (60→10 wakeups/s per walking bot). `_moveToLocation` returns whether navigation failed, and PATROL backs off 0.3–0.5s (jittered) after a failure before picking the next roam destination.

#### B4. Redundant Instance lookups in hot paths — **[FIXED]** · Low
The fire path did `FindFirstChildOfClass("Humanoid")` per landed shot even though `_evaluateTarget` already caches `_currentTargetHum`; `_getForcedTarget` paid two child lookups per 10Hz evaluation during retaliation.
**Fix applied:** fire path reuses `_currentTargetHum` (lazy re-resolve if stale); forced-target hum/root resolved once when the retaliation target is set and cached (`_forcedTargetHum`/`_forcedTargetRoot`), refreshed lazily, cleared in `Stop`.

#### B5. Humanoid state machines never trimmed — **[FIXED]** · Low–Medium
No `SetStateEnabled` calls existed anywhere in the bot path; every bot Humanoid simulated Climbing, Swimming, Seated, PlatformStanding, FallingDown, Ragdoll, and GettingUp states it can never legitimately enter.
**Fix applied:** those seven states are disabled per bot at spawn; Dead/Running/Jumping/Freefall/Landed stay enabled (movement, animations and the Died signal depend on them). Verified safe: the kill effects (`Default`/`Gravity`) force `ChangeState(Dead)` and manage `GettingUp` themselves — they don't use the Ragdoll/FallingDown states.

#### B6. Rig positioned after parenting — **[FIXED]** · Low
`_spawnOneBot` parented the rig to Workspace and then set the root CFrame, allowing one frame of physics/replication at the template's stored position.
**Fix applied:** root CFrame set before parenting (the joined assembly moves together — identical end state).

#### B7. Per-shot network fan-out · Informational · *acceptable today*
Each bot shot allocates a `fireInfo` table and fires `WeaponFired:FireClient` per player within 200 studs. Theoretical worst case at the real cap (8 bots × 10 shots/s × 6 players) ≈ 480 packets/s; realistic numbers are far lower (mixed FSM states, range filter, pause cycles). **Acceptable at current scale.** If bot count or fire rate grows: batch bot shots per-Heartbeat per-player into one remote payload, or move bot tracer/audio replication to a lightweight unreliable remote.

---

### C. Memory

#### C1. Rig pool grows with the outfit catalog — **[FIXED]** · Low
`_botRigPoolByKey` parked up to 3 rigs **per outfit** in ServerStorage forever. Memory grew linearly as outfits are added to `ItemsConfig.Outfits`.
**Fix applied:** global cap of `TeamSizeTarget × 4` (16) total parked rigs — refills stop at the cap and a cold take pays one sync clone (rare). At real round end (not the defensive `OnRoundEnd` call inside `OnRoundStart`), every pool is trimmed to 1 parked rig; the Voting-phase prewarm (B2) rebuilds them off the critical path. Identities re-roll every round, so hot pools had no cross-round hit-rate benefit anyway.

#### C2. No leaks found in the per-bot path · Positive
`BotAI:Stop` disconnects and clears all per-instance state; `LastAttackerStore` is weak-keyed; character-bound connections die with their instances; `_playerRootByPlayer` is cleaned on `PlayerRemoving`; `PathfindingQueue.clear()` at round end deliberately releases closures. The death pipeline is defensively staged (visual cleanup first, each step pcall-isolated, guarded one-shot execution with a deferred fallback). This is solid work.

---

### D. Gameplay logic

#### D1. Personalities are cosmetic-only — **[FIXED]** · High value / low effort
`BotPersonalities` drove level, historical kills, cosmetic rarity, and hat probability — but **every bot shared identical combat skill** from the global `BotConfig.Combat` (Precision 40, ReactionDelay 0.15–0.35s, same strafe/pause/jump tuning). A "level 80 veteran" aimed exactly like a level-2 rookie.
**Fix applied:** each personality tier now carries an optional `combat` block (precision, reaction delay range, strafe/pause cadence, jump-chance multiplier) that overrides the global profile field-by-field: Noob aims at 25 with 0.3–0.55s reaction and pauses more; Whale aims at 60 with 0.08–0.18s reaction and strafes/jumps more. The profile is resolved **once per bot at construction** into a flat table (`BotAI._combat`), so the 10–20Hz combat loops pay zero override-chain cost. Jump chance is a *multiplier* because the base is intentionally asymmetric per target type (VsPlayer 0.03 vs VsBot 0.4). Rubber-banding vs struggling players remains a possible second step.

#### D2. Bots ignore spawn-selection logic; dead config — **[FIXED]** · Medium
Bots spawned at a **pure random** spawn point (`_getRandomSpawnPoint`) while players went through `SpawnSelector` scoring — bots could spawn on top of enemies or into crossfire. Additionally, `BotConfig.Navigation.SpawnMinDist`/`SpawnMaxDist` were defined and typed but **never read anywhere** (dead config implying behavior that doesn't exist).
**Fix applied:** bot spawn-point choice now routes through `SpawnService.SelectBotSpawnPoint` → `SpawnSelector` (same scoring, same combatant scan, same per-map `UseIntelligentSpawning` flag as players); MatchService injects the selector into `AIService:OnRoundStart` so the AI module stays decoupled from match modules, with the old random pick kept as fallback. The dead config keys were deleted. `SpawnSelector` also gained **spawn-uniqueness guards** shared by players and bots: a 2s reuse window stamped at *selection* time (the player body-swap yields, so round-start bursts pick points before any body lands) plus a 6-stud occupancy check against live combatants — no two players/bots receive the same point in a burst, and the occupancy check also stops the ally-proximity *bonus* from favoring points with a teammate standing on top. If every point is filtered out (tiny maps, heavy churn), selection degrades gracefully to the full list rather than failing the spawn.

#### D3. No bot respawn delay — **[FIXED]** (knob, default keeps current feel) · Low
Bot death → deferred rebalance → respawn on the next frame, vs players' 1s `RespawnCooldown`. Instant bot reappearance affects pacing and makes farming streaks off bots slightly faster.
**Fix applied:** `BotConfig.Lifecycle.RespawnDelay` — the bot death handler arms a per-team spawn hold and the spawn pump skips a held team (without exiting) until it expires. **Default is 0**, which preserves the historical instant-respawn feel exactly; set it to 1 for parity with players. Round-start fills are never held. The decision itself is now a one-line config change instead of a code change.

#### D4. Hit model is RNG decoupled from ballistics · Informational / design trade-off — corpse-LoS quirk **[FIXED]**
Bot hits are a dice roll (`Precision`) taken before any trajectory exists; damage is instant hitscan based on a ≤100ms-stale LoS check, while clients see a cosmetic projectile. No falloff, no headshots, damage tuned separately (`VsPlayer` 2–5 vs `VsBot` 10–25 — intentional UX asymmetry). This *works* and is cheap, but it is a second weapons implementation to keep in tune with the real one (see E2).
**Quirk fixed:** fresh corpses (3s ragdolls) blocked LoS raycasts, so bots briefly "stared" at targets behind falling bodies. The bot `RaycastParams` now sets `CollisionGroup = CHARACTERS` — RAGDOLL parts don't collide with CHARACTERS, so the rays ignore corpses while walls and live characters still block. The broader hit-model design remains as documented (see E2 for the unification path).

#### D5. Inline tuning magic numbers — **[FIXED]** · Low
Target-memory grace `now + 3`, retaliation window `+ 4`, range extensions `DetectRange + 20` / `+ 15` lived inline in `BotAI.luau` while everything else is centralized in `BotConfig`.
**Fix applied:** moved to `BotConfig.Combat` as `TargetMemoryGrace`, `RetaliationWindow`, `ForcedTargetRangeBonus`, `GraceRangeBonus` (same values — no behavior change).

---

### E. Architecture & maintainability

#### E1. `AI/init.luau` is a god module · Medium · *refactor recommendation*
~950 lines carrying ≥6 responsibilities: round lifecycle, identity assignment, identity recycling, rig pooling, the alive-targets registry, the death pipeline, and the roster API. Each is individually well-written, but they share one module-level mutable namespace, which is where bugs like A2 breed.
**Recommend (behavior-preserving split):** `AliveTargetsRegistry.luau`, `BotIdentityPool.luau`, `BotRigPool.luau`, with `init.luau` as the `AIService` facade wiring them. Mechanical extraction; no behavior change.

#### E2. Two parallel weapon systems · High (long-term) · *refactor recommendation*
Bots bypass the WeaponsSystem entirely — own fire loop, own hit model, own damage numbers, own replication call. Every weapon-feel change must be hand-ported to bots; any new weapon type needs a bot-specific reimplementation.
**Recommend:** a server-side fire driver on `BaseWeapon` so a bot can own a *real* weapon instance and share ballistics, damage, falloff, and effects with players (keep the bot-only precision/reaction layer on top as the "aim error" input). This is the biggest long-term maintainability win in the system; medium-large effort, best done after E1.

#### E3. 3 coroutines × N bots scheduling — **[CLOSED — won't do]**
Each bot runs three `task.wait` loops (FSM, target eval, stuck tick). At 8 bots this is fine — the centralized `BotManager` Heartbeat tick was only the prerequisite for 20+ bots. **Project owner confirmed the bot count will not grow beyond the current envelope**, so this refactor has no payoff and is closed. If that decision ever changes, the original recommendation stands: per-bot accumulators, staggered evaluation, per-frame budget, one profiling point.

#### E4. No automated tests · Medium
The repo has no test infrastructure. Several bot modules are pure or nearly-pure logic and unit-testable with light seams: Navigator throttle/generation rules, StuckDetector escalation, RoamGraph ring-pick, identity pooling/recycling. These are exactly the spots where the audit found races; tests would have caught A2/A3 cheaply.

#### E5. Minor quality items — **[FIXED]** (code items) · Low
- ~~`BotRecord.ai: typeof(BotAI.new(({} :: any), "A"))`~~ — **fixed**: uses the exported `BotAI.BotAIInstance` type.
- ~~`RaycastViz.isEnabled()` reads a workspace attribute per raycast~~ — **fixed**: cached bool behind `GetAttributeChangedSignal`, same pattern as `DetectRangeViz`.
- Mixed `time()` / `os.clock()` — kept as a documented convention rather than refactored: **attributes and cross-system timestamps use `time()`; intra-module timers use `os.clock()`**. Each comparison domain is internally consistent; don't mix them in one comparison.
- Mixed Spanish/English comments — ongoing style note (new comments from this audit are English per project owner's choice).

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

### G. Post-audit feature work (this branch)

#### G1. Per-identity bot weapons
Bots previously all carried one hardcoded NPC tool (`ReplicatedStorage.AR-NPC`). Now each bot identity rolls a `weaponId` from the **same** weapon catalog players use (`ItemsConfig.Main` ∩ Tools present in `ServerStorage.WeaponTools.Main`), filtered by the personality's allowed rarities — Noobs carry the Common starter AK, Veterans/Whales pull from the full catalog. The weapon is part of the identity's appearance, so it stays stable across deaths within a round (recycle pool), and the existing wrap roll applies to it (the wrap system targets any tool's `WeaponModel`).

Because the bot clones the **real player Tool** (tagged `WeaponsSystemWeapon`, `WeaponType` attribute intact), the client WeaponsSystem builds the proper weapon wrapper and the existing `WeaponFired:FireClient(..., weapon, fireInfo)` replication renders the correct per-weapon tracers, sounds and muzzle effects with zero new client code. Bot fire **cadence** follows the weapon's `Configuration.ShotCooldown` (clamped 0.08–1.5s) so a Sniper bot doesn't hose at AR cadence; per-shot **damage** intentionally stays on the bot RNG profile (`VsPlayer`/`VsBot`) — unchanged UX balance. Kill attribution now records the real weapon name. `AR-NPC` remains only as the fallback when an identity has no weaponId (empty WeaponTools catalog).

This is also a meaningful step toward **E2** (the two-weapon-systems problem): visuals, audio, wraps and cadence are now single-sourced from the player weapon templates; only the hit/damage model remains bot-specific — by design.

---

## 3. Roadmap

| Priority | Item | Status |
|---|---|---|
| **P0** | A1 teamless targets, A2 round-generation guard, A3 per-Path serialization, A4 lazy WeaponData, A5 wiring dedupe | ✅ done |
| **P1** | B1 amortized refill; B2 staggered spawns + Voting-phase pre-warm; B3 PATROL 10Hz wait + failure backoff; B4 cached lookups; B5 humanoid states; B6 position-before-parent; C1 rig-pool cap + round-end trim | ✅ done |
| **P2** | D1 per-personality combat profiles; D2 SpawnSelector routing + spawn-uniqueness + dead config removal; D3 respawn-delay knob (default 0 = unchanged feel); D4 corpse-LoS exclusion; D5 magic numbers → BotConfig | ✅ done |
| **P3** | E5 quality items (type hack, RaycastViz cache); G1 per-identity bot weapons (steps toward E2) | ✅ done |
| **P3** | E1 split god module; E2 full fire-path unification (less pressing after G1); E4 test seams | open |
| **P3** | E3 BotManager tick | ❌ closed — bot count won't grow (owner decision) |

## 4. Verifying the applied fixes (Studio)

1. **A1:** stand a teamless character (no team attr/Team) within 35 studs of a bot — it must be ignored; assign a team — it gets targeted. Retaliation: damage a bot with a teamless character (Command Bar `TakeDamage`) — the bot must not lock onto it.
2. **A2:** force `AIService:OnRoundEnd()` from the Command Bar in the same frame a bot dies; start a new round and confirm `GetBotRoster()` has unique `fakeUserId`s.
3. **A3:** teleport all bots repeatedly to force a repath storm; confirm no `ComputeAsync` pcall failures and `NavMetrics` shows no `queue_depth_high` spam.
4. **A4/A5:** smoke test — getting shot by a bot still shows the hit-direction indicator; player respawns don't accumulate duplicate listeners (no behavioral change expected).
5. **D2:** start a round with full bot teams and confirm every bot/player lands on a **distinct** spawn point (no stacked spawns at round start). Then farm a bot near a group of enemies and confirm it respawns away from them instead of inside the crossfire (all current maps have `UseIntelligentSpawning = true`).
6. **B2:** at round start, MicroProfiler should show the 8-bot burst spread over ~4 frames (2 spawns/frame) instead of one spike; the scoreboard must still show all 8 bots within a few frames (the pump re-broadcasts the roster when it finishes). Kill chains: bots keep respawning 1:1 with no duplicates or missing bots after heavy churn.
7. **B3:** on a map without authored `AINav` roam points, NavMetrics' `roam_pick_count` should grow at a bounded rate (~2–3/s per idle bot) instead of respinning every other frame.
8. **C1:** after a round ends, `ServerStorage._BotRigPool` should shrink to ≤1 rig per outfit, then refill during the next Voting phase; total parked rigs never exceed 16.
9. **D1:** check the roster for a Noob and a Whale (`GetBotRoster` levels / career card). The Noob should feel sluggish (slow first shot, more standing still, ~25% hit rate); the Whale should snap-react, strafe constantly and hit ~60%. Confirm via Command Bar: `require(game.ServerScriptService.Server.AI)` roster → personality tiers map to visibly different fight feel.
10. **D3:** with `RespawnDelay = 0` (default), bot respawn timing is unchanged. Set it to 1 in Studio: a killed bot's replacement must appear ~1s later, while round-start spawns stay immediate.
11. **D4:** kill a bot so its ragdoll falls between another bot and a visible enemy — the surviving bot must keep firing through the falling corpse instead of holding fire for ~3s.
12. **G1:** with Tools present under `ServerStorage.WeaponTools.Main`, bots should spawn with varied weapons (Noobs always AK; higher tiers varied), keep the same weapon after respawning, show their wrap on it, and fire with that weapon's sound/tracer at its own cadence (a Sniper bot shoots visibly slower than an AK bot). Empty the WeaponTools folder → all bots fall back to AR-NPC with no errors.
