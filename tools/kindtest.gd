extends SceneTree
# ------------------------------------------------------------------------------
# Does a LANE get the same world an ARENA gets?
#
# Terrain takes a layout kind now — Kind.ARENA for Layout.gd (the PvP generator)
# and Kind.LANE for Lane.gd (the campaign) — and the whole claim of that change
# is that the kind picks the PLAN and nothing else forks. The failure this file
# exists to catch is the one that compiles perfectly and ships grey: a lane that
# renders as a flat corridor with walls because somewhere downstream it stopped
# getting the biome's palette, its fog, its terrain parameters, its props or its
# ground cover.
#
# So every assertion here is a measurement of a GENERATED REGION, never of the
# source. tools/preview.gd renders the same regions to PNG for the half of this
# that only an eye can judge; this file is the half a machine can.
#
#   godot --headless --path . --script tools/kindtest.gd
# ------------------------------------------------------------------------------

const CELLS := 384
const CELL := 0.5
const EXTENT := Vector2(CELLS * CELL, CELLS * CELL)

## Four biomes that stress different parameters: temperate and green, high
## amplitude and ridged, high water, and thick fog.
const BIOMES: PackedStringArray = ["greenwood", "frostcrag", "molten", "mistmoor"]

var fails: int = 0
## Measurements per biome, for the art-parity comparisons at the end.
var _lane: Dictionary = {}
var _arena: Dictionary = {}


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_the_kind()
	_measure_regions()
	_the_art()
	_the_traps()
	_the_route()
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------
# 1. The kind selects a generator, and nothing else
# ------------------------------------------------------------------------------

func _the_kind() -> void:
	print("\n=== the layout kind ===")
	var arena: Layout = Terrain.plan_for(Terrain.Kind.ARENA, 4242, EXTENT,
		Layout.Sym.ASYMMETRIC, 11)
	var lane: Layout = Terrain.plan_for(Terrain.Kind.LANE, 4242, EXTENT)
	var pvp: Layout = Terrain.plan_for(Terrain.Kind.ARENA, 4242, EXTENT,
		Layout.Sym.ROTATIONAL, 11)

	check("Kind.ARENA builds a Layout and not a Lane",
		arena is Layout and not (arena is Lane), "%d nodes" % arena.nodes.size())
	check("Kind.LANE builds a Lane", lane is Lane,
		"%d nodes, %.0f m of spine" % [lane.nodes.size(),
			(lane as Lane).spine_length])
	check("kind_of() reads the plan back",
		Terrain.kind_of(arena) == Terrain.Kind.ARENA
			and Terrain.kind_of(lane) == Terrain.Kind.LANE)

	# The PvP symmetry is the one thing the campaign work could have broken by
	# reaching into the shared generator. It is checked here as well as in
	# lanetest, because this file is the one that touches Terrain's selection.
	var paired: int = 0
	for n in pvp.nodes:
		if String(n["kind"]) == Layout.SPAWN:
			continue
		if pvp._node_at(-(n["pos"] as Vector2)) >= 0:
			paired += 1
	check("Kind.ARENA still reaches the 180-degree PvP generator",
		paired >= pvp.nodes.size() - 2,
		"%d of %d nodes have a rotated twin" % [paired, pvp.nodes.size()])


# ------------------------------------------------------------------------------
# 2. Generate both kinds, in every test biome, and keep the measurements
# ------------------------------------------------------------------------------

