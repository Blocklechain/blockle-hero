class_name Terrain
extends RefCounted
# ------------------------------------------------------------------------------
# The heightfield, and everything derived from it.
#
# Order of operations matters, so it is worth stating plainly:
#
#   1.  MACRO      warped fbm/ridged noise — the landform the player walks
#   1b. NORMALISE  rescale so the mean slope hits a target (see below)
#   1c. WATER      decide the water line from the INTERIOR, before any rim
#   2.  RIM        lift the region edge into an impassable wall, so the play
#                  area is bounded by terrain, not an invisible collider
#   3.  CARVE      flatten arenas and cut paths, by STAMPING only the cells each
#                  one covers (testing every cell against every carve point is
#                  far too slow in GDScript at 147k cells)
#   4.  TERRACE    optional plateau stepping, per biome
#   5.  MICRO      fine surface detail, added to the rendered height ONLY
#   6.  DERIVE     slope, surface type, walkability, ambient occlusion
#
# TWO HEIGHTFIELDS. `h_macro` is the landform; `h` is h_macro plus fine detail.
# Walkability and slope are computed from h_macro, while the mesh and the
# lighting use h. Without the split, the detail needed to make ground look like
# ground registers as slope and shreds walkability — and normalising it away
# instead leaves terrain as flat as a billiard table. Both failures happened on
# the first two passes.
# ------------------------------------------------------------------------------

# Steeper than this and you cannot walk it. Rise over run, so 0.78 is about 38
# degrees: generous enough for rolling hills, tight enough that cliffs block.
const MAX_WALK_SLOPE: float = 0.78

# Water deeper than this blocks movement; shallower is waded.
const WADE_DEPTH: float = 0.45

# Arena floors are held at least this far above the water line.
const DRY_MARGIN: float = 1.4

# Surface classes, written into `surf` for the mesher and the footstep system.
enum Surf { GROUND, ROCK, SAND, PATH, WATER, FLOOR }

var size: int = 192                  # cells per side
var cell: float = 1.0                # metres per cell
var biome_id: String = "greenwood"
var seed: int = 0

var h: PackedFloat32Array = PackedFloat32Array()          # rendered height, m
var h_macro: PackedFloat32Array = PackedFloat32Array()    # landform height, m
var ao: PackedFloat32Array = PackedFloat32Array()         # 0 dark .. 1 open
var slope: PackedFloat32Array = PackedFloat32Array()
var surf: PackedByteArray = PackedByteArray()
var walk: PackedByteArray = PackedByteArray()             # 1 = walkable
var carve: PackedFloat32Array = PackedFloat32Array()      # 0 natural .. 1 carved

# Noise fields, configured once per region and shared by every pass (and by
# Shade and Scatter). Building these per call — or worse, re-deriving their seeds
# with Rng.seed_of() inside a per-vertex loop, which is what Shade used to do —
# hands back most of the speedup.
var fields: Dictionary = {}

# One clone of every field per worker band. `FastNoiseLite.get_noise_2d` does not
# mutate anything observable, but octaves, gain and warp all live on the object,
# so a shared instance is one stray setter away from a race that would be
# miserable to track down. Clones cost 11 fields x 8 bands = 88 small objects.
var _band_fields: Array = []

# Scratch for the carve pass. `_stamps` is read-only once built; each band writes
# only cells inside its own row range, so these need no locking.
# Baked per-cell vertex colour (rgb = albedo x AO, a = rockiness) and normal,
# filled by Shade.bake(). The mesher reads these directly.
var vcol: PackedColorArray = PackedColorArray()
var vnrm: PackedVector3Array = PackedVector3Array()

# Metres to the nearest path cell, filled by _path_field(). Read by Scatter.
var path_dist: PackedFloat32Array = PackedFloat32Array()

var _stamps: Array = []
var _sum_w: PackedFloat32Array = PackedFloat32Array()
var _sum_wh: PackedFloat32Array = PackedFloat32Array()
var _max_w: PackedFloat32Array = PackedFloat32Array()
var _bands_n: int = 1

var water_h: float = -100000.0
var h_min: float = 0.0
var h_max: float = 1.0
var layout: Layout = null


# ------------------------------------------------------------------------------

