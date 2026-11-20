extends Node3D
# ------------------------------------------------------------------------------
# Visual + numeric verification of an animated hero in the REAL game scene.
#
#   godot --path . --resolution 1170x1200 res://tools/VisVerify.tscn -- <hero>
#
# Differs from animshots.gd in three ways that matter:
#
#   1. It drives HeroRig.set_state() DIRECTLY for the ability clips, so the
#      ability_1/2/3 clips can be seen even though Play.gd never calls
#      setup_combat() and therefore makes every button play `attack`.
#   2. The close camera is re-framed on the SAME frame it is read, so a moving
#      hero does not walk out of its own close-up.
#   3. It measures FOOT SLIDE: the world-space horizontal speed of the planted
#      (lowest) foot during locomotion. A planted foot should be near 0 m/s in
#      world space; if it tracks the hero's own speed, the clip's stride does
#      not match the controller's metres-per-second and the hero skates.
# ------------------------------------------------------------------------------

const OUT := "res://tools/out"

var _play: Node3D
var _hero: HeroController
var _closecam: Camera3D
var _log: Array[String] = []
var _sk: Skeleton3D = null
var _foot_bones: Array[int] = []
var _stride_fwd: float = -INF
var _stride_back: float = INF


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var hero: String = ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		hero = args[0]

	_play = load("res://scenes/Play.tscn").instantiate()
	_play.hero = hero
	add_child(_play)

	var waited: float = 0.0
	while _play._hero == null and waited < 120.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	if _play._hero == null:
		print("!! hero never loaded")
		get_tree().quit(1)
		return
	_hero = _play._hero

	var sks: Array = _hero.rig._model.find_children("*", "Skeleton3D", true, false)
	_sk = sks[0] as Skeleton3D if not sks.is_empty() else null
	if _sk != null:
		for b in range(_sk.get_bone_count()):
			var n := _sk.get_bone_name(b).to_lower()
			if n.contains("toebase") or (n.contains("foot") and not n.contains("end")):
				_foot_bones.append(b)
	print("hero=", _hero.rig.hero_name, " rigged=", _hero.rig.is_rigged)
	print("clips=", _hero.rig._anim.get_animation_list())
	print("clip_for=", _hero.rig._clip_for)
	print("model scale=", _hero.rig._model.scale)
	print("foot bones=", _foot_bones.map(func(b): return _sk.get_bone_name(b)))
	print("controller.abilities.size()=", _hero.abilities.size(),
		"  basic=", "null" if _hero.basic == null else _hero.basic.id)

	_closecam = Camera3D.new()
	_closecam.fov = 32.0
	add_child(_closecam)
	_build_reference()

	# --- idle -------------------------------------------------------------
	_hero.rig.set_state(HeroRig.State.IDLE, true)
	for _i in range(60):
		await get_tree().process_frame
	await _capture("vv_01_idle", "idle")

	# --- actions FIRST, at the spawn point ---------------------------------
	# The spawn is the open clearing the idle shot proves is unobstructed; the
	# locomotion legs walk 16 m and reliably end up inside tree canopy, which
	# puts foliage between the close camera and the hero.
	await _action("vv_04_attack", HeroRig.State.ATTACK)
	await _action("vv_05_ability_1", HeroRig.State.ABILITY_1)
	await _action("vv_06_ability_2", HeroRig.State.ABILITY_2)
	await _action("vv_07_ability_3", HeroRig.State.ABILITY_3)

	# --- locomotion, with slide measurement -------------------------------
	await _locomotion("run", true, "vv_02_run")
	await _locomotion("walk", false, "vv_03_walk")

	print("\n--- measurements (metres) ---")
	for l in _log:
		print(l)
	get_tree().quit()


# ------------------------------------------------------------------------------

func _foot_world(b: int) -> Vector3:
	return _sk.to_global(_sk.get_bone_global_pose(b).origin)