func _measure_regions() -> void:
	print("\n=== generating %d regions ===" % (BIOMES.size() * 2))
	for bid in BIOMES:
		# SAME SEED FOR BOTH KINDS. Any difference between the two rows below is
		# then the plan and only the plan — identical noise, identical palette.
		var sd: int = 4242
		_arena[bid] = _measure(Terrain.Kind.ARENA, bid, sd)
		_lane[bid] = _measure(Terrain.Kind.LANE, bid, sd)
		var a: Dictionary = _arena[bid]
		var l: Dictionary = _lane[bid]
		print("  %-10s arena %5d ms  relief %5.1f m  walk %4.1f%%  props %4d  cover %5d" % [
			bid, int(a["ms"]), float(a["relief"]), float(a["walk"]) * 100.0,
			int(a["props"]), int(a["cover"])])
		print("  %-10s lane  %5d ms  relief %5.1f m  walk %4.1f%%  props %4d  cover %5d   lane %.0f m" % [
			"", int(l["ms"]), float(l["relief"]), float(l["walk"]) * 100.0,
			int(l["props"]), int(l["cover"]), float(l["lane_m"])])


func _measure(kind: int, bid: String, sd: int) -> Dictionary:
	var plan: Layout = Terrain.plan_for(kind, sd, EXTENT, Layout.Sym.ASYMMETRIC, 11)
	var t0: int = Time.get_ticks_msec()
	var ter := Terrain.generate(sd, bid, CELLS, CELL, plan)
	var ms: int = Time.get_ticks_msec() - t0

	# Props and cover are part of the art, so they are generated and their
	# blocking folded in — which is what WorldBuilder ships.
	var scat := Scatter.generate(ter, plan, sd)
	scat.apply_blocking(ter)

	var hist := PackedInt32Array()
	hist.resize(6)
	var carved: int = 0
	var mean := Vector3.ZERO
	for i in range(ter.surf.size()):
		hist[ter.surf[i]] += 1
		if ter.carve[i] > 0.5:
			carved += 1
		var c: Color = ter.vcol[i]
		mean += Vector3(c.r, c.g, c.b)
	mean /= float(maxi(ter.surf.size(), 1))

	var blocked: int = 0
	for b in scat.blocked:
		if b == 1:
			blocked += 1

	var entry: Dictionary = plan.node_of_kind(Layout.ENTRY)
	var start: Vector2 = ter.nearest_walkable(entry.get("pos", Vector2.ZERO))

	# The interior landform, away from the rim: every cell of the central box
	# that is not under water, so neither the 20 m boundary wall nor a 7 m lake
	# bed is mistaken for ground the player walks over.
	var inner := PackedFloat32Array()
	var m: int = int(float(ter.size) * 0.18)
	for y in range(m, ter.size - m):
		for x in range(m, ter.size - m):
			var i2: int = ter.idx(x, y)
			if ter.surf[i2] != Terrain.Surf.WATER:
				inner.append(ter.h[i2])

	var out: Dictionary = {
		"ter": ter, "plan": plan, "scat": scat, "ms": ms, "start": start,
		"interior_span": _span(inner),
		"relief": ter.h_max - ter.h_min,
		"walk": ter.walkable_fraction(),
		"reach": ter.reachable_fraction(start),
		"connected": ter.nodes_connected(plan, start),
		"carved": float(carved) / float(ter.carve.size()),
		"blocked": float(blocked) / float(ter.walk.size()),
		"hist": hist, "mean": mean,
		"props": scat.items.size(), "cover": scat.cover.size(),
		"lane_m": (plan as Lane).spine_length if plan is Lane else 0.0,
	}
	if plan is Lane:
		out["lane_reach"] = ter.lane_reachable_fraction(plan as Lane, start)
		out["lane_cells"] = _lane_cells(ter, plan as Lane)
	return out


# Every cell within 6 m of the spine: the ground the player actually walks down.
# Art claims about "the lane" have to be measured HERE, not over the region,
# or a beautiful biome with a grey corridor through it still passes.
func _lane_cells(t: Terrain, l: Lane) -> PackedInt32Array:
	var out := PackedInt32Array()
	var seen := {}
	var half: float = float(t.size) * t.cell * 0.5
	var ring: int = int(6.0 / t.cell)
	for s in range(0, l.spine.size()):
		var p: Vector2 = l.spine[s]
		var cx: int = clampi(int((p.x + half) / t.cell), 0, t.size - 1)
		var cy: int = clampi(int((p.y + half) / t.cell), 0, t.size - 1)
		for dy in range(-ring, ring + 1, 2):
			for dx in range(-ring, ring + 1, 2):
				if not t.in_bounds(cx + dx, cy + dy):
					continue
				var i: int = t.idx(cx + dx, cy + dy)
				if seen.has(i):
					continue
				seen[i] = true
				out.append(i)
	return out


