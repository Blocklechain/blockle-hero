class_name Lane
extends Layout
# ------------------------------------------------------------------------------
# The campaign level PLAN: a long lane from an entrance to a boss arena.
#
# This is the SECOND layout generator, standing beside Layout.gd rather than
# replacing it. Layout builds 180-degree rotationally symmetric arena graphs for
# PvP, where both players must be handed a provably identical map. A campaign
# map wants the opposite property: a journey with a beginning and an end, which
# is asymmetric by definition.
#
# IT EXTENDS Layout ON PURPOSE. Terrain, Scatter, Play and WorldBuilder all take
# a `Layout` and read `nodes`, `edges`, `node_influence()` and `node_of_kind()`
# off it. A lane that produced its own private shape would force every one of
# those to grow a second code path. A lane IS a layout — a particular topology of
# one — so it inherits the contract instead of duplicating it, and the selection
# task D makes is `plan is Lane` with nothing downstream to change.
# (Lane.generate() is Layout's static and still builds an ARENA; the lane
# constructor is Lane.make(), because GDScript requires an override to keep the
# parent's signature and a lane does not take a symmetry mode.)
#
# WHAT MAKES IT A LANE AND NOT A TUNNEL
#
#   SPINE       A serpentine route — several sweeps across the region, joined by
#               rounded U-turns, every waypoint jittered and the whole thing run
#               through a Catmull-Rom spline. Serpentine because a region is a
#               bounded square and the lane has to be LONG: a straight run
#               across a 192 m region is 150 m, which is a room. Folding the
#               route back on itself three or four times buys ~500 m of travel
#               out of the same ground, and the spline plus the jitter is what
#               keeps it reading as a wandering trail rather than a hairpin.
#   WIDTH       Stations along the spine alternate through a fixed rhythm of
#               PINCH / OPEN / WIDE, and the corridor between two stations takes
#               its width from the narrower of them. So the lane physically
#               tightens and opens as the player advances, and the fight rhythm
#               changes with it — a pinch is a held line, a clearing is a
#               surround. The rhythm is a rotated PATTERN, not a dice roll, so
#               every lane is guaranteed to contain both.
#   POCKETS     Short dead-end branches off the spine, ending in treasure or a
#               shrine. These are the reason to leave the route, and the reason a
#               lane is explored rather than walked.
#   BOSS        A single wide arena at the far end, pulled far enough inside the
#               region that its whole floor clears the boundary wall.
#   ENTRANCE    Where the player spawns, at progress 0.
#
# PROGRESS, NOT ANGLE. The encounter system places arena spawns in a ring around
# the player; on a lane that is meaningless, because everything behind the player
# is already cleared. So a lane is parameterised by arc length: position_at(t),
# width_at(t), tangent_at(t) and progress_at(p) for t in 0..1, with t = 0 the
# entrance and t = 1 the boss.
#
# Everything is derived from (world_seed) through Rng, so a map replays
# identically from a save — the same guarantee Layout and Combat already make.
# ------------------------------------------------------------------------------

## Spacing of the dense spine samples, in metres. This is the resolution of every
## position_at()/progress_at() query, so it is fine detail — 2 m keeps the arc
## table honest on the U-turns without being large (a 600 m lane is 300 points).
const SPINE_STEP: float = 2.0

## Spacing of the points handed to Terrain as carve instructions. Deliberately
## coarser than SPINE_STEP and for the same reason Layout samples its corridors
## at 5 m: the carve blends over `width * 3.6`, so finer stamps resolve detail
## the stamp cannot express while each one re-walks a bbox dominated by that
## reach. Queries get 2 m; the heightfield gets 5 m.
const CARVE_STEP: float = 5.0

const ENTRY_RADIUS: float = 9.0
const BOSS_RADIUS: float = 20.0
const EXIT_RADIUS: float = 7.0

## The widest a spine station can be. Used to size the serpentine box, so it has
## to bound _radius_for_beat().
const MAX_STATION_RADIUS: float = 14.2

## Where Terrain._rim_band starts lifting the ground into the boundary wall, as a
## fraction of the half-extent, and the slack kept beyond a node's own radius.
## Layout learned this the hard way — an exit pushed past the boss landed inside
## the wall and was buried in a cliff. Here every node is placed through _fits(),
## so the whole flattened floor of every station clears the rim by construction.
const RIM_START: float = 0.78
const RIM_MARGIN: float = 1.5

