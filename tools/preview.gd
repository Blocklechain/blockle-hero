extends SceneTree
# ------------------------------------------------------------------------------
# Headless generation preview. Writes PNGs of generated regions so the output can
# be JUDGED BY EYE rather than by whether the generator exited zero.
#
# This harness exists because on Blockle Idle twenty builds passed headless
# validation and the result still looked bad — nobody had looked at it. Every
# change to the generator gets rendered and viewed.
#
#   godot --headless --script tools/preview.gd -- [lane|arena|both] [biome ...]
#
# BOTH LAYOUT KINDS ARE PREVIEWED, because both ship: `arena` is Layout.gd (and
# PvP's rotational mode), `lane` is Lane.gd and the campaign. They are rendered
# through the same code with the same biome, so the question "did the lane lose
# the arena's art" is answered by putting the two images side by side rather than
# by reading the generator.
#
# Shading here deliberately mimics what the 3D mesher will do (directional key
# on the surface normal, ambient fill, AO multiply, aerial haze), so the preview
# predicts the in-game look instead of being a pretty lie.
#
# THREE IMAGES PER REGION:
#   <biome>[_lane].png        lit terrain, with the plan's nodes ringed
#   <biome>[_lane]_life.png   the same ground WITH ITS PROPS AND GROUND COVER,
#                             which is most of what the player actually sees. The
#                             terrain-only render cannot show whether a biome's
#                             prop and cover tables reached the map at all, and
#                             on a lane that is exactly the claim under test.
#   <biome>[_lane]_walk.png   walkable green / blocked red / water blue / path
# ------------------------------------------------------------------------------

const OUT_DIR := "res://tools/out"
# 384 cells at 0.5 m is the same 192 m region at double resolution — the first
# previews were 192 px and far too coarse to judge detail by eye.
const CELLS := 384
const CELL := 0.5

# Props are drawn from the real meshes Props.build() returns, so the dot colour
# and footprint come from the shipping art rather than from a guess here. One
# build per (kind, variant, biome) is cached; there are a few dozen.
var _prop_look: Dictionary = {}


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var args := OS.get_cmdline_user_args()
	var kinds: Array[int] = []
	var biomes: Array = []
	for a in args:
		var s := String(a)
		match s:
			"lane": kinds.append(Terrain.Kind.LANE)
			"arena": kinds.append(Terrain.Kind.ARENA)
			"both": kinds = [Terrain.Kind.ARENA, Terrain.Kind.LANE]
			_: biomes.append(s)
	if kinds.is_empty():
		kinds = [Terrain.Kind.ARENA, Terrain.Kind.LANE]
	if biomes.is_empty():
		biomes = ["greenwood", "frostcrag", "molten", "mistmoor",
			"voidrift", "throne"]

	for kind in kinds:
		var label: String = "lane" if kind == Terrain.Kind.LANE else "arena"
		print("\n=== %s layouts ===" % label)
		for i in range(biomes.size()):
			var bid: String = biomes[i]
			if not Biome.TABLE.has(bid):
				print("  ?? unknown biome: ", bid)
				continue
			# Same seed per biome in both kinds, so the two renders differ only in
			# the plan carved into them.
			_region(kind, bid, 1000 + i * 7919)

	# A PvP arena too — the symmetry is the thing to verify by eye.
	var pplan := Layout.generate(4242, Vector2(CELLS * CELL, CELLS * CELL),
		Layout.Sym.ROTATIONAL, 11)
	var pter := Terrain.generate(4242, "shimmer", CELLS, CELL, pplan)
	_render(pter, pplan, "%s/pvp_shimmer.png" % OUT_DIR)
	var spawns := pplan.nodes_of_kind(Layout.SPAWN)
	var ps: Vector2 = pter.nearest_walkable(spawns[0]["pos"] if spawns.size() > 0 else Vector2.ZERO)
	print("\npvp         rotational  walk %4.1f%%  reach %5.1f%%  NODES-CONNECTED %5.1f%%  (spawns %d)" % [
		pter.walkable_fraction() * 100.0, pter.reachable_fraction(ps) * 100.0,
		pter.nodes_connected(pplan, ps) * 100.0, spawns.size()])

	print("\nwrote ", ProjectSettings.globalize_path(OUT_DIR))
	quit()