# ------------------------------------------------------------------------------
# 3. The art. Palette, light, relief, props, cover — along the lane itself
# ------------------------------------------------------------------------------

func _the_art() -> void:
	print("\n=== the lane gets the biome, not a grey box ===")
	var means: Array[Vector3] = []
	for bid in BIOMES:
		var l: Dictionary = _lane[bid]
		var a: Dictionary = _arena[bid]
		var ter: Terrain = l["ter"]
		var cells: PackedInt32Array = l["lane_cells"]
		means.append(l["mean"] as Vector3)

		# PALETTE. Baked vertex colour along the lane must sit in the same place
		# as the region's: a lane whose floor was painted from somewhere else
		# would show up as a colour the rest of the biome never uses.
		var lane_mean := Vector3.ZERO
		var lane_var: float = 0.0
		for i in cells:
			var c: Color = ter.vcol[i]
			lane_mean += Vector3(c.r, c.g, c.b)
		lane_mean /= float(maxi(cells.size(), 1))
		for i in cells:
			var c2: Color = ter.vcol[i]
			lane_var += (Vector3(c2.r, c2.g, c2.b) - lane_mean).length_squared()
		lane_var = sqrt(lane_var / float(maxi(cells.size(), 1)))
		check("[%s] the lane is painted from the biome palette" % bid,
			(lane_mean - (l["mean"] as Vector3)).length() < 0.12,
			"lane mean rgb %.3f from region mean" % (
				lane_mean - (l["mean"] as Vector3)).length())
		# ...and it is not ONE colour. A flat ribbon is the grey box.
		check("[%s] ...and it is not a single flat colour" % bid,
			lane_var > 0.012, "rgb spread %.3f along the lane" % lane_var)

		# THE LANE CLIMBS AND FALLS, measured against the LANDFORM it is cut into
		# and not against `h_max - h_min`. That region span is 28-31 m in every
		# biome because the boundary rim adds 20 m and the lake basins dig 7 m
		# down, so judging a route by it would call every lane flat by
		# construction. The honest denominator is the interior landform: about 4 m
		# across a 192 m region, because _normalise_slope targets a mean GRADIENT
		# rather than an amplitude. A lane that uses a good share of that is a
		# lane that rises and falls as much as its world does.
		var lane_span: float = _span(_heights(ter, cells))
		var world_span: float = float(l["interior_span"])
		check("[%s] the lane climbs and falls with the landform" % bid,
			lane_span > world_span * 0.35,
			"%.1f m of climb over %.0f m of lane, in a landform %.1f m deep" % [
				lane_span, float(l["lane_m"]), world_span])

		# TERRAIN PARAMETERS. amplitude/ridge/roughness/warp are the biome's, and
		# the region they built has to have real relief either side of the route.
		check("[%s] the region has the biome's relief" % bid,
			float(l["relief"]) > 8.0
				and absf(float(l["relief"]) - float(a["relief"])) < 8.0,
			"lane %.1f m vs arena %.1f m" % [l["relief"], a["relief"]])

		# PROPS AND COVER. Both tables must reach the ground, and props must be
		# NEAR the lane (framing it) without standing in it.
		var near: int = 0
		var on_path: int = 0
		var scat: Scatter = l["scat"]
		for it in scat.items:
			var p: Vector3 = it["pos"]
			var d: float = ter.path_dist[_cell_of(ter, Vector2(p.x, p.z))]
			if d < 14.0:
				near += 1
			if d < 1.0:
				on_path += 1
		check("[%s] props stand along the lane" % bid,
			near > 40 and on_path == 0,
			"%d props within 14 m of the route, %d on it" % [near, on_path])
		var cover_near: int = 0
		for it2 in scat.cover:
			var p2: Vector3 = it2["pos"]
			if ter.path_dist[_cell_of(ter, Vector2(p2.x, p2.z))] < 14.0:
				cover_near += 1
		check("[%s] ground cover grows along it too" % bid,
			cover_near > 40, "%d tufts within 14 m of the route" % cover_near)

		# PARITY. Whatever the arena got in this biome, the lane got too.
		check("[%s] lane and arena carry the same palette" % bid,
			((l["mean"] as Vector3) - (a["mean"] as Vector3)).length() < 0.06,
			"region mean rgb differs by %.3f" % (
				(l["mean"] as Vector3) - (a["mean"] as Vector3)).length())
		check("[%s] ...and the same prop and cover budget" % bid,
			int(l["props"]) == int(a["props"])
				and float(l["cover"]) > float(a["cover"]) * 0.75,
			"props %d vs %d, cover %d vs %d" % [l["props"], a["props"],
				l["cover"], a["cover"]])

	# Four biomes must not come out looking like one biome.
	var worst: float = 1e9
	for i in range(means.size()):
		for j in range(i + 1, means.size()):
			worst = minf(worst, (means[i] - means[j]).length())
	check("lanes in different biomes look different",
		worst > 0.03, "closest pair differs by %.3f rgb" % worst)