## Placements tried per junction before a pocket is given up on. ONE was not
## enough: the side was a single coin flip, so a junction whose side happened to
## face the neighbouring fold failed outright — and with every junction on a lane
## failing that way, seed 246489 of the sweep produced a lane with NO POCKETS,
## which is the tunnel this generator exists to avoid. Attempts alternate sides
## and then shrink the room, which is the one knob that loosens every clearance
## rule at once.
const POCKET_ATTEMPTS: int = 6

## The width rhythm, as indices into _radius_for_beat(). A PATTERN rather than a
## random draw per station: a lane whose pinches and clearings were rolled
## independently can come out all one width, and "the fight rhythm changes as you
## advance" is then true only on average. The pattern is rotated by the seed, so
## two lanes still start on different beats.
const BEAT_PINCH: int = 0
const BEAT_OPEN: int = 1
const BEAT_WIDE: int = 2
## Written as literals rather than as the BEAT_* names above because GDScript
## will not constant-fold a typed array built from other constants.
## Reads: OPEN PINCH WIDE OPEN PINCH OPEN WIDE PINCH.
const BEATS: Array[int] = [1, 0, 2, 1, 0, 1, 2, 0]

## Densely sampled centreline, in travel order, entrance first and boss last.
var spine: PackedVector2Array = PackedVector2Array()
## Total travelled length of the spine, in metres.
var spine_length: float = 0.0
## Node ids of the stations ON the spine, in travel order: ENTRY .. BOSS.
var stations: Array[int] = []
## Node ids of the dead ends at the far end of each side pocket.
var pockets: Array[int] = []

## Cumulative arc length at each spine sample; _arc[0] == 0.
var _arc: PackedFloat32Array = PackedFloat32Array()
## Arc length at which each station sits, parallel to `stations`.
var _station_arc: PackedFloat32Array = PackedFloat32Array()
## Width of the corridor from station k to station k+1.
var _spine_width: PackedFloat32Array = PackedFloat32Array()
## Everything metric scales with the region, so a small region is a short lane
## rather than the same lane with the stations overlapping into one blob.
var _scale: float = 1.0


# ------------------------------------------------------------------------------
# Generation
# ------------------------------------------------------------------------------

static func make(world_seed: int, size: Vector2) -> Lane:
	var l := Lane.new()
	l.seed = Rng.seed_of(world_seed, "lane")
	l.extent = size
	# A journey has no mirror. Recorded rather than left at the default so that
	# anything reading `symmetry` off a plan gets an answer that is true.
	l.symmetry = Sym.ASYMMETRIC
	l._scale = clampf(minf(size.x, size.y) / 192.0, 0.5, 1.25)
	l._build_spine()
	l._place_stations()
	l._dig_pockets()
	l._place_exit()
	return l


# ---- spine -------------------------------------------------------------------

func _build_spine() -> void:
	var raw: PackedVector2Array = _spline(_serpentine())
	if raw.size() < 2:
		spine = raw
		_measure(raw)
		return

	# Trim the tail until the LAST point can hold the boss arena. The boss is the
	# end of the lane, so progress 1.0 has to be the middle of its floor; a boss
	# centred on the final waypoint would have half its arena inside the rim.
	var last: int = raw.size() - 1
	var boss_r: float = BOSS_RADIUS * _scale
	while last > 2 and not _fits(raw[last], boss_r):
		last -= 1
	spine = raw.slice(0, last + 1)
	_measure(spine)


func _measure(pts: PackedVector2Array) -> void:
	_arc = PackedFloat32Array()
	_arc.resize(pts.size())
	var run: float = 0.0
	for i in range(pts.size()):
		if i > 0:
			run += pts[i - 1].distance_to(pts[i])
		_arc[i] = run
	spine_length = run


