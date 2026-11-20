extends Node3D
# ------------------------------------------------------------------------------
# THE DREAD CURVE FROM THE GAME CAMERA. The one view worth an opinion.
#
#   godot --path . --resolution 760x428 res://scenes/DreadShots.tscn
#   godot --path . --resolution 760x428 res://scenes/DreadShots.tscn -- molten
#
# NOT headless, and it cannot be: the sky, the volumetric fog and the real
# DirectionalLight only exist in the 3D environment, and those are three of the
# five things the dread shift moves. The top-down tools/dreadshots.gd can show
# the ground draining of colour and the cover thinning out; it cannot show the
# zenith going black behind a hill, which is the single loudest read in the
# whole curve.
#
# THE REGION IS BUILT ONCE. All four frames show the same terrain from the same
# camera — only the biome id differs, by its dread tag — so the strip is a
# controlled comparison rather than four pretty screenshots. A champion stands
# at the focus point in every frame because the question "is map 100 still
# playable" is really "can I see the thing in front of me".
#
# Output: tools/out/dread3d_<biome>.png, dread 0.00 / 0.33 / 0.66 / 1.00 left
# to right.
# ------------------------------------------------------------------------------

const OUT := "res://tools/out"
const CELLS := 384
const CELL := 0.5
const RUNGS: PackedFloat32Array = [0.0, 0.33, 0.66, 1.0]
const GUTTER := 6

var _cam: Camera3D
var _world: Node3D
var _env: WorldEnvironment
var _sun: DirectionalLight3D
var _hero: HeroRig


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))

	var biomes: Array = []
	for a in OS.get_cmdline_user_args():
		biomes.append(String(a))
	if biomes.is_empty():
		biomes = ["greenwood"]

	_world = Node3D.new()
	add_child(_world)
	_cam = Camera3D.new()
	# The same long lens tools/shots.gd uses — a Diablo-like keeps the ground
	# plane legible and the character undistorted at the edges.
	_cam.fov = 38.0
	_cam.far = 600.0
	add_child(_cam)

	for bid in biomes:
		if not Biome.exists(String(bid)):
			print("?? unknown biome: ", bid)
			continue
		print("\n=== %s ===" % bid)
		await _run(String(bid))
	get_tree().quit()


func _run(bid: String) -> void:
	var world_seed: int = 31337
	var extent: float = float(CELLS) * CELL

	# ONE plan, ONE terrain geometry per rung. The heightfield is identical
	# across the four (tools/dreadtest.gd asserts it bit for bit), so the mesh
	# is rebuilt only because its VERTEX COLOUR is baked from the palette.
	var panels: Array[Image] = []
	for d in RUNGS:
		var id: String = Biome.tag(bid, d)
		var plan: Layout = Terrain.plan_for(Terrain.Kind.LANE, world_seed,
			Vector2(extent, extent))
		var ter := Terrain.generate(world_seed, id, CELLS, CELL, plan)
		var scat := Scatter.generate(ter, plan, world_seed)
		scat.apply_blocking(ter)

		_clear()
		_build(ter, scat, id)

		# Stand where the player would, a third of the way down the lane, so
		# the shot has both near ground and a far horizon in it.
		var spine: PackedVector2Array = (plan as Lane).spine
		var at: Vector2 = ter.nearest_walkable(
			spine[int(float(spine.size()) * 0.33)])
		var ground: float = ter.height_at(at)
		_place_hero(at, ground)
		_frame(at, ground)

		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw

		var img: Image = get_viewport().get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		panels.append(img)

		var b: Dictionary = Biome.get_biome(id)
		print("  dread %.2f  key x%.2f  fill x%.2f  fog %.4f/m  sky_top %s  mean %.3f" % [
			d, float(b.get("key_mult", 1.0)), float(b.get("fill_mult", 1.0)),
			float(b["fog_density"]), (b["sky_top"] as Color).to_html(false),
			_mean_lum(img)])

	_compose(panels, "%s/dread3d_%s.png" % [OUT, bid])


