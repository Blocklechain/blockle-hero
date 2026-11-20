# Blockle Hero

An iOS action-RPG built in Godot 4.7. Procedurally generated worlds, 139
rigged champions, per-champion progression and a pooled stash.

## What's here

| Path | What it is |
|---|---|
| `scripts/world/` | World generation — 16 biomes, two heightfields, chunked mesher |
| `scripts/game/` | Character control, combat, progression, economy |
| `scenes/Play.tscn` | The game |
| `tools/` | Headless harnesses: profiling, balance tests, screenshots |
| `assets/heroes/animated/` | The 139 rigged champions (Git LFS) |
| `docs/` | Threading notes, the animation contract, release readiness |

## Running it

Requires [Godot 4.7.2](https://godotengine.org/download) and **Git LFS**.

```bash
git lfs install
git clone https://github.com/Blocklechain/blockle-hero.git
cd blockle-hero
godot --headless --path . --import   # first run also extracts glTF textures
godot --path . scenes/Play.tscn
```

If champions are invisible, LFS content did not download — the `.glb` files
will be ~130-byte pointer files. Run `git lfs pull`.

## Checks

```bash
godot --headless --path . --script tools/bundlecheck.gd  # models load from res://
godot --headless --path . --script tools/metatest.gd     # progression + economy
godot --headless --path . --script tools/combattest.gd   # combat + balance
godot --headless --path . --script tools/profile.gd      # world-gen timing
```

`bundlecheck.gd` blanks the development asset paths first, so it fails if a
champion can only be loaded from a local authoring directory rather than from
the shipped project — the failure mode that produced a build where every
champion was missing on device.

## The animation contract

Each champion is a single `.glb` with a `Skeleton3D`, an `AnimationPlayer` and
eight clips: `idle-loop`, `walk-loop`, `run-loop`, `attack`, `ability_1..3`,
`death`. No root motion — the controller owns position.

`walk` does double duty as the stun animation: a stun does not freeze a
champion, it forces them out of a run and down to 55% speed. See
`docs/ANIMATION-HANDOFF.md`.

## Builds

`.github/workflows/ios-testflight.yml` builds and ships to TestFlight on push
to `main`. It needs `ASC_KEY_BASE64`, `ASC_KEY_ID` and `ASC_ISSUER_ID`.