# Height spread, as a 2nd-to-98th percentile range rather than min-to-max: one
# cell of rubble on a ridge is not relief the player experiences.
func _span(vals: PackedFloat32Array) -> float:
	if vals.size() < 8:
		return 0.0
	vals.sort()
	return vals[int(float(vals.size()) * 0.98)] - vals[int(float(vals.size()) * 0.02)]


func _heights(t: Terrain, cells: PackedInt32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in cells:
		out.append(t.h[i])
	return out


func _cell_of(t: Terrain, p: Vector2) -> int:
	var half: float = float(t.size) * t.cell * 0.5
	return t.idx(clampi(int((p.x + half) / t.cell), 0, t.size - 1),
		clampi(int((p.y + half) / t.cell), 0, t.size - 1))


# ------------------------------------------------------------------------------
# 4. The traps this file has fallen into before
# ------------------------------------------------------------------------------

func _the_traps() -> void:
	print("\n=== the documented traps, re-tested on lanes ===")
	for bid in BIOMES:
		var l: Dictionary = _lane[bid]
		var ter: Terrain = l["ter"]
		var lane: Lane = l["plan"]

		# WATER BEFORE RIM. If the water line were taken after the rim raised
		# h_max, it would sit above the play area and the map would flood.
		if ter.water_h > -99999.0:
			var drowned: int = 0
			for i in range(ter.surf.size()):
				if ter.surf[i] == Terrain.Surf.WATER:
					drowned += 1
			check("[%s] the region is not flooded" % bid,
				float(drowned) / float(ter.surf.size()) < 0.35,
				"%.1f%% under water" % [float(drowned) / float(ter.surf.size()) * 100.0])

			# DRY FLOORS. Every station, pocket and the boss arena must sit at
			# least DRY_MARGIN above the water, or the player spawns underwater.
			var wettest: float = 1e9
			for nd in lane.nodes:
				var h: float = ter.h_macro[_cell_of(ter, nd["pos"] as Vector2)]
				wettest = minf(wettest, h - ter.water_h)
			check("[%s] every station floor clears the water line" % bid,
				wettest >= Terrain.DRY_MARGIN - 0.35,
				"driest floor sits %.2f m above water (margin %.2f)" % [
					wettest, Terrain.DRY_MARGIN])
		else:
			check("[%s] dry biome has no water" % bid, true, "water_level < 0")

		# SLOPE NORMALISATION. Absolute amplitude does not survive fractal
		# summation; the mean interior slope is what is actually targeted, and if
		# it drifts the region becomes either a cliff field or a billiard table.
		var lo: int = ter.size / 8
		var hi: int = ter.size - lo
		var total: float = 0.0
		var taps: int = 0
		for y in range(lo, hi, 3):
			for x in range(lo, hi, 3):
				total += ter.slope[ter.idx(x, y)]
				taps += 1
		var mean_slope: float = total / float(maxi(taps, 1))
		check("[%s] slope was normalised, not left to the amplitude" % bid,
			mean_slope > 0.08 and mean_slope < 0.55,
			"mean interior slope %.3f" % mean_slope)

		# PROP FOOTPRINTS. Trees are radius 0 on purpose; blanket-blocking them
		# collapsed walkability from 71% to 27% once already.
		check("[%s] prop footprints do not blanket the region" % bid,
			float(l["blocked"]) < 0.08 and float(l["walk"]) > 0.35,
			"%.1f%% of cells blocked, %.0f%% walkable" % [
				float(l["blocked"]) * 100.0, float(l["walk"]) * 100.0])

		# THE RIM IS TERRAIN, NOT AN INVISIBLE WALL — and it holds.
		var leaks: int = 0
		for x in range(ter.size):
			if ter.walk[ter.idx(x, 0)] == 1 or ter.walk[ter.idx(x, ter.size - 1)] == 1:
				leaks += 1
			if ter.walk[ter.idx(0, x)] == 1 or ter.walk[ter.idx(ter.size - 1, x)] == 1:
				leaks += 1
		check("[%s] the boundary holds" % bid, leaks == 0,
			"%d walkable border cells" % leaks)

		# THE LANE IS CUT THROUGH THE BIOME, NOT OVER IT.
		check("[%s] the carve did not pave the region" % bid,
			float(l["carved"]) > 0.04 and float(l["carved"]) < 0.45,
			"%.1f%% of the region carved" % [float(l["carved"]) * 100.0])


# ------------------------------------------------------------------------------
# 5. The whole route is walkable, pockets and boss arena included
# ------------------------------------------------------------------------------

func _the_route() -> void:
	print("\n=== the lane is walkable end to end ===")
	for bid in BIOMES:
		var l: Dictionary = _lane[bid]
		var ter: Terrain = l["ter"]
		var lane: Lane = l["plan"]
		# nodes_connected covers the pockets and the boss arena; it is measured
		# AFTER prop blocking, which is the walkability the game ships.
		check("[%s] every station, pocket and the boss are reachable" % bid,
			is_equal_approx(float(l["connected"]), 1.0),
			"%.0f%% of %d nodes, %d of them pockets" % [
				float(l["connected"]) * 100.0, lane.nodes.size(),
				lane.pockets.size()])
		check("[%s] and so is the route between them" % bid,
			float(l["lane_reach"]) > 0.999,
			"%.1f%% of %.0f m of spine" % [float(l["lane_reach"]) * 100.0,
				lane.spine_length])

	# DETERMINISM. A region replays identically from its seed, lane and all.
	var p1: Layout = Terrain.plan_for(Terrain.Kind.LANE, 777, EXTENT)
	var p2: Layout = Terrain.plan_for(Terrain.Kind.LANE, 777, EXTENT)
	var t1 := Terrain.generate(777, "greenwood", 128, 1.0, p1)
	var t2 := Terrain.generate(777, "greenwood", 128, 1.0, p2)
	var diff: int = 0
	for i in range(t1.h.size()):
		if not is_equal_approx(t1.h[i], t2.h[i]) or t1.surf[i] != t2.surf[i]:
			diff += 1
	check("a lane region replays identically from its seed", diff == 0,
		"%d of %d cells differed" % [diff, t1.h.size()])