func _locomotion(label: String, run: bool, shot: String) -> void:
	var here: Vector2 = _hero.ground_position()
	var ok := false
	for ang in range(0, 360, 20):
		var d := Vector2(cos(deg_to_rad(ang)), sin(deg_to_rad(ang))) * 16.0
		if _hero.move_to(here + d, run):
			ok = true
			break
	if not ok:
		print("!! could not path for ", label)
		return

	# Let it reach steady state.
	var t0: float = 0.0
	while _hero.is_moving() and t0 < 0.8:
		await get_tree().process_frame
		t0 += get_process_delta_time()

	# Sample planted-foot world speed vs hero world speed.
	var prev: Dictionary = {}
	for b in _foot_bones:
		prev[b] = _foot_world(b)
	var prev_hero: Vector3 = _hero.position
	_stride_fwd = -INF
	_stride_back = INF
	var planted_speeds: Array[float] = []
	var hero_speeds: Array[float] = []
	var samples: int = 0
	# The clip must be sampled INSIDE the loop. Reading it afterwards reads it
	# after the hero has arrived and the controller has already switched to
	# IDLE, which makes a perfectly good run look like it is playing the idle
	# clip.
	var live_clip: String = ""
	var live_len: float = 0.0
	while _hero.is_moving() and samples < 150:
		await get_tree().process_frame
		if not _hero.is_moving():
			break
		var dt: float = get_process_delta_time()
		if dt <= 0.0001:
			continue
		live_clip = _hero.rig._anim.current_animation
		live_len = _hero.rig._anim.current_animation_length
		# The planted foot this frame is the lowest one.
		var lowest: int = -1
		var ly: float = INF
		var cur: Dictionary = {}
		for b in _foot_bones:
			var w: Vector3 = _foot_world(b)
			cur[b] = w
			if w.y < ly:
				ly = w.y
				lowest = b
		# Foot excursion along the hero's own forward axis = stride length.
		for b in _foot_bones:
			var lp: Vector3 = _hero.to_local(cur[b])
			_stride_fwd = maxf(_stride_fwd, lp.z)
			_stride_back = minf(_stride_back, lp.z)
		if lowest >= 0 and prev.has(lowest):
			var a: Vector3 = prev[lowest]
			var c: Vector3 = cur[lowest]
			planted_speeds.append(Vector2(c.x - a.x, c.z - a.z).length() / dt)
		hero_speeds.append(Vector2(
			_hero.position.x - prev_hero.x,
			_hero.position.z - prev_hero.z).length() / dt)
		prev = cur
		prev_hero = _hero.position
		samples += 1

	var pm: float = 0.0
	for s in planted_speeds:
		pm += s
	pm = pm / maxf(planted_speeds.size(), 1)
	var hm: float = 0.0
	for s in hero_speeds:
		hm += s
	hm = hm / maxf(hero_speeds.size(), 1)
	var pmin: float = INF
	for s in planted_speeds:
		pmin = minf(pmin, s)
	# The metric that actually matters: what FRACTION of the cycle the planted
	# foot is genuinely stationary in world space. A real gait plants for
	# roughly 40% of the cycle (more for a walk). A single frame touching zero
	# proves nothing — a skating foot still crosses zero as it reverses.
	var planted: int = 0
	for s in planted_speeds:
		if s < hm * 0.25:
			planted += 1
	var frac: float = float(planted) / maxf(planted_speeds.size(), 1)

	# The actionable number: how far the clip actually swings a foot, against
	# how far it MUST swing to cover the controller's speed. Stride is measured
	# in the hero's own frame (so the body's travel is subtracted out) along its
	# forward axis.
	var clip_len: float = live_len
	var have: float = _stride_fwd - _stride_back
	var need: float = hm * clip_len / 2.0        # two steps per cycle
	_log.append("%-16s STRIDE: clip '%s' %.2fs swings a foot %.2f m; %.2f m/s needs %.2f m per step -> clip covers %.0f%%" % [
		label, live_clip, clip_len, have, hm, need,
		100.0 * have / maxf(need, 0.001)])

	_log.append("%-16s SLIDE: hero %.2f m/s | planted-foot world speed mean %.2f m/s (%.0f%% of body speed), min %.2f | STANCE %.0f%% of frames -> %s" % [
		label, hm, pm, 100.0 * pm / maxf(hm, 0.001), pmin, frac * 100.0,
		("SKATING - stride does not cover the ground speed" if frac < 0.12
			else ("short stride / partial slide" if frac < 0.28 else "plants cleanly"))])

	await _capture(shot, label + " mid-stride")
	_hero.stop()


func _action(shot: String, state: int) -> void:
	_hero._busy_until = 0.0
	_hero.pending_cast = null
	_hero.stop()
	_hero.rig.set_state(HeroRig.State.IDLE, true)
	for _i in range(10):
		await get_tree().process_frame
	_hero.rig.set_state(state, true)
	_hero._busy_until = 10.0        # keep the controller from yanking it to IDLE
	var ap: AnimationPlayer = _hero.rig._anim
	var clip: String = ap.current_animation
	var len_s: float = ap.current_animation_length
	# Three phases, not one frame: a single mid-clip pose cannot distinguish
	# "a slam" from "crumpling forward", and the question being asked is how the
	# ability READS over its arc.
	for phase in [0.25, 0.5, 0.8]:
		while ap.current_animation == clip \
				and ap.current_animation_position < len_s * phase:
			await get_tree().process_frame
		await _capture("%s_p%d" % [shot, int(phase * 100)],
			"clip='%s' len=%.2fs at %.2fs (%d%%)" % [
				clip, len_s, ap.current_animation_position, int(phase * 100)])
	_hero._busy_until = 0.0


# ------------------------------------------------------------------------------

func _capture(name: String, note: String) -> void:
	_frame_close()
	await RenderingServer.frame_post_draw

	_closecam.current = false
	_frame_close()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("%s/%s.png" % [OUT, name]))

	_closecam.current = true
	_frame_close()
	await RenderingServer.frame_post_draw
	_frame_close()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("%s/%s_close.png" % [OUT, name]))
	_closecam.current = false

	_measure(name, note)
	print("shot ", name, "  ", note)


var _disc: MeshInstance3D
var _rod: Node3D

