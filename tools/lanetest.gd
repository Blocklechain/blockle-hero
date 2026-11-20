extends SceneTree
# ------------------------------------------------------------------------------
# Is the lane a lane?
#
# scripts/world/Lane.gd is the campaign's level plan: a long route from an
# entrance to a boss arena, with the width changing as you advance and dead-end
# pockets off to the side. Every one of those words is a claim that can be
# measured, and every one of them has a failure mode that compiles perfectly:
#
#   * a "route" that is a straight corridor across the region
#   * a boss arena the player cannot reach, because the plan drew a line the
#     terrain never made walkable, or because the arena was placed inside the
#     boundary wall (Layout shipped exactly that bug with its exit node)
#   * a wandering route with a SHORTCUT — two folds of the serpentine carving
#     into each other, so the player walks diagonally past half the level
#   * "width that varies" that is in fact one width, because the rhythm was
#     rolled per station and came up the same
#   * pockets that are not dead ends, or are bulges in the route rather than
#     detours off it
#   * a map that does not replay from its seed, which makes a bug report useless
#
# So this is a measuring instrument, not a smoke test. It builds many lanes and,
# for each, PATH-FINDS the ground the lane asks Terrain to flatten — entrance to
# boss, entrance to every pocket — then compares the route it found against the
# spine, the region and the declared widths. The last section throws away the
# estimate and builds three REAL regions with real noise, real rim and real
# walkability, and path-finds those.
#
#   godot --headless --path . --script tools/lanetest.gd
# ------------------------------------------------------------------------------

## The region a campaign lane is planned for: 384 cells at 0.5 m.
const REGION: Vector2 = Vector2(192.0, 192.0)
## How many seeds the sweep covers. Enough that a one-in-twenty geometry accident
## shows up as a failure rather than as a lucky green run.
const SEEDS: int = 32
## Resolution of the plan raster the sweep path-finds over, in metres. 0.5 m is
## the shipping terrain's own cell size, and it has to be this fine: at 1 m a
## narrow pocket branch running diagonally rasterised into a staircase that
## AStarGrid2D's no-corner-cutting rule refused to walk, and 21 of 124 perfectly
## good pockets were reported unreachable.
const CELL: float = 0.5

## The real-terrain section. Full shipping size, because a lane's length is the
## thing under test and a smaller region is a different lane.
const TERRAIN_CELLS: int = 384
const TERRAIN_CELL: float = 0.5
const TERRAIN_SEEDS: Array[int] = [1, 17, 4242]

var fails: int = 0

## Per-seed measurements from the sweep, printed as a table and then asserted on.
var rows: Array[Dictionary] = []


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_sweep()
	_the_journey()
	_the_width()
	_the_pockets()
	_the_ends()
	_determinism()
	_the_arena_generator_is_untouched()
	_on_real_terrain()

	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------
# The sweep: build SEEDS lanes and measure every one
# ------------------------------------------------------------------------------

## SEEDS by default; `-- 256` after the script widens the sweep. A geometry
## accident that happens to one lane in a hundred has to be findable without
## editing the instrument meant to find it, and the seeds are spaced so that a
## wider run is a superset of a narrower one.
func _seed_count() -> int:
	for a in OS.get_cmdline_user_args():
		if a.is_valid_int():
			return clampi(a.to_int(), 1, 4096)
	return SEEDS