# One region: generate, measure, render.
func _region(kind: int, bid: String, world_seed: int) -> void:
	var suffix: String = "_lane" if kind == Terrain.Kind.LANE else ""
	var t0: int = Time.get_ticks_msec()

	var plan: Layout = Terrain.plan_for(kind, world_seed,
		Vector2(CELLS * CELL, CELLS * CELL), Layout.Sym.ASYMMETRIC, 11)
	var ter := Terrain.generate(world_seed, bid, CELLS, CELL, plan)
	var ms: int = Time.get_ticks_msec() - t0

	# Props and cover are generated here, not just rendered: the life render has
	# to show the SAME placements the game will build MultiMeshes from.
	var scat := Scatter.generate(ter, plan, world_seed)

	var entry: Dictionary = plan.node_of_kind(Layout.ENTRY)
	var start: Vector2 = ter.nearest_walkable(entry.get("pos", Vector2.ZERO))
	var wf: float = ter.walkable_fraction()
	var rf: float = ter.reachable_fraction(start)

	_render(ter, plan, "%s/%s%s.png" % [OUT_DIR, bid, suffix])
	_render_life(ter, scat, "%s/%s%s_life.png" % [OUT_DIR, bid, suffix])
	_render_walk(ter, plan, "%s/%s%s_walk.png" % [OUT_DIR, bid, suffix])

	var nc: float = ter.nodes_connected(plan, start)
	print("%-11s %5d ms  relief %5.1f m  walk %4.1f%%  reach %5.1f%%  NODES-CONNECTED %5.1f%%  (%d nodes, %d edges)  props %5d  cover %6d" % [
		bid, ms, ter.h_max - ter.h_min, wf * 100.0, rf * 100.0, nc * 100.0,
		plan.nodes.size(), plan.edges.size(), scat.items.size(),
		scat.cover.size()])

	if ter.is_lane():
		var lane: Lane = plan as Lane
		# ROUTE reachability, not just node reachability: a lane is one thread and
		# a severed stretch between two stations is a broken campaign map even
		# when every station is in the same walkable blob.
		var lr: float = ter.lane_reachable_fraction(lane, start)
		var w_lo: float = 1e9
		var w_hi: float = 0.0
		for s in range(81):
			var w: float = lane.width_at(float(s) / 80.0)
			w_lo = minf(w_lo, w)
			w_hi = maxf(w_hi, w)
		print("            lane %5.0f m  LANE-REACHABLE %5.1f%%  width %.1f-%.1f m  (%d stations, %d pockets)" % [
			lane.spine_length, lr * 100.0, w_lo, w_hi,
			lane.stations.size(), lane.pockets.size()])


# ------------------------------------------------------------------------------
# Lit render — predicts the in-game surface
# ------------------------------------------------------------------------------

func _shaded_image(t: Terrain) -> Image:
	# Shading comes from Shade.gd, the SAME function the in-game mesher calls,
	# so this preview predicts the shipped look instead of being a pretty lie.
	var img := Image.create(t.size, t.size, false, Image.FORMAT_RGB8)
	for y in range(t.size):
		for x in range(t.size):
			img.set_pixel(x, y, Shade.shaded(t, x, y))
	return img


func _render(t: Terrain, plan: Layout, path: String) -> void:
	var img := _shaded_image(t)
	_overlay(img, t, plan)
	img.save_png(ProjectSettings.globalize_path(path))


# ------------------------------------------------------------------------------
# Life render — the ground plus everything growing on it
# ------------------------------------------------------------------------------