func _clear() -> void:
	for c in _world.get_children():
		_world.remove_child(c)
		c.queue_free()
	for c in get_children():
		if c is DirectionalLight3D or c is WorldEnvironment:
			remove_child(c)
			c.queue_free()
	_hero = null


func _build(ter: Terrain, scat: Scatter, id: String) -> void:
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
		wi.material_override = Mesher.water_material(id)
		_world.add_child(wi)

	# Environment and key light come from Mesher, which reads the SAME shifted
	# dictionary Shade bakes the ground from. That is the whole mechanism under
	# test: one tagged id, every renderer in step.
	_env = WorldEnvironment.new()
	_env.environment = Mesher.build_environment(id)
	add_child(_env)
	_sun = Mesher.build_sun(id)
	add_child(_sun)

	var pmat: ShaderMaterial = Props.material()
	_emit(scat.buckets(), id, pmat, true)
	_emit(scat.cover_buckets(), id, pmat, false)


func _emit(buckets: Dictionary, id: String, mat: ShaderMaterial,
		shadows: bool) -> void:
	for key in buckets.keys():
		var group: Array = buckets[key]
		var parts: PackedStringArray = String(key).split("#")
		var mesh: ArrayMesh = Props.build(parts[0], id, int(parts[1]))
		if mesh == null:
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
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
			var pos: Vector3 = it["pos"]
			var hx: int = int(pos.x * 7.0)
			var hz: int = int(pos.z * 7.0)
			var v: float = Rng.unit2(991, hx, hz)
			var w: float = Rng.unit2(4441, hx, hz)
			mm.set_instance_custom_data(i, Color(0.86 + v * 0.26,
				0.88 + w * 0.22, 0.84 + (1.0 - v) * 0.24, 1.0))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_world.add_child(mmi)


func _place_hero(at: Vector2, ground: float) -> void:
	var roster: PackedStringArray = HeroRig.animated_heroes()
	if roster.is_empty():
		return
	var rig := HeroRig.new()
	# A fixed champion, so the four frames differ by dread and nothing else.
	if not rig.load_hero(roster[0]):
		return
	rig.position = Vector3(at.x, ground, at.y)
	rig.rotation.y = deg_to_rad(215.0)
	_world.add_child(rig)
	_hero = rig


func _frame(focus: Vector2, ground: float) -> void:
	var pitch: float = deg_to_rad(48.0)
	var yaw: float = deg_to_rad(35.0)
	# 18 m, not the 25 m tools/shots.gd uses. These frames are evidence about
	# whether a champion stays readable, so the champion has to be big enough in
	# them to answer the question.
	var dist: float = 18.0
	var offset := Vector3(sin(yaw) * cos(pitch), sin(pitch),
		cos(yaw) * cos(pitch)) * dist
	var look_at := Vector3(focus.x, ground + 1.0, focus.y)
	_cam.position = look_at + offset
	_cam.look_at(look_at, Vector3.UP)


func _mean_lum(img: Image) -> float:
	var sum: float = 0.0
	var step: int = 4
	var taps: int = 0
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			sum += img.get_pixel(x, y).get_luminance()
			taps += 1
	return sum / float(maxi(taps, 1))


func _compose(panels: Array[Image], path: String) -> void:
	if panels.is_empty():
		return
	var w: int = panels[0].get_width()
	var h: int = panels[0].get_height()
	var out := Image.create(w * panels.size() + GUTTER * (panels.size() - 1), h,
		false, Image.FORMAT_RGB8)
	out.fill(Color(0.10, 0.10, 0.11))
	for i in range(panels.size()):
		out.blit_rect(panels[i], Rect2i(0, 0, w, h), Vector2i(i * (w + GUTTER), 0))
	out.save_png(ProjectSettings.globalize_path(path))
	print("  -> ", path)