func _sweep() -> void:
	var count: int = _seed_count()
	print("\n=== %d lanes in a %.0f x %.0f m region ===" % [count, REGION.x, REGION.y])
	print("  %5s %7s %7s %6s %6s %5s %4s %6s %6s %6s %6s %5s" % ["seed",
		"length", "walked", "bbox", "ratio", "stns", "pkt", "w.min", "w.max",
		"m.min", "m.max", "dt"])

	var t0: int = Time.get_ticks_usec()
	for s in range(count):
		var sd: int = 1000 + s * 7919          # spread out, not 0..31
		var lane: Lane = Lane.make(sd, REGION)
		var grid: Dictionary = _plan_grid(lane)

		var entry: Dictionary = lane.node_of_kind(Layout.ENTRY)
		var boss: Dictionary = lane.node_of_kind(Layout.BOSS)
		var walked: float = _walk(grid, entry.get("pos", Vector2.ZERO),
			boss.get("pos", Vector2.ZERO))

		# How far the lane spans, as the crow flies, in its own bounding box. The
		# comparison that makes "long" mean something.
		var bb: Rect2 = Rect2(lane.spine[0], Vector2.ZERO)
		for p in lane.spine:
			bb = bb.expand(p)
		var bbox: float = maxf(bb.size.x, bb.size.y)

		# Declared width, sampled up to the boss. The boss arena is deliberately
		# enormous and would dominate the range without saying anything about the
		# lane the player walks to get there.
		var w_min: float = 1e9
		var w_max: float = 0.0
		var m_min: float = 1e9
		var m_max: float = 0.0
		for i in range(80):
			var t: float = float(i) / 79.0 * 0.93
			var w: float = lane.width_at(t)
			w_min = minf(w_min, w)
			w_max = maxf(w_max, w)
			var m: float = _measure_width(grid, lane, t)
			m_min = minf(m_min, m)
			m_max = maxf(m_max, m)

		# position_at and progress_at have to be inverses, or spawn placement by
		# progress lands somewhere else on the lane.
		var worst_t: float = 0.0
		for i in range(40):
			var t: float = float(i) / 39.0
			worst_t = maxf(worst_t, absf(lane.progress_at(lane.position_at(t)) - t))

		# Every node's floor has to clear the rim Terrain raises at 0.78.
		var worst_rim: float = 0.0
		for n in lane.nodes:
			worst_rim = maxf(worst_rim,
				Rng.superellipse(n["pos"] as Vector2, REGION * 0.5, 3.2))

		var pocket_ok: int = 0
		var pocket_dead: int = 0
		var pocket_off: float = 1e9
		for id in lane.pockets:
			var p: Vector2 = lane.nodes[id]["pos"]
			if _walk(grid, entry.get("pos", Vector2.ZERO), p) > 0.0:
				pocket_ok += 1
			if _degree(lane, id) == 1:
				pocket_dead += 1
			pocket_off = minf(pocket_off, _distance_to_spine(lane, p))

		var r_mean: float = 0.0
		for id in lane.stations:
			r_mean += float(lane.nodes[id]["radius"])
		r_mean /= float(maxi(lane.stations.size(), 1))

		rows.append({
			"seed": sd, "len": lane.spine_length, "walked": walked,
			"bbox": bbox, "stations": lane.stations.size(),
			"pockets": lane.pockets.size(), "pocket_ok": pocket_ok,
			"pocket_dead": pocket_dead, "pocket_off": pocket_off,
			"w_min": w_min, "w_max": w_max, "m_min": m_min, "m_max": m_max,
			"worst_t": worst_t, "worst_rim": worst_rim,
			"boss_r": float(boss.get("radius", 0.0)), "mean_r": r_mean,
			"entry_at": (entry.get("pos", Vector2.ONE * 1e9) as Vector2)
				.distance_to(lane.position_at(0.0)),
			"boss_at": (boss.get("pos", Vector2.ONE * 1e9) as Vector2)
				.distance_to(lane.position_at(1.0)),
			"digest": _digest(lane),
		})

		print("  %5d %7.1f %7.1f %6.1f %6.2f %5d %4d %6.1f %6.1f %6.1f %6.1f %5.3f" % [
			sd, lane.spine_length, walked, bbox,
			walked / maxf(lane.spine_length, 0.001), lane.stations.size(),
			lane.pockets.size(), w_min, w_max, m_min, m_max, worst_t])

	print("  %d lanes built and path-found in %.2f s" % [count,
		float(Time.get_ticks_usec() - t0) / 1000000.0])


# ------------------------------------------------------------------------------
# 1. It is a journey
# ------------------------------------------------------------------------------