# Top-down, so a prop is a disc the size of its own mesh with a shadow cast in
# the sun direction Shade uses. Crude as a picture of a tree, but it answers the
# questions that matter: are props there, do they cluster, do they stay off the
# route and out of the fighting floors, and is the cover table reaching the
# ground at all.
func _render_life(t: Terrain, scat: Scatter, path: String) -> void:
	var img := _shaded_image(t)
	var b: Dictionary = Biome.get_biome(t.biome_id)
	var half: float = float(t.size) * t.cell * 0.5
	var span: float = maxf(t.h_max - t.h_min, 0.0001)
	# Shade.SUN_DIR points TOWARD the light, so a shadow falls the other way.
	var sun_xz := Vector2(-Shade.SUN_DIR.x, -Shade.SUN_DIR.z).normalized()

	for it in scat.cover:
		var look: Dictionary = _look(String(it["kind"]), int(it["variant"]),
			t.biome_id)
		var p: Vector3 = it["pos"]
		_splat(img, t, b, span, int((p.x + half) / t.cell),
			int((p.z + half) / t.cell), 0, look["col"], 0.62)

	# Shadows for every prop first, then the props, so one tree's canopy is not
	# darkened by its own shadow.
	for it in scat.items:
		var look: Dictionary = _look(String(it["kind"]), int(it["variant"]),
			t.biome_id)
		var p: Vector3 = it["pos"]
		var scl: float = float(it["scale"])
		var off: Vector2 = sun_xz * float(look["height"]) * scl * 0.55
		_shadow(img, t, int((p.x + off.x + half) / t.cell),
			int((p.z + off.y + half) / t.cell),
			_radius_cells(t, float(look["radius"]) * scl))
	for it in scat.items:
		var look2: Dictionary = _look(String(it["kind"]), int(it["variant"]),
			t.biome_id)
		var p2: Vector3 = it["pos"]
		var scl2: float = float(it["scale"])
		_splat(img, t, b, span, int((p2.x + half) / t.cell),
			int((p2.z + half) / t.cell),
			_radius_cells(t, float(look2["radius"]) * scl2), look2["col"], 1.0)

	img.save_png(ProjectSettings.globalize_path(path))


func _radius_cells(t: Terrain, metres: float) -> int:
	return clampi(int(round(metres / t.cell)), 0, 12)


# Draw a prop or a tuft, lit through Shade.light so it sits in the same key,
# ambient and aerial haze as the ground under it.
func _splat(img: Image, t: Terrain, b: Dictionary, span: float, cx: int, cy: int,
		r: int, col: Color, weight: float) -> void:
	if not t.in_bounds(cx, cy):
		return
	var i: int = t.idx(cx, cy)
	var alt: float = clampf((t.h[i] - t.h_min) / span, 0.0, 1.0)
	var lit: Color = Shade.light(col, Vector3.UP, t.ao[i], alt, b)
	var r2: int = r * r
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			if not t.in_bounds(x, y):
				continue
			var dx: int = x - cx
			var dy: int = y - cy
			if r > 0 and dx * dx + dy * dy > r2:
				continue
			# Edge pixels blend, so a canopy has a soft rim instead of aliasing
			# into a hard circle that reads as a sticker.
			var edge: float = 1.0
			if r > 1:
				edge = clampf(1.0 - (sqrt(float(dx * dx + dy * dy)) / float(r))
					* 0.55, 0.0, 1.0)
			img.set_pixel(x, y, img.get_pixel(x, y).lerp(lit,
				clampf(weight * edge, 0.0, 1.0)))


func _shadow(img: Image, t: Terrain, cx: int, cy: int, r: int) -> void:
	var r2: int = r * r
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			if not t.in_bounds(x, y):
				continue
			var dx: int = x - cx
			var dy: int = y - cy
			if r > 0 and dx * dx + dy * dy > r2:
				continue
			img.set_pixel(x, y, (img.get_pixel(x, y) * 0.74).clamp())


