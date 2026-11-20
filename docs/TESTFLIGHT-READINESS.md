# Blockle Hero — TestFlight readiness report

Date: 2026-11-19
Engine: Godot v4.7.2.stable.official.ed1daf0bf
Project: `/Volumes/ExtremePro/trail-of-heroes` (directory not renamed; the game is now named
"Blockle Hero" in `project.godot` → `config/name`)

Every number in this report came from running something. Where a claim could not be verified by
execution it is labelled **UNVERIFIED** and treated as not done.

---

## 1. Verdict

# NO-GO

Not "needs polish" — **there is currently no path to an .ipa at all**, and if there were, it would
launch into an empty scene with zero hero models in the bundle.

Three independent, verified facts each block a build on their own:

| # | Fact | How it was verified |
|---|---|---|
| 1 | No iOS export preset exists. `find . -name export_presets.cfg` → **0 results**. `ls -a` of the project root shows only `.godot branding docs icon.png icon.png.import project.godot scenes scripts tools`. | run |
| 2 | **No hero asset ships.** `find . -name "*.glb"` inside the project → **0 results**. `HeroRig.gd` loads models at runtime from absolute macOS paths (`/Volumes/ExtremePro/raid/assets/heroes/{animated,tex}`) via `GLTFDocument.append_from_file`. An iOS device cannot read `/Volumes`. A build today contains 0 bytes of heroes and resolves no model. | run |
| 3 | **The configured main scene is an empty stub.** `project.godot` line 18: `run/main_scene="res://scenes/Main.tscn"`, and `scenes/Main.tscn` is literally `[node name="Main" type="Node3D"]` and nothing else. The playable scene is `scenes/Play.tscn`, which nothing boots into. A TestFlight build launches to an empty 3D viewport. | run |

On top of those, the playable scene cannot execute the game's own combat verbs (abilities are
unreachable), and the locomotion/stun presentation has a confirmed defect the animation contract
calls out as its most important note.

Nothing in this list is a research problem. All of it is mechanical work, and most of it is under a
day. But none of it is done.

---

## 2. Blockers

### B1 — Nothing hero-related is in the bundle; hero loading is an absolute dev path

`scripts/game/HeroRig.gd:52-55` points `search_dirs` at `/Volumes/ExtremePro/raid/assets/heroes/animated`
and `.../tex`, and `HeroRig.gd:117` loads them at runtime with `GLTFDocument.append_from_file`.

Evidence:
- `find /Volumes/ExtremePro/trail-of-heroes -name "*.glb"` → 0 results (re-verified for this report).
- `ls export_presets.cfg` → no such file.
- grep: the only `.glb` paths anywhere in the codebase are the three absolute `/Volumes/ExtremePro/raid/...`
  constants in `HeroRig.gd:53-54`, `tools/riginfo.gd:6`, `tools/shots.gd:16`.

Fix: copy the chosen hero set under `res://assets/heroes/...`, repoint `ANIMATED_DIR`/`STATIC_DIR`
at `res://` paths, and load the imported `.scn` (or keep the glb-at-runtime path but ship the glbs —
see §3, that costs 1113.6 MiB instead of 378.9 MiB for the same 139 heroes).

### B2 — `main_scene` is an empty Node3D

`scenes/Main.tscn` contains one node and no script. Either point `run/main_scene` at
`res://scenes/Play.tscn` or make `Main.tscn` a real boot/menu scene that loads it. Until then the
build boots to nothing. Verified by reading both the setting and the scene file.

### B3 — `ability_1` / `ability_2` / `ability_3` never play in the shippable scene

`scripts/game/Play.gd:55-57` calls `_hero.setup()` and **never** `setup_combat()`, so
`HeroController.abilities` stays empty and `basic` stays null. `ability_in_slot()` returns null for
every slot, and `HeroController.gd:168` falls through:

```gdscript
rig.set_state(ab.anim_state() if ab != null else HeroRig.State.ATTACK)
```

Keys 1-4 therefore all play the `attack` clip. Nothing in `scripts/` calls `setup_combat()` — only
`tools/stunlive.gd:58` does.