# The waypoints the spline runs through. Built in a local frame — `u` across the
# region, `v` down it — then mapped to world space, which keeps the folding
# arithmetic readable and lets the sweep axis be a single flag.
func _serpentine() -> PackedVector2Array:
	var half: Vector2 = extent * 0.5

	# The box the route is allowed to wander in: as large as the boundary rule
	# allows for the BIGGEST disc the lane will place, which is the boss arena.
	# Sized by binary search rather than by a hand-written inset, because the rim
	# is a superellipse and the worst case is the corner of the box, where a
	# straight `half * 0.78 - radius` is wrong by the diagonal. Sizing it for the
	# widest station instead left the final sweep unable to hold the boss, and the
	# trim below then ate a third of the lane.
	var lim: Vector2 = _wander_box(maxf(MAX_STATION_RADIUS, BOSS_RADIUS) * _scale)

	var sideways: bool = Rng.unit1(seed, 3) < 0.5
	var lu: float = lim.y if sideways else lim.x     # along a sweep
	var lv: float = lim.x if sideways else lim.y     # across the sweeps

	# Sweeps have to clear each other by more than two WIDE stations plus a
	# corridor, or two neighbouring folds carve into one shapeless open field and
	# the lane the player walks is no longer the lane that was planned.
	var gap_min: float = (MAX_STATION_RADIUS * 2.0 + 16.0) * _scale
	var rows: int = clampi(int((lv * 2.0) / maxf(gap_min, 1.0)) + 1, 2, 5)
	var gap: float = (lv * 2.0) / float(rows - 1)

	var flip_u: bool = Rng.unit1(seed, 4) < 0.5
	var flip_v: float = 1.0 if Rng.unit1(seed, 5) < 0.5 else -1.0

	const PER_ROW: int = 5
	var out := PackedVector2Array()
	for r in range(rows):
		var v: float = (-lv + gap * float(r)) * flip_v
		# Sweeps alternate direction; that is what makes it a fold rather than a
		# comb with a return leg down the side.
		var forward: bool = ((r % 2) == 0) != flip_u
		# Ends pulled in by a seeded amount per row, so the U-turns do not all
		# line up on the same two columns.
		var ku: float = Rng.range2(seed, r, 41, 0.84, 1.0)
		var u0: float = -ku * lu
		var u1: float = ku * lu
		if not forward:
			var t: float = u0
			u0 = u1
			u1 = t

		for j in range(PER_ROW):
			var f: float = float(j) / float(PER_ROW - 1)
			var u: float = lerpf(u0, u1, f) \
				+ Rng.range2(seed, r * 29 + j, 42, -lu * 0.07, lu * 0.07)
			# A deliberate alternation across the sweep on top of the jitter: pure
			# jitter can roll a nearly straight row, and a straight row is the
			# corridor this generator exists to avoid. Kept inside a fifth of the
			# row spacing so two sweeps still cannot wander into each other.
			var swing: float = (1.0 if (j % 2) == 0 else -1.0) * gap * 0.10
			var vv: float = v + (swing + Rng.range2(seed, r * 29 + j, 43,
				-gap * 0.12, gap * 0.12)) * flip_v
			out.append(_to_world(clampf(u, -lu, lu), clampf(vv, -lv, lv), sideways))

		# The turn. One elbow pushed slightly past the end of the sweep and set
		# between the two rows: without it the spline cuts the corner and the two
		# sweeps meet at a crease the carve cannot make walkable.
		if r < rows - 1:
			var vt: float = (-lv + gap * (float(r) + 0.5)) * flip_v
			var ue: float = clampf(u1 * 1.07, -lu, lu)
			out.append(_to_world(ue, clampf(vt + Rng.range2(seed, r, 44,
				-gap * 0.08, gap * 0.08), -lv, lv), sideways))

	return out


func _to_world(u: float, v: float, sideways: bool) -> Vector2:
	return Vector2(v, u) if sideways else Vector2(u, v)


# Catmull-Rom through a polyline, endpoints duplicated so the curve starts and
# ends exactly on the first and last waypoint. `step` is the sample spacing, so
# the same routine serves both the query spine (fine) and carve ribbons (coarse).
func _spline(w: PackedVector2Array, step: float = SPINE_STEP) -> PackedVector2Array:
	if w.size() < 3:
		return w
	var out := PackedVector2Array()
	for i in range(w.size() - 1):
		var p0: Vector2 = w[maxi(i - 1, 0)]
		var p1: Vector2 = w[i]
		var p2: Vector2 = w[i + 1]
		var p3: Vector2 = w[mini(i + 2, w.size() - 1)]
		var steps: int = maxi(int(p1.distance_to(p2) / step), 2)
		# The segment's own endpoint is left to the next iteration, so no sample
		# is emitted twice (a duplicated point is a zero-length arc step, which
		# shows up later as a flat spot in progress_at).
		for s in range(steps):
			out.append(_catmull(p0, p1, p2, p3, float(s) / float(steps)))
	out.append(w[w.size() - 1])
	return out