static func generate(world_seed: int, biome: String, cells: int,
		cell_size: float, plan: Layout) -> Terrain:
	var t := Terrain.new()
	t.seed = Rng.seed_of(world_seed, "terrain")
	t.biome_id = biome
	t.size = cells
	t.cell = cell_size
	t.layout = plan

	var n: int = cells * cells
	t.h.resize(n)
	t.h_macro.resize(n)
	t.ao.resize(n)
	t.slope.resize(n)
	t.surf.resize(n)
	t.walk.resize(n)
	t.carve.resize(n)

	# ONE BAND. Not a placeholder — a measured decision.
	#
	# tools/bandsweep.gd runs the terrain passes at 1/2/4/8 bands in one process.
	# Results were 1.01x at 2 bands, 0.74x at 4, and 0.57x at 8: more threads,
	# consistently SLOWER, with byte-identical output. tools/meshsweep.gd found
	# the same for coarse-grained chunk meshing (2.15x slower threaded).
	#
	# The cause is GDScript, not the algorithm. `PackedFloat32Array` is
	# copy-on-write, so every indexed access goes through Variant machinery that
	# touches an atomic refcount; eight threads hammering one cache line lose to
	# a single thread that owns it outright.
	#
	# The banding structure below is kept because it is correct and costs nothing
	# at one band — if these loops ever move to a GDExtension or a compute
	# shader, the row split is exactly the decomposition they need. Raise this
	# only with a fresh measurement. See docs/THREADING.md.
	t._bands_n = 1
	t._build_fields()
	t._macro()
	t._normalise_slope()
	t._set_water_level()
	t._rim()
	t._carve_layout()
	t._path_field()
	t._basins()
	t._terrace()
	t._micro()
	t._derive()
	Shade.bake(t)
	return t


func idx(x: int, y: int) -> int:
	return y * size + x


# World-space position of a cell centre, with the region centred on the origin.
func pos_of(x: int, y: int) -> Vector2:
	var half: float = float(size) * cell * 0.5
	return Vector2(float(x) * cell - half, float(y) * cell - half)


func height_at_cell(x: int, y: int) -> float:
	return h[idx(clampi(x, 0, size - 1), clampi(y, 0, size - 1))]


func macro_at_cell(x: int, y: int) -> float:
	return h_macro[idx(clampi(x, 0, size - 1), clampi(y, 0, size - 1))]


# Bilinear height sample in world space — what the character controller and the
# prop placer both use, so props sit exactly on the surface the player walks.
func height_at(p: Vector2) -> float:
	var half: float = float(size) * cell * 0.5
	var fx: float = (p.x + half) / cell
	var fy: float = (p.y + half) / cell
	var x0: int = int(floor(fx))
	var y0: int = int(floor(fy))
	var tx: float = fx - float(x0)
	var ty: float = fy - float(y0)
	return lerpf(
		lerpf(height_at_cell(x0, y0), height_at_cell(x0 + 1, y0), tx),
		lerpf(height_at_cell(x0, y0 + 1), height_at_cell(x0 + 1, y0 + 1), tx), ty)


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < size and y < size


func is_walkable(x: int, y: int) -> bool:
	return in_bounds(x, y) and walk[idx(x, y)] == 1


# ------------------------------------------------------------------------------
# 0. Noise fields
# ------------------------------------------------------------------------------

# Split `size` rows across the worker bands. Band `b` owns [row_lo(b), row_hi(b)).
# Integer division covers every row even when size is not a multiple of the band
# count, which matters because a dropped row is a seam you only notice later.
func _row_lo(band: int) -> int:
	return band * size / _bands_n


func _row_hi(band: int) -> int:
	return (band + 1) * size / _bands_n


# Run one method across the bands and block until every band is done.
func _run_bands(method: String) -> void:
	if _bands_n <= 1:
		call(method, 0)
		return
	var gid: int = WorkerThreadPool.add_group_task(
		Callable(self, method), _bands_n, _bands_n, true, method)
	WorkerThreadPool.wait_for_group_task_completion(gid)


func _build_fields() -> void:
	var b: Dictionary = Biome.get_biome(biome_id)
	var freq: float = float(b["freq"])
	var rough: float = float(b["roughness"])

	fields = {
		# landform
		"elev_lo": Field.fbm(Rng.seed_of(seed, "elev.lo"), freq, 4, rough),
		"elev_hi": Field.ridged(Rng.seed_of(seed, "elev.hi"), freq, 4, rough),
		"warp_x": Field.fbm(Rng.seed_of(seed, "elev.warp"), freq * 0.5, 3),
		"warp_y": Field.fbm(Rng.seed_of(seed, "elev.warp2"), freq * 0.5, 3),
		"rim": Field.fbm(Rng.seed_of(seed, "rim"), 0.03, 3),
		# surface detail
		"micro_a": Field.fbm(Rng.seed_of(seed, "micro.a"), 0.09, 3),
		"micro_b": Field.fbm(Rng.seed_of(seed, "micro.b"), 0.42, 2),
		# colour, read by Shade
		"patch": Field.fbm(Rng.seed_of(seed, "patch"), 0.012, 3),
		"dry": Field.fbm(Rng.seed_of(seed, "dry"), 0.045, 3),
		"strata": Field.fbm(Rng.seed_of(seed, "strata"), 0.06, 2),
		"grain": Field.fbm(Rng.seed_of(seed, "grain"), 0.55, 2),
		"path": Field.fbm(Rng.seed_of(seed, "path"), 0.35, 2),
	}

	_band_fields.clear()
	for b2 in range(_bands_n):
		var copy: Dictionary = {}
		for k in fields.keys():
			copy[k] = (fields[k] as Field).clone()
		_band_fields.append(copy)


