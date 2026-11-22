class_name Scatter
extends RefCounted

# Preloaded by path. A new class_name is absent from Godot's global class
# cache until the editor reimports, and this script is compiled on the WORLD
# BUILD THREAD — where the failure is a silent "generate() does not exist"
# and the map simply never finishes, rather than an error anyone reads.
const Dress := preload("res://scripts/world/Dress.gd")
# ------------------------------------------------------------------------------
# Where props go — and, just as importantly, where they do not.
#
# Scatter is what turns a heightfield into a place, but it is also the easiest
# way to ruin a level: props in a fight arena block movement, props on a path
# hide the route, and props spread with uniform density read as wallpaper. So
# placement is rule-driven:
#
#   * NEVER on a path or in the flat heart of an arena — those are cleared on
#     purpose, and the clearing is what makes the arena legible as a space
#   * NEVER on ground too steep to stand on, or under water
#   * CLUSTERED, not uniform. Real forests have thickets and glades; a Poisson
#     field of evenly-spaced trees looks like an orchard
#   * DENSER just outside arenas, which frames the fighting space and gives the
#     player a readable edge to the room
#
# Output is a flat list of placements. The renderer buckets them by (kind,
# variant) into MultiMesh instances, so a thousand trees cost one draw call.
# ------------------------------------------------------------------------------

# Metres of clear ground kept either side of a path. See the note in _place().
const PATH_CLEARANCE: float = 2.0

# A placement: {kind, variant, pos (Vector3), yaw, scale}
var items: Array[Dictionary] = []

# Ground cover: grass, ferns, pebbles, twigs. Kept in a SEPARATE list from props
# because it obeys different rules — placed in the thousands, never blocking,
# allowed inside arenas (a bare arena floor looks unfinished; it is the standing
# props that must stay out of the fighting space), and skipped at distance.
var cover: Array[Dictionary] = []

var blocked: PackedByteArray = PackedByteArray()      # 1 = a prop blocks this cell


## [form_id] is the map's MapShape form ("warren", "hollow", ...). It changes
## how much is planted and what kind — see Dress.gd. Empty means "no opinion",
## which is what every caller written before forms existed passes, so they
## keep the dressing they already had.
## The MapShape form this scatter was generated for, or "" for none.
var _form: String = ""


static func generate(t: Terrain, plan: Layout, world_seed: int,
		form_id: String = "") -> Scatter:
	var s := Scatter.new()
	s.blocked.resize(t.size * t.size)
	s._form = form_id
	s._place(t, plan, Rng.seed_of(world_seed, "scatter"))
	s._place_cover(t, plan, Rng.seed_of(world_seed, "cover"))
	return s


# ------------------------------------------------------------------------------
# Ground cover
# ------------------------------------------------------------------------------

