class_name Pathing
extends RefCounted
# ------------------------------------------------------------------------------
# Click-to-move pathfinding over the terrain's walkability grid.
#
# Uses Godot's built-in `AStarGrid2D`, which is C++ — and after discovering that
# GDScript costs roughly 140x native on the noise, hand-rolling A* here would be
# exactly the same mistake twice.
#
# The grid is the walk mask the terrain already produces, so what the pathfinder
# believes is walkable is by construction what the generator marked walkable.
# There is no second source of truth to drift.
# ------------------------------------------------------------------------------

var _grid: AStarGrid2D
var _t: Terrain


func _init(terrain: Terrain) -> void:
	_t = terrain
	_grid = AStarGrid2D.new()
	_grid.region = Rect2i(0, 0, terrain.size, terrain.size)
	_grid.cell_size = Vector2(terrain.cell, terrain.cell)
	# Diagonals only when both orthogonal neighbours are open, so a path never
	# squeezes through the corner gap between two blocked cells — which reads as
	# the hero clipping through scenery.
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_grid.update()

	for y in range(terrain.size):
		for x in range(terrain.size):
			if terrain.walk[y * terrain.size + x] != 1:
				_grid.set_point_solid(Vector2i(x, y), true)


func to_cell(p: Vector2) -> Vector2i:
	var half: float = float(_t.size) * _t.cell * 0.5
	return Vector2i(
		clampi(int((p.x + half) / _t.cell), 0, _t.size - 1),
		clampi(int((p.y + half) / _t.cell), 0, _t.size - 1))


func is_walkable(p: Vector2) -> bool:
	var c: Vector2i = to_cell(p)
	return _t.walk[c.y * _t.size + c.x] == 1


# Path between two world-space points, as world XZ waypoints — ONE PER CELL,
# deliberately unsmoothed. Empty if no route.
#
# Smoothing used to happen here, once, from the path's first cell. That is a
# trap: the hero then follows long straight legs computed from a position it is
# no longer at, and any drift can put a step into a blocked cell — after which
# re-planning produces the same first leg and the hero deadlocks on the spot.
#
# The raw cell path is always valid by construction (every waypoint is a
# walkable cell adjacent to the last), so the follower can trust it absolutely.
# Corner-cutting is the follower's job, re-checked from where the hero actually
# is — see HeroController._lookahead().
func find(from: Vector2, to: Vector2) -> PackedVector2Array:
	var a: Vector2i = to_cell(from)
	var b: Vector2i = to_cell(to)

	# Tapping a cliff, a lake or a tree is normal play, not an error — walk to
	# the nearest reachable cell instead of refusing to move.
	if _grid.is_point_solid(b):
		b = to_cell(_t.nearest_walkable(to))
	if _grid.is_point_solid(a):
		a = to_cell(_t.nearest_walkable(from))
	if _grid.is_point_solid(a) or _grid.is_point_solid(b):
		return PackedVector2Array()

	var cells: PackedVector2Array = _grid.get_point_path(a, b)
	if cells.size() < 2:
		return PackedVector2Array()

	# AStarGrid2D returns positions scaled from the grid origin; the world is
	# centred on zero, so shift them — and offset to the CELL CENTRE.
	#
	# Terrain uses a corner convention (pos_of() returns a cell's origin), which
	# is right for mesh vertices and wrong for waypoints: a path of corners runs
	# exactly along the boundary between cells, so a line-of-sight ray from one
	# immediately enters the neighbour. When that neighbour is solid, the hero
	# is "blocked" while standing on walkable ground. Centres keep every ray in
	# cell interiors where the answer is unambiguous.
	var half: float = float(_t.size) * _t.cell * 0.5
	var mid: float = _t.cell * 0.5
	var out := PackedVector2Array()
	for c in cells:
		out.append(Vector2(c.x - half + mid, c.y - half + mid))
	return out


# The centre of the nearest walkable cell. Terrain.nearest_walkable() hands back
# a corner; see the note above for why that is not a safe place to stand.
func nearest_walkable_centre(p: Vector2) -> Vector2:
	var mid: float = _t.cell * 0.5
	return _t.nearest_walkable(p) + Vector2(mid, mid)