func _the_journey() -> void:
	print("\n=== it is a journey, and the journey is the route ===")

	# THE HEADLINE: path-found, not assumed. _walk returns 0 when A* finds no
	# route over the ground the lane asks to be carved.
	var unreachable: Array[int] = []
	for r in rows:
		if float(r["walked"]) <= 0.0:
			unreachable.append(int(r["seed"]))
	check("every entrance path-finds to its boss arena", unreachable.is_empty(),
		"%d of %d lanes failed%s" % [unreachable.size(), rows.size(),
			"" if unreachable.is_empty() else ": %s" % str(unreachable)])

	# A lane folds back on itself to buy length. If two folds carve into each
	# other the player can cut the corner, and the walked distance collapses well
	# below the spine — which is the only symptom a shortcut has.
	var worst: Dictionary = _worst("walked_ratio", false)
	check("the walk to the boss follows the lane, not a shortcut",
		float(worst["v"]) >= 0.70,
		"shortest walk was %.0f%% of the spine (seed %d)" % [
			float(worst["v"]) * 100.0, int(worst["seed"])])

	# ...and not far above it either: a route much longer than the spine would
	# mean the carve is so broken that A* is detouring around holes in it.
	var longest: Dictionary = _worst("walked_ratio", true)
	check("...and is not detouring around gaps in it",
		float(longest["v"]) <= 1.30,
		"longest walk was %.0f%% of the spine (seed %d)" % [
			float(longest["v"]) * 100.0, int(longest["seed"])])

	var shortest: Dictionary = _worst("len", false)
	# 1.6 -> 1.3, and the reason is recorded rather than the number quietly
	# edited. Fold separation is now sized for the carve REACH (width * 3.6)
	# instead of the station radius, because folds whose fields merged let the
	# player cut between them — a late map's boss was reachable in 48% of its
	# lane. Properly separated folds are bigger, so fewer fit a region and lanes
	# run ~305 m instead of ~400 m.
	#
	# The journey got LONGER even though the lane got shorter: the player used
	# to walk 0.32 x 400 = ~128 m of it, and now walks 0.82 x 305 = ~250 m. The
	# drawn length is the weaker measure; encountertest's `bypass:` line is the
	# one that matters, and it is the reason this threshold moved.
	check("a lane is far longer than the region is wide",
		float(shortest["v"]) >= REGION.x * 1.3,
		"shortest lane %.0f m across a %.0f m region (seed %d)" % [
			float(shortest["v"]), REGION.x, int(shortest["seed"])])

	var squat: Dictionary = _worst("aspect", false)
	check("a lane is longer than it is wide", float(squat["v"]) >= 2.2,
		"worst was %.1fx its own bounding box (seed %d)" % [
			float(squat["v"]), int(squat["seed"])])


# ------------------------------------------------------------------------------
# 2. The width genuinely varies
# ------------------------------------------------------------------------------

func _the_width() -> void:
	print("\n=== the width varies, in the plan and on the ground ===")

	var no_pinch: Array[int] = []
	var no_clearing: Array[int] = []
	for r in rows:
		if float(r["w_min"]) > 5.5:
			no_pinch.append(int(r["seed"]))
		if float(r["w_max"]) < 11.0:
			no_clearing.append(int(r["seed"]))
	check("every lane has a pinch point", no_pinch.is_empty(),
		"%d lanes never narrow below 5.5 m" % no_pinch.size())
	check("every lane has an open clearing", no_clearing.is_empty(),
		"%d lanes never open past 11 m" % no_clearing.size())

	var flat: Dictionary = _worst("w_ratio", false)
	check("widest is at least twice the narrowest", float(flat["v"]) >= 2.0,
		"worst spread was %.1fx (seed %d)" % [float(flat["v"]),
			int(flat["seed"])])

	# And measured on the raster, not read back off the same numbers that drew
	# it: the perpendicular run of carved ground at each point along the lane.
	var flat_m: Dictionary = _worst("m_ratio", false)
	check("...and the carved ground really does narrow and open",
		float(flat_m["v"]) >= 1.8,
		"worst measured spread %.1fx (seed %d)" % [float(flat_m["v"]),
			int(flat_m["seed"])])
	var thin: Dictionary = _worst("m_min", false)
	check("the narrowest point is still wide enough to walk",
		float(thin["v"]) >= 2.5,
		"narrowest measured %.1f m (seed %d)" % [float(thin["v"]),
			int(thin["seed"])])


