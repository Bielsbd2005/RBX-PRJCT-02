# Test Checklist — Audit Fixes (commit ba5bd82)

How to use: each fix has **✅ Confirm the fix** (positive test) and **🔁 Regression**
(what must still work). Test environments:
- **Studio**: F5 (Play) or "Start" with 2+ players (Test → Players = 2) for client/server splits.
- **Mobile emulation**: Studio → Test → Device → pick a phone (enables `TouchEnabled`).
- **Real device**: publish to a private/test place, join from the Roblox mobile app.
- **Exploit simulation**: there's no real exploit client needed — fire the remote with
  bad args yourself from a **LocalScript** or the **client command bar** to mimic a
  cheater. The server guard should reject it.

General sanity before anything: no red errors in **Output** on join, and
`selene src/` passes (no linter installed in CI env — run locally).

---

## 1. SECURITY

### S1 — Server-side hit validation (WeaponSecurity / BulletWeapon / NetworkingCallbacks)
- ✅ **Damage falloff**: fire at a target point-blank vs at max range — damage should
  drop with distance. Confirm a close shot does NOT do less than a far shot.
- ✅ **Headshot**: shoot an enemy's head → headshot multiplier (2×) + headshot reward.
  Shoot the torso → normal damage, no headshot.
- ✅ **Exploit blocked (falloff)**: from a LocalScript, fire `WeaponFired` then `WeaponHit`
  with `hitInfo.d = 0` while standing far away → server should apply *far* (reduced)
  damage, not max. (Check the victim's health delta.)
- ✅ **Exploit blocked (fake headshot)**: send `WeaponHit` with `hitInfo.part` = the
  victim's Head but `hitInfo.p` far from the head → server rejects ("part/point mismatch",
  no damage). Send a non-BasePart as `part` → rejected ("bad part").
- 🔁 All weapon types still deal damage normally: pistol/rifle (hitscan + projectile),
  shotgun (multiple projectiles), bow, RPG/explosive. No "0 damage" weapons.
- 🔁 Kill feed, kill streaks, assists, and rewards still fire on a legit kill.
- 🔁 PvE: shooting bots still damages/kills them.

### S2 — Health-pickup eligibility (HealthPickupService / MatchService)
- ✅ **Legit heal**: get a kill in a round, walk over the dropped health orb → you heal +30
  (capped at MaxHealth). One orb per kill.
- ✅ **Exploit blocked**: from a LocalScript spam `Network.Match.RequestPickup.Send({kind="Health"})`
  rapidly **without** getting kills → you should heal **at most once per real kill**, not
  every 0.2s. With zero recent kills, no healing at all.
- ✅ **Bot kills count**: kill a bot, then pick up the orb → heal works (the eligibility is
  recorded on the bot-kill path too).
- 🔁 You can't heal above MaxHealth; healing while already full does nothing.
- 🔁 No heal while in menu / round inactive / dead.
- 🔁 After a round resets, leftover eligibility credits are cleared (no banked heals carried
  into the next round). Play two rounds back-to-back to confirm.
- 🔁 Player leaves mid-round → no error, their eligibility table is cleaned.

### S3 — `/resetdata` Studio-only (ClearDataCommandService)
- ✅ In **Studio**, an authorized user typing `/resetdata` still wipes their profile.
- ✅ In a **published place** (or "Start" server that reports `IsServer()` true but not
  Studio), `/resetdata` does **nothing** even for the previously-authorized userId.
- 🔁 Normal chat is unaffected; no errors when any other message is sent.

### S4 — Reload remote ownership (NetworkingCallbacks)
- ✅ Your own weapon still reloads normally (manual reload + auto-reload on empty).
- ✅ **Griefing blocked**: with 2 players, from player A's LocalScript call
  `WeaponReloadRequest`/`WeaponReloadCanceled` passing **player B's** Tool instance →
  B's weapon must NOT enter/exit reload (no forced `IsReloading`, no fake reload broadcast).
- 🔁 Reload animation/sound and ammo refill still work for the legit owner.
- 🔁 No error when a weapon has no metatable / isn't reloadable.