Evidence (live interrogation of the real Play scene, windowed, Metal/M2 Pro):
```
controller.abilities.size()=0  basic=null
ability_in_slot(0..3) = <null> for all four
use_ability(0)=true rig.state=3 clip='attack' len=0.77
use_ability(1)=true rig.state=3 clip='attack' len=0.77
use_ability(2)=true rig.state=3 clip='attack' len=0.77
use_ability(3)=true rig.state=3 clip='attack' len=0.77
```
`rig.state=3` is `ATTACK` (`HeroRig.gd:28`). Driving the rig directly instead:
`ability_1` 0.63 s, `ability_2` 0.73 s, `ability_3` 0.83 s — all present and correct in the glbs.
The same gap was hit independently by `tools/playtest.gd` (all four slots reported `state=3`).

So: three quarters of the delivered animation work is unreachable in the only playable scene, and
the animator's main question ("do the abilities read?") **cannot be answered by a tester**.

---

## 3. Major findings

### M1 — Feet skate during all locomotion, on every hero

`HeroRig.set_locomotion()` (`HeroRig.gd:244-245`) writes only `_speed01`. `_speed01` appears 6 times
in the file and every read is inside `_procedural()` (`HeroRig.gd:286-315`), which `_process()` gates
behind `if not is_rigged` (`HeroRig.gd:278`). On a rigged hero `set_locomotion()` is dead code, and
`set_state()` plays clips at speed 1.0 with no rate matching. There is no `speed_scale` reference
anywhere in `HeroRig.gd`.

Measured planted-foot slide (world-space horizontal speed of the lowest foot bone vs body speed) and
stride excursion against what the speed requires:

| hero | run 6.15 m/s (needs 2.26 m/step) | walk 3.40 m/s (needs 2.49 m/step) |
|---|---|---|
| aldous | stride 0.42 m (18%), foot at 90% of body speed, stance 14% of cycle | stride 0.30 m (12%), 95%, stance 20% |
| g001 | stride 1.29 m (57%), 91%, stance 5% | stride 0.93 m (38%), 84%, stance 9% |
| brom | stride 1.40 m (62%), 76%, stance 4% | stride 0.97 m (39%), 83%, stance 5% |

A real gait holds the stance foot near 0 m/s for ~40% of the cycle. Live probe confirms
`AnimationPlayer.speed_scale == 1.00` both running and stunned.

### M2 — The stun reads as "strolling", not "laboured" — and is invisible when standing still

`docs/ANIMATION-HANDOFF.md` calls walk-vs-run legibility "the single most valuable note in this
document", because walk doubles as the stun animation.

What works (measured on the real `HeroController` in a real generated world, `tools/stunlive.gd`):
```
unstunned: plays RUN,  6.13 m/s
stunned:   plays WALK, 1.87 m/s  (= WALK_SPEED 3.4 x STUN_SPEED_MULT 0.55 = 1.870 exactly)
all four ability slots refused while stunned
stun expires -> back to RUN at 6.20 m/s
```
Walk and run are genuinely different clips, not one time-scaled: roster-wide 139/139 heroes have
walk 1.467 s / run 0.733 s, leg ROM 45° vs 74°, phase-matched whole-skeleton diff 22.4° (walk-vs-idle
control: 11.0°), hip bob 4.7 vs 9.8 cm, foot lift 10.1 vs 16.6 cm.

What is wrong — the posture is inverted (`tools/walklabour.gd`, aldous):

| | walk (stun) | run | delta |
|---|---|---|---|
| mean forward lean | **-0.0°** | 17.0° | -17.0° |
| mean head height | **1.457 m** | 1.406 m | **+5.0 cm higher** |
| L/R stride asymmetry | 4.3% (no limp) | 10.7% | — |

A stunned hero stands up *straighter* and lifts his head. Every "laboured" marker is absent or
inverted; the stun reads as a speed change, not as damage.

Worse, it can be completely invisible: `HeroController._physics_process` returns early to
`State.IDLE` when there is no path (`HeroController.gd:195-199`), *before* the stun branch at
`:262`. Verified live — stunned + stationary plays IDLE, pixel-identical to an unstunned idle hero.

And in the shippable scene you cannot stun the hero at all: `Play.gd` never calls `setup_combat()`,
so `HeroController.body` is null and `is_stunned()` is permanently false, and `_order_move` always
passes `run=true`. `State.WALK` is unreachable in `Play.tscn` today — which is why this was never
caught by eye.

