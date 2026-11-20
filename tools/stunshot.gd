extends Node3D
# ------------------------------------------------------------------------------
# VISUAL PROOF for the stun. Two copies of the SAME hero, side by side:
#
#   left  = running   (HeroRig.State.RUN, what you look like normally)
#   right = stunned   (HeroRig.State.WALK, which IS the stun animation)
#
# Both are seeked to the same normalised phase of their own clip and rendered
# together, so the difference in the frame is the difference the player sees.
#
#   godot --path . --resolution 1600x900 res://scenes/StunShot.tscn
#
# Writes tools/out/stun_<hero>_p<phase>.png.
#
# Why a bespoke scene rather than Play.tscn: Play.gd never calls
# setup_combat(), so HeroController.body is null, is_stunned() is always false,
# and it always orders move_to(run=true) — the walk/stun state is UNREACHABLE in
# the playable scene today. There is nothing to screenshot there.
# ------------------------------------------------------------------------------

const OUT := "res://tools/out"
const HEROES := ["aldous", "kaelen", "willow"]
const PHASES := [0.0, 0.25, 0.5, 0.75]

var _cam: Camera3D
var _rigs: Array = []          # [{rig, clip, label}]
var _label: Label


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.09, 0.10, 0.13)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.58, 0.66)
	e.ambient_light_energy = 0.9
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, -38.0, 0.0)
	sun.light_energy = 2.0
	add_child(sun)

	# A floor, so the feet have something to read against.
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(24.0, 24.0)
	floor_mi.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.22, 0.24, 0.20)
	floor_mi.material_override = mat
	add_child(floor_mi)

	_cam = Camera3D.new()
	_cam.fov = 38.0
	# look_at_from_position, not look_at: nothing is inside the tree yet in _ready.
	_cam.look_at_from_position(Vector3(0.0, 1.35, 4.3), Vector3(0.0, 0.95, 0.0), Vector3.UP)
	add_child(_cam)

	var ui := Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ui)
	_label = Label.new()
	_label.position = Vector2(20, 16)
	_label.add_theme_font_size_override("font_size", 22)
	_label.add_theme_color_override("font_color", Color(1, 1, 1))
	ui.add_child(_label)

	_run()


# One linear coroutine instead of a _process() state machine: the capture has to
# await two frames, and _process kept running underneath it, advancing the
# AnimationPlayer and relabelling the shot that was mid-flight. The first run of
# this harness wrote "phase 0.25" onto the phase-0.00 file for exactly that
# reason. Driving it sequentially makes the label and the pixels the same frame.
func _run() -> void:
	for hero in HEROES:
		_load_hero(hero)
		for phase in PHASES:
			await _capture(hero, float(phase))
	print("done")
	get_tree().quit()


func _load_hero(hero: String) -> void:
	for d in _rigs:
		(d["rig"] as Node).queue_free()
	_rigs.clear()

	# Left: running. Right: stunned (= walk). Same hero, same camera, same light.
	var specs := [
		{"x": -1.25, "state": HeroRig.State.RUN, "label": "RUN"},
		{"x": 1.25, "state": HeroRig.State.WALK, "label": "STUNNED (walk)"},
	]
	for s in specs:
		var rig := HeroRig.new()
		add_child(rig)
		if not rig.load_hero(hero):
			push_error("could not load " + hero)
			continue
		rig.position = Vector3(float(s["x"]), 0.0, 0.0)
		# The models face +Z (ANIMATION-HANDOFF.md) and the camera sits at +Z, so
		# 0 deg is straight at the lens; 25 deg is the three-quarter the game uses.
		rig.rotation_degrees = Vector3(0.0, 25.0, 0.0)
		rig.set_state(int(s["state"]))
		# Freeze the procedural stand-in out of the picture: these are rigged, so
		# _procedural() never runs, but assert it rather than hope.
		if not rig.is_rigged:
			push_error(hero + " is not rigged; this harness proves nothing")
		_rigs.append({
			"rig": rig,
			"clip": rig._clip_for.get(int(s["state"]), ""),
			"label": String(s["label"]),
		})


func _pose(phase: float) -> void:
	for d in _rigs:
		var rig: HeroRig = d["rig"]
		var clip: String = d["clip"]
		if clip == "":
			continue
		var ap: AnimationPlayer = rig._anim
		var a: Animation = ap.get_animation(clip)
		ap.play(clip)
		ap.seek(a.length * phase, true)


func _capture(hero: String, phase: float) -> void:
	var lens := []
	for d in _rigs:
		var rig: HeroRig = d["rig"]
		var a: Animation = rig._anim.get_animation(String(d["clip"]))
		lens.append("%s  %s  len %.2fs" % [d["label"], d["clip"], a.length])
	_label.text = "%s   both clips seeked to phase %.2f\nLEFT   %s\nRIGHT  %s" % [
		hero, phase,
		lens[0] if lens.size() > 0 else "?",
		lens[1] if lens.size() > 1 else "?"]

	# Pose, let one frame draw with that pose, re-pose (the AnimationPlayer
	# advanced during that frame), then grab the next frame.
	_pose(phase)
	await RenderingServer.frame_post_draw
	_pose(phase)
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/stun_%s_p%02d.png" % [OUT, hero, int(phase * 100.0)]
	img.save_png(ProjectSettings.globalize_path(path))
	print("wrote ", path)