# ------------------------------------------------------------------------------
# 1. Macro landform
# ------------------------------------------------------------------------------

func _macro() -> void:
	_run_bands("_macro_band")


func _macro_band(band: int) -> void:
	var b: Dictionary = Biome.get_biome(biome_id)
	var amp: float = float(b["amplitude"])
	var freq: float = float(b["freq"])
	var ridge_w: float = float(b["ridge"])
	var rough: float = float(b["roughness"])
	var warp_s: float = float(b["warp"])

	var bf: Dictionary = _band_fields[band]
	var f_lo: Field = bf["elev_lo"]
	var f_hi: Field = bf["elev_hi"]
	var f_wx: Field = bf["warp_x"]
	var f_wy: Field = bf["warp_y"]

	for y in range(_row_lo(band), _row_hi(band)):
		for x in range(size):
			var p: Vector2 = pos_of(x, y)

			# Domain warp before sampling. Two extra noise reads, and the single
			# largest quality gain available: unwarped fbm looks like a weather
			# map, warped fbm looks eroded.
			var q: Vector2 = p
			if warp_s > 0.001:
				q = p + Vector2(f_wx.at(p.x, p.y), f_wy.at(p.x, p.y)) \
					* (warp_s / maxf(freq, 0.0001)) * 0.06

			# Four octaves, not five. The macro field only has to carry landform;
			# surface detail comes from _micro() where it cannot cost walkability.
			var smooth: float = f_lo.at(q.x, q.y)
			var crags: float = f_hi.at01(q.x, q.y)

			# fbm is -1..1 and ridged is 0..1, so lift fbm before blending or the
			# ridged weight silently raises the whole landmass as well.
			var v: float = lerpf((smooth + 1.0) * 0.5, crags, ridge_w)
			h_macro[idx(x, y)] = v * amp


# ------------------------------------------------------------------------------
# 1b. Slope normalisation — the fix that makes any of this playable
# ------------------------------------------------------------------------------

func _normalise_slope() -> void:
	# An absolute `amplitude` in metres cannot survive fractal summation. With
	# lacunarity 2 and gain 0.5 each octave contributes the SAME gradient as the
	# one before (amplitude halves, frequency doubles), so the octaves multiply
	# steepness. Authoring heights in metres therefore gave wildly different
	# slopes per biome and the first render came out 4-20% walkable: a cliff
	# field, not a level.
	#
	# So measure the slope the field actually produced and rescale to a target.
	# `amplitude` stops being a metre count and becomes what it was always meant
	# to be — a relative drama dial.
	var b: Dictionary = Biome.get_biome(biome_id)
	var amp: float = float(b["amplitude"])

	# Dramatic biomes get steeper ground, but every biome stays under the
	# walkable ceiling ON AVERAGE, so terrain is traversable by default and a
	# cliff is a deliberate local event rather than the baseline.
	var target: float = clampf(0.12 + (amp / 30.0) * 0.26, 0.12, 0.40)

	var lo: int = size / 8
	var hi: int = size - lo
	var total: float = 0.0
	var taps: int = 0
	for y in range(lo, hi):
		for x in range(lo, hi):
			var dx: float = (macro_at_cell(x + 1, y) - macro_at_cell(x - 1, y)) \
				/ (2.0 * cell)
			var dy: float = (macro_at_cell(x, y + 1) - macro_at_cell(x, y - 1)) \
				/ (2.0 * cell)
			total += sqrt(dx * dx + dy * dy)
			taps += 1
	var mean: float = total / float(maxi(taps, 1))
	if mean < 0.00001:
		return

	var k: float = target / mean
	for i in range(h_macro.size()):
		h_macro[i] *= k


# ------------------------------------------------------------------------------
# 1c. Water level, from the interior, BEFORE the rim is added
# ------------------------------------------------------------------------------

func _set_water_level() -> void:
	# The first version computed this after the rim and flooded every map: the
	# rim raised h_max so far that lerp(h_min, h_max, 0.24) sat above the whole
	# play area. Water has to be decided from the ground the player walks on.
	var wl: float = float(Biome.field(biome_id, "water_level", -1.0))
	if wl < 0.0:
		water_h = -100000.0
		return

	var lo: int = size / 8
	var hi: int = size - lo
	var vals := PackedFloat32Array()
	for y in range(lo, hi):
		for x in range(lo, hi):
			vals.append(h_macro[idx(x, y)])
	vals.sort()

	# A percentile rather than a lerp between extremes: water_level 0.24 now
	# means "cover the lowest 24% of the interior", which is what the number
	# reads as, and is robust to one freak peak skewing the range.
	water_h = vals[clampi(int(float(vals.size()) * wl), 0, vals.size() - 1)]


# ------------------------------------------------------------------------------
# 2. Boundary rim
# ------------------------------------------------------------------------------