Captured at true shipping framing (ArpgCamera 25 m / 48° pitch / 35° yaw / 38° lens, 1170x2532
SubViewport, hero 181 px tall): `tools/out/gait_aldous.png`, `gait_kaelen.png`. At that size the
cadence difference is the only signal that survives; the pose difference is modest.

### M3 — `aldous` `ability_2` reads as a ragdoll, not a slam (per-hero, not systemic)

At 25% through the clip aldous is fully horizontal and airborne: skinned-mesh silhouette collapses
1.85 m → 1.02 m and the bottom of the mesh sits **+0.304 m above** the terrain. The contract requires
`ability_2` to read as a slam/shove/shockwave for every hero. aldous also clips 7-13 cm of foot
through terrain on `attack` / `ability_1` / `ability_3` (`ability_1` @25% = -0.129 m,
`ability_3` @50% = -0.110 m).

Roster-wide scan of all 139 heroes (556 clips) by silhouette collapse vs idle: worst is
`g050 ability_3` at 47.2% of idle height, then `g050 ability_1`, `g146`, `g060`, `g149`, with
`aldous ability_2` 4th (54.4%) and `aldous ability_3` 3rd (53.9%). 176 clips sit at a normal
crouching 78-80%, so only the sub-60% tail is suspect. `g001` and `brom` are clean
(ground contact -0.014 to +0.05 m, upright arms-forward `ability_2`).

This is an animation-source fix for a handful of heroes, not an engineering blocker.

---

## 4. iOS packaging decision

### Recommendation: ship the **139 animated heroes only**, as imported `.scn` + `.ctex`, as a single
### full download for the first TestFlight build — and plan On-Demand Resources before public release.

All sizes below were measured, not estimated: the 139 glbs were copied into `res://assets/heroes_test`,
`--import` was run for real (exit 0, 139 `.scn` produced) with `project.godot`'s
`rendering/textures/vram_compression/import_etc2_astc=true` and `renderer/rendering_method="mobile"`
(both confirmed present in `project.godot` lines 32-33). The test dirs and all 800 generated imported
files were then deleted and `--import` re-run clean.

| set | raw .glb | imported (.scn + .ctex) | per hero | gzip -6 download |
|---|---|---|---|---|
| 139 animated | 1113.6 MiB (1,167,652,996 B) | **580.1 MiB** (378.9 + 201.2) | 4.17 MiB | **~556 MiB** |
| 61 static-only (tex/) | 135.6 MiB | 170.4 MiB (81.5 + 88.9) | 2.79 MiB | — |
| all 200 | 1249 MiB | 750.5 MiB | — | — |

Gzip ratios measured on 12-file random samples of the imported artifacts: `.scn` 0.945,
`.ctex` 0.998. (Raw `.glb` gzips to 0.34-0.39, but the raw `.glb` is not what the import pipeline
ships — do not quote that number.)

Against Apple's thresholds as applied in the audit: 580.1 MiB is **2.8x the 200 MB over-the-air
threshold** and **14% of the 4 GB app hard limit**. It fits the App Store; it does not fit under the
cellular-download threshold, so a public release would be Wi-Fi-gated unless ODR or asset reduction
lands. For a first internal TestFlight build that is acceptable; for release it is not.

Supporting decisions, all evidence-backed:

- **Do not ship `tex/` for the 139.** Basename diff (`comm` on sorted basenames): 200 tex, 139 animated,
  61 tex-only, **0 animated-only**. The animated set is a strict subset, so `tex/`'s 304.9 MiB of
  overlapping heroes is pure redundancy. `tex/` is only needed if the roster goes back to 200.
- **Why animated is 3.6x tex:** glb chunk parse of `aldous.glb` — 8.30 MiB = 180 KB JSON + 8.12 MiB BIN,
  1 mesh @ 119,970 verts, 1 skin, 35 nodes, 8 clips, 1 PNG @ 1.52 MiB. Static `g004.glb` is
  26,263 verts, POSITION+TEXCOORD_0 only, 0 anims. 4.6x the geometry plus skinning and animation.
