extends SceneTree
# ------------------------------------------------------------------------------
# THE DREAD CURVE, LOOKED AT. One map, four moods, side by side.
#
#   godot --headless --path . --script tools/dreadshots.gd -- [biome ...]
#
# Writes tools/out/dread_<biome>.png: a strip of four renders of THE SAME REGION
# — same seed, same lane, same props in the same places — at dread 0.00, 0.33,
# 0.66 and 1.00, left to right. Nothing in the image varies except light, colour
# and air, because the dread shift is forbidden from touching terrain parameters
# (tools/dreadtest.gd proves the heightfield is bit-identical across the four).
# That is what makes the strip evidence: any difference you can see is the
# curve, not a different map.
#
# Also writes tools/out/dread_campaign.png, which is not one biome but the
# CAMPAIGN: ten maps spread across the hundred, each with the biome
# Campaign.biome_at() chose and the dread Campaign.dread() gave it. The strip
# above answers "what does the shift do"; this one answers "what does the player
# actually walk through from map 1 to map 100", which is the question the
# roadmap asked.
#
# Rendering goes through Shade.shaded() and Props.build() — the same functions
# the game meshes with — for the reason tools/preview.gd states: a preview that
# does not predict the ship is a pretty lie. What a top-down render CANNOT show
# is the sky and the volumetric fog, which only exist in the 3D environment; for
# those, Mesher.build_environment() reads the same shifted biome dictionary and
# tools/dreadtest.gd prints the numbers it will be handed.
# ------------------------------------------------------------------------------

const OUT_DIR := "res://tools/out"

# 192 m of region. Half the resolution tools/preview.gd uses, because four of
# them go in one image and a 1536 px strip of four 384 px panels is already
# wider than anything that will be opened to look at it.
const CELLS := 192
const CELL := 1.0

## The rungs, matching tools/dreadtest.gd's RUNGS so the table and the picture
## describe the same four points.
const RUNGS: PackedFloat32Array = [0.0, 0.33, 0.66, 1.0]

## Panels are separated by a band of neutral grey rather than butted together,
## so the eye does not read the join as a terrain feature.
const GUTTER := 6
const GUTTER_COL := Color(0.10, 0.10, 0.11)

var _prop_look: Dictionary = {}


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var biomes: Array = []
	for a in OS.get_cmdline_user_args():
		biomes.append(String(a))
	if biomes.is_empty():
		# One temperate, one bleak, one unreal, and the citadel: enough to see
		# that the shift reads on a bright palette as well as on a dark one.
		biomes = ["greenwood", "mistmoor", "voidrift", "throne"]

	for i in range(biomes.size()):
		var bid: String = String(biomes[i])
		if not Biome.exists(bid):
			print("?? unknown biome: ", bid)
			continue
		_biome_strip(bid, 1000 + i * 7919)

	_campaign_strip()
	print("\nwrote ", ProjectSettings.globalize_path(OUT_DIR))
	quit()


# One biome, four dreads, one seed.
func _biome_strip(bid: String, world_seed: int) -> void:
	print("\n=== %s ===" % bid)
	var panels: Array[Image] = []
	for d in RUNGS:
		panels.append(_panel(Biome.tag(bid, d), world_seed, "dread %.2f" % d))
	_compose(panels, "%s/dread_%s.png" % [OUT_DIR, bid])


# Ten maps across the hundred: the biome the campaign chose, at the dread the
# campaign gave it.
func _campaign_strip() -> void:
	print("\n=== the campaign, every eleventh map ===")
	var panels: Array[Image] = []
	for n in range(10):
		var index: int = int(round(float(n) / 9.0 * float(Campaign.map_count() - 1)))
		var id: String = Biome.tag(Campaign.biome_at(index), Campaign.dread(index))
		panels.append(_panel(id, Campaign.region_seed(4242, index),
			"map %3d  %s" % [index + 1, Campaign.region_title(index)]))
	_compose(panels, "%s/dread_campaign.png" % OUT_DIR)