### S5 — Server-side respawn cooldown (MatchService)
- ✅ Die, then watch the death screen — you can only respawn after the full
  `GameConfig.RespawnCooldown` (=1s), not instantly.
- ✅ **Exploit blocked**: from a LocalScript spam `RequestRespawn` immediately after death →
  server ignores until the cooldown elapses.
- 🔁 Normal respawn flow (death screen → respawn button / auto) still works and spawns you at
  a valid spawn point with your loadout.
- 🔁 Return-to-menu still works; respawning after returning isn't blocked incorrectly.

### S6 — ByteNet malformed-buffer guard (read.luau)
- ✅ **Hard to trigger legitimately** — confirm no regression: everything networked still
  works (all remotes below). The guard only matters under a forged buffer.
- ✅ (Optional) From a LocalScript, fire `ReplicatedStorage...ByteNetReliable` with a junk
  `buffer.create(4)` → server should NOT spew errors or drop the frame's other packets;
  the bad buffer is silently discarded.
- 🔁 All real packets still deliver (shop, settings, match, locker, gifting, kill feed).

### S7 — NetGuards numeric validation
- ✅ **Settings sliders**: drag SFX/Music/sensitivity sliders → values apply and persist.
- ✅ **Color picker** (if exposed): set a color → applies; out-of-[0,1] is clamped/rejected.
- ✅ **Battle Pass claim**: claim a valid tier works.
- ✅ **Bad input rejected**: from a LocalScript send `UpdateSlider` with `value = 0/0` (NaN),
  `math.huge`, or `-5` → server rejects (no crash, value unchanged). Send `ClaimTier` with
  `tier = -1` or `1.5` → rejected.
- 🔁 Existing string-capped packets (username for gifting, redeem codes) still validate:
  normal names/codes work; over-long or invalid-UTF8 strings are rejected.

---

## 2. MOBILE PERFORMANCE / LEAKS

> For all perf items, use the **MicroProfiler** (Ctrl+F6 / `Ctrl+Alt+F6`) and the
> **Developer Console → Memory** tab. Watch Instance counts and frame time.

### P1 — Wrap previews throttled + released on close (WeaponWrapPreviewer / Locker / BattlePass)
- ✅ **Throttle (mobile)**: in mobile emulation, open the Locker Wraps tab with animated
  wraps → animations still scroll, but the per-frame cost is lower (check MicroProfiler;
  texture offset updates at ~30Hz, not every frame).
- ✅ **Released on close**: open the Locker (browse Wraps), then close it. In the Dev Console
  Memory/Instances, confirm the animated-texture update loop is no longer doing per-frame
  work (frame time in the lobby returns to baseline; no lingering Texture animation).
- ✅ Same for **Battle Pass**: open (view animated wrap rewards), close → no leftover
  per-frame texture writes.
- 🔁 Reopen Locker/Battle Pass → previews animate again correctly (pooling didn't break
  re-population). Equip a wrap → it still applies and the 3D preview shows it.
- 🔁 Desktop (MouseEnabled) wraps still animate at full smoothness.

### P2 / L1 — Loading screen (LoadingScreen.client)
- ✅ **Normal load**: join → progress bar fills, screen dismisses. Minimum wait now ~2s (was
  6s) — feels faster on a warm/cached join.
- ✅ **No hang (empty assets)**: simulate Lobby/Menu not present (rename "Lobby" in workspace
  before play, or test a stripped place) → loading screen still dismisses (doesn't spin
  forever).
- ✅ **Hard timeout**: artificially make a preload asset stall → screen force-dismisses by
  ~20s instead of trapping the player.
- 🔁 Title text mask still sizes to the title correctly (event-driven now) on different
  screen sizes — test phone, tablet, desktop aspect ratios.
- 🔁 No error if AbsoluteSize stays 0 briefly (bounded wait, 5s).

### P5 — DOF / Blur gated on mobile (DepthOfFieldController / BlurController)
- ✅ **Mobile**: in mobile emulation, idle in the lobby and open a panel → DepthOfField is
  OFF and blur is reduced/half size. Lobby should feel lighter (check frame time).