- **No outlier to trim.** animated/ per-file: avg 8.01 MiB, median 8.00, min 7.69 (`g035.glb`),
  max 8.30 (`aldous.glb`). Extremely tight spread — size reduction has to come from mesh decimation
  or texture budget, not from deleting a few fat files.
- **Everything else is noise:** `scenes/` 24 K + `scripts/` 472 K ≈ 0.5 MiB of shippable non-hero
  content.
- **`tools/` must be export-excluded.** It is 46 MB, including 39 PNGs totalling 36.9 MiB of QA
  screenshots, and they are currently being imported into `.godot/imported`.

**UNVERIFIED:** no ODR implementation exists, and no `.ipa` has ever been produced, so the download
figures above are measured import sizes — not an Apple-reported app size.

---

## 5. What is still unwired

### `hit` — no clip, and **no procedural fallback either** (the common assumption is wrong)

`hit` is absent on **139/139** heroes. Roster sweep (`tools/rigsweep.gd`, all 139, not a sample):
```
rigged=139 / 139
missing-state tally:   { "hit": 139 }
distinct missing sets: { "[\"hit\"]": 139 }
distinct clip sets:    one 8-clip set for all 139
  ["ability_1","ability_2","ability_3","attack","death","idle-loop","run-loop","walk-loop"]
anomalies: none
```
`ANIMATION-HANDOFF.md` lists `hit` as "not wired yet, ship it if cheap", so its absence is permitted
by the contract.

But it does **not** fall back to procedural recoil on a rigged hero. `HeroRig.set_state()` for an
unresolved state on a rigged model sets a timer and returns (`HeroRig.gd:266-269`):
```gdscript
if st in [State.ATTACK, State.ABILITY_1, State.ABILITY_2, State.ABILITY_3]:
    _oneshot_left = 0.45
elif st == State.HIT:
    _oneshot_left = 0.25
```
and `_process()` gates the stand-in behind `is_rigged` (`HeroRig.gd:278`):
```gdscript
if not is_rigged and _model != null:
    _procedural(delta)
```
The recoil pose does exist — `_procedural()` has a `State.HIT: lean = -0.4 * ...` branch at
`HeroRig.gd:306-307` — but it is unreachable for all 139 rigged heroes. A rigged hero entering HIT
plays no new clip **and** gets no flinch; the previously-playing clip simply keeps running for 0.25 s
until `state_finished` fires. Timing stays honest; the visual is a silent no-op. This is the one
place the "rigged or static, the controller never knows" seam leaks.

### `death` — the clip exists and is **never triggered anywhere**. Confirmed.

The suspicion in the brief is correct. Verified by exhaustive grep over `scripts/ tools/ scenes/`:

```
$ grep -rn "State.DEATH\|State.HIT" scripts tools scenes
scripts/game/HeroController.gd:324:   HeroRig.State.HIT]:            <- only in the state_finished filter
scripts/game/HeroRig.gd:34,48,49,268,306,308                         <- only tables + the stand-in
```

There is **no `set_state(HeroRig.State.DEATH)` call in the entire project**, and no
`set_state(State.HIT)` either. `HeroController` sets exactly four states: `IDLE` (`:197`, `:224`,
`:334`), `RUN`/`WALK` (`:293`), and `ATTACK`/`ABILITY_*` (`:168`). The `HIT` reference at `:324` is in
the `_on_rig_state_finished` filter list — it handles a HIT *ending* that can never begin.

The plumbing is half-built: `Combatant.gd:18` declares `signal died()` and `Combatant.gd:206` emits
it — but grep for `died` across `scripts/` finds **no `.connect()` to it anywhere**. The only signal
connections in the project are `HeroController.gd:71` (`rig.state_finished`), `HeroRig.gd:183`
(`animation_finished`), and `Play.gd:32,34` (world-builder progress/finished).

So: a 5.80 s death animation is present on all 139 heroes, imported, and shipping bytes — and no
hero or enemy will ever play it. That is both a content gap (nobody dies on screen) and ~5.80 s of
keyframes per hero paid for in download size for nothing.

Also still unwired, for completeness:
- `setup_combat()` is never called from `scripts/` (only `tools/stunlive.gd:58`) — see B3. This single
  omission is what makes abilities, stun, and HIT unreachable in `Play.tscn`.
