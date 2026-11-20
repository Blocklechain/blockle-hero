extends Node3D
# ------------------------------------------------------------------------------
# In-engine screenshots from the ACTUAL game camera.
#
# The top-down preview is good for debugging a layout and useless for judging
# whether a place looks good — a Diablo-style game is seen from a three-quarter
# camera a few metres off the ground, and that is the only view worth an opinion.
#
#   godot --path . --resolution 1170x1200 res://scenes/Shots.tscn
#
# A hero model is dropped into each shot for scale. The 200 heroes are glTF from
# the retired raid project and are loaded at runtime through GLTFDocument, so no
# import step is needed to see one standing in the world.
# ------------------------------------------------------------------------------

const HERO_DIR := "/Volumes/ExtremePro/raid/assets/heroes/tex"
const OUT := "res://tools/out"

# 192 m across at 0.5 m cells. Four times the vertex density of the first pass,
# which is affordable now that the mesh is split into cullable chunks and the
# sub-metre detail moved into the shader.
const CELLS := 384
const CELL := 0.5

# Which biome, and from where. Each entry is one screenshot.
const SHOTS: Array = [
	{"biome": "greenwood", "at": "entry", "name": "01_greenwood"},
	{"biome": "tidebreak", "at": "entry", "name": "02_tidebreak"},
	{"biome": "emberfall", "at": "entry", "name": "03_emberfall"},
	{"biome": "frostcrag", "at": "entry", "name": "04_frostcrag"},
	{"biome": "mistmoor", "at": "entry", "name": "05_mistmoor"},
	{"biome": "stormreach", "at": "boss", "name": "06_stormreach"},
	{"biome": "duskvale", "at": "entry", "name": "07_duskvale"},
	{"biome": "gloomroot", "at": "entry", "name": "08_gloomroot"},
	{"biome": "thornspire", "at": "boss", "name": "09_thornspire"},
	{"biome": "ashwastes", "at": "boss", "name": "10_ashwastes"},
	{"biome": "boneyard", "at": "entry", "name": "11_boneyard"},
	{"biome": "hollows", "at": "entry", "name": "12_hollows"},
	{"biome": "shimmer", "at": "entry", "name": "13_shimmer"},
	{"biome": "molten", "at": "boss", "name": "14_molten"},
	{"biome": "voidrift", "at": "boss", "name": "15_voidrift"},
	{"biome": "throne", "at": "boss", "name": "16_throne"},
]

var _cam: Camera3D
var _world: Node3D
var _hero_files: PackedStringArray = PackedStringArray()


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_scan_heroes()

	_world = Node3D.new()
	add_child(_world)

	_cam = Camera3D.new()
	# A fairly long lens. Diablo-likes use a narrow field of view so the ground
	# plane stays legible and the character does not distort at the edges.
	_cam.fov = 38.0
	_cam.far = 600.0
	add_child(_cam)

	await _run()
	get_tree().quit()


func _scan_heroes() -> void:
	var d := DirAccess.open(HERO_DIR)
	if d == null:
		print("!! hero dir not readable: ", HERO_DIR)
		return
	d.list_dir_begin()
	var f: String = d.get_next()
	while f != "":
		if f.ends_with(".glb"):
			_hero_files.append(f)
		f = d.get_next()
	_hero_files.sort()
	print("heroes available: ", _hero_files.size())


func _run() -> void:
	for i in range(SHOTS.size()):
		var spec: Dictionary = SHOTS[i]
		var bid: String = spec["biome"]
		var world_seed: int = 7000 + i * 1361

		var plan := Layout.generate(world_seed,
			Vector2(CELLS * CELL, CELLS * CELL), Layout.Sym.ASYMMETRIC, 11)
		var ter := Terrain.generate(world_seed, bid, CELLS, CELL, plan)
		var scat := Scatter.generate(ter, plan, world_seed)
		scat.apply_blocking(ter)

		_clear(_world)
		_build_scene(ter, bid)
		_build_props(scat, bid)

		# Frame on the requested node, standing where the player would.
		var target_node: Dictionary = plan.node_of_kind(
			Layout.BOSS if String(spec["at"]) == "boss" else Layout.ENTRY)
		var focus: Vector2 = ter.nearest_walkable(
			target_node.get("pos", Vector2.ZERO) as Vector2)
		var ground: float = ter.height_at(focus)

		_place_hero(i, focus, ground)
		_frame_camera(focus, ground)

		# Two frames: one to build, one with everything resident.
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw

		var img: Image = get_viewport().get_texture().get_image()
		var path: String = "%s/%s.png" % [OUT, String(spec["name"])]
		img.save_png(ProjectSettings.globalize_path(path))
		print("shot %-14s %-10s relief %5.1f m  walk %3.0f%%  props %5d  cover %6d  draws %d" % [
			String(spec["name"]), bid, ter.h_max - ter.h_min,
			ter.walkable_fraction() * 100.0, scat.items.size(),
			scat.cover.size(), scat.buckets().size() + scat.cover_buckets().size()])