func _rim() -> void:
	# Lift the outer band into high ground. The player should never meet an
	# invisible wall — they should meet a mountain, a cliff or an ocean, which
	# the walkability pass then marks unwalkable for honest reasons.
	#
	# Height here is metres above the local surface, NOT a multiple of
	# amplitude: 20 m of rise is already far steeper than anything climbable,
	# and scaling by amplitude built absurd 90 m walls in dramatic biomes that
	# swallowed the playable area.
	_run_bands("_rim_band")


func _rim_band(band: int) -> void:
	const RIM_RISE: float = 20.0
	var half: float = float(size) * cell * 0.5
	var inner: float = 0.78
	var f_rim: Field = (_band_fields[band] as Dictionary)["rim"]

	for y in range(_row_lo(band), _row_hi(band)):
		for x in range(size):
			var p: Vector2 = pos_of(x, y)
			# A superellipse rather than a circle: keeps the usable area close
			# to the full square instead of wasting the corners.
			var d: float = Rng.superellipse(p, Vector2(half, half), 3.2)
			if d <= inner:
				continue
			var t: float = Rng.smoothstep01(inner, 1.04, d)
			# Break the rim up so it does not read as a perfectly even bowl.
			var rough: float = f_rim.at(p.x, p.y) * 0.30
			h_macro[idx(x, y)] += (t + rough * t) * RIM_RISE


# ------------------------------------------------------------------------------
# 3. Carve the layout
# ------------------------------------------------------------------------------

func _carve_layout() -> void:
	if layout == null:
		return

	# INVERTED LOOP. The original stamped each arena and path segment into
	# whatever cells it covered, which is output-sensitive and fast serially but
	# cannot be threaded: two stamps that overlap would write the same
	# accumulator from two workers.
	#
	# Rewritten so each worker owns a BAND OF ROWS and pulls from every stamp
	# that reaches into it. Identical arithmetic, identical results, but every
	# write now targets a cell only one thread can touch — the races are gone by
	# construction rather than by locking. This was the single largest remaining
	# cost after the noise swap (28.7%).
	_stamps = _build_stamps()
	if _stamps.is_empty():
		return

	var n: int = size * size
	_sum_w = PackedFloat32Array()
	_sum_wh = PackedFloat32Array()
	_max_w = PackedFloat32Array()
	_sum_w.resize(n)
	_sum_wh.resize(n)
	_max_w.resize(n)

	_run_bands("_carve_band")

	for i in range(n):
		var w: float = _max_w[i]
		if w <= 0.0005:
			continue
		var target: float = _sum_wh[i] / maxf(_sum_w[i], 0.0001)
		# Not a full flatten — keeping a little original slope stops arenas
		# reading as poured concrete.
		h_macro[i] = lerpf(h_macro[i], target, clampf(w, 0.0, 1.0) * 0.92)
		carve[i] = clampf(w, 0.0, 1.0)

	# Release the scratch buffers; a region holds three of these at 147k floats.
	_stamps = []
	_sum_w = PackedFloat32Array()
	_sum_wh = PackedFloat32Array()
	_max_w = PackedFloat32Array()


# Flatten the layout into a list of stamps, each with the row span it touches so
# a band can skip the ones that cannot reach it.
#   kind 0 = arena disc   {cx, cz, r, reach, target}
#   kind 1 = path segment {ax, az, bx, bz, width, reach, target}
func _build_stamps() -> Array:
	var out: Array = []
	var half: float = float(size) * cell * 0.5

	var relief: float = _interior_relief()
	var node_h: Array[float] = []
	for nd in layout.nodes:
		var base: float = _macro_at(nd["pos"] as Vector2) \
			+ float(nd["elev"]) * relief * 0.26
		# AND THEN KEEP IT DRY. Negative elevation bias was sinking arena floors
		# below the water line, so the first render's "lakes" were in fact the
		# arenas — the player would have spawned underwater.
		if water_h > -99999.0:
			base = maxf(base, water_h + DRY_MARGIN)
		node_h.append(base)

	for i in range(layout.nodes.size()):
		var nd: Dictionary = layout.nodes[i]
		var p: Vector2 = nd["pos"]
		var r: float = float(nd["radius"])
		# A wide blend skirt, not a tight one. The flat floor ends at `r`, but
		# the carve has to fade back into natural ground over a long enough run
		# that the join is a slope rather than a step — a narrow skirt ringed
		# every arena with an unclimbable lip and marooned it from its corridors.
		var reach: float = r * 2.4
		out.append({
			"kind": 0, "cx": p.x, "cz": p.y, "r": r, "reach": reach,
			"target": node_h[i],
			"y0": clampi(int((p.y - reach + half) / cell) - 1, 0, size - 1),
			"y1": clampi(int((p.y + reach + half) / cell) + 1, 0, size - 1),
			"x0": clampi(int((p.x - reach + half) / cell) - 1, 0, size - 1),
			"x1": clampi(int((p.x + reach + half) / cell) + 1, 0, size - 1),
		})

	for e in layout.edges:
		var pts: PackedVector2Array = e["pts"]
		if pts.size() < 2:
			continue
		var width: float = float(e["width"])
		# Same reasoning as the arena skirt: the walkable path is `width`, but
		# the carve needs a much wider fade or the path becomes a trench with
		# vertical sides wherever it crosses sloping ground.
		var reach2: float = width * 3.6
		var ha: float = node_h[int(e["a"])]
		var hb: float = node_h[int(e["b"])]
		var segs: int = pts.size() - 1
		for sg in range(segs):
			var a: Vector2 = pts[sg]
			var bb: Vector2 = pts[sg + 1]
			# Height along the path interpolates between the two arena floors,
			# so a corridor between a high room and a low one becomes a ramp.
			out.append({
				"kind": 1, "ax": a.x, "az": a.y, "bx": bb.x, "bz": bb.y,
				"width": width, "reach": reach2,
				"target": lerpf(ha, hb, (float(sg) + 0.5) / float(segs)),
				"y0": clampi(int((minf(a.y, bb.y) - reach2 + half) / cell) - 1, 0, size - 1),
				"y1": clampi(int((maxf(a.y, bb.y) + reach2 + half) / cell) + 1, 0, size - 1),
				"x0": clampi(int((minf(a.x, bb.x) - reach2 + half) / cell) - 1, 0, size - 1),
				"x1": clampi(int((maxf(a.x, bb.x) + reach2 + half) / cell) + 1, 0, size - 1),
			})

	return out