- `AnimationPlayer.speed_scale` is never driven — see M1.
- `tools/playtest.gd` cannot verify abilities for the same reason, so **ability clip playback is
  unverified by any automated harness**, even though it works when the rig is driven directly.

---

## 6. Exact remaining manual steps to TestFlight

Steps marked **HUMAN** cannot be done from this machine by a script — they need an Apple Developer
account, Xcode, and a signing identity.

### Code / project work (no human account needed)

1. Point `run/main_scene` at a real scene (`res://scenes/Play.tscn`, or make `Main.tscn` boot it). — B2
2. Copy the 139 animated `.glb` into `res://assets/heroes/animated/`, run
   `Godot --headless --path . --import`, and repoint `HeroRig.ANIMATED_DIR` / `STATIC_DIR` at the
   `res://` paths. Keep the per-hero fallback order. — B1
3. Call `HeroController.setup_combat()` from `Play.gd` alongside `setup()`. This one line unblocks
   abilities, stun, and HIT in the playable build. — B3
4. Drive `AnimationPlayer.speed_scale` from `HeroRig.set_locomotion()` on rigged models, or blend
   walk/run by speed. — M1
5. Connect `Combatant.died` → `rig.set_state(HeroRig.State.DEATH)` so the death clip is reachable. — §5
6. Decide on `hit`: either request the clip, or let `_procedural()` run for unresolved states on
   rigged models so the existing recoil pose is used. — §5
7. Exclude `tools/` (and `branding/`) from the export filter so 36.9 MiB of QA screenshots and the
   test scenes do not ship. — §4
8. Fix the stun posture (lean/head-drop/asymmetry on `walk-loop`) and re-author the sub-60%-collapse
   ability clips (`g050 ability_3/ability_1`, `g146`, `g060`, `g149`, `aldous ability_2/ability_3`).
   Animation-source work, not code. — M2, M3

### Godot export setup

9. Install the Godot 4.7.2 **iOS export templates** (Editor → Manage Export Templates). Not present
   on this machine — **UNVERIFIED**, no export has ever been attempted here.
10. Create the iOS export preset (this writes the missing `export_presets.cfg`). Set:
    - `application/bundle_identifier` = `org.blockle.hero`
      (nothing sets this today: `project.godot` has no `*identifier` key and there is no
      `export_presets.cfg` at all — both re-verified for this report)
    - **HUMAN** Team ID, signing identity / provisioning profile
    - orientation: portrait (`project.godot:28` already sets `window/handheld/orientation="portrait"`)
    - leave the icon slots empty — the exporter falls back to `application/config/icon`, which is set
      to `res://icon.png` (`project.godot:20`). Confirmed from the binary: `strings` on
      `/Applications/Godot.app/Contents/MacOS/Godot` contains `icons/app_store_1024x1024`,
      `icons/iphone_180x180`, `icons/iphone_120x120` and `- falling back to project icon: `.
      `icon.png` verified 1024x1024, FORMAT_RGB8, no alpha, opaque to the pixel corners.
11. Export the Xcode project / `.ipa`, bump `application/short_version` + `application/version`.

### Apple side — all **HUMAN**

12. **HUMAN** App Store Connect: create the "Blockle Hero" app record with bundle id `org.blockle.hero`.
13. **HUMAN** Register the bundle id and create a distribution provisioning profile; have a valid
    Apple Distribution certificate in the login keychain.
14. **HUMAN — DECISION NEEDED, DO THIS BEFORE SHIPPING ANY BUILD:**
    `scripts/game/IAPCatalog.gd` `PRODUCT_PREFIX` was changed from `org.blockle.trailofheroes.` to
    `org.blockle.hero.`, which renames all 9 IAP product IDs (e.g. `org.blockle.hero.gold.small`).
    Nothing in the repo depends on the old prefix (grepped), and no products appear to be registered
    yet — but **App Store Connect product IDs cannot be renamed after creation**. If any of the 9
    already exist in ASC, revert that one line.
15. **HUMAN** Archive in Xcode (or `xcodebuild -exportArchive`), then upload with
    `xcrun altool --upload-app -f Blockle Hero.ipa -t ios -u <apple-id> -p <app-specific-password>`
    (or Transporter.app, or `xcrun notarytool`-era `xcrun altool` replacement
    `xcrun altool`/`xcrun iTMSTransporter`). An app-specific password or an App Store Connect API key
    is required — **HUMAN**.
