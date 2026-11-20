extends Node3D
# Drive the controller and check it actually works: does the hero path to where
# it was told, does it arrive, do ability states enter and clear, and does it
# stay on walkable ground the whole way.

var _builder: WorldBuilder
var _cam: ArpgCamera
var _hero: HeroController
var _ter: Terrain
var _plan: Layout
var _offground: int = 0
var _samples: int = 0


func _ready() -> void:
	_cam = ArpgCamera.new()
	add_child(_cam)
	_builder = WorldBuilder.new()
	add_child(_builder)
	_builder.finished.connect(_go)
	_builder.build(7000, "greenwood", 384, 0.5)


func _go(root: Node3D, ter: Terrain, plan: Layout) -> void:
	add_child(root)
	add_child(Mesher.build_sun("greenwood"))
	var we := WorldEnvironment.new()
	we.environment = Mesher.build_environment("greenwood")
	add_child(we)
	_ter = ter
	_plan = plan

	var heroes: PackedStringArray = HeroRig.animated_heroes()
	print("heroes available: %d" % heroes.size())

	# Deliberately play an ANIMATED hero: take the first name that actually has
	# a .glb in ANIMATED_DIR, so this run exercises the real rig and not the
	# procedural stand-in.
	var pick: String = ""
	for h in heroes:
		if HeroRig.is_animated(h):
			pick = h
			break
	if pick == "":
		print("FAIL: no animated hero found in %s" % HeroRig.ANIMATED_DIR)
		get_tree().quit(); return
	print("picked ANIMATED hero '%s' (is_animated=%s)" % [pick, str(HeroRig.is_animated(pick))])

	var entry: Dictionary = plan.node_of_kind(Layout.ENTRY)
	_hero = HeroController.new()
	add_child(_hero)
	if not _hero.setup(ter, pick, entry.get("pos", Vector2.ZERO)):
		print("FAIL: hero setup"); get_tree().quit(); return
	_cam.terrain = ter
	_cam.target = _hero
	_cam.snap_to_target()

	print("hero '%s'  rigged=%s  missing clips: %s" % [
		pick, str(_hero.rig.is_rigged), str(_hero.rig.missing_states())])
	await _run()
	get_tree().quit()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://tools/out"))

	# Walk to every arena on the plan in turn. If the generator says the level
	# is connected, the controller should be able to prove it on foot.
	var targets: Array = []
	for n in _plan.nodes:
		targets.append(n["pos"])

	var reached: int = 0
	var failed: int = 0
	for i in range(mini(targets.size(), 8)):
		var goal: Vector2 = targets[i]
		# Already standing there (the entry node) is not a failure.
		if _hero.ground_position().distance_to(goal) < 2.0:
			print("  %d. already at (%.0f, %.0f)" % [i, goal.x, goal.y])
			reached += 1
			continue
		var ok: bool = _hero.move_to(goal, true)
		if not ok:
			print("  %d. NO PATH to (%.0f, %.0f)" % [i, goal.x, goal.y])
			failed += 1
			continue

		var legs: int = _hero.path_points().size()
		var t0: int = Time.get_ticks_msec()
		var guard: int = 0
		while _hero.is_moving() and guard < 4000:
			await get_tree().process_frame
			guard += 1
			_check_ground()
		var dist: float = _hero.ground_position().distance_to(goal)
		var secs: float = float(Time.get_ticks_msec() - t0) / 1000.0
		if guard >= 4000:
			print("  %d. TIMED OUT %.1f m short of (%.0f, %.0f)" % [
				i, dist, goal.x, goal.y])
			failed += 1
		else:
			print("  %d. reached (%6.0f,%6.0f)  %2d waypoints  %4.1f s  within %.1f m"
				% [i, goal.x, goal.y, legs, secs, dist])
			reached += 1
		if i == 1:
			_shot("play_01_walk")

	# --- abilities --------------------------------------------------------
	print("\nabilities:")
	for slot in range(4):
		var started: bool = _hero.use_ability(slot)
		var entered: int = _hero.rig.state()
		var guard2: int = 0
		while _hero.is_busy() and guard2 < 600:
			await get_tree().process_frame
			guard2 += 1
		print("  slot %d: started=%s  state=%d  cleared=%s" % [
			slot, str(started), entered, str(not _hero.is_busy())])
	_shot("play_02_ability")

	print("\n=== result ===")
	print("  arenas reached: %d / %d   failed: %d" % [reached, reached + failed, failed])
	print("  off-walkable samples: %d / %d" % [_offground, _samples])


func _check_ground() -> void:
	_samples += 1
	if not _hero.pathing.is_walkable(_hero.ground_position()):
		_offground += 1
	# Feet must stay on the surface, not float above or sink into it.
	var want: float = _ter.height_at(_hero.ground_position())
	if absf(_hero.position.y - want) > 0.05:
		_offground += 1


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("res://tools/out/%s.png" % name))