func _build_reference() -> void:
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.5
	cyl.bottom_radius = 0.5
	cyl.height = 0.01
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
	for i in range(4):
		var b := BoxMesh.new()
		b.size = Vector3(0.06, 0.4625, 0.06)
		var mi := MeshInstance3D.new()
		mi.mesh = b
		var bm := StandardMaterial3D.new()
		bm.albedo_color = Color(1, 1, 1) if i % 2 == 0 else Color(0.05, 0.05, 0.05)
		bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.material_override = bm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(0, 0.4625 * (i + 0.5), 0)
		_rod.add_child(mi)


func _frame_close() -> void:
	var g2: Vector2 = _hero.ground_position()
	var gy: float = _hero.terrain.height_at(g2)
	_disc.position = Vector3(g2.x, gy, g2.y)

	var p: Vector3 = _hero.position
	# Pick whichever of 8 bearings puts the camera on the LOWEST ground, so on a
	# slope it ends up downhill instead of buried inside the hillside.
	var best := Vector3.ZERO
	var best_h := INF
	for ang in range(0, 360, 45):
		var y := deg_to_rad(float(ang))
		var c := p + Vector3(sin(y), 0.0, cos(y)) * 4.6
		var h: float = _hero.terrain.height_at(Vector2(c.x, c.z))
		if h < best_h:
			best_h = h
			best = c
	# And never below the terrain under the camera itself.
	best.y = maxf(p.y + 1.35, best_h + 1.35)
	_closecam.position = best
	_closecam.look_at(p + Vector3(0, 0.80, 0), Vector3.UP)

	# The 1.85 m rod must sit at the SAME distance from the camera as the hero,
	# otherwise perspective alone makes the height comparison wrong — so offset
	# it along the camera's right vector, not a fixed world axis.
	var right: Vector3 = _closecam.global_transform.basis.x
	var rp := Vector2(g2.x + right.x * 1.15, g2.y + right.z * 1.15)
	_rod.position = Vector3(rp.x, _hero.terrain.height_at(rp), rp.y)


func _measure(name: String, note: String) -> void:
	var ground: float = _hero.terrain.height_at(_hero.ground_position())
	var foot_lo := INF
	var foot_name := "<none>"
	var head_hi := -INF
	if _sk != null:
		for b in range(_sk.get_bone_count()):
			var gy: float = _foot_world(b).y
			head_hi = maxf(head_hi, gy)
			var bn := _sk.get_bone_name(b).to_lower()
			if bn.contains("foot") or bn.contains("toe"):
				if gy < foot_lo:
					foot_lo = gy
					foot_name = _sk.get_bone_name(b)

	var sil: Vector2 = _skinned_extent_y()      # (lowest y, highest y) in world
	_log.append("%-16s ground=%+.3f | lowest foot bone %-22s %+.3f | SKIN bottom %+.3f vs ground, top %+.3f, HEIGHT %.2f m | %s" % [
		name, ground, foot_name, foot_lo - ground,
		sil.x - ground, sil.y - ground, sil.y - sil.x, note])


## True world-space vertical extent of the SKINNED mesh.
##
## MeshInstance3D.get_aabb() cannot be used here: on these runtime-imported glb
## skins Godot reports a degenerate ~0.01 m box, so it says nothing about where
## the hero's feet and head actually are. This walks the vertices through the
## skin bind poses and the live bone transforms instead, which is what the GPU
## is doing and therefore what the player sees.
func _skinned_extent_y() -> Vector2:
	var lo := INF
	var hi := -INF
	for c in _hero.rig._model.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null:
			continue
		var skin: Skin = mi.skin
		var xf: Transform3D = mi.global_transform
		for s in range(mi.mesh.get_surface_count()):
			var arr: Array = mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if verts.is_empty():
				continue
			var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES] if arr[Mesh.ARRAY_BONES] != null else PackedInt32Array()
			var wts: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS] if arr[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
			var per: int = 0
			if not bones.is_empty():
				per = bones.size() / verts.size()
			# Stride the vertex list: extremes survive sampling, and these
			# meshes are tens of thousands of verts per measurement.
			var step: int = maxi(1, verts.size() / 4000)
			for i in range(0, verts.size(), step):
				var v: Vector3 = verts[i]
				var w: Vector3
				if _sk == null or skin == null or per == 0:
					w = xf * v
				else:
					var acc := Vector3.ZERO
					var tot: float = 0.0
					for k in range(per):
						var wi: float = wts[i * per + k]
						if wi <= 0.0:
							continue
						var bind: int = bones[i * per + k]
						if bind < 0 or bind >= skin.get_bind_count():
							continue
						var bone: int = skin.get_bind_bone(bind)
						if bone < 0 or bone >= _sk.get_bone_count():
							continue
						var m: Transform3D = _sk.get_bone_global_pose(bone) * skin.get_bind_pose(bind)
						acc += (m * v) * wi
						tot += wi
					if tot <= 0.0001:
						continue
					w = _sk.global_transform * (acc / tot)
				lo = minf(lo, w.y)
				hi = maxf(hi, w.y)
	return Vector2(lo, hi)