# ------------------------------------------------------------------------------
# 3. Side pockets
# ------------------------------------------------------------------------------

func _the_pockets() -> void:
	print("\n=== side pockets: optional, reachable, and dead ends ===")

	var fewest: Dictionary = _worst("pockets", false)
	check("every lane has at least two side pockets", float(fewest["v"]) >= 2.0,
		"fewest was %d (seed %d)" % [int(fewest["v"]), int(fewest["seed"])])

	var unreached: int = 0
	var alive: int = 0
	var total: int = 0
	for r in rows:
		total += int(r["pockets"])
		unreached += int(r["pockets"]) - int(r["pocket_ok"])
		alive += int(r["pockets"]) - int(r["pocket_dead"])
	check("every pocket path-finds from the entrance", unreached == 0,
		"%d of %d pockets unreachable" % [unreached, total])
	check("every pocket is a dead end", alive == 0,
		"%d of %d pockets had more than one way out" % [alive, total])

	# A pocket has to be OFF the lane. One that sits on the spine is a wide spot
	# in the route, and the player gets its loot without choosing to detour.
	var close: Dictionary = _worst("pocket_off", false)
	check("a pocket is a detour, not a bulge in the route",
		float(close["v"]) >= 10.0,
		"closest pocket sat %.1f m off the spine (seed %d)" % [
			float(close["v"]), int(close["seed"])])


# ------------------------------------------------------------------------------
# 4. The two ends, and progress between them
# ------------------------------------------------------------------------------

func _the_ends() -> void:
	print("\n=== an entrance at 0, a boss arena at 1 ===")

	var e: Dictionary = _worst("entry_at", true)
	check("progress 0 is the entrance", float(e["v"]) < 0.01,
		"worst was %.3f m out (seed %d)" % [float(e["v"]), int(e["seed"])])
	var b: Dictionary = _worst("boss_at", true)
	check("progress 1 is the middle of the boss arena", float(b["v"]) < 0.01,
		"worst was %.3f m out (seed %d)" % [float(b["v"]), int(b["seed"])])

	var p: Dictionary = _worst("worst_t", true)
	check("position_at and progress_at are inverses", float(p["v"]) <= 0.04,
		"worst round trip was %.3f off (seed %d)" % [float(p["v"]),
			int(p["seed"])])

	var small: Dictionary = _worst("boss_ratio", false)
	check("the boss arena is a distinct wide area", float(small["v"]) >= 1.6,
		"smallest was %.1fx the mean station radius (seed %d)" % [
			float(small["v"]), int(small["seed"])])

	# Layout buried its exit in the boundary wall by pushing it past the boss
	# without clamping. Every lane node is placed through Lane._fits, so this is
	# the check that the rule is actually applied.
	var rim: Dictionary = _worst("worst_rim", true)
	check("no node is buried in the boundary wall", float(rim["v"]) <= 0.78,
		"worst node sat at superellipse %.3f, rim starts at 0.78 (seed %d)" % [
			float(rim["v"]), int(rim["seed"])])


# ------------------------------------------------------------------------------
# 5. Determinism
# ------------------------------------------------------------------------------

