# Animation handoff — Blockle Hero

For the agent rigging and animating the 200 heroes. This is the contract the
game already codes against; meet it and the models light up with no code change
on either side.

---

## Where everything is

| What | Path |
|---|---|
| **Game project** | `/Volumes/ExtremePro/trail-of-heroes` |
| **Source models (static, 200)** | `/Volumes/ExtremePro/raid/assets/heroes/tex/*.glb` |
| Higher-poly variants (200) | `/Volumes/ExtremePro/raid/assets/heroes/shapes/*.glb` |
| **PUT ANIMATED OUTPUT HERE** | `/Volumes/ExtremePro/raid/assets/heroes/animated/<hero>.glb` |
| Reference art | `/Volumes/ExtremePro/raid/assets/heroes/qa/*.png`, `concepts/` |

The animated directory is searched **first** and falls back to `tex/` per hero,
so you can deliver incrementally — a newly animated hero works alongside the
static ones, no flag to flip. Keep the **same base filename** (`aldous.glb`
stays `aldous.glb`); the filename is the hero's identity everywhere in the game.

### The playable roster is `animated/`, and only `animated/`

139 of the 200 heroes auto-rigged; the remaining 61 did not. Those 61 **ship
hidden**: `HeroRig.animated_heroes()` is the only source of `Roster.catalogue`,
so starters, gem unlocks and crystal rolls can never hand the player a hero
with no skeleton. Paying 300 gems for a sliding T-pose is a broken product;
a slightly shorter roster is not.

They are hidden, not deleted — **drop a rigged `<hero>.glb` into `animated/`
and that hero rejoins the roster on next launch, with no code change.** The
static `tex/` mesh stays as a per-hero load fallback, so a save that already
owns one of the 61 keeps it and still plays it on the procedural stand-in.

`tools/rostersplit.gd` prints the cut's effect on every rarity tier and class,
and `tools/metatest.gd` asserts the gate holds.

Declared in `scripts/game/HeroRig.gd`:

```gdscript
const ANIMATED_DIR := "/Volumes/ExtremePro/raid/assets/heroes/animated"  # yours; the roster
const STATIC_DIR   := "/Volumes/ExtremePro/raid/assets/heroes/tex"       # load fallback only

static var search_dirs := PackedStringArray([ANIMATED_DIR, STATIC_DIR])
```

### Files you may care about

| File | Why |
|---|---|
| `scripts/game/HeroRig.gd` | **The contract.** Clip matching, scale, fallback. |
| `scripts/game/Ability.gd` | Which ability uses which clip slot. |
| `scripts/game/HeroController.gd` | When each state is triggered. |
| `scripts/game/StatusEffect.gd` | Why `walk` matters so much (see below). |
| `tools/riginfo.gd` | Inspects a `.glb` — run it on your output. |
| `scenes/Play.tscn` | Playable scene to see it in motion. |

---

## The clip contract

**Nine states.** The five in bold are what the game actually drives today:

| State | Loops | Used when |
|---|---|---|
| **`idle`** | yes | standing still |
| **`walk`** | yes | moving slowly **and whenever stunned** |
| **`run`** | yes | normal movement |
| **`attack`** | no | basic attack (slot 0) |
| **`ability_1`** | no | the damage ability |
| **`ability_2`** | no | the control ability (always a stun) |
| **`ability_3`** | no | the self ability (heal / shield / haste) |
| `hit` | no | taking damage — not wired yet, ship it if cheap |
| `death` | no | dying — not wired yet, ship it if cheap |

### Naming — matching is deliberately forgiving

Exact canonical name first, then a case-insensitive substring match after
stripping `Armature|` and `mixamo.com`. All of these resolve correctly:

```
walk            Walking          Armature|Walk        mixamo.com (if it is the walk file)
ability_1       ability1         skill_1              cast        spell
ability_3       ability3         skill_3              ultimate
attack          slash            swing                punch       strike
hit             hurt             impact               damage      flinch
```

Full alias table is `HeroRig.ALIASES`. **Prefer the canonical names** — the
aliases exist so a Mixamo export does not need renaming by hand, not as a
licence to invent names.

### Format