# Mean vertex colour and footprint of a real prop mesh. The colours in the mesh
# are LINEAR (Props converts on the way in) and their alpha is emission, not
# opacity, so only rgb is averaged and it is converted back for display.
func _look(kind: String, variant: int, biome_id: String) -> Dictionary:
	var key: String = "%s#%d#%s" % [kind, variant, biome_id]
	if _prop_look.has(key):
		return _prop_look[key]

	var out: Dictionary = {"col": Color(0.45, 0.45, 0.42), "radius": 0.35,
		"height": 0.5}
	var mesh: ArrayMesh = Props.build(kind, biome_id, variant)
	if mesh != null and mesh.get_surface_count() > 0:
		var arr: Array = mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var cols: Variant = arr[Mesh.ARRAY_COLOR]
		var rad: float = 0.0
		var hgt: float = 0.0
		for v in verts:
			rad = maxf(rad, sqrt(v.x * v.x + v.z * v.z))
			hgt = maxf(hgt, v.y)
		out["radius"] = rad
		out["height"] = hgt
		if cols != null:
			var cc: PackedColorArray = cols
			var acc := Vector3.ZERO
			for c in cc:
				acc += Vector3(c.r, c.g, c.b)
			if cc.size() > 0:
				acc /= float(cc.size())
				out["col"] = Color(acc.x, acc.y, acc.z).linear_to_srgb()
	_prop_look[key] = out
	return out


# ------------------------------------------------------------------------------
# Debug overlays
# ------------------------------------------------------------------------------

func _overlay(img: Image, t: Terrain, plan: Layout) -> void:
	var half: float = float(t.size) * t.cell * 0.5
	for n in plan.nodes:
		var p: Vector2 = n["pos"]
		var cx: int = int((p.x + half) / t.cell)
		var cy: int = int((p.y + half) / t.cell)
		var col: Color = _kind_colour(String(n["kind"]))
		_ring(img, cx, cy, int(float(n["radius"]) / t.cell), col)
		_dot(img, cx, cy, 2, col)


func _kind_colour(kind: String) -> Color:
	match kind:
		Layout.ENTRY: return Color(0.35, 1.0, 0.45)
		Layout.EXIT: return Color(0.4, 0.75, 1.0)
		Layout.BOSS: return Color(1.0, 0.25, 0.3)
		Layout.SHRINE: return Color(1.0, 0.9, 0.35)
		Layout.TREASURE: return Color(1.0, 0.6, 0.2)
		Layout.SPAWN: return Color(0.6, 1.0, 1.0)
		_: return Color(1.0, 1.0, 1.0)


func _ring(img: Image, cx: int, cy: int, r: int, col: Color) -> void:
	if r <= 0:
		return
	var steps: int = maxi(r * 8, 24)
	for s in range(steps):
		var a: float = float(s) / float(steps) * TAU
		var x: int = cx + int(round(cos(a) * float(r)))
		var y: int = cy + int(round(sin(a) * float(r)))
		if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
			img.set_pixel(x, y, col)


func _dot(img: Image, cx: int, cy: int, r: int, col: Color) -> void:
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				img.set_pixel(x, y, col)


# ------------------------------------------------------------------------------
# Walkability render — green walkable, red blocked, blue water
# ------------------------------------------------------------------------------

func _render_walk(t: Terrain, plan: Layout, path: String) -> void:
	var img := Image.create(t.size, t.size, false, Image.FORMAT_RGB8)
	var span: float = maxf(t.h_max - t.h_min, 0.0001)
	for y in range(t.size):
		for x in range(t.size):
			var i: int = t.idx(x, y)
			var shade: float = 0.45 + 0.55 * ((t.h[i] - t.h_min) / span)
			var c: Color
			if t.surf[i] == Terrain.Surf.WATER:
				c = Color(0.15, 0.35, 0.70)
			elif t.walk[i] == 1:
				c = Color(0.20, 0.72, 0.30)
			else:
				c = Color(0.72, 0.20, 0.22)
			if t.surf[i] == Terrain.Surf.PATH and t.walk[i] == 1:
				c = Color(0.95, 0.85, 0.45)
			img.set_pixel(x, y, (c * shade).clamp())
	_overlay(img, t, plan)
	img.save_png(ProjectSettings.globalize_path(path))