func _carve_band(band: int) -> void:
	var lo: int = _row_lo(band)
	var hi: int = _row_hi(band)

	# Pre-filter to the stamps that actually reach this band. Roughly 430 stamps
	# per region against 8 bands, so this is a few thousand comparisons total and
	# saves every row re-testing the whole list.
	var mine: Array = []
	for st in _stamps:
		if int(st["y1"]) >= lo and int(st["y0"]) < hi:
			mine.append(st)
	if mine.is_empty():
		return

	for st in mine:
		var y0: int = maxi(int(st["y0"]), lo)
		var y1: int = mini(int(st["y1"]), hi - 1)
		var x0: int = int(st["x0"])
		var x1: int = int(st["x1"])
		var reach: float = float(st["reach"])
		var target: float = float(st["target"])

		if int(st["kind"]) == 0:
			var cx: float = float(st["cx"])
			var cz: float = float(st["cz"])
			var inner: float = float(st["r"]) * 0.55
			var reach2: float = reach * reach
			var half2: float = float(size) * cell * 0.5
			for y in range(y0, y1 + 1):
				var pz: float = float(y) * cell - half2
				var dz: float = pz - cz
				var dz2: float = dz * dz
				for x in range(x0, x1 + 1):
					var dx: float = (float(x) * cell - half2) - cx
					var d2: float = dx * dx + dz2
					if d2 >= reach2:
						continue          # outside the skirt; skip the sqrt
					var w: float = Rng.smoothstep01(reach, inner, sqrt(d2))
					if w <= 0.0:
						continue
					var i: int = idx(x, y)
					_sum_w[i] += w
					_sum_wh[i] += w * target
					_max_w[i] = maxf(_max_w[i], w)
		else:
			var ax: float = float(st["ax"])
			var az: float = float(st["az"])
			var abx: float = float(st["bx"]) - ax
			var abz: float = float(st["bz"]) - az
			var l2: float = abx * abx + abz * abz
			var inv_l2: float = 1.0 / l2 if l2 > 0.000001 else 0.0
			var width: float = float(st["width"])
			var inner2: float = width * 0.6
			var mark: float = width * 0.85
			var reach2: float = reach * reach
			var half2: float = float(size) * cell * 0.5
			for y in range(y0, y1 + 1):
				var pz: float = float(y) * cell - half2
				for x in range(x0, x1 + 1):
					var px: float = float(x) * cell - half2
					# Segment distance, inlined and kept squared until the last
					# moment. Calling out to Layout._seg_dist() allocated two
					# Vector2s and made a static call for every one of several
					# million cell visits.
					var rx: float = px - ax
					var rz: float = pz - az
					var tt: float = clampf((rx * abx + rz * abz) * inv_l2, 0.0, 1.0)
					var ex: float = rx - abx * tt
					var ez: float = rz - abz * tt
					var d2: float = ex * ex + ez * ez
					if d2 >= reach2:
						continue          # outside the skirt; skip the sqrt
					var d: float = sqrt(d2)
					var w: float = Rng.smoothstep01(reach, inner2, d)
					if w <= 0.0:
						continue
					var i: int = idx(x, y)
					_sum_w[i] += w
					_sum_wh[i] += w * target
					_max_w[i] = maxf(_max_w[i], w)
					if d < mark:
						surf[i] = Surf.PATH