- ✅ **Desktop**: DOF + full blur still present in the lobby/panels (visual parity preserved
  for non-touch).
- 🔁 Panels still open/close with their backdrop; menu readability is fine without DOF on
  mobile.
- 🔁 Match start/return transitions still toggle effects correctly (no stuck blur).

### P6 — UISoundsController weak refs (UISoundsController)
- ✅ **Sounds still play**: click buttons across menus (nav, locker, shop) → hover/click SFX
  play.
- ✅ **No leak**: switch Locker categories repeatedly (which rebuilds nav buttons ~20×), then
  check Dev Console → Memory: GuiButton / connection counts should stabilize, not climb
  unbounded. Destroyed buttons release their connection.
- 🔁 Persistent menu buttons still produce SFX for the whole session.

### P7 — ByteNet per-player channel cleanup (server.luau)
- ✅ With 2+ players, have one **leave**, then keep playing → no errors, networking for the
  remaining player is unaffected.
- ✅ **No leak**: join/leave a bot or test player several times → server memory for ByteNet
  channels doesn't grow per departed player (Dev Console → Server memory).
- 🔁 `SendTo` to remaining players still delivers after someone leaves.

### P3 — Projectile raycast caps (Parabola / BulletWeapon)
- ✅ **Penetration cap (8)**: fire through a stack of non-collidable/tagged parts → bullet
  stops penetrating after a reasonable number (no frame spike from 50 raycasts).
- ✅ **MAX_BULLET_TIME (2s)**: fire a slow projectile into open sky → it despawns by ~2s.
  Verify normal-range shots still reach their target (2s is enough for normal maps).
- 🔁 ⚠️ **Regression risk**: confirm long-range weapons (sniper/bow arcs) still HIT targets
  at their intended max range and aren't despawning mid-flight. If any weapon legitimately
  needs >2s travel, this needs tuning. Test the longest sightline on each map.
- 🔁 Shotgun (8 projectiles) still hits and the frame stays smooth on mobile.

### P8 — Effect caps & DI leak (HealEffect / BonusEffect / DirectionalIndicatorGuiManager)
- ✅ **Heal particles capped**: trigger a big heal → particle images cap at ~20 concurrent,
  no runaway GUI overdraw.
- ✅ **Bonus coins halved on mobile**: trigger a coin/streak bonus on a touch device → fewer
  physics coins spawn; still smooth.
- ✅ **DI frame no leak**: take damage from several directions rapidly → directional
  indicators appear and **all** fade out and are destroyed (no lingering frames; check
  Instances count returns to baseline). Confirm legacy `wait()` replaced (no scheduler
  warning).
- 🔁 Effects still look correct: heal shimmer, coin burst, damage direction arrows all show.

---

## 3. LOGIC

### L2 — GlobalKillFeed disconnect (GlobalKillFeed)
- ✅ Kill feed shows entries during a match.
- ✅ **Teardown clean**: end the match / leave → no "attempt to call / index" error on
  `Destroy()`. Re-enter a match → kill feed still works (listener re-subscribed, not leaked).
- 🔁 No duplicate kill-feed entries after a HUD rebuild.

### L3 — ByteNet client namespace race (values.luau)
- ✅ Join repeatedly (especially in Studio "Run" and a fresh server) → no "namespace value
  failed to replicate" error and no dead networking. All remotes work on first join.
- 🔁 ⚠️ If you ever see the new error in Output, it means a `StringValue` truly didn't
  replicate in 10s — investigate server startup order rather than reverting.

### L14 — Per-resource cash/XP caps (MatchService / RewardService)
- ✅ Earn cash + XP in a match. Hit the **cash cap** but not XP cap (or vice-versa) → you keep
  earning the **uncapped** resource; the capped one stops.
- ✅ Hit both caps → grants stop, but **Assist counters / extraUpdates still persist**.
- 🔁 Normal kills/headshots/streaks grant the right amounts when under both caps.
- 🔁 Other `RewardService.Award` callers (non-match rewards) are unaffected — daily tasks,
  battle pass, codes still grant fully.

