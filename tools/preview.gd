extends SceneTree
# ------------------------------------------------------------------------------
# Headless generation preview. Writes PNGs of generated regions so the output can
# be JUDGED BY EYE rather than by whether the generator exited zero.
#
# This harness exists because on Blockle Idle twenty builds passed headless
# validation and the result still looked bad — nobody had looked at it. Every
# change to the generator gets rendered and viewed.
#
#   godot --headless --script tools/preview.gd -- [biome ...]
#
# Shading here deliberately mimics what the 3D mesher will do (directional key
# on the surface normal, ambient fill, AO multiply, aerial haze), so the preview
# predicts the in-game look instead of being a pretty lie.
# ------------------------------------------------------------------------------

const OUT_DIR := "res://tools/out"
# 384 cells at 0.5 m is the same 192 m region at double resolution — the first
# previews were 192 px and far too coarse to judge detail by eye.
const CELLS := 384
const CELL := 0.5


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var args := OS.get_cmdline_user_args()
	var biomes: Array = []
	if args.is_empty():
		biomes = ["greenwood", "frostcrag", "molten", "mistmoor",
			"voidrift", "throne"]
	else:
		for a in args:
			biomes.append(String(a))

	var report: Array[String] = []

	for i in range(biomes.size()):
		var bid: String = biomes[i]
		if not Biome.TABLE.has(bid):
			print("  ?? unknown biome: ", bid)
			continue
		var world_seed: int = 1000 + i * 7919
		var t0: int = Time.get_ticks_msec()

		var plan := Layout.generate(world_seed, Vector2(CELLS * CELL, CELLS * CELL),
			Layout.Sym.ASYMMETRIC, 11)
		var ter := Terrain.generate(world_seed, bid, CELLS, CELL, plan)

		var ms: int = Time.get_ticks_msec() - t0
		var entry: Dictionary = plan.node_of_kind(Layout.ENTRY)
		var start: Vector2 = ter.nearest_walkable(entry.get("pos", Vector2.ZERO))
		var wf: float = ter.walkable_fraction()
		var rf: float = ter.reachable_fraction(start)

		_render(ter, plan, "%s/%s.png" % [OUT_DIR, bid])
		_render_walk(ter, plan, "%s/%s_walk.png" % [OUT_DIR, bid])

		var nc: float = ter.nodes_connected(plan, start)
		var line := "%-11s %5d ms  relief %5.1f m  walk %4.1f%%  reach %5.1f%%  NODES-CONNECTED %5.1f%%  (%d nodes, %d edges)" % [
			bid, ms, ter.h_max - ter.h_min, wf * 100.0, rf * 100.0, nc * 100.0,
			plan.nodes.size(), plan.edges.size()]
		report.append(line)
		print(line)

	# A PvP arena too — the symmetry is the thing to verify by eye.
	var pplan := Layout.generate(4242, Vector2(CELLS * CELL, CELLS * CELL),
		Layout.Sym.ROTATIONAL, 11)
	var pter := Terrain.generate(4242, "shimmer", CELLS, CELL, pplan)
	_render(pter, pplan, "%s/pvp_shimmer.png" % OUT_DIR)
	var spawns := pplan.nodes_of_kind(Layout.SPAWN)
	var ps: Vector2 = pter.nearest_walkable(spawns[0]["pos"] if spawns.size() > 0 else Vector2.ZERO)
	print("pvp         rotational  walk %4.1f%%  reach %5.1f%%  NODES-CONNECTED %5.1f%%  (spawns %d)" % [
		pter.walkable_fraction() * 100.0, pter.reachable_fraction(ps) * 100.0,
		pter.nodes_connected(pplan, ps) * 100.0, spawns.size()])

	print("\nwrote ", ProjectSettings.globalize_path(OUT_DIR))
	quit()


# ------------------------------------------------------------------------------
# Lit render — predicts the in-game surface
# ------------------------------------------------------------------------------

func _render(t: Terrain, plan: Layout, path: String) -> void:
	# Shading comes from Shade.gd, the SAME function the in-game mesher calls,
	# so this preview predicts the shipped look instead of being a pretty lie.
	var img := Image.create(t.size, t.size, false, Image.FORMAT_RGB8)
	for y in range(t.size):
		for x in range(t.size):
			img.set_pixel(x, y, Shade.shaded(t, x, y))
	_overlay(img, t, plan)
	img.save_png(ProjectSettings.globalize_path(path))


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