func _determinism() -> void:
	print("\n=== the same seed is the same lane; a different seed is not ===")

	var differ: int = 0
	for r in rows:
		var again: Lane = Lane.make(int(r["seed"]), REGION)
		if _digest(again) != String(r["digest"]):
			differ += 1
	check("re-generating a seed reproduces the lane exactly", differ == 0,
		"%d of %d differed" % [differ, rows.size()])

	var seen: Dictionary = {}
	for r in rows:
		seen[String(r["digest"])] = true
	check("every seed gives a different lane", seen.size() == rows.size(),
		"%d distinct lanes from %d seeds" % [seen.size(), rows.size()])

	# Determinism has to survive the region size too, or a lane generated for a
	# preview at one size is not the lane that gets played.
	var a: Lane = Lane.make(5150, Vector2(256.0, 256.0))
	var b: Lane = Lane.make(5150, Vector2(256.0, 256.0))
	check("...at other region sizes as well", _digest(a) == _digest(b))
	check("a bigger region makes a longer lane",
		a.spine_length > 1.2 * float(rows[0]["len"]),
		"%.0f m at 256 m vs %.0f m at 192 m" % [a.spine_length,
			float(rows[0]["len"])])


# ------------------------------------------------------------------------------
# 6. The arena generator still builds arenas
# ------------------------------------------------------------------------------

## Lane EXTENDS Layout so that Terrain, Scatter and Play can take either without
## growing a second code path. That inheritance is the one way this work could
## have damaged the PvP generator, so it is checked here: a rotational arena is
## still symmetric, and it is still a Layout and not a Lane.
func _the_arena_generator_is_untouched() -> void:
	print("\n=== the PvP arena generator is untouched ===")
	var arena: Layout = Layout.generate(4242, REGION, Layout.Sym.ROTATIONAL, 11)
	check("Layout still builds a rotational arena",
		arena.nodes.size() >= 7 and not (arena is Lane),
		"%d nodes" % arena.nodes.size())
	var paired: int = 0
	for n in arena.nodes:
		if String(n["kind"]) == Layout.SPAWN:
			continue
		if arena._node_at(-(n["pos"] as Vector2)) >= 0:
			paired += 1
	check("...and its 180-degree symmetry survives", paired >= arena.nodes.size() - 2,
		"%d of %d nodes have a rotated twin" % [paired, arena.nodes.size()])

	var lane: Lane = Lane.make(4242, REGION)
	check("a lane is a Layout, so Terrain needs no second path",
		lane is Layout and lane.nodes.size() > 0 and lane.edges.size() > 0,
		"%d nodes, %d edges" % [lane.nodes.size(), lane.edges.size()])


# ------------------------------------------------------------------------------
# 7. On real terrain
# ------------------------------------------------------------------------------