### ShoulderCamera / WeaponsGui disable→enable (L8 / L7)
- ✅ **Equip → unequip → re-equip** a weapon several times → aim camera works every time,
  bullets use the camera ray (not stuck on gun-look).
- ✅ Re-equip then **change resolution** (resize window) or switch camera → the weapon GUI
  still rescales (lifetime watchers survived the disable cycle).
- 🔁 First equip after join works (camera setup completes even if CurrentCamera was briefly
  nil).
- 🔁 Scope/zoom, crosshair, hotbar all still scale correctly.

### Roblox.findInstanceImpl (L10)
- ✅ Weapon system boots without hanging (it uses `waitForInstance` internally) — join and
  equip a weapon. No infinite-yield warnings.
- 🔁 All weapon assets resolve (effects, sounds load on first shot).

### DeathScreenView fades (L12)
- ✅ Die → death screen **fades in** smoothly (from transparent to base), then **fades out**
  on respawn (to fully transparent), not a hard cut.
- 🔁 Death screen timer/respawn button still function; no stuck overlay after respawn.

### Music volume race (L11 / settings)
- ✅ Open Settings → Music Volume slider actually changes lobby music loudness, even on a
  fresh join where the Sound is created late.
- 🔁 SFX slider and other settings still apply; values persist across rejoin.

### TeamUtils (L13)
- ✅ Friendly fire: you **cannot** damage teammates; you **can** damage enemies.
- ✅ Team color comparisons are case-insensitive (no friendly-fire glitch from "Red" vs
  "red").
- 🔁 ⚠️ **Regression risk**: lobby/teamless characters are now NOT auto-enemies — confirm
  this didn't disable any intended lobby interaction. Verify in-match team assignment still
  damages enemies correctly.

### KillEffects: destroy joints, not ClearAllChildren (Default / Gravity / Utils)
- ✅ Kill a player/bot with the **Default** kill effect → ragdoll forms correctly, **death
  sound still plays**, root attachments intact.
- ✅ **Gravity** kill effect → ragdoll floats/falls per design.
- ✅ **Non-R15 rig** (R6, if any) under Gravity → does NOT dismember into loose parts (the
  non-R15 fix); rig stays connected.
- 🔁 Ragdoll cleanup still removes the corpse after the lifecycle delay; no leftover welds.
- 🔁 Both effects look the same as before (the dedup is behavior-preserving for R15).

### Cosmetics config reconciliation (L5 / L6 — ItemsConfig)
- ✅ **No phantom face**: new player spawns with a valid default face (the head shows the
  base face, not a blank/broken decal). Equipping "Default" in the Locker resets to base
  face.
- ✅ **BP-exclusive items hidden/locked**: Gravity, Face2/5/9, Hat2/3 now show as
  locked/BP-exclusive in the Locker (not as buyable with a price). Attempting to buy is
  consistent with the server (no "buy button that always fails").
- 🔁 Genuinely buyable items (other faces/hats/wraps) still purchase normally and deduct
  cash.
- 🔁 Players who already own a BP-exclusive item (via the pass) can still equip it.
- 🔁 ⚠️ Verify the `Default` face Image (`rbxasset://textures/face.png`) renders in the
  Locker grid tile (it should show the classic face icon).

---

## 4. QUALITY (low-risk, mostly "did I break a require")

- ✅ **Deleted locker modules** (ActionFrameController, NavTabPopulator,
  PurchaseFlowController, KillEffectsDummyController): game boots, Locker fully works
  (categories, nav, purchase flow, kill-effect dummy preview) — all functionality is the
  inline version in `locker/init.luau`. No "module not found" errors.
- ✅ **Removed RemoteFunction setup** (WeaponsSystem): weapons still fire/reload (it was dead
  code; `REMOTE_FUNCTION_NAMES` was empty).
