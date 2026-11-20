# Blockle Hero — region generation: making it fast enough to ship

> **STATUS: 17.3 s -> 1.7 s (10.1x), and non-blocking.** Worst main-thread frame
> during a build is now 20 ms, down from 3737 ms. What follows is the full
> record, including the phase that was implemented, measured, and thrown away —
> the measurements are the point, not the plan.
>
> | Step | Total | Note |
> |---|---:|---|
> | Baseline | 17267 ms | hand-written GDScript Perlin |
> | Phase 0: `FastNoiseLite` | 4005 ms | 141x on the noise itself |
> | Phase 1: `WorkerThreadPool` | *rejected* | 0.57x at 8 threads — **slower** |
> | Phase 2: background thread | 4044 ms | same CPU, frame no longer blocked |
> | Phase 3: algorithmic | **1715 ms** | see section 6 |


Generating one 192 m region currently takes **~17 s** (profiled on an M2 Pro at
384² cells, under some load from a concurrent render; call it 12–15 s clean).
That is fine for a screenshot harness and completely unacceptable for a game —
the player cannot wait fifteen seconds at every zone transition.

This document is the plan to fix it. It is ordered by measured payoff, which is
*not* the order you would guess.

---

## 1. What the time is actually spent on

Measured with `tools/profile.gd` (greenwood, 384² = 147,456 cells):

| Pass | Time | Share | Noise-bound? |
|---|---:|---:|---|
| `Terrain._macro` | 6718 ms | 38.9% | yes |
| `Mesher.build_chunks` | 4233 ms | 24.5% | yes (via `Shade.albedo`) |
| `Terrain._micro` | 2429 ms | 14.1% | yes |
| `Scatter` (props + cover) | 1193 ms | 6.9% | partly |
| `Terrain._carve_layout` | 1176 ms | 6.8% | no |
| `Terrain._rim` | 780 ms | 4.5% | yes |
| `Terrain._derive` | 551 ms | 3.2% | no |
| `_normalise_slope` | 86 ms | 0.5% | no |
| `_basins` | 51 ms | 0.3% | no |
| `Props.build` ×73 | 35 ms | 0.2% | no |
| `_set_water_level` | 13 ms | 0.1% | no |
| `Layout.generate` | 0.5 ms | 0.0% | no |

**Roughly 82% of the time is evaluating noise**, and essentially all of that is
my hand-written GDScript Perlin in `Rng`.

A direct comparison, 200,000 four-octave samples:

| | Time |
|---|---:|
| `Rng.fbm` (GDScript) | 2564 ms |
| `FastNoiseLite` (engine C++) | 18 ms |

**141× faster.**

### Why this reorders the plan

The obvious move is "put it on threads". But this machine has 8 performance
cores, so perfect threading is bounded at **8×** — and by Amdahl's law, applied
to a workload that is 82% noise, it cannot do better than about 4× overall once
the serial remainder is accounted for.

Replacing the noise is worth **141× on 82% of the work**, which takes the total
from ~17 s to roughly **3 s** on a single thread. *Then* threading the remainder
is worth another 4–6×.

Do them in that order. Threading first would mean parallelising code that should
not exist, and would make the subsequent rewrite harder because the concurrency
scaffolding would have to be reworked around it.

---

## 2. Phase 0 — replace the field noise with `FastNoiseLite` — **DONE**

**Predicted ~17 s → ~3 s. Measured 17.3 s → 4.0 s, a 4.3x cut.**

Implemented as `scripts/world/Field.gd`: configured `FastNoiseLite` instances
built once per region and stored on `Terrain.fields`, read by `Terrain`, `Shade`
and `Scatter`. Measured per-pass:

| Pass | Before | After | Speedup |
|---|---:|---:|---:|
| `Terrain._macro` | 6718 ms | 158 ms | **42x** |
| `Terrain._micro` | 2429 ms | 106 ms | **23x** |
| `Terrain._rim` | 780 ms | 91 ms | **8.6x** |
| `Mesher.build_chunks` | 4233 ms | 931 ms | **4.5x** |
| **TOTAL** | **17267 ms** | **4005 ms** | **4.3x** |

