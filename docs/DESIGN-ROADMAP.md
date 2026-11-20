# Blockle Hero — design direction

Captured from direction given during development. Ordered by what blocks what,
not by when it was said. Nothing here is built yet unless it says so.

---

## 1. Campaign shape: 100 lane maps × 8 difficulties

**Target.** 100 levels per difficulty, 8 difficulties, campaign replayed at each.

**What exists today, and how far off it is:**

| | now | target |
|---|---|---|
| Regions | **16** (`Campaign.REGIONS_PER_ACT = 4`, 4 acts) | **100** |
| Difficulties | **4** — `Tier { NORMAL, VETERAN, MERCILESS, ETERNAL }` | **8** |
| Map shape | circular arenas, graph of nodes + loops | **lanes** |

`Campaign.TIER_*` are dictionaries keyed by the 4-value enum — levels, health,
damage, XP, loot bonus. Going to 8 means either four more hand-tuned rows or,
better, a curve the tiers sample, so tier 8 cannot be forgotten in one table and
present in another.

**Reward.** Clearing a whole difficulty grants **one spawn crystal, once ever**.
Must be idempotent and persisted in `Roster` (the single save) — a per-tier
`cleared` flag, not a counter that a replay can increment again.

## 2. Lane-centric maps — ALONGSIDE the arenas, not instead of them

**Target.** Each campaign map is a long lane that leads to the boss at the end.

**THE ARENA GENERATOR STAYS. It is the PvP mode.** `scripts/world/Layout.gd`
already builds 180° rotationally symmetric arena graphs — that symmetry exists
*for* PvP, where both players must get a mirror-identical start. Do not
"simplify" it away while building lanes; it is load-bearing for a mode that has
not been built yet, and nothing else in the project will re-derive it.

So the world gains a layout KIND:

| kind | generator | used by |
|---|---|---|
| `ARENA` | `Layout.gd` as it stands — MST + loops, 180° symmetry | PvP (later) |
| `LANE` | new — a spine with side pockets, boss at the far end | the 100-map campaign |

`Terrain._carve_layout` and `_path_field` consume whichever kind they are given,
so both must produce the same shape of output (walkable cells + a path field).

**Spawn placement follows the kind, and both are wanted:**

- **Ring placement** — `Encounter.gd` as written (untested): spawns in a ring
  around the player, outside a safe radius. This is the ARENA/PvP strategy and
  is **kept**, not discarded.
- **Spine placement** — new: spawns distributed along the lane with the boss at
  the far end, so a map is a journey rather than an ambush.

**Per-map enemy identity.** Each lane features particular champions as its
enemies, and some maps deliberately reuse a champion across maps. With 100 maps
and 139 champions that wants an explicit assignment table (seeded, inspectable)
rather than a uniform random draw, so a map has a recognisable cast.

**A DREAD CURVE, map 1 to map 100.** The lanes get steadily more frightening
across a difficulty. This is a presentation requirement as much as a balance
one, and it has to be driven by a single number — call it `dread = index/99` —
so that every system reads the same curve instead of each being tuned by hand
in its own file:

- **Biome selection** — `Biome.IDS` ordering stops being a 16-entry cycle and
  becomes a progression, early maps drawing from the temperate ids and late
  maps from the hostile ones.
- **Palette and light** — biomes already carry `sun`, `ambient`, `fog`,
  `fog_density`, `sky_top`. Dread should push these toward lower key, colder
  ambient and thicker fog, which is a shift applied ON TOP of the biome rather
  than sixteen more biome entries.
- **Stage art** — `tools/gen_concept_art.py` composes prompts from each biome's
  `mood` string. Dread becomes an extra prompt clause so the plates darken with
  the campaign, generated per biome × dread band rather than per biome.
- **Encounter density and elite rate**, and how far the boss sits down the lane.

The risk to avoid: tuning "scary" in five places independently, so map 60 looks
menacing, plays like map 10 and is scored like map 90.

## 3. Controls

- **Drag-button movement.** *Built:* `HeroController.drive(dir, run)` steers
  continuously, wall-slides along blocked edges, and reuses the existing stun
  rule and distance-metered footsteps. The on-screen stick itself is not built.
- **Pinch to zoom**, slight. Camera is `ArpgCamera` in `Play.gd`. Needs a
  clamped range — an ARPG that can zoom out far enough to see the whole lane
  stops being an ARPG.

## 4. Abilities: movement and AoE

**Target.** Movement abilities — charge, blink — on some champions, and AoEs
with unique effects.

**The hard constraint:** every champion has **exactly four actions** (basic
attack + `ability_1..3`) because that is what the rig provides — eight clips,
no more. A charge or a blink must therefore *reuse* one of those three slots
and read through its existing clip, not ask for a fifth animation.

`Ability.gd` already models shape/range/cooldown/status. Movement abilities add
a kind it does not have yet: displacement of the caster. That is new state in
`HeroController` (a dash in progress), not just a new row in the kit table.

`MageSpells.gd` already composes per-hero spellbooks from element × delivery
form, with `FORM_DAMAGE` derived from measured values rather than set by feel —
unique AoE effects should extend that composition rather than hand-authoring
139 bespoke spells.

## 5. Presentation

- **Landscape.** *Built:* viewport is 2532×1170 and `HeroTheme` is retuned.
  Previously a 1170×2532 portrait design was being squeezed into a landscape
  screen at ~0.46 scale, which is why everything was unreadable.
- **Full UI revision** for landscape — screens still lay out as a single narrow
  column. `HeroTheme.COL_W` / `SAFE_X` exist for this; the screens do not use
  them yet.
- **Character loadout** showing the champion you are about to play, with stats.
  Worth a live 3D preview playing the idle clip — all 139 are rigged.
- **Inventory reachable from the campaign**, via a HUD button.
- **Concept-art backgrounds** for menus and stage select. **Blocked:** there is
  no image-generation tool in this environment. Options are (a) render real
  in-engine biome stills as stage art, which ties the art to the actual level,
  (b) supply externally generated art and wire it in.