# Can a disc of radius `r` sit at `p` clear of the boundary wall?
#
# Tested against the SUPERELLIPSE Terrain actually raises the rim on, pushed out
# from the centre by most of the radius: an axis-aligned `half * 0.78 - r` box is
# wrong at the corners by the diagonal, which is exactly where the lane's U-turns
# put their widest rooms.
#
# FLOOR_CLEAR of the radius rather than all of it. The rim rise is smoothstepped
# over 0.78..1.04 and the carve blends a station's floor out to 2.4r, so the
# outer fifth of a disc may sit in the first centimetres of the rise and still be
# flat, walkable ground — demanding the whole disc clear it would cost a third of
# the usable region for nothing. tools/lanetest.gd proves the result on real
# terrain, not on this estimate.
func _fits(p: Vector2, r: float) -> bool:
	const FLOOR_CLEAR: float = 0.8
	var half: Vector2 = extent * 0.5
	var out: Vector2 = p.normalized() if p.length() > 0.001 else Vector2.RIGHT
	var edge: Vector2 = p + out * (r * FLOOR_CLEAR + RIM_MARGIN)
	return Rng.superellipse(edge, half, 3.2) <= RIM_START


# The largest centred box whose CORNER can still hold a disc of radius `r`, found
# by bisection on _fits. The corner is the worst case, so a box sized by it is
# safe everywhere inside.
func _wander_box(r: float) -> Vector2:
	var half: Vector2 = extent * 0.5
	var lo: float = 0.0
	var hi: float = RIM_START
	for i in range(22):
		var mid: float = (lo + hi) * 0.5
		if _fits(Vector2(half.x * mid, half.y * mid), r):
			lo = mid
		else:
			hi = mid
	return Vector2(maxf(half.x * lo, half.x * 0.12),
		maxf(half.y * lo, half.y * 0.12))


# ---- stations ----------------------------------------------------------------

func _place_stations() -> void:
	if spine.size() < 2:
		return

	var boss_r: float = BOSS_RADIUS * _scale
	_add_station(0.0, ENTRY, ENTRY_RADIUS * _scale)

	# Where the boss floor begins. Nothing else may be placed inside it, or the
	# approach to the arena is already an arena.
	var stop: float = spine_length - (boss_r * 1.25 + 10.0 * _scale)
	var rot: int = int(Rng.unit1(seed, 9) * 97.0)
	var at: float = 0.0
	var r_prev: float = ENTRY_RADIUS * _scale
	var i: int = 1
	while i < 200:
		var beat: int = BEATS[(i + rot) % BEATS.size()]
		var r: float = _radius_for_beat(beat, i)
		# Spacing follows the two discs, so clearings get room and pinches come
		# close together. A fixed spacing would put WIDE stations shoulder to
		# shoulder and merge them.
		var gap: float = (r_prev + r) * 0.85 \
			+ Rng.range2(seed, i, 51, 5.0, 13.0) * _scale
		if at + gap > stop:
			break
		at += gap
		# A station on one sweep must not carve into a station on the next one. The
		# route keeps the sweeps apart, but a WIDE room on each side of the gap can
		# still reach across it, which would merge two stretches of the lane into
		# one field and hand the player a shortcut past everything between them.
		# Shrinking the room is the cheap fix: the rhythm survives, the fold does.
		var p: Vector2 = _point_at_arc(at)
		r = minf(r, maxf(_nearest_dist(p) - 7.0 * _scale, 4.0 * _scale))
		_add_station(at, ARENA, r)
		r_prev = r
		i += 1

	_add_station(spine_length, BOSS, boss_r)
	_link_stations()