`Shade` gained the most per line changed: `_ground()` was calling
`Rng.seed_of()` **twice per vertex** — hashing a string 147k times — before
doing any noise work at all. Fields are now built once and read from `Terrain`.

Structure verified unchanged after the swap: 100% `nodes_connected` on every
biome, walkability 61-76%, surface-class distribution healthy. The slope
normalisation absorbing the different noise distribution is why no biome
parameters needed retuning — that adaptive pass paid for itself here.

### The profile has completely reordered — re-read before doing Phase 1

| Pass | After Phase 0 | Share |
|---|---:|---:|
| `Terrain._carve_layout` | 1150 ms | **28.7%** |
| `Mesher.build_chunks` | 931 ms | **23.2%** |
| `Scatter` | 844 ms | **21.1%** |
| `Terrain._derive` | 543 ms | 13.5% |
| `_macro` / `_micro` / `_rim` | 355 ms | 8.9% |
| everything else | 182 ms | 4.6% |

**This changes the Phase 1 plan.** `_carve_layout` was 6.8% and dismissed as
"not worth the correctness risk"; it is now the single largest cost at 28.7%,
and the three passes called out below as serial-or-awkward (`_carve_layout`,
`Scatter._place`) are together ~45% of what remains. Threading only the easy
per-cell passes now caps out around 1.6x.

So Phase 1 should start with the hard one: parallelise `_carve_layout` by giving
each node and edge a private `(sum_w, sum_wh, max_w)` buffer and merging them in
a second pass. The merge is associative — sum, sum, max — so it is order
independent and keeps determinism.

### Original rationale (kept for the record)

`Rng` currently serves two different jobs, and only one of them is hot:

- **Field sampling** — `fbm`, `ridged`, `billow`, `warp`, called once per cell
  per field. This is the 82%. **Move it to `FastNoiseLite`.**
- **Decisions** — `hash2`, `unit2`, `pick_weighted`, `range2`, used for choosing
  a prop, jittering a position, seeding a variant. A few thousand calls total,
  utterly insignificant. **Leave these in GDScript.**

Keeping the decision half in `Rng` matters: that is where the bit-avalanche
lives, and it is what stops every "random" roll coming out identical (Godot's
built-in `hash()` returns near-sequential values for similar keys). That bug
cost a full rebuild on Blockle Idle and must not be reintroduced.

`FastNoiseLite` covers every field we need natively:

| Current | Replacement |
|---|---|
| `Rng.fbm(s, x, y, oct)` | `fractal_type = FRACTAL_FBM`, `fractal_octaves = oct` |
| `Rng.ridged(...)` | `fractal_type = FRACTAL_RIDGED` |
| `Rng.warp(...)` | `domain_warp_enabled = true`, `domain_warp_amplitude` |
| `Rng.seed_of(s, "key")` | `noise.seed = Rng.seed_of(s, "key")` — keep our hashing for the seed itself |

### Things to get right

- **One configured instance per field, built once per region**, not per call.
  Creating a `FastNoiseLite` inside the cell loop would hand back most of the win.
- **One instance per worker thread.** `get_noise_2d` does not mutate observable
  state, but domain warp and fractal settings live on the object, so sharing a
  single instance across threads invites a subtle race the moment anyone adds a
  per-call parameter change. Cheap to avoid: give each worker its own copies.
- **Worlds will change.** `FastNoiseLite` produces different values than our
  Perlin, so every seed generates different terrain. That is fine now and would
  not be after launch — do this before any seed is published or saved.
- **Determinism is preserved.** `FastNoiseLite` is deterministic in its seed, and
  all our generation is already a pure function of (seed, coordinates). Nothing
  about the architecture has to change.
- **`Shade.albedo` is inside the 24.5% `build_chunks` figure** — its per-vertex
  `patch`/`dry` fields are `Rng.fbm` calls. Convert those too, or push them into
  `terrain.gdshader` as the fine mottle already was.

