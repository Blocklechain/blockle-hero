class_name Rng
extends RefCounted
# ------------------------------------------------------------------------------
# Deterministic noise. Every function here is a pure function of (seed, coords),
# which is what makes the whole world reproducible from a single integer: the
# client and the server can generate the same campaign region, and a PvP arena
# can be described over the wire as one number instead of a mesh.
#
# A WARNING EARNED THE HARD WAY: do NOT use Godot's built-in hash() for this.
# hash("tk1") and hash("tk2") return near-sequential integers, so every lookup
# with a similar key lands in the same bucket and the "random" choices all come
# out identical. Everything below runs an explicit bit-avalanche so neighbouring
# inputs produce completely unrelated outputs.
# ------------------------------------------------------------------------------

# 31-bit arithmetic throughout. GDScript ints are 64-bit signed, so a product of
# two 31-bit values can never overflow — the mask is what keeps it in range.
const MASK: int = 0x7FFFFFFF
const M1: int = 0x7feb352d
const M2: int = 0x846ca68b


# The avalanche itself (a 32-bit variant of Murmur's finaliser). One bit flipped
# on the way in flips about half the bits on the way out.
static func mix(h: int) -> int:
	h = (h ^ (h >> 16)) & MASK
	h = (h * M1) & MASK
	h = (h ^ (h >> 15)) & MASK
	h = (h * M2) & MASK
	h = (h ^ (h >> 16)) & MASK
	return h


static func hash1(seed: int, x: int) -> int:
	return mix(((seed * 0x27d4eb2d) ^ (x * 0x9e3779b1)) & MASK)


static func hash2(seed: int, x: int, y: int) -> int:
	var h: int = (seed * 0x27d4eb2d) & MASK
	h = mix((h ^ (x * 0x9e3779b1)) & MASK)
	return mix((h ^ (y * 0x85ebca6b)) & MASK)


static func hash3(seed: int, x: int, y: int, z: int) -> int:
	return mix((hash2(seed, x, y) ^ (z * 0xc2b2ae35)) & MASK)


# Derive a child seed from a parent seed and a name. Lets each subsystem own an
# independent noise field — "elevation", "moisture", "scatter" — without any of
# them correlating with the others.
static func seed_of(seed: int, key: String) -> int:
	var h: int = (seed * 0x27d4eb2d) & MASK
	for i in range(key.length()):
		h = mix((h ^ (key.unicode_at(i) * 0x01000193)) & MASK)
	return h


# ---- uniform scalars ---------------------------------------------------------

static func unit1(seed: int, x: int) -> float:
	return float(hash1(seed, x) % 1000003) / 1000003.0


static func unit2(seed: int, x: int, y: int) -> float:
	return float(hash2(seed, x, y) % 1000003) / 1000003.0


static func unit3(seed: int, x: int, y: int, z: int) -> float:
	return float(hash3(seed, x, y, z) % 1000003) / 1000003.0


static func range2(seed: int, x: int, y: int, lo: float, hi: float) -> float:
	return lo + unit2(seed, x, y) * (hi - lo)


# ---- gradient noise ----------------------------------------------------------

# Perlin rather than value noise: gradient noise has no axis-aligned blockiness,
# which matters a great deal once the field is driving a terrain silhouette.
static func _grad(seed: int, ix: int, iy: int) -> Vector2:
	var a: float = float(hash2(seed, ix, iy) % 65536) / 65536.0 * TAU
	return Vector2(cos(a), sin(a))


static func _fade(t: float) -> float:
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


# Returns roughly -1..1.
static func perlin(seed: int, x: float, y: float) -> float:
	var ix: int = int(floor(x))
	var iy: int = int(floor(y))
	var fx: float = x - float(ix)
	var fy: float = y - float(iy)
	var u: float = _fade(fx)
	var v: float = _fade(fy)
	var n00: float = _grad(seed, ix, iy).dot(Vector2(fx, fy))
	var n10: float = _grad(seed, ix + 1, iy).dot(Vector2(fx - 1.0, fy))
	var n01: float = _grad(seed, ix, iy + 1).dot(Vector2(fx, fy - 1.0))
	var n11: float = _grad(seed, ix + 1, iy + 1).dot(Vector2(fx - 1.0, fy - 1.0))
	return lerpf(lerpf(n00, n10, u), lerpf(n01, n11, u), v) * 1.4142