func _clear(n: Node) -> void:
	for c in n.get_children():
		n.remove_child(c)
		c.queue_free()
	for c in get_children():
		if c is DirectionalLight3D or c is WorldEnvironment:
			remove_child(c)
			c.queue_free()


func _build_scene(ter: Terrain, bid: String) -> void:
	# One MeshInstance3D per chunk so Godot can frustum-cull the region.
	var gmat: ShaderMaterial = Mesher.ground_material()
	for chunk in Mesher.build_chunks(ter, 1):
		var mi := MeshInstance3D.new()
		mi.mesh = chunk
		mi.material_override = gmat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_world.add_child(mi)

	var wm: ArrayMesh = Mesher.build_water(ter)
	if wm != null:
		var wi := MeshInstance3D.new()
		wi.mesh = wm
		wi.material_override = Mesher.water_material(bid)
		_world.add_child(wi)

	var we := WorldEnvironment.new()
	we.environment = Mesher.build_environment(bid)
	add_child(we)
	var sun: DirectionalLight3D = Mesher.build_sun(bid)
	add_child(sun)
	# Confirm the key light actually points down-ish once parented, rather than
	# trusting that it does.
	print("  sun travels ", sun.global_transform.basis.z * -1.0)


func _build_props(scat: Scatter, bid: String) -> void:
	var mat: ShaderMaterial = Props.material()
	_emit_group(scat.buckets(), bid, mat, true)
	# Ground cover does not cast shadows. Thousands of blades each throwing a
	# shadow costs real time on a phone and contributes almost nothing visually
	# at this scale — the props above them already ground the scene.
	_emit_group(scat.cover_buckets(), bid, mat, false)


func _emit_group(buckets: Dictionary, bid: String, mat: ShaderMaterial,
		shadows: bool) -> void:
	# One MultiMesh per (kind, variant) — a forest in a handful of draws.
	for key in buckets.keys():
		var group: Array = buckets[key]
		var parts: PackedStringArray = String(key).split("#")
		var mesh: ArrayMesh = Props.build(parts[0], bid, int(parts[1]))
		if mesh == null:
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		# Custom data rather than instance colour: Godot folds instance colour
		# into vertex COLOR, whose alpha channel the prop shader reads as
		# emission, so tinting that way would relight every glowing prop.
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = group.size()
		for i in range(group.size()):
			var it: Dictionary = group[i]
			var tr := Transform3D()
			tr = tr.scaled(Vector3.ONE * float(it["scale"]))
			tr = tr.rotated(Vector3.UP, float(it["yaw"]))
			tr.origin = it["pos"]
			mm.set_instance_transform(i, tr)

			# A small per-instance tint, keyed off position so it is stable
			# across runs. This is what stops a stand of trees reading as one
			# mesh stamped three hundred times.
			var pos: Vector3 = it["pos"]
			var hx: int = int(pos.x * 7.0)
			var hz: int = int(pos.z * 7.0)
			var v: float = Rng.unit2(991, hx, hz)
			var w: float = Rng.unit2(4441, hx, hz)
			mm.set_instance_custom_data(i, Color(
				0.86 + v * 0.26,
				0.88 + w * 0.22,
				0.84 + (1.0 - v) * 0.24, 1.0))

		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_world.add_child(mmi)


# The ARPG camera: high, tilted down about 48 degrees, looking at the player.
func _frame_camera(focus: Vector2, ground: float) -> void:
	# 48 degrees down and 17 m out. The first pass sat at 34 m and the hero was
	# a speck — an ARPG camera has to be close enough that the character reads
	# as a character, not a cursor.
	var pitch: float = deg_to_rad(48.0)
	var yaw: float = deg_to_rad(35.0)
	var dist: float = 25.0
	var offset := Vector3(
		sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * dist
	var look_at := Vector3(focus.x, ground + 1.0, focus.y)
	_cam.position = look_at + offset
	_cam.look_at(look_at, Vector3.UP)


func _place_hero(i: int, at: Vector2, ground: float) -> void:
	if _hero_files.is_empty():
		return
	var file: String = _hero_files[i % _hero_files.size()]
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err: int = doc.append_from_file(HERO_DIR.path_join(file), state)
	if err != OK:
		print("  (hero load failed: ", file, ")")
		return
	var scene: Node = doc.generate_scene(state)
	if scene == null:
		return
	var holder := Node3D.new()
	holder.add_child(scene)
	holder.position = Vector3(at.x, ground, at.y)
	# The raid models were authored for a different scale; normalise to roughly
	# a 1.8 m fighter so the terrain reads at human scale.
	var aabb: AABB = _aabb_of(scene)
	if aabb.size.y > 0.001:
		holder.scale = Vector3.ONE * (1.8 / aabb.size.y)
	holder.rotation.y = deg_to_rad(215.0)
	_world.add_child(holder)
	print("  hero: ", file, "  raw height ", "%.2f" % aabb.size.y, " m")


func _aabb_of(n: Node) -> AABB:
	var out := AABB()
	var first := true
	for c in n.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null:
			continue
		var a: AABB = mi.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out
