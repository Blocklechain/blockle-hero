class_name Layout
extends RefCounted
# ------------------------------------------------------------------------------
# The level PLAN, in two dimensions, before any terrain exists.
#
# This module is the difference between a landscape and a level. Pure noise makes
# scenery you walk across; an ARPG needs a readable graph — arenas you fight in,
# joined by paths you travel, with a way in, a way on, and loops so no corridor
# is a dead end you have to walk back down. So the plan is laid out first and the
# terrain is carved to serve it, never the other way round.
#
# Two symmetry modes:
#   ASYMMETRIC  campaign. Entry on one edge, boss far from it, side rooms.
#   ROTATIONAL  PvP. Nodes are generated in a half-space and copied through a
#               180 degree rotation about the centre, so the two spawns face a
#               provably identical map. Mirroring across an axis would NOT do:
#               it hands one player the left-handed version of every sightline.
# ------------------------------------------------------------------------------

enum Sym { ASYMMETRIC, ROTATIONAL }

# Node kinds. The terrain pass reads these to decide how hard to flatten, and the
# scatter pass reads them to decide what to keep clear.
const ENTRY := "entry"
const EXIT := "exit"
const BOSS := "boss"
const ARENA := "arena"
const SHRINE := "shrine"
const TREASURE := "treasure"
const SPAWN := "spawn"

var nodes: Array[Dictionary] = []
var edges: Array[Dictionary] = []
var extent: Vector2 = Vector2(192.0, 192.0)
var symmetry: int = Sym.ASYMMETRIC
var seed: int = 0


# ------------------------------------------------------------------------------
# Generation
# ------------------------------------------------------------------------------

static func generate(world_seed: int, size: Vector2, sym: int = Sym.ASYMMETRIC,
		node_count: int = 11) -> Layout:
	var l := Layout.new()
	l.seed = Rng.seed_of(world_seed, "layout")
	l.extent = size
	l.symmetry = sym
	if sym == Sym.ROTATIONAL:
		l._build_rotational(node_count)
	else:
		l._build_campaign(node_count)
	l._connect()
	l._carve_curves()
	return l


# ---- campaign ----------------------------------------------------------------

func _build_campaign(count: int) -> void:
	var half: Vector2 = extent * 0.5
	var margin: float = minf(extent.x, extent.y) * 0.13

	# Entry and boss are placed first, on opposite sides, as far apart as the
	# region allows. Everything else fills the space between them so the journey
	# has length rather than the player spawning next to the objective.
	var ang: float = Rng.unit1(seed, 1) * TAU
	var reach: Vector2 = half - Vector2(margin, margin)
	var entry_p: Vector2 = Vector2(cos(ang), sin(ang)) * reach * 0.94
	var boss_p: Vector2 = -entry_p * Rng.range2(seed, 2, 0, 0.82, 1.0)

	_add(entry_p, ENTRY, 9.0, -0.35)
	_add(boss_p, BOSS, 17.0, -0.55)

	# The remainder are scattered by best-candidate sampling: throw several
	# darts, keep whichever lands furthest from everything already placed. It
	# gives Poisson-like spacing for a fraction of the bookkeeping, and spacing
	# is what stops two arenas overlapping into one shapeless blob.
	var want: int = maxi(count - 2, 0)
	for i in range(want):
		var best: Vector2 = Vector2.ZERO
		var best_d: float = -1.0
		for t in range(14):
			var c: Vector2 = Vector2(
				Rng.range2(seed, i * 31 + t, 7, -reach.x, reach.x),
				Rng.range2(seed, i * 31 + t, 8, -reach.y, reach.y))
			var d: float = _nearest_dist(c)
			if d > best_d:
				best_d = d
				best = c
		var kind: String = _campaign_kind(i)
		_add(best, kind, _radius_for(kind, i), _elev_for(kind, i))

	# The exit sits beyond the boss — you leave through the thing you killed.
	# Clamped well inside the rim: pushed out past the boss unclamped it landed
	# at superellipse ~0.80, which is INSIDE the boundary wall the terrain pass
	# raises at 0.78, so the exit was being buried in a cliff.
	var exit_p: Vector2 = boss_p * 1.08
	var lim: Vector2 = reach * 0.90
	if absf(exit_p.x) > lim.x or absf(exit_p.y) > lim.y:
		exit_p *= minf(lim.x / maxf(absf(exit_p.x), 0.001),
			lim.y / maxf(absf(exit_p.y), 0.001))
	_add(exit_p, EXIT, 7.0, -0.3)


func _campaign_kind(i: int) -> String:
	# Roughly: mostly fighting space, with a shrine and some treasure to find.
	var r: float = Rng.unit2(seed, i, 44)
	if i == 0:
		return SHRINE
	if r < 0.18:
		return TREASURE
	if r < 0.30:
		return SHRINE
	return ARENA


# ---- PvP ---------------------------------------------------------------------