# Is the straight line between two points walkable end to end?
#
# This is a SUPERCOVER GRID TRAVERSAL (Amanatides-Woo), not point sampling.
# Sampling the segment at fixed intervals is the obvious implementation and it
# is wrong twice over: a blocked cell nearer than the first sample is never
# tested at all, and a line clipping the corner of a cell can step over it
# entirely. Both produce the same symptom — the follower believes it has a clear
# line, walks one frame, lands in a solid cell, and deadlocks there.
#
# The traversal below visits EVERY cell the segment touches, so a "clear" answer
# is exact rather than probable.
func clear_line(a: Vector2, b: Vector2) -> bool:
	var half: float = float(_t.size) * _t.cell * 0.5
	var ax: float = (a.x + half) / _t.cell
	var ay: float = (a.y + half) / _t.cell
	var bx: float = (b.x + half) / _t.cell
	var by: float = (b.y + half) / _t.cell

	var x: int = int(floor(ax))
	var y: int = int(floor(ay))
	var ex: int = int(floor(bx))
	var ey: int = int(floor(by))
	if not _open(x, y):
		return false

	var dx: float = bx - ax
	var dy: float = by - ay
	var step_x: int = 1 if dx > 0.0 else -1
	var step_y: int = 1 if dy > 0.0 else -1

	# Distance (in t along the segment) to the next cell boundary on each axis,
	# and how much t one whole cell costs. Infinity when an axis does not move.
	var t_max_x: float = INF
	var t_delta_x: float = INF
	if absf(dx) > 1e-9:
		var next_x: float = float(x + (1 if step_x > 0 else 0))
		t_max_x = (next_x - ax) / dx
		t_delta_x = 1.0 / absf(dx)

	var t_max_y: float = INF
	var t_delta_y: float = INF
	if absf(dy) > 1e-9:
		var next_y: float = float(y + (1 if step_y > 0 else 0))
		t_max_y = (next_y - ay) / dy
		t_delta_y = 1.0 / absf(dy)

	# Bounded by the cells the segment can possibly cross, so a degenerate input
	# cannot spin here forever.
	var guard: int = absi(ex - x) + absi(ey - y) + 2
	while guard > 0:
		guard -= 1
		if x == ex and y == ey:
			return true
		if t_max_x < t_max_y:
			t_max_x += t_delta_x
			x += step_x
		else:
			t_max_y += t_delta_y
			y += step_y
		if not _open(x, y):
			return false
	return true


# ------------------------------------------------------------------------------
# REACHABILITY, which is not the same question as walkability.
#
# is_walkable() answers "is this cell open", and a cell can be open while
# sitting in a pocket the player cannot get to. Encounter placement used the
# walkable test alone, so five of the hundred campaign maps put the BOSS in a
# sealed pocket — walkable, visible on no path, and unkillable. The region
# then never clears, and because region N+1 is sealed until N is cleared, the
# campaign stops there.
#
# This is a FLOOD FILL rather than a path query because of what it costs to
# say NO. A failed A* explores the entire connected component before giving
# up, and placement wants a dozen tries — so a dozen refusals is a dozen full
# sweeps of a 200,000-cell grid, on a phone, during generation. One fill does
# the same work once and then answers in constant time.
# ------------------------------------------------------------------------------

## Every cell reachable from `origin`, as a mask parallel to Terrain.walk.
##
## Pass it back to in_region() to test a point. Built once per placement pass,
## because the answer is the same for every spawn in a region.
func region_from(origin: Vector2) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(_t.size * _t.size)
	var start: Vector2i = to_cell(origin)
	if not _open(start.x, start.y):
		start = to_cell(_t.nearest_walkable(origin))
	if not _open(start.x, start.y):
		# Nothing is walkable anywhere near the origin. An empty mask is the
		# honest answer; the caller falls back rather than trusting it.
		return mask

	var queue := PackedInt32Array([start.y * _t.size + start.x])
	mask[start.y * _t.size + start.x] = 1
	var head: int = 0
	while head < queue.size():
		var at: int = queue[head]
		head += 1
		var x: int = at % _t.size
		var y: int = at / _t.size
		# FOUR-WAY, deliberately. The grid allows diagonals only when both
		# orthogonal neighbours are open, so a four-way fill can never claim
		# a cell A* would refuse to route to — it is the conservative
		# direction, and being conservative here means never promising a
		# route that does not exist.
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1),
				Vector2i(0, -1)]:
			var nx: int = x + d.x
			var ny: int = y + d.y
			if not _open(nx, ny):
				continue
			var ni: int = ny * _t.size + nx
			if mask[ni] == 1:
				continue
			mask[ni] = 1
			queue.append(ni)
	return mask


## Is `p` inside a mask from region_from()? An empty mask answers false for
## everything, which is what makes a failed fill fall through to a fallback
## rather than silently approving every point.
func in_region(mask: PackedByteArray, p: Vector2) -> bool:
	if mask.size() != _t.size * _t.size:
		return false
	var c: Vector2i = to_cell(p)
	return mask[c.y * _t.size + c.x] == 1


## How many cells the mask covers. Used to tell "the fill failed" from "the
## region really is tiny".
static func region_size(mask: PackedByteArray) -> int:
	var n: int = 0
	for b in mask:
		if b == 1:
			n += 1
	return n


func _open(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= _t.size or y >= _t.size:
		return false
	return _t.walk[y * _t.size + x] == 1