---

## 3. Phase 1 — parallelise with `WorkerThreadPool` — **TRIED, REJECTED**

**Expected ~3 s → under 1 s. Measured: consistently SLOWER. Reverted.**

Implemented in full and measured with `tools/bandsweep.gd`, which runs the
terrain passes at 1/2/4/8 bands inside one process:

| Bands | Total | vs serial |
|---:|---:|---:|
| 1 | 2174 ms | — |
| 2 | 2155 ms | 1.01x |
| 4 | 2936 ms | **0.74x** |
| 8 | 3832 ms | **0.57x** |

Every banded pass regressed, and the heightfield checksum was **byte-identical**
at all four settings — so the decomposition was correct and the approach was
simply wrong.

Suspecting the problem was fine-grained writes into shared arrays, coarse-grained
work was tried too: `tools/meshsweep.gd` threads `build_chunks`, where each task
builds its own local vertex buffers and its own `ArrayMesh`, sharing only
read-only terrain. That was **2.15x slower** (910 ms -> 1959 ms), reproducibly.

### Why

`PackedFloat32Array` is copy-on-write. Every indexed access from GDScript goes
through Variant machinery that touches an **atomic refcount**, so several threads
walking the same heightfield contend on one cache line and lose to a single
thread that owns it outright. Read-only sharing is enough to trigger it, which is
why even the coarse-grained version regressed.

**This is a property of GDScript, not of the algorithm.** The same row
decomposition in C++ or in a compute shader would scale. The banding structure is
therefore kept in `Terrain` with `_bands_n = 1` — it costs nothing serially and is
exactly the decomposition a GDExtension would want. Raise it only with a fresh
measurement from `tools/bandsweep.gd`.

### The original plan, kept for the record

Use `WorkerThreadPool.add_group_task()`, which splits an index range across the
pool. Split **by row**, not by cell — a 147k-element task queue costs more in
dispatch than it saves.

```gdscript
var group := WorkerThreadPool.add_group_task(
    _macro_rows, size, -1, true, "terrain.macro")
WorkerThreadPool.wait_for_group_task_completion(group)
```

### Parallelises cleanly

Each of these writes only to the cell it owns, and reads only arrays it does not
write — so there is no sharing to coordinate:

| Pass | Why it is safe |
|---|---|
| `_macro` | writes `h_macro[i]` only; reads nothing but noise |
| `_rim` | read-modify-write of its own cell |
| `_micro` | writes `h[i]`; reads `h_macro[i]`, `carve[i]` |
| `_derive` | writes `slope`/`surf`/`walk`/`ao`; reads `h`/`h_macro` — **disjoint arrays** |
| `Mesher.build_chunks` | chunks are fully independent; natural task unit |
| `Props.build` | independent per (kind, variant) |

`_micro` and `_derive` deserve a note: `_derive` reads *neighbouring* cells, which
is only safe because it never writes the arrays it reads from. The two-heightfield
split (`h_macro` for landform, `h` for rendering) happens to make this trivially
correct. Keep that property — if a future pass ever writes `h` while reading it,
this parallelisation silently breaks.

### Needs a reduction, not a plain fan-out

- **`_normalise_slope`** sums mean slope over the interior, then scales every
  cell. Do it as: parallel partial sums into a per-row array → serial combine
  (147 adds, free) → parallel scale. Two group tasks and a trivial join.

### Must stay serial — and why

- **`_carve_layout` (6.8%)** — arena and path stamps overlap, so workers would
  race on `sum_w`/`sum_wh`/`max_w`. It *could* be parallelised per-node into
  private buffers and merged, but that is ~1.2 s of work behind a real
  correctness risk. Revisit only if it becomes the bottleneck after Phase 0.
- **`_basins` (0.3%)** — the chamfer distance transform is two sequential sweeps
  where each cell depends on the one before it. Inherently serial, and at 51 ms
  it does not matter.
- **`_set_water_level` (0.1%)** — needs a global sort for the percentile.
- **`Scatter._place` (part of 6.9%)** — genuinely order-dependent: whether a prop
  is placed depends on `blocked`, which earlier placements wrote. Parallelising
  it would change results run to run and break determinism.