func _build_rotational(count: int) -> void:
	var half: Vector2 = extent * 0.5
	var margin: float = minf(extent.x, extent.y) * 0.12
	var reach: Vector2 = half - Vector2(margin, margin)

	# A single centre node — the contested ground every arena needs.
	_add(Vector2.ZERO, ARENA, 19.0, -0.6)

	# Spawns go at opposite corners of the long diagonal.
	var sp: Vector2 = Vector2(reach.x * 0.9, reach.y * 0.9)
	_add(-sp, SPAWN, 10.0, -0.4)
	_add(sp, SPAWN, 10.0, -0.4)

	# Everything else is generated in the half-plane above the anti-diagonal and
	# duplicated through a 180 degree rotation, so each player's side of the map
	# is the same map.
	var pairs: int = maxi((count - 3) / 2, 1)
	for i in range(pairs):
		var best: Vector2 = Vector2.ZERO
		var best_d: float = -1.0
		for t in range(16):
			var c: Vector2 = Vector2(
				Rng.range2(seed, i * 53 + t, 11, -reach.x, reach.x),
				Rng.range2(seed, i * 53 + t, 12, -reach.y, reach.y))
			# keep to one half-plane; the rotation supplies the other
			if c.x + c.y < 0.0:
				c = -c
			var d: float = _nearest_dist(c)
			if d > best_d:
				best_d = d
				best = c
		var kind: String = TREASURE if Rng.unit2(seed, i, 61) < 0.34 else ARENA
		var rad: float = _radius_for(kind, i)
		var ev: float = _elev_for(kind, i)
		_add(best, kind, rad, ev)
		_add(-best, kind, rad, ev)      # the rotated twin


# ---- shared node helpers -----------------------------------------------------

func _radius_for(kind: String, i: int) -> float:
	match kind:
		BOSS: return 17.0
		TREASURE: return 7.0
		SHRINE: return 8.0
		SPAWN: return 10.0
		_: return Rng.range2(seed, i, 17, 9.0, 14.5)


func _elev_for(kind: String, i: int) -> float:
	# Negative biases sink a node into the terrain, which reads as a natural
	# basin and gives the surrounding ground a lip to fight against. Shrines go
	# the other way: raised, so they are visible from across the region.
	if kind == SHRINE:
		return Rng.range2(seed, i, 19, 0.25, 0.60)
	if kind == TREASURE:
		return Rng.range2(seed, i, 20, -0.15, 0.35)
	return Rng.range2(seed, i, 21, -0.50, -0.15)


func _add(p: Vector2, kind: String, radius: float, elev: float) -> void:
	nodes.append({
		"id": nodes.size(),
		"pos": p,
		"kind": kind,
		"radius": radius,
		"elev": elev,
	})


func _nearest_dist(p: Vector2) -> float:
	if nodes.is_empty():
		return 1e9
	var best: float = 1e9
	for n in nodes:
		best = minf(best, p.distance_to(n["pos"] as Vector2))
	return best


# ------------------------------------------------------------------------------
# Connectivity
# ------------------------------------------------------------------------------

func _connect() -> void:
	if nodes.size() < 2:
		return

	# Prim's minimum spanning tree first. The MST guarantees the single property
	# that actually matters — every room is reachable — with no redundant edges.
	var inside: Array[int] = [0]
	var outside: Array[int] = []
	for i in range(1, nodes.size()):
		outside.append(i)

	while not outside.is_empty():
		var best_a: int = -1
		var best_b: int = -1
		var best_d: float = 1e18
		for a in inside:
			for b in outside:
				var d: float = (nodes[a]["pos"] as Vector2).distance_to(
					nodes[b]["pos"] as Vector2)
				if d < best_d:
					best_d = d
					best_a = a
					best_b = b
		if best_b < 0:
			break
		_add_edge(best_a, best_b)
		inside.append(best_b)
		outside.erase(best_b)

	# Then a few extra edges to create loops. A pure tree plays badly: every
	# branch is a dead end the player has to retrace. Loops let you fight
	# through and come out somewhere new, which is most of what makes a Diablo
	# level feel like a place rather than a flowchart.
	var want_loops: int = maxi(nodes.size() / 4, 1)
	var added: int = 0
	var tries: int = 0
	while added < want_loops and tries < 200:
		tries += 1
		var a: int = int(Rng.unit2(seed, tries, 71) * float(nodes.size())) % nodes.size()
		var b: int = int(Rng.unit2(seed, tries, 72) * float(nodes.size())) % nodes.size()
		if a == b or _has_edge(a, b):
			continue
		var d: float = (nodes[a]["pos"] as Vector2).distance_to(
			nodes[b]["pos"] as Vector2)
		# only short-circuits that are actually short, or the map turns to soup
		if d > minf(extent.x, extent.y) * 0.42:
			continue
		_add_edge(a, b)
		added += 1

	# Rotational maps must stay symmetric after the loop pass, so mirror every
	# edge through the rotation as well.
	if symmetry == Sym.ROTATIONAL:
		_symmetrise_edges()