func _radius_for_beat(beat: int, i: int) -> float:
	match beat:
		BEAT_PINCH:
			return Rng.range2(seed, i, 52, 4.2, 5.6) * _scale
		BEAT_WIDE:
			return Rng.range2(seed, i, 53, 11.0, MAX_STATION_RADIUS) * _scale
		_:
			return Rng.range2(seed, i, 54, 7.0, 9.4) * _scale


func _add_station(at: float, kind: String, radius: float) -> void:
	var t: float = at / maxf(spine_length, 0.001)
	var ev: float = _elev_at(t)
	if kind == BOSS:
		# Sunk, so the player arrives looking DOWN into the arena. Same reasoning
		# as Layout's boss basin, held to a floor the ramp in can still reach.
		ev = clampf(ev - 0.30, -0.60, -0.20)
	elif kind == ENTRY:
		ev = -0.30
	_add(_point_at_arc(at), kind, radius, ev)
	stations.append(nodes.size() - 1)
	_station_arc.append(at)


func _link_stations() -> void:
	_spine_width = PackedFloat32Array()
	for k in range(stations.size() - 1):
		var a: int = stations[k]
		var b: int = stations[k + 1]
		var ra: float = float(nodes[a]["radius"])
		var rb: float = float(nodes[b]["radius"])
		# The corridor is as wide as the NARROWER of the rooms it joins, which is
		# what turns the station rhythm into a felt change in the route.
		var w: float = clampf(minf(ra, rb) * 0.62
			+ Rng.range2(seed, k, 55, -0.4, 0.7) * _scale,
			3.0 * _scale, 9.6 * _scale)
		if String(nodes[b]["kind"]) == BOSS:
			w = 9.6 * _scale          # the approach to a boss is a processional
		edges.append({
			"a": a, "b": b, "width": w,
			"pts": _carve_slice(_station_arc[k], _station_arc[k + 1]),
		})
		_spine_width.append(w)


# The carve instruction for one stretch of spine: the same curve, resampled at
# the heightfield's resolution and pinned to both station centres.
func _carve_slice(s0: float, s1: float) -> PackedVector2Array:
	var span: float = maxf(s1 - s0, 0.001)
	var steps: int = maxi(int(span / CARVE_STEP), 2)
	var out := PackedVector2Array()
	for s in range(steps + 1):
		out.append(_point_at_arc(s0 + span * float(s) / float(steps)))
	return out


# One smooth field over progress drives the whole elevation profile, so the lane
# climbs and falls as a route. Rolling each station's height independently gives
# a sawtooth that the carve turns into a flight of ramps.
func _elev_at(t: float) -> float:
	var v: float = Rng.fbm(Rng.seed_of(seed, "lane.elev"), t * 3.4, 0.37, 3)
	return clampf(-0.10 + v * 0.55, -0.55, 0.55)


# ---- side pockets ------------------------------------------------------------

func _dig_pockets() -> void:
	if stations.size() < 5:
		return

	# Never off the entrance, the boss, or their immediate neighbours: a detour
	# at the mouth of the lane is taken before the lane is, and one at the boss
	# door is taken after the fight that was the point of the map.
	var cand: Array[int] = []
	for k in range(2, stations.size() - 2):
		cand.append(k)
	_shuffle(cand, 12)

	var want: int = clampi(stations.size() / 4, 2, 6)
	var made: int = 0
	for n in range(cand.size()):
		if made >= want:
			break
		if _branch(cand[n]):
			made += 1


# Fisher-Yates, driven by Rng so the order a map tries its branch sites in is
# part of the seed rather than of the array's construction.
func _shuffle(a: Array[int], salt: int) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j: int = int(Rng.unit2(seed, i, salt) * float(i + 1)) % (i + 1)
		var t: int = a[i]
		a[i] = a[j]
		a[j] = t


func _branch(k: int) -> bool:
	var tan: Vector2 = tangent_at(_station_arc[k] / maxf(spine_length, 0.001))
	var perp: Vector2 = Vector2(-tan.y, tan.x)
	var flip: float = 1.0 if Rng.unit2(seed, k, 61) < 0.5 else -1.0
	for att in range(POCKET_ATTEMPTS):
		var side: Vector2 = perp * (flip if (att % 2) == 0 else -flip)
		# Both sides at full size first, then both a size down, and so on. A
		# smaller room is the LAST resort rather than the first, so the attempt
		# that succeeds is the largest one that fits.
		var tighten: float = 1.0 - float(att / 2) * 0.15
		if _grow(k, side, tighten, att):
			return true
	return false