# Generate a lane region for one (possibly dread-tagged) biome id and render it
# with everything growing on it.
func _panel(id: String, world_seed: int, label: String) -> Image:
	var extent: float = float(CELLS) * CELL
	var plan: Layout = Terrain.plan_for(Terrain.Kind.LANE, world_seed,
		Vector2(extent, extent))
	var ter := Terrain.generate(world_seed, id, CELLS, CELL, plan)
	var scat := Scatter.generate(ter, plan, world_seed)
	var b: Dictionary = Biome.get_biome(id)

	var img := Image.create(ter.size, ter.size, false, Image.FORMAT_RGB8)
	for y in range(ter.size):
		for x in range(ter.size):
			img.set_pixel(x, y, Shade.shaded(ter, x, y))
	_render_life(img, ter, scat, b, id)

	# The mean of what was just drawn, which is the one number that says whether
	# a panel went dark rather than merely cold.
	var mean: float = 0.0
	for y in range(ter.size):
		for x in range(ter.size):
			mean += img.get_pixel(x, y).get_luminance()
	mean /= float(ter.size * ter.size)
	print("  %-44s mean luminance %.3f  fog %.4f/m  cover %5d  props %4d" % [
		label, mean, float(b["fog_density"]), scat.cover.size(),
		scat.items.size()])
	return img


# Props and ground cover, drawn exactly as tools/preview.gd's life render does
# — a disc the size of the real mesh, in the mean colour of the real mesh, with
# a shadow cast in Shade's sun direction.
func _render_life(img: Image, t: Terrain, scat: Scatter, b: Dictionary,
		id: String) -> void:
	var half: float = float(t.size) * t.cell * 0.5
	var span: float = maxf(t.h_max - t.h_min, 0.0001)
	var sun_xz := Vector2(-Shade.SUN_DIR.x, -Shade.SUN_DIR.z).normalized()

	for it in scat.cover:
		var look: Dictionary = _look(String(it["kind"]), int(it["variant"]), id)
		var p: Vector3 = it["pos"]
		_splat(img, t, b, span, int((p.x + half) / t.cell),
			int((p.z + half) / t.cell), 0, look["col"], 0.62)

	for it in scat.items:
		var look2: Dictionary = _look(String(it["kind"]), int(it["variant"]), id)
		var p2: Vector3 = it["pos"]
		var scl: float = float(it["scale"])
		var off: Vector2 = sun_xz * float(look2["height"]) * scl * 0.55
		_shadow(img, t, int((p2.x + off.x + half) / t.cell),
			int((p2.z + off.y + half) / t.cell),
			_radius_cells(t, float(look2["radius"]) * scl))
	for it in scat.items:
		var look3: Dictionary = _look(String(it["kind"]), int(it["variant"]), id)
		var p3: Vector3 = it["pos"]
		var scl3: float = float(it["scale"])
		_splat(img, t, b, span, int((p3.x + half) / t.cell),
			int((p3.z + half) / t.cell),
			_radius_cells(t, float(look3["radius"]) * scl3), look3["col"], 1.0)


func _radius_cells(t: Terrain, metres: float) -> int:
	return clampi(int(round(metres / t.cell)), 0, 12)


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


# Mean vertex colour and footprint of a real prop mesh. Keyed by the FULL id,
# tag included, because a dread-shifted biome builds dread-shifted props — that
# is the whole point of routing props through Biome.get_biome().
func _look(kind: String, variant: int, id: String) -> Dictionary:
	var key: String = "%s#%d#%s" % [kind, variant, id]
	if _prop_look.has(key):
		return _prop_look[key]

	var out: Dictionary = {"col": Color(0.45, 0.45, 0.42), "radius": 0.35,
		"height": 0.5}
	var mesh: ArrayMesh = Props.build(kind, id, variant)
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


# Lay the panels out left to right, ascending dread.
func _compose(panels: Array[Image], path: String) -> void:
	if panels.is_empty():
		return
	var w: int = panels[0].get_width()
	var h: int = panels[0].get_height()
	var out := Image.create(w * panels.size() + GUTTER * (panels.size() - 1), h,
		false, Image.FORMAT_RGB8)
	out.fill(GUTTER_COL)
	for i in range(panels.size()):
		out.blit_rect(panels[i], Rect2i(0, 0, w, h),
			Vector2i(i * (w + GUTTER), 0))
	out.save_png(ProjectSettings.globalize_path(path))
	print("  -> ", path)