func _macro_at(p: Vector2) -> float:
	var half: float = float(size) * cell * 0.5
	var fx: float = (p.x + half) / cell
	var fy: float = (p.y + half) / cell
	var x0: int = int(floor(fx))
	var y0: int = int(floor(fy))
	var tx: float = fx - float(x0)
	var ty: float = fy - float(y0)
	return lerpf(
		lerpf(macro_at_cell(x0, y0), macro_at_cell(x0 + 1, y0), tx),
		lerpf(macro_at_cell(x0, y0 + 1), macro_at_cell(x0 + 1, y0 + 1), tx), ty)


# ------------------------------------------------------------------------------
# 3b. Water basins
# ------------------------------------------------------------------------------

# Two-pass chamfer distance transform: for every cell, the distance IN CELLS to
# the nearest cell where `seeds` is 1. Linear in the number of cells, which is
# what makes it cheap enough to use as a general tool rather than a special case.
#
# Written once and used twice — water basins need distance-to-shore, and the
# scatter pass needs distance-to-path. Computing the latter by looping every
# path segment per candidate was costing 15M segment tests per region.
func _chamfer(seeds: PackedByteArray) -> PackedFloat32Array:
	const BIG: float = 1.0e9
	var n: int = size * size
	var dist := PackedFloat32Array()
	dist.resize(n)
	for i in range(n):
		dist[i] = 0.0 if seeds[i] == 1 else BIG

	var diag: float = sqrt(2.0)

	for y in range(size):
		for x in range(size):
			var i: int = idx(x, y)
			if dist[i] == 0.0:
				continue
			var best: float = dist[i]
			if x > 0:
				best = minf(best, dist[i - 1] + 1.0)
			if y > 0:
				best = minf(best, dist[i - size] + 1.0)
			if x > 0 and y > 0:
				best = minf(best, dist[i - size - 1] + diag)
			if x < size - 1 and y > 0:
				best = minf(best, dist[i - size + 1] + diag)
			dist[i] = best

	for y in range(size - 1, -1, -1):
		for x in range(size - 1, -1, -1):
			var i: int = idx(x, y)
			if dist[i] == 0.0:
				continue
			var best: float = dist[i]
			if x < size - 1:
				best = minf(best, dist[i + 1] + 1.0)
			if y < size - 1:
				best = minf(best, dist[i + size] + 1.0)
			if x < size - 1 and y < size - 1:
				best = minf(best, dist[i + size + 1] + diag)
			if x > 0 and y < size - 1:
				best = minf(best, dist[i + size - 1] + diag)
			dist[i] = best

	return dist


# Metres from every cell to the nearest carved path. Replaces Layout
# .path_distance(), which walked all ~420 path segments per query.
func _path_field() -> void:
	var seeds := PackedByteArray()
	seeds.resize(size * size)
	var any: bool = false
	for i in range(seeds.size()):
		if surf[i] == Surf.PATH:
			seeds[i] = 1
			any = true
	if not any:
		path_dist = PackedFloat32Array()
		path_dist.resize(size * size)
		path_dist.fill(1.0e9)
		return
	path_dist = _chamfer(seeds)
	for i in range(path_dist.size()):
		path_dist[i] *= cell


func _basins() -> void:
	# Give every body of water a real basin, with depth driven by DISTANCE FROM
	# SHORE rather than by the puddle depth that happened to be there.
	#
	# An earlier attempt just scaled existing depth (x2.6). That only helps water
	# that was already deep: a 10 cm puddle became a 26 cm puddle, so most
	# biomes still had no depth gradient to shade and their lakes rendered as
	# flat sheets of shoreline foam. Distance-to-shore is the property that
	# actually describes a lake bed.
	if water_h <= -99999.0:
		return

	const SLOPE: float = 0.42        # metres of depth per metre from shore
	const MAX_DEPTH: float = 7.0

	var seeds := PackedByteArray()
	seeds.resize(size * size)
	for i in range(seeds.size()):
		seeds[i] = 0 if h_macro[i] < water_h else 1
	var dist: PackedFloat32Array = _chamfer(seeds)

	for i in range(dist.size()):
		if dist[i] <= 0.0:
			continue
		# Smoothstep rather than a straight ramp, so the bed eases away from the
		# bank instead of meeting it at a hard crease.
		var metres: float = dist[i] * cell
		var target: float = minf(metres * SLOPE, MAX_DEPTH)
		target *= Rng.smoothstep01(0.0, 2.5, metres) * 0.35 + 0.65
		var now: float = water_h - h_macro[i]
		h_macro[i] = water_h - maxf(now, target)


# ------------------------------------------------------------------------------
# 4. Terrace
# ------------------------------------------------------------------------------

func _terrace() -> void:
	var terr: float = float(Biome.field(biome_id, "terrace", 0.0))
	if terr <= 0.001:
		return
	var relief: float = _interior_relief()
	var steps: float = lerpf(14.0, 5.0, clampf(terr, 0.0, 1.0))
	for i in range(h_macro.size()):
		# Carved ground is left alone: terracing an arena floor would put a step
		# through the middle of a fight.
		var v: float = h_macro[i] / maxf(relief, 0.0001)
		var stepped: float = Rng.terrace(v, steps, 0.30) * relief
		h_macro[i] = lerpf(stepped, h_macro[i], carve[i])