func _add_edge(a: int, b: int) -> void:
	var kinds := [String(nodes[a]["kind"]), String(nodes[b]["kind"])]
	# Approach to a boss is a wide processional; side routes are narrow.
	var w: float = 5.0
	if BOSS in kinds or SPAWN in kinds:
		w = 7.5
	elif TREASURE in kinds:
		w = 3.5
	edges.append({"a": a, "b": b, "width": w, "pts": PackedVector2Array()})


func _has_edge(a: int, b: int) -> bool:
	for e in edges:
		if (int(e["a"]) == a and int(e["b"]) == b) \
				or (int(e["a"]) == b and int(e["b"]) == a):
			return true
	return false


func _symmetrise_edges() -> void:
	# For each edge, find the node whose position is the rotation of each
	# endpoint, and ensure the corresponding edge exists too.
	var existing: int = edges.size()
	for i in range(existing):
		var e: Dictionary = edges[i]
		var ra: int = _node_at(-(nodes[int(e["a"])]["pos"] as Vector2))
		var rb: int = _node_at(-(nodes[int(e["b"])]["pos"] as Vector2))
		if ra >= 0 and rb >= 0 and ra != rb and not _has_edge(ra, rb):
			edges.append({"a": ra, "b": rb, "width": float(e["width"]),
				"pts": PackedVector2Array()})


func _node_at(p: Vector2, tol: float = 0.75) -> int:
	for n in nodes:
		if (n["pos"] as Vector2).distance_to(p) <= tol:
			return int(n["id"])
	return -1


# ------------------------------------------------------------------------------
# Path curves
# ------------------------------------------------------------------------------

func _carve_curves() -> void:
	# Straight corridors read as machine-made. Every path gets two interior
	# control points pushed sideways off the straight line and is sampled as a
	# Catmull-Rom spline, so it arrives at each arena on a curve.
	for i in range(edges.size()):
		var e: Dictionary = edges[i]
		var a: Vector2 = nodes[int(e["a"])]["pos"]
		var b: Vector2 = nodes[int(e["b"])]["pos"]
		var along: Vector2 = b - a
		var len_: float = along.length()
		if len_ < 0.001:
			continue
		var side: Vector2 = Vector2(-along.y, along.x) / len_
		var bow: float = minf(len_ * 0.22, 16.0)

		var c1: Vector2 = a + along * 0.33 + side * Rng.range2(seed, i, 81, -bow, bow)
		var c2: Vector2 = a + along * 0.66 + side * Rng.range2(seed, i, 82, -bow, bow)

		# Rotational symmetry has to survive the jitter too, so one half of the
		# edge list derives its bow from its twin rather than rolling fresh.
		if symmetry == Sym.ROTATIONAL and a.x + a.y < 0.0:
			c1 = a + along * 0.33 - side * Rng.range2(seed, i, 81, -bow, bow)
			c2 = a + along * 0.66 - side * Rng.range2(seed, i, 82, -bow, bow)

		var pts := PackedVector2Array()
		# One sample per 5 m, not per 2.5 m. The carve blends over `width * 3.6`
		# (up to 27 m), so 2.5 m sampling resolved detail far below what the
		# stamp can express while doubling the number of stamps — and each stamp
		# re-walks a bbox dominated by that same reach. Halving the segment count
		# halves the carve cost with no visible change to the path curve.
		var steps: int = maxi(int(len_ / 5.0), 6)
		for s in range(steps + 1):
			pts.append(_catmull(a, c1, c2, b, float(s) / float(steps)))
		e["pts"] = pts
		edges[i] = e


# Catmull-Rom through the two interior points, clamped at the endpoints so the
# path actually touches both arenas.
static func _catmull(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2,
		t: float) -> Vector2:
	var t2: float = t * t
	var t3: float = t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


# ------------------------------------------------------------------------------
# Queries used by the terrain and scatter passes
# ------------------------------------------------------------------------------

func node_of_kind(kind: String) -> Dictionary:
	for n in nodes:
		if String(n["kind"]) == kind:
			return n
	return {}


func nodes_of_kind(kind: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for n in nodes:
		if String(n["kind"]) == kind:
			out.append(n)
	return out


# Influence of the arena graph at a point: 1.0 dead centre of a node, falling to
# 0 at its rim. The terrain pass uses it to flatten, the scatter pass to clear.
func node_influence(p: Vector2) -> float:
	var best: float = 0.0
	for n in nodes:
		var r: float = float(n["radius"])
		var d: float = p.distance_to(n["pos"] as Vector2)
		best = maxf(best, Rng.smoothstep01(r, r * 0.45, d))
	return best


# Signed-ish distance to the nearest path centreline, in metres, plus the width
# of that path. Returns [distance, width].
func path_distance(p: Vector2) -> Array:
	var best: float = 1e9
	var w: float = 4.0
	for e in edges:
		var pts: PackedVector2Array = e["pts"]
		for i in range(pts.size() - 1):
			var d: float = _seg_dist(p, pts[i], pts[i + 1])
			if d < best:
				best = d
				w = float(e["width"])
	return [best, w]


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var l2: float = ab.length_squared()
	if l2 < 0.000001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)