func _place_cover(t: Terrain, plan: Layout, sd: int) -> void:
	var tbl: Dictionary = Biome.field(t.biome_id, "cover", {}) as Dictionary
	if tbl.is_empty():
		return
	var names: Array = tbl.keys()
	var weights: Array = []
	for k in names:
		weights.append(float(tbl[k]))

	# Ground cover follows the form too, or a hollow is bare of props and
	# still carpeted in grass — which reads as a mown lawn, not open ground.
	var density: float = float(Biome.field(t.biome_id, "cover_density", 30.0)) \
		* Dress.density_scale(_form)

	# GRID JITTER, not rejection sampling. The prop pass throws darts and retries
	# up to 14 times per placement, which is fine for a few thousand but hopeless
	# at cover densities — greenwood wants ~23,000 instances, so that loop would
	# run a third of a million times. Walking a lattice and nudging each slot is
	# one pass, gives even coverage with no clumping artefacts, and stays
	# deterministic.
	var spacing: float = sqrt(100.0 / maxf(density, 0.5))
	var half: float = float(t.size) * t.cell * 0.5
	var steps: int = int((half * 2.0) / spacing)
	var f_clump: Field = Field.fbm(Rng.seed_of(sd, "cover.clump"), 0.09, 3)

	for gy in range(steps):
		for gx in range(steps):
			var n: int = gy * steps + gx
			var p := Vector2(
				-half + (float(gx) + 0.5) * spacing
					+ Rng.range2(sd, n, 1, -spacing * 0.45, spacing * 0.45),
				-half + (float(gy) + 0.5) * spacing
					+ Rng.range2(sd, n, 2, -spacing * 0.45, spacing * 0.45))

			var cx: int = clampi(int((p.x + half) / t.cell), 0, t.size - 1)
			var cy: int = clampi(int((p.y + half) / t.cell), 0, t.size - 1)
			var i: int = t.idx(cx, cy)

			if t.surf[i] == Terrain.Surf.WATER:
				continue
			if t.slope[i] > 0.66:
				continue
			# Thin out on paths rather than clearing them: a trodden track still
			# has some growth at its edges, and a hard boundary reads as a decal.
			if t.surf[i] == Terrain.Surf.PATH and Rng.unit2(sd, n, 3) > 0.18:
				continue
			if blocked[i] == 1 and Rng.unit2(sd, n, 4) > 0.3:
				continue

			# Patchy, not uniform — bare ground between tufts is what makes the
			# tufts read as plants rather than as carpet.
			var clump: float = f_clump.at01(p.x, p.y)
			if Rng.unit2(sd, n, 5) > clampf(clump * 1.35 - 0.16, 0.0, 1.0):
				continue

			var kind: String = String(Rng.pick_weighted(sd, n, 6, names, weights))
			if kind == "":
				continue

			cover.append({
				"kind": kind,
				"variant": Rng.hash2(sd, n, 7) % Props.variants_for(kind),
				"pos": Vector3(p.x, t.height_at(p), p.y),
				"yaw": Rng.unit2(sd, n, 8) * TAU,
				"scale": Rng.range2(sd, n, 9, 0.62, 1.32),
			})


# Group cover placements the same way props are grouped.
func cover_buckets() -> Dictionary:
	var out: Dictionary = {}
	for it in cover:
		var key: String = "%s#%d" % [String(it["kind"]), int(it["variant"])]
		if not out.has(key):
			out[key] = []
		(out[key] as Array).append(it)
	return out