- **`.glb`**, single file per hero, all clips embedded.
- Must contain a `Skeleton3D` and an `AnimationPlayer` after Godot's glTF
  import. `tools/riginfo.gd` reports exactly what Godot sees.
- **Root motion: none.** The controller owns position; a clip that translates
  the root will fight it and the hero will slide or drift.
- **Scale: ~1.85 m tall.** The rig normalises from the mesh AABB anyway, so
  being off will not break anything — consistent authoring just makes the
  normalisation a no-op.
- +Y up, facing +Z. (The current static models already are.)

---

## The one thing that is unusual: `walk` is also the stun animation

A stun in this game does **not** freeze the character. It forces them out of a
run and down to a walk, slows that walk to 55%, and locks out their abilities.

So **`walk` is doing double duty** and gets seen far more than in a typical
ARPG. It should read clearly as *laboured* next to `run` — the drop from run to
walk is the player's main visual signal that something has hit them.

This is why there is no `stagger` clip in the list. Reusing `walk` was chosen
precisely so 200 models would not each need a bespoke one. If `walk` reads as a
confident stroll, the stun will not land visually, and that is the single most
valuable note in this document.

---

## Ability clips: 3, and exactly 3

Every champion has one basic attack plus **three** abilities, because that is
what the rig provides. The game is built to the rig, not the other way round —
nothing will ever ask for `ability_4`.

What the three slots mean (same grammar for every class, so the kit is
learnable across 200 heroes):

1. **`ability_1` — damage.** The one pressed on cooldown. Short, punchy.
2. **`ability_2` — control.** *Always applies a stun*, every class, every hero.
   Should read as forceful: a slam, a shove, a shockwave.
3. **`ability_3` — self.** Heal, shield or burst of speed. Inward-facing, no
   strike — the character buffs themselves.

**Classes are assigned by hero name**, so you can check any hero before
animating it:

```bash
cd /Volumes/ExtremePro/trail-of-heroes
godot --headless --path . --script tools/metatest.gd   # prints class + rarity spread
```

Fighter and Ranger share a class kit. **Mages each get their own generated
spellbook** (element × delivery form) — but they still use the same three clip
slots, so this changes nothing about what you animate. A Frost mage and a Fire
mage both play `ability_1`; only the effect differs.

### Timing

Damage resolves **at the end of the clip**, not on the button press
(`HeroController.cast_landed`). So the clip length *is* the ability's commit
window — a 2-second swing means two seconds rooted. Keep attack and ability
clips **snappy (0.4–0.9 s)**; anything slower will feel unresponsive on a
phone, and the game has no animation-cancel.

---

## How to check your own work

```bash
cd /Volumes/ExtremePro/trail-of-heroes

# 1. What does Godot actually see inside the file?
godot --headless --path . --script tools/riginfo.gd
#    Expect: skeletons=1, animplayers=1, and your clip list.
#    (Today it prints skeletons=0 animplayers=0 — that is the static set.)

# 2. Does the game resolve every state?
#    HeroRig.missing_states() returns what is still unmatched for a loaded hero.
#    Play.gd already prints it on load:
godot --path . scenes/Play.tscn
#    Look for:  hero 'x': rigged     missing clips: []

# 3. See it move. Tap to walk, 1-4 for attack and the three abilities.
godot --path . scenes/Play.tscn
```

If `riginfo` shows an `AnimationPlayer` but `missing clips` is non-empty, it is
a **naming** problem, not a rigging one — check the alias table.

---

## What is already done, so you do not rebuild it

- World generation, 16 biomes, 1.7 s per region, non-blocking.
- Character controller: tap-to-move, pathfinding, 8/8 arenas reachable.
- Combat: damage, crits, dodge, armour, status effects, 3 abilities per class.
- Progression: per-champion levels and skill points, pooled stash, 4 campaign
  difficulty tiers, gold/gems/crystals, IAP catalogue.
- `HeroRig` already drives a **procedural stand-in** (bob, lean, lunge) so the
  game is playable with the static models today. **Your clips replace it
  automatically** — `is_rigged` flips the moment an `AnimationPlayer` is found.

**Nothing above this file needs to change when you deliver.** Drop glbs into
`animated/`, and the game picks them up.