# One attempt at a pocket off station `k`: one or two rooms out along `side`,
# whose radii are scaled by `tighten`. Returns false, having placed nothing, if
# the first room cannot be made to fit.
func _grow(k: int, side: Vector2, tighten: float, attempt: int) -> bool:
	var from: int = stations[k]
	var p: Vector2 = nodes[from]["pos"]

	# One or two rooms deep. Two is a detour you commit to; one is a nook you can
	# see into from the route, and a lane wants both.
	var links: int = 1 if Rng.unit2(seed, k, 62) < 0.55 else 2
	var prev: int = from
	var tail: int = -1
	for d in range(links):
		# The attempt index is part of the salt, so a retry is a genuinely
		# different placement and not the same one re-rolled at a new size.
		var salt: int = (k * 7 + d) * 13 + attempt
		# Step length is NOT tightened. The room shrinks; the distance the detour
		# leaves the route by does not, because that distance is what makes a
		# pocket a detour rather than a bulge in the lane.
		var step: float = Rng.range2(seed, salt, 63, 15.0, 24.0) * _scale
		# Fanned, so a two-room pocket bends away instead of continuing straight
		# out and reading as a spur of the main route.
		var dir: Vector2 = side.rotated(Rng.range2(seed, salt, 64, -0.55, 0.55))
		var q: Vector2 = p + dir * step
		var r: float = Rng.range2(seed, salt, 65, 5.5, 8.0) * tighten * _scale
		if not _fits(q, r):
			break
		# Clear of every room already placed — RIM to rim, not centre to centre.
		# Layout's _nearest_dist is a centre distance, which is blind to radius: a
		# pocket 24 m from the boss looks clear and is in fact 4 m from the edge of
		# a 20 m arena floor. Seed 206894 bridged a pocket into the boss arena
		# exactly that way and cut 44% off the walk to it.
		if _disc_gap(q, r, from, prev) < 9.0 * _scale:
			break
		# ...AND of every stretch of lane other than the junction it branches
		# from. This is the rule that keeps a lane a lane. A station sitting off
		# the middle of its sweep can throw a 24 m pocket most of the way to the
		# next fold; the pocket then bridges the two, and the player walks
		# diagonally through it past a third of the level. Measured over 32 seeds
		# this cost up to 46% of the route before the rule existed — and it is
		# also what stops a "pocket" being a bulge in the lane rather than a
		# detour off it.
		if _off_lane_distance(q, _station_arc[k], 34.0 * _scale) < r + 10.0 * _scale:
			break
		# A pocket also has to be properly OFF the spine near its own junction,
		# where the rule above is deliberately blind. Without this the detour can
		# sit so close to the route that the player collects it in passing, and
		# the choice the pocket exists to offer is never made.
		if _spine_gap(q) < r + 5.0 * _scale:
			break
		var pts: PackedVector2Array = _bowed(p, q, salt)
		# The CARVED CURVE, not the straight line between the ends: the bow can
		# push the middle of a branch back toward the fold the room itself
		# cleared, and it is the carve that becomes walkable ground.
		var bridged: bool = false
		for pt in pts:
			if _off_lane_distance(pt, _station_arc[k], 34.0 * _scale) < 8.0 * _scale:
				bridged = true
				break
		if bridged:
			break
		# Treasure by default — loot is the reason to leave the route at all.
		# Shrines are the occasional landmark, and are raised so they can be seen
		# from the lane and deliberately walked to.
		var kind: String = SHRINE if Rng.unit2(seed, salt, 66) < 0.28 \
			else TREASURE
		var ev: float = Rng.range2(seed, salt, 67, 0.25, 0.60) \
			if kind == SHRINE else Rng.range2(seed, salt, 68, -0.15, 0.35)
		_add(q, kind, r, ev)
		var id: int = nodes.size() - 1
		edges.append({
			"a": prev, "b": id,
			"width": clampf(r * 0.52, 3.0 * _scale, 4.6 * _scale),
			"pts": pts,
		})
		prev = id
		tail = id
		p = q

	if tail < 0:
		return false
	pockets.append(tail)
	return true