# ------------------------------------------------------------------------------
# 5. Micro detail — rendered height only
# ------------------------------------------------------------------------------

func _micro() -> void:
	# Fine surface relief at a scale the walkability pass never sees. This is
	# what gives the ground something to catch light on; without it the
	# normalised macro field renders as a smooth painted sheet.
	#
	# Amplitude is in centimetres-to-tens-of-centimetres on purpose. Big enough
	# to shade, far too small to climb or trip on.
	_run_bands("_micro_band")
	# The min/max scan stays serial: it is a reduction over the whole field and
	# takes under a millisecond.
	h_min = h[0]
	h_max = h[0]
	for v in h:
		h_min = minf(h_min, v)
		h_max = maxf(h_max, v)


func _micro_band(band: int) -> void:
	var bf: Dictionary = _band_fields[band]
	var f_a: Field = bf["micro_a"]
	var f_b: Field = bf["micro_b"]
	var rocky: float = float(Biome.field(biome_id, "ridge", 0.3))

	for y in range(_row_lo(band), _row_hi(band)):
		for x in range(size):
			var i: int = idx(x, y)
			var p: Vector2 = pos_of(x, y)

			# Two scales: gentle undulation plus a crisper rubble layer whose
			# strength follows the biome's rockiness.
			var bump: float = f_a.at(p.x, p.y) * 0.55
			var grit: float = f_b.at(p.x, p.y) * (0.10 + rocky * 0.22)

			# Carved ground keeps only a whisper of it — arena floors and paths
			# should feel deliberately cleared, not rubble-strewn.
			var k: float = lerpf(1.0, 0.22, carve[i])
			h[i] = h_macro[i] + (bump + grit) * k


# Peak-to-trough relief of the playable interior, ignoring the rim.
func _interior_relief() -> float:
	var lo: int = size / 8
	var hi: int = size - lo
	var mn: float = h_macro[idx(lo, lo)]
	var mx: float = mn
	for y in range(lo, hi):
		for x in range(lo, hi):
			var v: float = h_macro[idx(x, y)]
			mn = minf(mn, v)
			mx = maxf(mx, v)
	return maxf(mx - mn, 0.001)


# ------------------------------------------------------------------------------
# 6. Derived fields
# ------------------------------------------------------------------------------

func _derive() -> void:
	_run_bands("_derive_band")


# Safe to parallelise ONLY because it never writes the arrays it reads: it reads
# `h` and `h_macro` (including neighbouring cells) and writes `slope`, `surf`,
# `walk`, `ao`. If a future pass ever writes `h` while reading it, this breaks
# silently. Keep the two-heightfield split.
func _derive_band(band: int) -> void:
	var span: float = maxf(h_max - h_min, 0.0001)
	var has_water: bool = water_h > -99999.0
	var sz: int = size
	var inv_cell2: float = 1.0 / (2.0 * cell)
	var inv_ao: float = 1.0 / maxf(span * 0.10, 0.0001)

	for y in range(_row_lo(band), _row_hi(band)):
		# A cell is "interior" if every tap it needs is in bounds. The AO ring
		# reaches 3 cells, so that is the margin. 97% of a 384-wide region
		# qualifies, and the interior path skips twelve clamped function calls
		# per cell — the gradient taps and the eight AO ring taps all become
		# plain index arithmetic.
		var row_interior: bool = y >= 3 and y < sz - 3
		var base: int = y * sz

		for x in range(sz):
			var i: int = base + x
			var dx: float
			var dy: float
			var ring: float

			if row_interior and x >= 3 and x < sz - 3:
				dx = (h_macro[i + 1] - h_macro[i - 1]) * inv_cell2
				dy = (h_macro[i + sz] - h_macro[i - sz]) * inv_cell2
				ring = (h[i + 3] + h[i - 3] + h[i + sz * 3] + h[i - sz * 3]
					+ h[i + sz * 2 + 2] + h[i + sz * 2 - 2]
					+ h[i - sz * 2 + 2] + h[i - sz * 2 - 2]) * 0.125
			else:
				dx = (macro_at_cell(x + 1, y) - macro_at_cell(x - 1, y)) * inv_cell2
				dy = (macro_at_cell(x, y + 1) - macro_at_cell(x, y - 1)) * inv_cell2
				ring = (height_at_cell(x + 3, y) + height_at_cell(x - 3, y)
					+ height_at_cell(x, y + 3) + height_at_cell(x, y - 3)
					+ height_at_cell(x + 2, y + 2) + height_at_cell(x - 2, y + 2)
					+ height_at_cell(x + 2, y - 2) + height_at_cell(x - 2, y - 2)) * 0.125

			var g: float = sqrt(dx * dx + dy * dy)
			slope[i] = g

			var hv: float = h[i]
			var depth: float = water_h - hv

			# Surface classification. PATH was written by the carve pass and
			# outranks everything except water.
			var sf: int = surf[i]
			if has_water and depth > 0.0:
				sf = Surf.WATER
			elif sf != Surf.PATH:
				if g > 0.62:
					sf = Surf.ROCK
				elif carve[i] > 0.75:
					# CARVED GROUND IS NEVER SHORE. This test has to come before
					# the sand band: arena floors are clamped to water_h +
					# DRY_MARGIN (1.4 m), which fell inside an earlier 1.6 m
					# shoreline band, so every arena was classified as beach and
					# painted 70% soil — a quarter of the region came out sand.
					sf = Surf.FLOOR
				elif has_water and depth > -0.7:
					sf = Surf.SAND
				else:
					sf = Surf.GROUND
			surf[i] = sf

			# Walkability. Deep water and steep rock block; shallow water wades.
			var ok: bool = g <= MAX_WALK_SLOPE
			if has_water and depth > WADE_DEPTH:
				ok = false
			# Hard border, so no amount of terrain luck lets a player leave.
			if x <= 1 or y <= 1 or x >= sz - 2 or y >= sz - 2:
				ok = false
			walk[i] = 1 if ok else 0

			# Cheap ambient occlusion: how much lower this cell sits than the
			# ring around it. Sunk ground darkens, ridges stay bright. On
			# vertex-coloured terrain this does most of the work a baked
			# lightmap would, for almost nothing.
			ao[i] = clampf(0.64 + (hv - ring) * inv_ao * 0.36, 0.34, 1.0)