## Everything above measures the PLAN. This builds the region: warped noise, the
## rim wall, the carve, water, terracing and the walkability pass — then asks the
## same questions of the ground the player will actually stand on, with Godot's
## AStarGrid2D over Terrain.walk, through the same Pathing the hero walks with.
##
## This is the section that would have caught Layout's buried exit.
##
## WHAT IT DELIBERATELY DOES NOT ASSERT: that the straight line to the boss is
## blocked. It is not — a greenwood region is about 73% naturally walkable, so a
## player who ignores the lane can cut across the biome in a third of the
## distance. Walling the route in is explicitly NOT wanted ("a corridor of flat
## ground with walls is a failure of this task"); whether off-lane ground is
## discouraged is the terrain pass's business, and Terrain already computes
## `path_dist` — metres from every cell to the lane — which is exactly the field
## such a rule would need. What IS asserted here is the claim the lane generator
## is responsible for: every leg of the route is walkable on real ground.
func _on_real_terrain() -> void:
	print("\n=== the same lane, carved into real terrain ===")
	# Two ends of the biome list: a temperate one and a hostile one, because the
	# terrain parameters that could strand a station (amplitude, ridge, water)
	# differ most between those.
	var biomes: PackedStringArray = PackedStringArray([
		Biome.IDS[0], Biome.IDS[Biome.IDS.size() - 1], Biome.IDS[0]])

	for i in range(TERRAIN_SEEDS.size()):
		var sd: int = TERRAIN_SEEDS[i]
		var biome: String = biomes[i % biomes.size()]
		var extent: float = float(TERRAIN_CELLS) * TERRAIN_CELL
		var lane: Lane = Lane.make(sd, Vector2(extent, extent))
		var t0: int = Time.get_ticks_usec()
		var ter: Terrain = Terrain.generate(sd, biome, TERRAIN_CELLS,
			TERRAIN_CELL, lane)
		var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0

		var path: Pathing = Pathing.new(ter)
		var entry: Vector2 = path.nearest_walkable_centre(lane.position_at(0.0))
		var boss: Vector2 = path.nearest_walkable_centre(lane.position_at(1.0))
		var connected: float = ter.nodes_connected(lane, entry)

		# WALK THE LANE, station by station, the way a player does. A single
		# path-find from the entrance to the boss proves only that the two are in
		# the same walkable blob — over open biome ground it answers with the
		# diagonal and says nothing about the route. Leg by leg is the claim that
		# matters: every stretch of the lane is walkable, in order, end to end.
		var legs: int = 0
		var broken: int = 0
		var lane_walk: float = 0.0
		var worst_leg: float = 0.0
		for k in range(lane.stations.size() - 1):
			var a: Vector2 = path.nearest_walkable_centre(
				lane.nodes[lane.stations[k]]["pos"] as Vector2)
			var b: Vector2 = path.nearest_walkable_centre(
				lane.nodes[lane.stations[k + 1]]["pos"] as Vector2)
			var leg: PackedVector2Array = path.find(a, b)
			legs += 1
			if leg.size() < 2:
				broken += 1
				continue
			var walked: float = 0.0
			for i2 in range(leg.size() - 1):
				walked += leg[i2].distance_to(leg[i2 + 1])
			lane_walk += walked
			# How far the walkable route deviates from the planned stretch. A leg
			# that takes three times the arc is a carve the terrain refused.
			var arc: float = (lane.station_progress(k + 1)
				- lane.station_progress(k)) * lane.spine_length
			worst_leg = maxf(worst_leg, walked / maxf(arc, 0.001))

		var direct: PackedVector2Array = path.find(entry, boss)
		var direct_len: float = 0.0
		for k2 in range(direct.size() - 1):
			direct_len += direct[k2].distance_to(direct[k2 + 1])

		var paths: int = 0
		for s in range(ter.surf.size()):
			if ter.surf[s] == Terrain.Surf.PATH:
				paths += 1

		print("  seed %d, %s: %.0f ms, %.0f%% walkable, lane %.0f m, walked %.0f m over %d legs (straight line %.0f m)" % [
			sd, biome, ms, ter.walkable_fraction() * 100.0, lane.spine_length,
			lane_walk, legs, direct_len])

		check("[%d] every station is reachable on foot" % sd,
			is_equal_approx(connected, 1.0),
			"%.0f%% of %d nodes" % [connected * 100.0, lane.nodes.size()])
		check("[%d] every leg of the lane is walkable, in order" % sd,
			broken == 0 and lane_walk >= lane.spine_length * 0.9,
			"%d of %d legs blocked, %.0f m walked over a %.0f m lane" % [
				broken, legs, lane_walk, lane.spine_length])
		check("[%d] ...and no leg fights the terrain" % sd, worst_leg <= 2.0,
			"worst leg took %.1fx its planned length" % worst_leg)
		check("[%d] the lane seeded the path field" % sd, paths > 2000,
			"%d cells marked PATH" % paths)
		# Carving a 400 m lane through a region must not pave it: the biome is
		# most of what the player sees, and a lane that flattens everything is
		# the grey box this generator was told not to build.
		var carved: int = 0
		for c in range(ter.carve.size()):
			if ter.carve[c] > 0.5:
				carved += 1
		var frac: float = float(carved) / float(ter.carve.size())
		check("[%d] the lane is cut THROUGH the biome, not over it" % sd,
			frac > 0.04 and frac < 0.45,
			"%.1f%% of the region carved" % [frac * 100.0])
		# A LANE IS MOSTLY NOT WALKABLE, AND THAT IS THE POINT.
		#
		# This asked for >35% walkable, which was written when walkability came
		# from slope alone and a region was open ground a lane was drawn across.
		# It measured 68%, and the consequence was that the lane was a
		# suggestion: A* reached the boss in 130 m of a 400 m lane by cutting
		# between the serpentine's folds, so a player met one or two packs out
		# of nine. Terrain now requires carved ground for a lane to be walkable.
		#
		# So the bar is inverted AND the real property is tightened: the share
		# of the region that is walkable should be small (it is the lane, not
		# the map), while essentially ALL of it must be reachable from the
		# entrance — no stranded islands of lane behind a wall. 0.95 rather than
		# the old 0.5, because a lane with 40% of itself cut off is a broken
		# lane that the old threshold would have passed.
		var walk_frac: float = ter.walkable_fraction()
		var reach_frac: float = ter.reachable_fraction(entry)
		check("[%d] the walkable region IS the lane" % sd,
			walk_frac > 0.08 and walk_frac < 0.45 and reach_frac > 0.95,
			"%.0f%% walkable, %.0f%% of it reachable" % [
				walk_frac * 100.0, reach_frac * 100.0])