# Smallest gap between the rim of a disc of radius `r` at `q` and the rim of any
# existing node's disc, ignoring the two nodes this one is being linked to.
func _disc_gap(q: Vector2, r: float, skip_a: int, skip_b: int) -> float:
	var best: float = 1e9
	for n in nodes:
		var id: int = int(n["id"])
		if id == skip_a or id == skip_b:
			continue
		best = minf(best, q.distance_to(n["pos"] as Vector2)
			- float(n["radius"]) - r)
	return best


# Distance from `p` to the nearest point of the spine, the whole of it included.
func _spine_gap(p: Vector2) -> float:
	var best: float = 1e9
	for q in spine:
		best = minf(best, p.distance_to(q))
	return best


# Distance from `p` to the lane, ignoring the stretch of it within `window`
# metres of arc either side of `at`. That window is the branch's own junction,
# which is by definition next to the lane; everything outside it is lane the
# pocket must not touch.
func _off_lane_distance(p: Vector2, at: float, window: float) -> float:
	var best: float = 1e9
	for i in range(spine.size()):
		if absf(_arc[i] - at) <= window:
			continue
		best = minf(best, p.distance_to(spine[i]))
	return best


# A bowed path between two points — Layout's reasoning, kept: a straight branch
# reads as machine-made, and the bow is what makes a pocket worth peering into.
#
# BUT IT RUNS END TO END, which Layout's does not. Layout hands its four points
# straight to _catmull, and a Catmull-Rom segment spans the MIDDLE TWO of its
# four: those corridors therefore begin a third of the way along the edge and
# stop two thirds along, offset sideways by the bow. Inside a 17 m arena disc,
# with a carve skirt reaching 2.4r, that is invisible. Off a 5.7 m pocket it is a
# metre of UNCARVED GROUND between the branch and the room it leads to — the
# sweep's A* refused 13 of 85 pockets for exactly that reason. So the bow points
# go through _spline, which duplicates the endpoints and therefore touches both.
# Layout keeps its own behaviour; it is the PvP generator and is not being
# touched, and its discs are large enough to hide it.
func _bowed(a: Vector2, b: Vector2, i: int) -> PackedVector2Array:
	var along: Vector2 = b - a
	var len_: float = along.length()
	if len_ < 0.001:
		return PackedVector2Array([a])
	var side: Vector2 = Vector2(-along.y, along.x) / len_
	# Shallower than Layout's 0.20: the spline now passes THROUGH these points
	# rather than between them, so the same offset buys a stronger curve.
	var bow: float = minf(len_ * 0.16, 5.0)
	return _spline(PackedVector2Array([
		a,
		a + along * 0.33 + side * Rng.range2(seed, i, 81, -bow, bow),
		a + along * 0.66 + side * Rng.range2(seed, i, 82, -bow, bow),
		b,
	]), CARVE_STEP)


# ---- exit --------------------------------------------------------------------

func _place_exit() -> void:
	var boss: Dictionary = node_of_kind(BOSS)
	if boss.is_empty():
		return
	var bp: Vector2 = boss["pos"]
	var r: float = EXIT_RADIUS * _scale
	var reach: float = float(boss["radius"]) * 0.95 + r

	# Beyond the boss, on the heading the lane arrived on: you leave through the
	# thing you killed. But the boss arena is already as far into the corner as
	# the region allows, so "beyond" often has nowhere to go — walk the offset
	# back in until the exit floor fits, and if none of it does, leave through
	# the inside of the region instead.
	#
	# A CLAMP IS NOT ENOUGH, which is the bug Layout shipped: clamping each axis
	# to `half * 0.78 - r` puts the node at a corner where the superellipse rim
	# has already risen, and the exit is buried in a cliff. Measured at 0.822
	# against a rim that starts at 0.78 before this was placed through _fits.
	var dir: Vector2 = tangent_at(1.0)
	var out: Vector2 = bp + (bp.normalized() * -1.0 if bp.length() > 0.001
		else Vector2.RIGHT) * reach
	for i in range(8):
		var cand: Vector2 = bp + dir * (reach * (1.0 - float(i) * 0.09))
		if _fits(cand, r):
			out = cand
			break
	_add(out, EXIT, r, -0.30)
	var id: int = nodes.size() - 1
	edges.append({
		"a": int(boss["id"]), "b": id, "width": 7.0 * _scale,
		"pts": _bowed(bp, out, 777),
	})