# ------------------------------------------------------------------------------
# Queries
# ------------------------------------------------------------------------------

# Nearest walkable cell to a world point, searched outward in rings. Used to
# place the player, enemies and chests without ever dropping one in a cliff.
func nearest_walkable(p: Vector2, max_rings: int = 48) -> Vector2:
	var half: float = float(size) * cell * 0.5
	var cx: int = clampi(int((p.x + half) / cell), 0, size - 1)
	var cy: int = clampi(int((p.y + half) / cell), 0, size - 1)
	if is_walkable(cx, cy):
		return pos_of(cx, cy)
	for r in range(1, max_rings):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:    # ring only
					continue
				if is_walkable(cx + dx, cy + dy):
					return pos_of(cx + dx, cy + dy)
	return pos_of(cx, cy)


# Fraction of the region that can be walked at all. If this nears zero the
# biome parameters produced a cliff field with no level ground — a generation
# bug rather than a hard map.
func walkable_fraction() -> float:
	var c: int = 0
	for v in walk:
		if v == 1:
			c += 1
	return float(c) / float(maxi(walk.size(), 1))


# Flood fill of walkable ground from a world point. Both connectivity metrics
# read the visited mask, so the BFS is written once.
func flood_from(from: Vector2) -> PackedByteArray:
	var seen := PackedByteArray()
	seen.resize(size * size)
	var half: float = float(size) * cell * 0.5
	var start := Vector2i(
		clampi(int((from.x + half) / cell), 0, size - 1),
		clampi(int((from.y + half) / cell), 0, size - 1))
	if walk[idx(start.x, start.y)] != 1:
		return seen

	var queue: Array[Vector2i] = [start]
	seen[idx(start.x, start.y)] = 1
	var head: int = 0
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = c.x + o.x
			var ny: int = c.y + o.y
			if not in_bounds(nx, ny):
				continue
			var j: int = idx(nx, ny)
			if seen[j] == 1 or walk[j] != 1:
				continue
			seen[j] = 1
			queue.append(Vector2i(nx, ny))
	return seen


# Of the walkable cells, the fraction reachable on foot from `from`. Isolated
# ledges are fine and even desirable, so this need not be 100%.
func reachable_fraction(from: Vector2) -> float:
	var seen: PackedByteArray = flood_from(from)
	var count: int = 0
	var total: int = 0
	for i in range(walk.size()):
		if walk[i] == 1:
			total += 1
			if seen[i] == 1:
				count += 1
	return float(count) / float(maxi(total, 1))


# THE metric that decides whether a level is shippable: can the player walk from
# the entrance to every arena on the plan? A map can be 60% walkable and still
# broken if the boss room is marooned behind a cliff. This must be 100%.
func nodes_connected(plan: Layout, from: Vector2) -> float:
	if plan == null or plan.nodes.is_empty():
		return 1.0
	var seen: PackedByteArray = flood_from(from)
	var half: float = float(size) * cell * 0.5
	var ok: int = 0
	for nd in plan.nodes:
		var p: Vector2 = nearest_walkable(nd["pos"] as Vector2)
		var cx: int = clampi(int((p.x + half) / cell), 0, size - 1)
		var cy: int = clampi(int((p.y + half) / cell), 0, size - 1)
		if seen[idx(cx, cy)] == 1:
			ok += 1
	return float(ok) / float(plan.nodes.size())
