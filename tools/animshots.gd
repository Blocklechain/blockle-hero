extends Node3D
# ------------------------------------------------------------------------------
# Visual check of an ANIMATED hero in the real game scene.
#
#   godot --path . --resolution 1170x1200 res://tools/AnimShots.tscn -- <hero>
#
# Instances scenes/Play.tscn unmodified (same world build, same HeroController,
# same ArpgCamera) and then drives the hero through idle / run / walk / attack /
# the three abilities, saving a PNG at each. A second close camera is dropped in
# for the feet, because at the game camera's 25 m a 2 cm ground intersection is
# a single pixel.
#
# It also measures, per shot: lowest foot-bone height above the terrain surface,
# head height, and horizontal root drift -- the numbers behind the screenshots.
# ------------------------------------------------------------------------------

const OUT := "res://tools/out"

var _play: Node3D
var _hero: HeroController
var _closecam: Camera3D
var _log: Array[String] = []


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var hero: String = ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		hero = args[0]

	_play = load("res://scenes/Play.tscn").instantiate()
	_play.hero = hero
	add_child(_play)

	# Wait for the world build + hero load.
	var waited: float = 0.0
	while _play._hero == null and waited < 90.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	if _play._hero == null:
		print("!! hero never loaded (", waited, "s)")
		get_tree().quit(1)
		return
	_hero = _play._hero
	print("hero loaded: ", _hero.rig.hero_name, "  rigged=", _hero.rig.is_rigged)
	print("  clips: ", _hero.rig._anim.get_animation_list() if _hero.rig.is_rigged else [])
	print("  model scale: ", _hero.rig._model.scale)

	_closecam = Camera3D.new()
	_closecam.fov = 30.0
	add_child(_closecam)
	_build_reference()

	await _shoot_idle()
	await _shoot_locomotion("run", true)
	await _shoot_locomotion("walk", false)
	await _shoot_action("attack", 0)
	await _shoot_action("ability_1", 1)
	await _shoot_action("ability_2", 2)
	await _shoot_action("ability_3", 3)

	print("\n--- measurements (metres) ---")
	for l in _log:
		print(l)
	get_tree().quit()


# ------------------------------------------------------------------------------

func _shoot_idle() -> void:
	_hero.rig.set_state(HeroRig.State.IDLE, true)
	for _i in range(40):
		await get_tree().process_frame
	await _capture("anim_01_idle", "idle")


func _shoot_locomotion(label: String, run: bool) -> void:
	# Walk the hero a real distance so any foot-slide or drift accumulates.
	var here: Vector2 = _hero.ground_position()
	var ok := false
	for ang in range(0, 360, 30):
		var d := Vector2(cos(deg_to_rad(ang)), sin(deg_to_rad(ang))) * 14.0
		if _hero.move_to(here + d, run):
			ok = true
			break
	if not ok:
		print("!! could not path for ", label)
		return
	# Let it get up to speed, then shoot mid-stride.
	var moved: float = 0.0
	var start: Vector2 = _hero.ground_position()
	while _hero.is_moving() and moved < 6.0:
		await get_tree().process_frame
		moved = start.distance_to(_hero.ground_position())
	await _capture("anim_02_" + label, label + " (mid-stride, state=%d)" % _hero.rig.state())
	_hero.stop()


func _shoot_action(label: String, slot: int) -> void:
	# Clear the controller's busy lock left over from the previous shot: the
	# capture interrupts the clip, so state_finished never fires for it.
	_hero._busy_until = 0.0
	_hero.pending_cast = null
	_hero.rig.set_state(HeroRig.State.IDLE, true)
	for _i in range(10):
		await get_tree().process_frame
	if not _hero.use_ability(slot):
		print("!! use_ability(%d) refused" % slot)
		return
	var ap: AnimationPlayer = _hero.rig._anim
	var len_s: float = ap.current_animation_length if ap != null else 0.45
	var clip: String = ap.current_animation if ap != null else "<none>"
	# Mid-clip: the pose that actually reads as the ability.
	var target: float = len_s * 0.5
	while ap != null and ap.current_animation == clip \
			and ap.current_animation_position < target:
		await get_tree().process_frame
	await _capture("anim_03_" + label, "%s clip='%s' len=%.2fs at %.2fs" % [
		label, clip, len_s, ap.current_animation_position if ap != null else 0.0])