- **`Scatter._place_cover`** — *is* parallelisable (grid jitter, reads `blocked`
  but never writes it). Give each row its own output array and concatenate in
  index order, so the result stays deterministic.

---

## 4. Phase 2 — get it off the main thread entirely — **DONE**

Implemented as `scripts/world/WorldBuilder.gd`. Measured with
`tools/threadtest.gd`, which generates the same region twice and records the
worst frame in each:

| | Worst frame | Frames rendered during build |
|---|---:|---:|
| On the main thread | **3737 ms** | 0 |
| On a background thread | **148 ms** | **284** |

Same ~4 s of CPU either way — Phase 1 established that cannot be reduced by
threading — but it is no longer 240 consecutive dropped frames. The app stays
responsive, which on iOS also matters for not being judged hung by the watchdog.

The residual 148 ms spike is the main thread adopting 138 child nodes and
compiling shaders in one frame. If that matters, adopt the children across
several frames rather than in one `add_child` burst.

`WorldBuilder` emits `progress(stage, fraction)` for a loading bar and
`finished(root, terrain, plan)` once parented, both on the main thread.

### Original design notes

Even at 500 ms, blocking the main thread drops ~30 frames. The build runs on a
background `Thread`; the main thread shows a loading transition and stays
responsive.

### Godot 4 thread rules that actually bite

- **Resources may be created off-thread.** `ArrayMesh`, `MultiMesh`,
  `ShaderMaterial`, `NoiseTexture2D` are all fine to construct and populate in a
  worker.
- **Nodes must enter the scene tree on the main thread.** Build the
  `MeshInstance3D`/`MultiMeshInstance3D` off-thread, then
  `call_deferred("add_child", node)`. Adding from a worker is the classic source
  of intermittent crashes.
- **`MultiMesh.set_instance_transform` off-thread is fine** before the instance
  is in the tree.
- **Never touch the `SceneTree`, input, or any node's transform from a worker.**
- **Join the thread.** Keep the `Thread` handle and `wait_to_finish()` in
  `_exit_tree()`, or quitting mid-generation leaves a detached thread.

### Shape

```
main thread                      worker thread
-----------                      -------------
start loading screen  ──────▶    Layout.generate
                                 Terrain.generate   (group tasks inside)
                                 Scatter.generate
                                 Mesher.build_chunks (group tasks inside)
                                 Props.build        (group tasks inside)
                                 build nodes, not parented
      ◀────── call_deferred ──── hand over node list
add_child each node
drop loading screen
```

Nested `WorkerThreadPool` group tasks from inside a `Thread` are supported; the
pool is global and the calling thread blocks on
`wait_for_group_task_completion` while pool threads do the work.

---

## 5. Budget

| Stage | Expected | Actual |
|---|---:|---:|
| Before | — | 17.3 s |
| After Phase 0 (FastNoiseLite) | ~3 s | **4.0 s** |
| After Phase 1 (WorkerThreadPool) | ~0.5–0.8 s | — |
| After Phase 2 | 0 s blocking | — |

Phase 1's estimate assumed the easy per-cell passes dominated. They no longer
do — see the reordered table in section 2. A realistic Phase 1 target is
**~1.2 s** unless `_carve_layout` and `Scatter._place` are tackled directly.

If that is still not enough, the next levers in order are:

1. **Drop to 256² cells at 0.75 m** — 2.25× fewer cells, and the shader already
   carries all the sub-metre detail, so the visual cost is small.
2. **Generate chunks on demand** as the player approaches, rather than the whole
   region up front. The generator is a pure function of (seed, coordinates), so
   any chunk can be built independently at any time — this was designed in from
   the beginning and is the reason it is available as an option.
3. **Compute shader for the heightfield.** Biggest win, biggest complexity; only
   worth it if 1 and 2 are exhausted.

---

## 6. Order of work