# ------------------------------------------------------------------------------
# Instruments
# ------------------------------------------------------------------------------

## The ground the lane ASKS Terrain to flatten, rasterised at CELL metres: every
## station disc and every carve ribbon, exactly as Terrain._carve_layout reads
## them. Path-finding this is how the sweep can ask reachability questions of 32
## lanes without generating 32 heightfields.
func _plan_grid(l: Lane) -> Dictionary:
	var n: int = int(maxf(l.extent.x, l.extent.y) / CELL)
	var bits := PackedByteArray()
	bits.resize(n * n)
	var half: float = float(n) * CELL * 0.5

	for nd in l.nodes:
		var p: Vector2 = nd["pos"]
		var r: float = float(nd["radius"])
		var x0: int = clampi(int((p.x - r + half) / CELL), 0, n - 1)
		var x1: int = clampi(int((p.x + r + half) / CELL), 0, n - 1)
		var y0: int = clampi(int((p.y - r + half) / CELL), 0, n - 1)
		var y1: int = clampi(int((p.y + r + half) / CELL), 0, n - 1)
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var q0 := Vector2(float(x) * CELL - half, float(y) * CELL - half)
				if q0.distance_to(p) <= r:
					bits[y * n + x] = 1

	for e in l.edges:
		var pts: PackedVector2Array = e["pts"]
		var w: float = float(e["width"]) * 0.5
		for s in range(pts.size() - 1):
			var a: Vector2 = pts[s]
			var b: Vector2 = pts[s + 1]
			var lo: Vector2 = Vector2(minf(a.x, b.x), minf(a.y, b.y))
			var hi: Vector2 = Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
			var x0: int = clampi(int((lo.x - w + half) / CELL), 0, n - 1)
			var x1: int = clampi(int((hi.x + w + half) / CELL), 0, n - 1)
			var y0: int = clampi(int((lo.y - w + half) / CELL), 0, n - 1)
			var y1: int = clampi(int((hi.y + w + half) / CELL), 0, n - 1)
			for y in range(y0, y1 + 1):
				for x in range(x0, x1 + 1):
					var q := Vector2(float(x) * CELL - half, float(y) * CELL - half)
					if Layout._seg_dist(q, a, b) <= w:
						bits[y * n + x] = 1

	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, n, n)
	grid.cell_size = Vector2(CELL, CELL)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	grid.update()
	for y in range(n):
		for x in range(n):
			if bits[y * n + x] != 1:
				grid.set_point_solid(Vector2i(x, y), true)

	return {"n": n, "half": half, "bits": bits, "grid": grid}


## Metres walked from `a` to `b` across the rasterised plan, or 0 if there is no
## route. Octile A*, so the number is a real walking distance rather than a cell
## count.
func _walk(g: Dictionary, a: Vector2, b: Vector2) -> float:
	var grid: AStarGrid2D = g["grid"]
	var ca: Vector2i = _cell(g, a)
	var cb: Vector2i = _cell(g, b)
	if grid.is_point_solid(ca) or grid.is_point_solid(cb):
		return 0.0
	var ids: Array[Vector2i] = grid.get_id_path(ca, cb)
	if ids.size() < 2:
		return 0.0
	var run: float = 0.0
	for i in range(ids.size() - 1):
		run += Vector2(ids[i]).distance_to(Vector2(ids[i + 1])) * CELL
	return run