# ------------------------------------------------------------------------------

func _capture(name: String, note: String) -> void:
	_frame_close()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	# Game camera shot.
	_closecam.current = false
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [OUT, name]))

	# Close-up for the feet / ground contact.
	_closecam.current = true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img2: Image = get_viewport().get_texture().get_image()
	img2.save_png(ProjectSettings.globalize_path("%s/%s_close.png" % [OUT, name]))
	_closecam.current = false

	_measure(name, note)
	print("shot ", name, "  ", note)


# A red disc lying exactly ON the terrain under the hero, plus a 1.85 m rod
# banded every 0.5 m standing on that same surface. Anything ambiguous about
# ground contact or scale stops being ambiguous.
var _disc: MeshInstance3D
var _rod: Node3D

func _build_reference() -> void:
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.55
	cyl.bottom_radius = 0.55
	cyl.height = 0.012
	_disc = MeshInstance3D.new()
	_disc.mesh = cyl
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.95, 0.1, 0.1)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_disc.material_override = m
	_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_disc)

	_rod = Node3D.new()
	add_child(_rod)
	for i in range(4):                      # 4 bands x 0.4625 m = 1.85 m
		var b := BoxMesh.new()
		b.size = Vector3(0.07, 0.4625, 0.07)
		var mi := MeshInstance3D.new()
		mi.mesh = b
		var bm := StandardMaterial3D.new()
		bm.albedo_color = Color(1, 1, 1) if i % 2 == 0 else Color(0.05, 0.05, 0.05)
		bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.material_override = bm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(0, 0.4625 * (i + 0.5), 0)
		_rod.add_child(mi)


func _place_reference() -> void:
	var g2: Vector2 = _hero.ground_position()
	var gy: float = _hero.terrain.height_at(g2)
	_disc.position = Vector3(g2.x, gy, g2.y)
	var side := Vector2(0.9, 0.0)
	var rp := g2 + side
	_rod.position = Vector3(rp.x, _hero.terrain.height_at(rp), rp.y)


func _frame_close() -> void:
	_place_reference()
	# Eye level with the hero's shins, 4.5 m out, so the ground line is visible.
	var p: Vector3 = _hero.position
	var yaw: float = deg_to_rad(35.0)
	var off := Vector3(sin(yaw), 0.35, cos(yaw)) * 4.2
	_closecam.position = p + off + Vector3(0, 0.25, 0)
	_closecam.look_at(p + Vector3(0, 0.85, 0), Vector3.UP)


func _measure(name: String, note: String) -> void:
	var rig: HeroRig = _hero.rig
	var sk: Skeleton3D = null
	var sks: Array = rig._model.find_children("*", "Skeleton3D", true, false)
	if not sks.is_empty():
		sk = sks[0] as Skeleton3D
	var ground: float = _hero.terrain.height_at(_hero.ground_position())

	var foot_lo := INF
	var head_hi := -INF
	var foot_names: Array[String] = []
	if sk != null:
		for b in range(sk.get_bone_count()):
			var bn: String = sk.get_bone_name(b).to_lower()
			var gy: float = sk.to_global(sk.get_bone_global_pose(b).origin).y
			head_hi = maxf(head_hi, gy)
			if bn.contains("foot") or bn.contains("toe"):
				if gy < foot_lo:
					foot_lo = gy
					foot_names = [sk.get_bone_name(b)]
				elif is_equal_approx(gy, foot_lo):
					foot_names.append(sk.get_bone_name(b))

	# Visible silhouette: the mesh instance's global AABB as the renderer sees it.
	var mi: MeshInstance3D = rig._model.find_children("*", "MeshInstance3D", true, false)[0]
	var gaabb: AABB = mi.global_transform * mi.get_aabb()

	_log.append("%-22s hero.y=%+.3f ground=%+.3f | lowest foot bone %-18s y=%+.3f (%+.3f vs ground) | top bone y=%+.3f (height %.2f m) | mesh aabb y=[%+.3f .. %+.3f]" % [
		name, _hero.position.y, ground,
		(foot_names[0] if not foot_names.is_empty() else "<none>"),
		foot_lo, foot_lo - ground, head_hi, head_hi - ground,
		gaabb.position.y, gaabb.position.y + gaabb.size.y])