16. **HUMAN** Fill the TestFlight export-compliance answers. Note for that form: the app embeds no
    crypto of its own that we were shown, but the IAP catalogue and any Blockle wallet deep-linking
    should be reviewed by a human before answering.
17. **HUMAN** Decide full-download vs ODR before public release (§4). Not required for the first
    TestFlight build.

**Nothing in steps 9-17 has ever been executed on this machine.** No `.ipa` exists, no export
templates are configured, and `export_presets.cfg` does not exist. Treat the entire Apple half of
this pipeline as untested.

---

## 7. What *is* actually ready (so the NO-GO is not misread)

These were verified by running, on all 139 heroes where stated:

- **Animation delivery matches the contract, exactly, on 139/139 heroes.** `rigged=139/139`,
  `missing-state tally {"hit": 139}`, one single 8-clip set across the whole roster, `anomalies: none`.
  33-bone skeleton, 1 mesh, 1 skin, 1 AnimationPlayer per hero.
- **All nine state bindings resolve** except `hit`. `attack`/`ability_1..3`/`death` take the exact
  canonical-name branch in `_find_clip`; only `idle-loop`/`walk-loop`/`run-loop` use the fuzzy
  substring branch, with no alias cross-collision.
- **Clips are real motion, not poses:** 35-47 tracks and 805-6300 keyframes per clip, 28 rotation
  tracks, max bone rotation 90-161° on action clips. Loop flags correct. Root motion absent as
  required (`hip_pos_tracks=0`, `hip_xz_motion=false` on all sampled). Attack/ability lengths
  0.57-0.90 s, inside the contract's 0.4-0.9 s window.
- **Scale and ground contact are correct.** True skinned-vertex extent: aldous idle bottom -0.033 m
  / top +1.814 m / height 1.85 m; g001 -0.013 / +1.832 / 1.85 m. `HeroRig._normalise_scale` absorbs
  the 1.99 m source height at scale 0.927-0.931, exactly as the contract predicted. Confirmed
  visually against a 1.85 m banded rod at matched camera distance.
- **The roster gate works and the 139-hero split is safe.** `list_heroes()` (which returned the first
  non-empty dir and would have silently shipped 200 static heroes if `animated/` were empty) was
  deleted and replaced with `animated_heroes()` / `all_loadable_heroes()` / `is_animated()`; all 9
  call sites updated. `Roster._grant_champion()` now `push_error`s on an off-catalogue hero.
  Legacy saves keep heroes they already own (`from_dict` does not filter `owned`).
- **Test suites: zero failures.** `metatest.gd` 45 PASS / 0 FAIL; `combattest.gd` 0 failures;
  `rostersplit.gd` 20 PASS / 0 FAIL. Crystal odds actual 51.51/27.48/13.92/5.92/1.17% vs published
  52/28/14/5/1%; pity guarantee holds, worst observed gap 29 of 30; 2000 opens → 0 refunds, all 139
  champions obtainable; all 5 rarity tiers and all 3 classes populated; `Champion.starters()` returns
  g001/brom/g003 covering Fighter/Ranger/Mage.
- **Worlds generate and are traversable.** `preview.gd`: greenwood/frostcrag/molten all
  NODES-CONNECTED 100.0% (12 nodes, 14 edges), 1414/1470/1437 ms, walkable 74.0/73.1/60.9%;
  pvp 100.0%. `PlayTest.tscn` windowed on an animated hero (`aldous`, `rigged=true`): arenas reached
  8/8, failed 0, off-walkable samples 0 / 7969.
- **Region generation profiled:** TOTAL 1900.0 ms per 384² region (greenwood) — `_carve_layout`
  415.3 ms (21.9%), `Shade.bake` 372.3 ms (19.6%), `Scatter` 236.0 ms (12.4%).
- **Rename is complete and verified:** `config/name = 'Blockle Hero'`, IAP prefix `org.blockle.hero.`,
  9 packs built, and `grep -rniI -E "trail of heroes|blockle legends|trailofheroes"` over the project
  (excluding `.git`/`.godot`) returns zero matches.