func _cell(g: Dictionary, p: Vector2) -> Vector2i:
	var n: int = int(g["n"])
	var half: float = float(g["half"])
	return Vector2i(clampi(int((p.x + half) / CELL), 0, n - 1),
		clampi(int((p.y + half) / CELL), 0, n - 1))


## Carved width across the lane at progress `t`, measured on the raster by
## stepping out along the perpendicular until the ground stops being carved.
func _measure_width(g: Dictionary, l: Lane, t: float) -> float:
	var n: int = int(g["n"])
	var bits: PackedByteArray = g["bits"]
	var p: Vector2 = l.position_at(t)
	var tan: Vector2 = l.tangent_at(t)
	var side := Vector2(-tan.y, tan.x)
	# The cell the centreline is in counts: a 3 m pinch measured only by its two
	# flanks reads as 2 m, and the threshold would then be testing the raster's
	# quantisation rather than the lane.
	var c0: Vector2i = _cell(g, p)
	var run: float = CELL if bits[c0.y * n + c0.x] == 1 else 0.0
	for way in [1.0, -1.0]:
		for step in range(1, 120):
			var c: Vector2i = _cell(g, p + side * (way * float(step) * CELL))
			if bits[c.y * n + c.x] != 1:
				break
			run += CELL
	return run


## How many edges touch a node. A pocket's far end must have exactly one.
func _degree(l: Lane, id: int) -> int:
	var d: int = 0
	for e in l.edges:
		if int(e["a"]) == id or int(e["b"]) == id:
			d += 1
	return d


func _distance_to_spine(l: Lane, p: Vector2) -> float:
	var best: float = 1e9
	for q in l.spine:
		best = minf(best, p.distance_to(q))
	return best


## Everything a lane is, as text: every node, every carve point, the spine and
## its length. Two lanes with the same digest are the same level.
func _digest(l: Lane) -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append("%.4f" % l.spine_length)
	for n in l.nodes:
		var p: Vector2 = n["pos"]
		parts.append("%d|%s|%.4f|%.4f|%.4f|%.4f" % [int(n["id"]),
			String(n["kind"]), p.x, p.y, float(n["radius"]), float(n["elev"])])
	for e in l.edges:
		parts.append("%d-%d@%.4f" % [int(e["a"]), int(e["b"]), float(e["width"])])
		var pts: PackedVector2Array = e["pts"]
		for q in pts:
			parts.append("%.4f,%.4f" % [q.x, q.y])
	for q2 in l.spine:
		parts.append("%.4f;%.4f" % [q2.x, q2.y])
	parts.append(str(l.stations))
	parts.append(str(l.pockets))
	return "|".join(parts)


## The worst row for a metric, so a failure names the seed that caused it rather
## than leaving someone to re-run 32 lanes looking for it. `derived` metrics are
## ratios the sweep did not store directly.
func _worst(metric: String, want_max: bool) -> Dictionary:
	var best: float = -1e18 if want_max else 1e18
	var seed_of: int = 0
	for r in rows:
		var v: float = 0.0
		match metric:
			"walked_ratio":
				v = float(r["walked"]) / maxf(float(r["len"]), 0.001)
			"aspect":
				v = float(r["len"]) / maxf(float(r["bbox"]), 0.001)
			"w_ratio":
				v = float(r["w_max"]) / maxf(float(r["w_min"]), 0.001)
			"m_ratio":
				v = float(r["m_max"]) / maxf(float(r["m_min"]), 0.001)
			"boss_ratio":
				v = float(r["boss_r"]) / maxf(float(r["mean_r"]), 0.001)
			_:
				v = float(r[metric])
		if (want_max and v > best) or (not want_max and v < best):
			best = v
			seed_of = int(r["seed"])
	return {"v": best, "seed": seed_of}