- ✅ **KillFeed now Reliable**: kill feed entries don't drop under simulated packet loss.
- 🔁 GiftingController button recovers if a validate response is lost (5s timeout) — test by
  not responding.
- 🔁 MapVoteView: starting a new vote within ~3s of a previous winner reveal doesn't hide the
  new vote (token guard).
- 🔁 init.client: ResetButton callback still suppressed; no infinite retry spam in Output.

---

## 5. WEAPONS CONFIG MIGRATION (Configuration → Shared/constants/WeaponsConfig)

Prereq: run `tools/weapons/StudioMigration.luau` from the Studio command bar
(stamps `WeaponCategory`/`WeaponId` on each `ServerStorage.WeaponTools` Tool and
removes what the definition now covers: its legacy `Configuration`, the
`WeaponType`/`CurrentAmmo`/`IsReloading` attributes and the `AmmoType` value),
then save the place. Re-run it whenever you add a weapon.

- ✅ **Boot clean**: no `[WeaponsConfig]` errors (Studio fails fast on a bad key/type)
  and no `[BaseWeapon] ... Configuration obsoleta` warns (those mean the migration
  script has not been run on that Tool).
- ✅ **Per-weapon feel unchanged**: AK/Groza/Default automatic at 8 shots/s, Sniper has
  scope + 4.5x zoom + 1-round mag, Large fires 5 pellets, RPG explodes with the
  Rocket tracer, UZI at 20 shots/s. Compare against the values in
  `Definitions/<Category>/<Id>.luau`.
- ✅ **Locker stats panel**: select each weapon → Damage/FireRate/Reload/Ammo show
  instantly (no round-trip) and match the definition; compare bars vs equipped
  weapon still colour up/down; level scaling still applies with kills.
- ✅ **Hotbar ammo**: magazine capacity matches `AmmoCapacity` (× WeaponLevel).
- ✅ **Full magazine on spawn**: every weapon spawns loaded to its definition's
  capacity, with no reload animation on first equip. Watch the four weapons whose
  Tools were duplicated and carried a stale authored `CurrentAmmo`: Tommy (50),
  Short (2), Special Default (12), Laser (20). At weapon level 5 the starting
  count should be the scaled capacity (AK: 42), not the base one.
- ✅ **No phantom weapons**: nothing in `ServerStorage.WeaponTools` or
  `ReplicatedStorage` is instantiated as a live weapon at startup (previously each
  template became one on the server and on every client).
- ✅ **Bots**: a bot with a catalog weapon (e.g. Sniper) fires at that weapon's
  cadence; the client renders its tracers/sounds (Tool resolves its definition).
- ✅ **Both "Default" weapons**: Main/Default and Special/Default resolve to their own
  category (attribute-based identity), hotbar slots are correct.
- 🔁 **No definition, no weapon**: a Tool tagged `WeaponsSystemWeapon` with no definition
  (e.g. a prototype outside `WeaponTools`) logs one `[WeaponsSystem]` warn and is not
  instantiated; nothing else breaks.
- 🔁 Server-side hit validation (WeaponSecurity) still uses the same ShotCooldown /
  NumProjectiles / MaxDistance — no "shot too fast" rejections on legit fire.

---

## Suggested test order (fastest path to confidence)
1. **Boot + Output clean** (catches deletions / syntax / require breaks immediately).
2. **2-player match**: kills, damage falloff, headshots, kill feed, caps, respawn, death
   screen, ragdoll + death sound. (Covers S1, S5, L2, L12, L14, killEffects.)
3. **Self-heal exploit + reload-grief** from a LocalScript. (S2, S4.)
4. **Locker + Battle Pass** open/close/equip, cosmetics config, button leaks. (P1, P6, L5,
   L6, deletions.)
5. **Mobile emulation pass**: loading screen, DOF/blur, wrap throttle, effect caps. (P2, P5,
   P1, P8.)
6. **Settings**: sliders + NaN/range rejection. (S7, L11.)
7. **Join/leave churn** with 2+ players for ByteNet cleanup. (P7, L3.)
8. **Long-range weapon range check** — the one regression to watch from P3.