func _place(t: Terrain, plan: Layout, sd: int) -> void:
	# THE BIOME SAYS WHAT GROWS HERE; THE FORM SAYS HOW MUCH AND WHAT KIND.
	# Re-weighting rather than substituting keeps frostcrag frostcrag even
	# when it is shaped like a warren — see Dress.gd.
	var table: Array = Dress.apply(Biome.prop_table(t.biome_id), _form)
	var names: Array = table[0]
	var weights: Array = table[1]
	if names.is_empty():
		return

	var density: float = float(Biome.field(t.biome_id, "density", 4.0)) \
		* Dress.density_scale(_form)
	var area: float = float(t.size * t.size) * t.cell * t.cell
	# density is props per 100 m^2.
	var want: int = int(area / 100.0 * density)

	# The clumping field. Sampling a noise field and rejecting below a threshold
	# gives thickets and clearings for one extra noise read per candidate —
	# far cheaper and better looking than any explicit clustering algorithm.
	var f_clump: Field = Field.fbm(Rng.seed_of(sd, "clump"), 0.035, 3)

	# Terrain.generate() always fills this; a hand-built Terrain (the profiler,
	# a unit test) may not. Check once rather than per candidate, and degrade to
	# "no path clearance" rather than reading out of bounds.
	var has_pd: bool = t.path_dist.size() == t.size * t.size

	var placed: int = 0
	var tries: int = 0
	var max_tries: int = want * 14
	var half: float = float(t.size) * t.cell * 0.5

	while placed < want and tries < max_tries:
		tries += 1
		var p := Vector2(
			Rng.range2(sd, tries, 1, -half, half),
			Rng.range2(sd, tries, 2, -half, half))

		var cx: int = clampi(int((p.x + half) / t.cell), 0, t.size - 1)
		var cy: int = clampi(int((p.y + half) / t.cell), 0, t.size - 1)
		var i: int = t.idx(cx, cy)

		# --- hard rejections ---------------------------------------------------
		if t.surf[i] == Terrain.Surf.WATER or t.surf[i] == Terrain.Surf.PATH:
			continue
		if t.slope[i] > 0.70:
			continue
		if blocked[i] == 1:
			continue

		# Keep the flat heart of every arena clear. The skirt (influence between
		# roughly 0.15 and 0.55) is deliberately left plantable — that band is
		# what visually frames the room.
		var infl: float = plan.node_influence(p)
		if infl > 0.55:
			continue

		# Stay off the paths with a margin, so a tree never overhangs the route.
		#
		# Read from Terrain's precomputed distance field. This used to call
		# plan.path_distance(), which walked every one of ~420 path segments per
		# candidate — about 15 million segment tests per region, and the single
		# largest cost in this pass.
		#
		# The field measures distance to the PATH MASK, which the carve pass
		# marks at d < width*0.85; the old test was d < width*1.25. The gap
		# between the two is ~2 m across the width range in use (3.5-7.5 m), so
		# a flat 2 m margin reproduces the old behaviour closely.
		if has_pd and t.path_dist[i] < PATH_CLEARANCE:
			continue

		# --- clumping ----------------------------------------------------------
		var clump: float = f_clump.at01(p.x, p.y)
		# Props thicken just outside arenas: the framing effect.
		var frame: float = Rng.smoothstep01(0.08, 0.42, infl) * 0.35
		var chance: float = clampf(clump * 1.15 + frame - 0.34, 0.0, 1.0)
		if Rng.unit2(sd, tries, 3) > chance:
			continue

		# --- choose and place --------------------------------------------------
		var kind: String = String(Rng.pick_weighted(sd, tries, 4, names, weights))
		if kind == "":
			continue

		# Shoreline and rock want different things growing on them.
		if t.surf[i] == Terrain.Surf.ROCK and kind in ["tree_broad", "reed", "flower"]:
			continue
		if kind == "reed" and t.surf[i] != Terrain.Surf.SAND:
			continue

		var variant: int = Rng.hash2(sd, tries, 5) % Props.variants_for(kind)
		var scl: float = Rng.range2(sd, tries, 6, 0.80, 1.30)
		var yaw: float = Rng.unit2(sd, tries, 7) * TAU

		items.append({
			"kind": kind,
			"variant": variant,
			"pos": Vector3(p.x, t.height_at(p), p.y),
			"yaw": yaw,
			"scale": scl,
		})
		_block(t, cx, cy, _footprint(kind, scl))
		placed += 1


# How many cells a prop occupies for collision and for spacing. Grass and
# flowers block nothing — the player walks through them.
func _footprint(kind: String, scl: float) -> int:
	match kind:
		"grass_tuft", "flower", "mushroom", "reed", "bone":
			return 0
		"boulder", "rock_large", "statue", "ruin_wall":
			return 1
		_:
			# Radius 0 = the single cell the prop stands on. A tree trunk is
			# half a metre wide; you walk BETWEEN trees. Blocking a 5x5 patch
			# per prop collapsed walkability from 71% to 27%.
			return 0


func _block(t: Terrain, cx: int, cy: int, r: int) -> void:
	if r <= 0:
		# Still mark the exact cell so two props never stack in one spot.
		blocked[t.idx(cx, cy)] = 1
		return
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			if t.in_bounds(x, y):
				blocked[t.idx(x, y)] = 1


# Fold prop footprints into terrain walkability. Called after scatter so a
# boulder is genuinely solid rather than decorative.
func apply_blocking(t: Terrain) -> void:
	for i in range(blocked.size()):
		if blocked[i] == 1:
			t.walk[i] = 0


# Group placements by (kind, variant) so the renderer can build one MultiMesh
# per bucket — a thousand trees in a single draw call.
func buckets() -> Dictionary:
	var out: Dictionary = {}
	for it in items:
		var key: String = "%s#%d" % [String(it["kind"]), int(it["variant"])]
		if not out.has(key):
			out[key] = []
		(out[key] as Array).append(it)
	return out
