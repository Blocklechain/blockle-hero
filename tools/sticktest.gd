extends SceneTree
# ------------------------------------------------------------------------------
# The movement stick and the pinch zoom.
#
# THE ASSERTION THAT MATTERS is not "drive() was called". It is that pushing the
# stick a direction on the GLASS moves the champion that direction on the GLASS.
# ArpgCamera holds a fixed 35-degree yaw and never turns, so screen-up is not
# world-north; a raw stick vector sends the champion off at an angle to the
# thumb, and that reads as drift rather than as a bug — nobody files it, the
# game just feels wrong. The only honest way to check it is to move the hero
# along the computed direction and PROJECT THE RESULT BACK TO SCREEN SPACE,
# which is what _screen_agrees does. A dot-product against a hand-derived
# forward vector would just repeat the implementation's own arithmetic.
#
#   godot --headless --path . --script tools/sticktest.gd
# ------------------------------------------------------------------------------

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	# Deferred: during a SceneTree's _init the root window is not ready, so a
	# node added here is not yet "inside the tree" and get_viewport_rect()
	# returns an empty Rect2 — which silently makes every zone test pass.
	_go.call_deferred()


func _go() -> void:
	_zone()
	_response()
	_screen_agrees()
	_zoom()
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------

func _zone() -> void:
	print("\n=== the stick only claims its own corner ===")
	var js := Joystick.new()
	get_root().add_child(js)
	var vp: Vector2 = js.get_viewport_rect().size

	check("claims a press on the left", js.claims(Vector2(vp.x * 0.15, vp.y * 0.6)))
	check("ignores the right half, where the keys are",
		not js.claims(Vector2(vp.x * 0.85, vp.y * 0.6)))
	check("ignores the far bottom, where the home indicator lives",
		not js.claims(Vector2(vp.x * 0.15, vp.y * 0.99)))
	check("starts released", not js.is_active())
	js.queue_free()


func _response() -> void:
	print("\n=== dead zone, analogue range, and the run threshold ===")
	var js := Joystick.new()
	get_root().add_child(js)
	var origin := Vector2(300.0, 600.0)

	js._grab(0, origin)
	check("a press with no drag is NOT movement", js.direction() == Vector2.ZERO,
		"a thumb resting on glass must not creep")

	js._move(origin + Vector2(Joystick.RADIUS * 0.05, 0.0))
	check("a twitch inside the dead zone is still nothing",
		js.direction() == Vector2.ZERO, "5% deflection")

	js._move(origin + Vector2(Joystick.RADIUS * 0.35, 0.0))
	var mid: float = js.direction().length()
	check("a half push is a walk, not a run", mid > 0.0 and not js.wants_run(),
		"magnitude %.2f, run at %.2f" % [mid, Joystick.RUN_AT])

	js._move(origin + Vector2(Joystick.RADIUS * 2.0, 0.0))
	check("pushing past the ring clamps to full tilt",
		absf(js.direction().length() - 1.0) < 0.001,
		"magnitude %.3f at 200%% deflection" % js.direction().length())
	check("...and that is a run", js.wants_run())

	js._release()
	check("releasing stops the champion", js.direction() == Vector2.ZERO)

	# The reason the index is tracked at all.
	js._grab(3, origin)
	js._move(origin + Vector2(0.0, -Joystick.RADIUS))
	var held: Vector2 = js.direction()
	js._input(_touch_at(7, Vector2(1800.0, 700.0), true))     # an ability press
	check("a second finger does not steal the stick", js.direction() == held,
		"still %.2f, %.2f while another finger is down" % [held.x, held.y])
	js.queue_free()


func _screen_agrees() -> void:
	print("\n=== the champion goes where the thumb points, ON SCREEN ===")
	var cam := ArpgCamera.new()
	get_root().add_child(cam)
	var pivot := Node3D.new()
	get_root().add_child(pivot)
	pivot.position = Vector3.ZERO
	cam.target = pivot
	cam.snap_to_target()

	var here: Vector2 = cam.unproject_position(Vector3.ZERO)
	for probe in [
			{"name": "up", "dir": Vector2(0.0, -1.0), "dx": 0.0, "dy": -1.0},
			{"name": "down", "dir": Vector2(0.0, 1.0), "dx": 0.0, "dy": 1.0},
			{"name": "right", "dir": Vector2(1.0, 0.0), "dx": 1.0, "dy": 0.0},
			{"name": "left", "dir": Vector2(-1.0, 0.0), "dx": -1.0, "dy": 0.0}]:
		var d: Vector2 = probe["dir"]
		# THE SHIPPING FUNCTION, not a copy of it. See ArpgCamera.stick_to_world.
		var world: Vector2 = ArpgCamera.stick_to_world(d)
		var moved: Vector2 = cam.unproject_position(
			Vector3(world.x * 8.0, 0.0, world.y * 8.0))
		var delta: Vector2 = moved - here
		var want_x: float = float(probe["dx"])
		var want_y: float = float(probe["dy"])
		# Only the sign of the dominant axis is asserted: the camera is at a
		# yaw, so pushing "up" moves up AND slightly sideways on screen, which
		# is correct and expected.
		var ok: bool = (want_x == 0.0 or signf(delta.x) == signf(want_x)) \
			and (want_y == 0.0 or signf(delta.y) == signf(want_y))
		check("stick %-5s moves the champion %s on screen" % [probe["name"], probe["name"]],
			ok, "screen delta %.0f, %.0f px" % [delta.x, delta.y])

	cam.queue_free()
	pivot.queue_free()


func _zoom() -> void:
	print("\n=== pinch zoom is real, and bounded ===")
	var cam := ArpgCamera.new()
	get_root().add_child(cam)
	var pivot := Node3D.new()
	get_root().add_child(pivot)
	cam.target = pivot
	cam.snap_to_target()

	var base: float = cam.zoom_level()
	check("starts at 1:1", absf(base - 1.0) < 0.001, "%.2f" % base)

	for i in range(60):
		cam.pinch(1.2)
	cam._process(1.0)
	check("cannot zoom out past the limit", cam.zoom_level() <= ArpgCamera.ZOOM_MAX + 0.001,
		"%.2f, cap %.2f" % [cam.zoom_level(), ArpgCamera.ZOOM_MAX])

	for i in range(120):
		cam.pinch(0.8)
	cam._process(1.0)
	check("cannot zoom in past the limit", cam.zoom_level() >= ArpgCamera.ZOOM_MIN - 0.001,
		"%.2f, floor %.2f" % [cam.zoom_level(), ArpgCamera.ZOOM_MIN])

	# The point of the clamp: the view stays an ARPG view at both ends.
	check("the whole range is slight", ArpgCamera.ZOOM_MAX / ArpgCamera.ZOOM_MIN < 2.0,
		"%.2fx between the stops" % (ArpgCamera.ZOOM_MAX / ArpgCamera.ZOOM_MIN))
	cam.queue_free()
	pivot.queue_free()


func _touch_at(index: int, pos: Vector2, pressed: bool) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	return e