# Fractal sum. The workhorse: broad shapes from the low octaves, detail from the
# high ones. Returns about -1..1.
static func fbm(seed: int, x: float, y: float, octaves: int = 5,
		lacunarity: float = 2.0, gain: float = 0.5) -> float:
	var sum: float = 0.0
	var amp: float = 1.0
	var norm: float = 0.0
	var fx: float = x
	var fy: float = y
	for o in range(octaves):
		sum += perlin(seed + o * 7919, fx, fy) * amp
		norm += amp
		amp *= gain
		fx *= lacunarity
		fy *= lacunarity
	return sum / maxf(norm, 0.0001)


# Ridged multifractal — folds the noise at zero so the peaks come out as sharp
# creases instead of smooth domes. This is what makes mountains read as rock
# rather than as dunes. Returns 0..1.
static func ridged(seed: int, x: float, y: float, octaves: int = 5,
		lacunarity: float = 2.0, gain: float = 0.5) -> float:
	var sum: float = 0.0
	var amp: float = 1.0
	var norm: float = 0.0
	var fx: float = x
	var fy: float = y
	for o in range(octaves):
		var n: float = 1.0 - absf(perlin(seed + o * 6151, fx, fy))
		sum += n * n * amp
		norm += amp
		amp *= gain
		fx *= lacunarity
		fy *= lacunarity
	return clampf(sum / maxf(norm, 0.0001), 0.0, 1.0)


# Billowed noise — absolute value without the fold, giving soft rounded lumps.
# Good for hills, clouds and moss.
static func billow(seed: int, x: float, y: float, octaves: int = 4) -> float:
	var sum: float = 0.0
	var amp: float = 1.0
	var norm: float = 0.0
	var fx: float = x
	var fy: float = y
	for o in range(octaves):
		sum += absf(perlin(seed + o * 5333, fx, fy)) * amp
		norm += amp
		amp *= 0.5
		fx *= 2.0
		fy *= 2.0
	return clampf(sum / maxf(norm, 0.0001), 0.0, 1.0)


# Domain warp: push the sample point around with another noise field before
# reading. Costs two extra fbm evaluations and buys the single biggest quality
# jump available — straight fbm looks like a weather map, warped fbm looks like
# erosion carved it.
static func warp(seed: int, p: Vector2, strength: float = 1.0,
		freq: float = 0.5) -> Vector2:
	var sx: int = seed_of(seed, "warp.x")
	var sy: int = seed_of(seed, "warp.y")
	return p + Vector2(
		fbm(sx, p.x * freq, p.y * freq, 3),
		fbm(sy, p.x * freq, p.y * freq, 3)
	) * strength


# ---- picking -----------------------------------------------------------------

static func pick(seed: int, x: int, y: int, options: Array) -> Variant:
	if options.is_empty():
		return null
	return options[hash2(seed, x, y) % options.size()]


# Weighted pick. `weights` is parallel to `options`; zero-weight entries can
# never be chosen, which is how biome tables gate content by region.
static func pick_weighted(seed: int, x: int, y: int, options: Array,
		weights: Array) -> Variant:
	var total: float = 0.0
	for w in weights:
		total += maxf(float(w), 0.0)
	if total <= 0.0 or options.is_empty():
		return null
	var r: float = unit2(seed, x, y) * total
	for i in range(options.size()):
		r -= maxf(float(weights[i]), 0.0)
		if r <= 0.0:
			return options[i]
	return options[options.size() - 1]


# ---- shaping helpers ---------------------------------------------------------

static func smoothstep01(a: float, b: float, t: float) -> float:
	if is_equal_approx(a, b):
		return 0.0 if t < a else 1.0
	var x: float = clampf((t - a) / (b - a), 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


# Terrace a continuous field into `steps` plateaus, keeping `blend` of the
# original slope so the result is stepped rather than staircased.
static func terrace(v: float, steps: float, blend: float = 0.35) -> float:
	var s: float = floor(v * steps) / steps
	return lerpf(s, v, clampf(blend, 0.0, 1.0))


# Superellipse falloff — a squarish-to-round mask. `n` near 2 gives a circle,
# higher gives a rounded square. Used to bound regions without a hard edge.
static func superellipse(p: Vector2, radius: Vector2, n: float = 2.0) -> float:
	var ax: float = pow(absf(p.x) / maxf(radius.x, 0.0001), n)
	var ay: float = pow(absf(p.y) / maxf(radius.y, 0.0001), n)
	return pow(ax + ay, 1.0 / n)