# ------------------------------------------------------------------------------
# Progress queries — what the encounter system places spawns by
# ------------------------------------------------------------------------------

func total_length() -> float:
	return spine_length


## World position at progress `t` in 0..1, measured by ARC LENGTH, so equal steps
## in t are equal distances walked. Parameterising by sample index instead would
## bunch spawns up wherever the spline sampled densely.
func position_at(t: float) -> Vector2:
	return _point_at_arc(clampf(t, 0.0, 1.0) * spine_length)


## Unit heading of the lane at progress `t`.
func tangent_at(t: float) -> Vector2:
	if spine.size() < 2:
		return Vector2.RIGHT
	var s: float = clampf(t, 0.0, 1.0) * spine_length
	var i: int = _sample_at_arc(s)
	var j: int = mini(i + 1, spine.size() - 1)
	if i == j:
		i = maxi(j - 1, 0)
	var d: Vector2 = spine[j] - spine[i]
	return d.normalized() if d.length() > 0.0001 else Vector2.RIGHT


## How far along the lane a world point is, 0..1. The inverse of position_at,
## and what turns "where is the player" into "how far in are they" for encounter
## density, music and the dread curve.
func progress_at(p: Vector2) -> float:
	if spine.is_empty():
		return 0.0
	var best: int = 0
	var best_d: float = 1e18
	for i in range(spine.size()):
		var d: float = p.distance_squared_to(spine[i])
		if d < best_d:
			best_d = d
			best = i
	return _arc[best] / maxf(spine_length, 0.001)


## Carved width of the lane at progress `t`, in metres: the corridor width,
## widened to the full diameter of a station wherever one is near. This is the
## number that varies — pinch points and clearings — and it is read from the same
## nodes and edges Terrain carves, so it describes the ground, not an intention.
func width_at(t: float) -> float:
	if stations.size() < 2:
		return 0.0
	var s: float = clampf(t, 0.0, 1.0) * spine_length
	var k: int = _station_before(s)
	var w: float = _spine_width[k]
	for e in [k, k + 1]:
		var r: float = float(nodes[stations[e]]["radius"])
		var infl: float = Rng.smoothstep01(r, r * 0.45,
			absf(s - _station_arc[e]))
		w = maxf(w, lerpf(w, r * 2.0, infl))
	return w


## Progress of the k-th station along the lane, 0..1.
func station_progress(k: int) -> float:
	if _station_arc.is_empty():
		return 0.0
	var i: int = clampi(k, 0, _station_arc.size() - 1)
	return _station_arc[i] / maxf(spine_length, 0.001)


# ---- internals ---------------------------------------------------------------

# Index of the last spine sample at or before arc length `s`. Binary search: a
# linear walk here would be fine for one call and quadratic for a spawn table.
func _sample_at_arc(s: float) -> int:
	if _arc.size() < 2:
		return 0
	var lo: int = 0
	var hi: int = _arc.size() - 1
	while lo < hi - 1:
		var mid: int = (lo + hi) / 2
		if _arc[mid] <= s:
			lo = mid
		else:
			hi = mid
	return lo


func _point_at_arc(s: float) -> Vector2:
	if spine.is_empty():
		return Vector2.ZERO
	if spine.size() == 1:
		return spine[0]
	var c: float = clampf(s, 0.0, spine_length)
	var i: int = _sample_at_arc(c)
	var j: int = mini(i + 1, spine.size() - 1)
	var span: float = _arc[j] - _arc[i]
	if span <= 0.0001:
		return spine[i]
	return spine[i].lerp(spine[j], (c - _arc[i]) / span)


# Index into `stations` of the station at or before arc length `s`, capped so
# `k + 1` is always a valid station.
func _station_before(s: float) -> int:
	var k: int = 0
	for i in range(_station_arc.size()):
		if _station_arc[i] <= s:
			k = i
	return clampi(k, 0, stations.size() - 2)