1. `Rng` field functions → `FastNoiseLite`, including `Shade.albedo`. Re-run
   `tools/profile.gd` and confirm ~3 s.
2. Group-task `_macro`, `_rim`, `_micro`, `_derive`, `build_chunks`,
   `Props.build`, `_place_cover`; reduction for `_normalise_slope`.
3. Move the whole build onto a `Thread` with deferred node handover.
4. Re-profile. Only then consider resolution cuts or streaming.

Re-run `tools/profile.gd` after each step — the whole point of this document is
that the intuitive priority was the wrong one, and the only way that was visible
was by measuring.


---

## 6. Phase 3 — algorithmic wins (the ones that were actually left)

With threading ruled out, the remaining 4 s had to come down by doing less work,
not by doing it on more cores. Four changes, all measured, none costing quality:

| Pass | Before | After | Speedup | Change |
|---|---:|---:|---:|---|
| `Mesher.build_chunks` | 900 ms | 88 ms | **10.2x** | bake surface per cell |
| `Terrain._derive` | 538 ms | 99 ms | **5.4x** | direct-index interior path |
| `Scatter` | 843 ms | 218 ms | **3.9x** | path distance field |
| `Terrain._carve_layout` | 1145 ms | 396 ms | **2.9x** | inlined + coarser segments |

### What each one actually was

**`build_chunks` — a dictionary lookup per vertex.** `Shade.albedo()` called
`Biome.get_biome()` for every vertex, and `Biome.ground_at()` called it *again*,
153,664 times, plus a pile of `Color` temporaries. `Shade.bake()` now computes
vertex colour and normal once per CELL in one loop with every palette value
hoisted into a local; the mesher just reads two arrays. Baking per cell rather
than per vertex also removes the duplicated work where chunks share an edge row.

**`_derive` — twelve clamped calls per cell.** The gradient needs 4 taps and the
AO ring 8, each going through `height_at_cell()` with two `clampi` calls and an
`idx()`. A cell is "interior" if every tap is in bounds — with a 3-cell ring that
is 97% of a 384-wide region — so the interior path does plain index arithmetic
and only the border rows pay for clamping.

**`Scatter` — 15 million segment tests.** `plan.path_distance()` walked all ~420
path segments for every placement candidate. Replaced with a distance field
computed once by the chamfer transform (already written for water basins, now
generalised to `_chamfer(seeds)`). The field measures distance to the path *mask*
(laid at `width * 0.85`) where the old test used `width * 1.25`; the difference is
~2 m across the widths in use, so `PATH_CLEARANCE = 2.0` reproduces it closely.

**`_carve_layout` — overlapping stamps and boxed vector math.** Path polylines
were sampled every 2.5 m while the carve blends over up to 27 m, so adjacent
segments re-walked almost the same cells; 5 m sampling halves the stamp count
with no visible change to the curve. The inner loop also called
`Layout._seg_dist()`, allocating two `Vector2`s per cell visit — now inlined, kept
squared until the last moment, with an early-out before the `sqrt`.

### Correctness

The surface-class histogram matches the pre-optimisation run to within 0.07%.
The residual drift is a handful of cells crossing a classification threshold
because the gradient now multiplies by a reciprocal instead of dividing — a
different float rounding, not a different algorithm. `nodes_connected` remains
100% on every biome.

### What is left

| Pass | Now | Share |
|---|---:|---:|
| `_carve_layout` | 396 ms | 22.0% |
| `Shade.bake` | 349 ms | 19.4% |
| `Scatter` | 218 ms | 12.1% |
| `_macro` | 159 ms | 8.8% |
| `_path_field` | 109 ms | 6.0% |
| `_micro` / `_derive` / `_rim` / `_normalise` | 382 ms | 21.2% |

Nothing here is an obvious blunder any more — it is spread thin, which is where
micro-optimisation stops paying. The levers that remain are structural: 256²
cells at 0.75 m (2.25x less work, and the shader already carries the sub-metre
detail), chunk streaming on approach, or moving `_carve_layout` and `Shade.bake`
to a GDExtension where the row banding already in place would finally scale.
