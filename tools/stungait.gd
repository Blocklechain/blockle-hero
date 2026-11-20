extends Node3D
# ------------------------------------------------------------------------------
# THE HONEST STUN TEST: does run-vs-walk read AT THE REAL GAME CAMERA?
#
# tools/stunshot.gd compares poses from 4 m away, which flatters the difference.
# ArpgCamera actually sits DISTANCE=25 m out at 48 deg pitch / 35 deg yaw on a
# 38 deg lens, and the game ships portrait 1170x2532. At 25 m a 1.85 m hero is
# ~10.7% of the screen height, so a limb angle is small and CADENCE is the
# signal that has to carry the stun.
#
# So: run both clips at REAL TIME (AnimationPlayer.advance with a manual
# callback, no seeking), sample 8 instants across one full walk cycle, crop each
# hero out and tile them. Reading a row left-to-right is reading the gait at the
# speed the player sees it. Top row RUN, bottom row STUNNED (= walk).
#
# Rendered into a SubViewport at EXACTLY the shipping resolution, not into the
# OS window: a window is clamped to the desktop and silently rescaled (measured:
# asking for 1600x900 gave a 4501x2532 visible rect because of the canvas_items
# stretch), and then the pixel sizes in the sheet mean nothing.
#
#   godot --path . res://scenes/StunGait.tscn
# ------------------------------------------------------------------------------

const OUT := "res://tools/out"
const HEROES := ["aldous", "kaelen"]

# One full WALK cycle, which is exactly two RUN cycles. 8 samples across it.
const SPAN := 1.4667
const STEPS := 8

const SHIP := Vector2i(1170, 2532)       # project.godot display/window/size
const CW := 300                          # crop box, in SHIP pixels
const CH := 460
const ZOOM := 2                          # upscale the sheet so a human can see it

var _vp: SubViewport
var _cam: Camera3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))

	_vp = SubViewport.new()
	_vp.size = SHIP
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_2X
	add_child(_vp)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.11, 0.14)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.62, 0.7)
	e.ambient_light_energy = 1.0
	env.environment = e
	_vp.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	sun.light_energy = 1.8
	_vp.add_child(sun)

	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(80.0, 80.0)
	floor_mi.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.27, 0.30, 0.25)
	floor_mi.material_override = mat
	_vp.add_child(floor_mi)

	# EXACTLY ArpgCamera's framing, recomputed from its own constants so this
	# cannot drift away from the camera the game actually ships.
	var pitch: float = deg_to_rad(ArpgCamera.PITCH_DEG)
	var yaw: float = deg_to_rad(ArpgCamera.YAW_DEG)
	var off: Vector3 = Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) \
		* ArpgCamera.DISTANCE
	var look := Vector3(0.0, ArpgCamera.HEIGHT_BIAS, 0.0)
	_cam = Camera3D.new()
	_cam.fov = 38.0
	_cam.far = 600.0
	_cam.look_at_from_position(look + off, look, Vector3.UP)
	_vp.add_child(_cam)

	_go()


# Offset the two heroes along the CAMERA's right vector, not world X: the camera
# is yawed 35 deg, so a world-X split puts one hero closer to the lens than the
# other and their on-screen sizes stop being comparable.
func _spawn(hero: String, x: float, state: int) -> HeroRig:
	var rig := HeroRig.new()
	_vp.add_child(rig)
	if not rig.load_hero(hero):
		push_error("load failed: " + hero)
	if not rig.is_rigged:
		push_error(hero + " is not rigged; this harness would prove nothing")
	rig.position = _cam.global_transform.basis.x.normalized() * x
	rig.rotation_degrees = Vector3(0.0, 180.0 + ArpgCamera.YAW_DEG, 0.0)
	rig.set_state(state)
	# Manual advance only: the default callback would tick these every frame on
	# top of our stepping, and the whole point is that both clips see the SAME
	# elapsed time.
	rig._anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	rig._anim.seek(0.0, true)
	return rig


func _go() -> void:
	for hero in HEROES:
		var run_rig: HeroRig = _spawn(hero, -3.2, HeroRig.State.RUN)
		var walk_rig: HeroRig = _spawn(hero, 3.2, HeroRig.State.WALK)

		var sheet := Image.create(CW * STEPS, CH * 2, false, Image.FORMAT_RGBA8)
		sheet.fill(Color(0.06, 0.07, 0.09))

		var dt: float = SPAN / float(STEPS)
		for i in STEPS:
			if i > 0:
				run_rig._anim.advance(dt)
				walk_rig._anim.advance(dt)
			await RenderingServer.frame_post_draw
			var frame: Image = _vp.get_texture().get_image()
			if frame.get_format() != sheet.get_format():
				frame.convert(sheet.get_format())
			if i == 0:
				print("  %s: subviewport frame %dx%d, hero height ~%d px" % [
					hero, frame.get_width(), frame.get_height(),
					_hero_px(run_rig)])
			_blit(sheet, frame, run_rig, i, 0)
			_blit(sheet, frame, walk_rig, i, 1)

		sheet.resize(sheet.get_width() * ZOOM, sheet.get_height() * ZOOM,
			Image.INTERPOLATE_NEAREST)
		var path: String = "%s/gait_%s.png" % [OUT, hero]
		sheet.save_png(ProjectSettings.globalize_path(path))
		print("wrote %s  (top row RUN, bottom row STUNNED/walk; %dx upscaled)" % [path, ZOOM])
		run_rig.queue_free()
		walk_rig.queue_free()

	print("done")
	get_tree().quit()


# How tall is this hero in SHIP pixels? The number that decides whether any of
# this is visible on a phone.
func _hero_px(rig: HeroRig) -> int:
	var feet: Vector2 = _cam.unproject_position(rig.position)
	var head: Vector2 = _cam.unproject_position(rig.position + Vector3(0.0, 1.85, 0.0))
	return int(absf(head.y - feet.y))


func _blit(sheet: Image, frame: Image, rig: HeroRig, col: int, row: int) -> void:
	# unproject the hero's chest so the crop is centred on the body, not the feet.
	var p: Vector2 = _cam.unproject_position(rig.position + Vector3(0.0, 0.95, 0.0))
	var src := Rect2i(int(p.x) - CW / 2, int(p.y) - CH / 2, CW, CH)
	src = src.intersection(Rect2i(0, 0, frame.get_width(), frame.get_height()))
	if src.size.x <= 0 or src.size.y <= 0:
		push_error("hero off-screen at col %d row %d (p=%s)" % [col, row, str(p)])
		return
	sheet.blit_rect(frame, src, Vector2i(col * CW, row * CH))
