class_name Field
extends RefCounted
# ------------------------------------------------------------------------------
# A configured noise field, sampled once per cell.
#
# This replaces the hand-written Perlin in `Rng` for everything that is evaluated
# PER CELL. The measurement that forced it (tools/profile.gd, 200k four-octave
# samples):
#
#     Rng.fbm      (GDScript)   2564 ms
#     FastNoiseLite (engine C++)   18 ms      -> 141x
#
# About 82% of region generation was noise evaluation, so this one swap is worth
# more than putting the whole generator on eight threads. See docs/THREADING.md.
#
# WHAT STAYS IN `Rng`: the decision half — `hash2`, `unit2`, `range2`,
# `pick_weighted`, `seed_of`. Those run a few thousand times, not a few million,
# and they carry the bit-avalanche that stops every "random" roll coming out
# identical (Godot's built-in `hash()` returns near-sequential values for similar
# keys). That distinction is load-bearing; do not "finish the job" by moving them.
#
# THREADING: one FastNoiseLite instance per field per thread. `get_noise_2d` does
# not mutate anything observable, but octaves, gain and warp live on the object,
# so a shared instance is one stray setter away from a race. Use `duplicate()`
# when the parallel pass lands.
# ------------------------------------------------------------------------------

var _n: FastNoiseLite


# Fractal Brownian motion. Returns roughly -1..1, matching what Rng.fbm did, so
# call sites that lift it into 0..1 themselves keep working unchanged.
static func fbm(seed: int, freq: float, octaves: int = 4,
		gain: float = 0.5) -> Field:
	var f := Field.new()
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = seed
	# Our old Perlin had a lattice spacing of one world unit and call sites
	# pre-multiplied coordinates by `freq`. FastNoiseLite scales internally
	# instead, so the frequency goes here and sampling uses raw world metres.
	n.frequency = freq
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	n.fractal_gain = gain
	f._n = n
	return f


# Ridged multifractal — folds at zero so peaks come out as sharp creases rather
# than smooth domes. Returns 0..1, matching the old Rng.ridged contract.
static func ridged(seed: int, freq: float, octaves: int = 4,
		gain: float = 0.5) -> Field:
	var f := Field.new()
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = seed
	n.frequency = freq
	n.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	n.fractal_octaves = octaves
	n.fractal_gain = gain
	f._n = n
	return f


# Raw sample, -1..1 for fbm fields.
func at(x: float, y: float) -> float:
	return _n.get_noise_2d(x, y)


# Sample lifted into 0..1. Ridged fields use this to honour their old contract.
func at01(x: float, y: float) -> float:
	return _n.get_noise_2d(x, y) * 0.5 + 0.5


func sample(p: Vector2) -> float:
	return _n.get_noise_2d(p.x, p.y)


# An independent copy, for handing a field to a worker thread.
func clone() -> Field:
	var f := Field.new()
	f._n = _n.duplicate() as FastNoiseLite
	return f