- **App icon is in place:** `res://icon.png`, 1024x1024 RGB8, no alpha, loads in Godot, and sits in
  the documented iOS fallback slot.

---

## 8. Minor / known, not blocking

- **No Legendary Mage exists — in either roster.** Legendary × class is Fighter 1 / Ranger 2 /
  Mage 0 on the 139 **and** on the full 200. `Champion.rarity_of()` is a name hash; it simply never
  put a Mage in the 2% bucket. The animation gate did not cause this. A Mage player can never own a
  Legendary of their own school. Fixing it means touching the hash or the weights. Epic Mage also
  drops 5 → 2, so the Mage school's top two tiers are 2 heroes total.
- **Champion-pool rarity curve drifts off design weights** after hiding the 61: Epic 8.00% → 5.76%
  (target 7%), Rare 17.00% → 18.71% (target 15%), Uncommon 25.50% → 23.74% (target 26%). These are
  pool proportions, not the published crystal odds — `CrystalOdds` is a separate table and
  `metatest` still confirms rolls match the published figures.
- **The starting trio changed** for new accounts (now g001/brom/g003) because `starters()` takes the
  first Common per class in sorted order and several of the old picks are among the hidden 61.
  Existing saves are unaffected.
- **61 heroes ship hidden, not deleted.** Drop a rigged `.glb` into `animated/` and a hero rejoins
  the roster with no code change.
- **`tools/playtest.gd` has to be run as a scene**, not with `--script` (it `extends Node3D`), so it
  produces no output under `--script`.
- Two measurement traps were hit and corrected during verification, and are documented in the tools
  so they are not re-hit: `Skeleton3D.get_bone_global_pose()` is stale under `--headless` (returns an
  identical value at every phase, which first reported "walk and run are identical"), and `--headless`
  is not paced to realtime (wall-clock distance over-reported run speed as 6.78 m/s against a
  RUN_SPEED of 6.2). All metre figures in this report come from chaining `get_bone_pose()` through
  parents and from frames / `Engine.physics_ticks_per_second`.

---

## 9. Re-runnable verification harnesses

```
tools/rigsweep.gd      all 139 heroes: rigged?, clip set, missing states, motion detail
tools/rigverify.gd     12-hero spread: state bindings + which _find_clip branch
tools/rigcheck.gd      sample + root-motion probe (hip_pos_tracks / hip_xz_motion)
tools/rostersplit.gd   139-vs-200 roster invariants, 2000 live crystal opens
tools/walkrun.gd       per-bone phase-matched walk-vs-run diff, world-metre travel
tools/walkrun_all.gd   the same questions across all 139
tools/walklabour.gd    is the walk LABOURED (hunch / head drop / limp) or just smaller?
tools/walkrun_dbg.gd   kept: documents why the obvious bone-pose approach returns stale data
tools/stunlive.gd      + scenes/StunLive.tscn — real HeroController, real stunned Combatant
tools/stungait.gd      + scenes/StunGait.tscn — contact sheet at true ArpgCamera framing
tools/stunshot.gd      + scenes/StunShot.tscn — close-up phase-matched run vs stunned walk
tools/visverify.gd     + scenes/VisVerify.tscn — in-scene shots, slide/stride/scale numbers
tools/posescan.gd      + scenes/PoseScan.tscn — roster-wide pose scan (prints SCAN INVALID if the
                       skeletons did not actually move)
tools/castprobe.gd     + scenes/CastProbe.tscn — reproduces B3 in one run
tools/iconcheck.gd     app icon resolves, size, format, alpha, corner pixels
tools/metatest.gd      meta/roster/crystal suite (45 checks)
tools/combattest.gd    combat, stun, armour, mage-kit suite
tools/profile.gd       region-generation profile
tools/preview.gd       per-biome connectivity / walkability
```

Always run `Godot --headless --path /Volumes/ExtremePro/trail-of-heroes --import` after editing any
script or `project.godot`, before running these.

Screenshots: `tools/out/vv_*.png` (38, game-camera + feet close-ups per state),
`tools/out/gait_aldous.png`, `gait_kaelen.png`, `tools/out/stun_<hero>_p{00,25,50,75}.png`,
`tools/out/play_01_walk.png`, `play_02_ability.png`.
