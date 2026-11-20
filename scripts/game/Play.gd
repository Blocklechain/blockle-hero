extends Node3D
# ------------------------------------------------------------------------------
# The playable slice: generate a region on the background thread, drop a hero in
# it, and let the player walk around.
#
# Input is deliberately minimal and touch-first, because this ships on iOS only:
#   tap / click        walk there
#   hold               keep walking toward the finger
#   1-4 or on-screen   basic attack and the three abilities
# ------------------------------------------------------------------------------

@export var world_seed: int = 7000
@export var biome: String = "greenwood"
@export var hero: String = ""

var _builder: WorldBuilder
var _cam: ArpgCamera
var _hero: HeroController
var _ui: Control
var _status: Label
var _holding: bool = false
var _hold_at: Vector2 = Vector2.ZERO


func _ready() -> void:
	_cam = ArpgCamera.new()
	add_child(_cam)
	_build_ui()

	_builder = WorldBuilder.new()
	add_child(_builder)
	_builder.progress.connect(func(s: String, f: float):
		_status.text = "%s  %d%%" % [s, int(f * 100.0)])
	_builder.finished.connect(_on_world_ready)
	_builder.build(world_seed, biome, 384, 0.5)


func _on_world_ready(root: Node3D, ter: Terrain, plan: Layout) -> void:
	add_child(root)

	var we := WorldEnvironment.new()
	we.environment = Mesher.build_environment(biome)
	add_child(we)
	add_child(Mesher.build_sun(biome))

	var heroes: PackedStringArray = HeroRig.animated_heroes()
	var pick: String = hero if hero != "" else (heroes[0] if heroes.size() > 0 else "")
	if pick == "":
		_status.text = "No hero models found"
		return

	var entry: Dictionary = plan.node_of_kind(Layout.ENTRY)
	var at: Vector2 = entry.get("pos", Vector2.ZERO)

	_hero = HeroController.new()
	add_child(_hero)
	if not _hero.setup(ter, pick, at):
		_status.text = "Failed to load hero '%s'" % pick
		return

	_cam.terrain = ter
	_cam.target = _hero
	_cam.snap_to_target()

	var rigged: String = "rigged" if _hero.rig.is_rigged else "STATIC (procedural stand-in)"
	_status.text = "%s — %s   tap to move, 1-4 to strike" % [pick, rigged]
	print("hero '%s': %s" % [pick, rigged])
	if _hero.rig.is_rigged:
		print("  missing clips: ", _hero.rig.missing_states())


# ------------------------------------------------------------------------------
# Input
# ------------------------------------------------------------------------------

func _unhandled_input(e: InputEvent) -> void:
	if _hero == null:
		return

	if e is InputEventScreenTouch or e is InputEventMouseButton:
		if e.pressed:
			_holding = true
			_hold_at = e.position
			_order_move(e.position)
		else:
			_holding = false
	elif e is InputEventScreenDrag or e is InputEventMouseMotion:
		if _holding:
			_hold_at = e.position
	elif e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_1: _hero.use_ability(0)
			KEY_2: _hero.use_ability(1)
			KEY_3: _hero.use_ability(2)
			KEY_4: _hero.use_ability(3)
			KEY_ESCAPE: get_tree().quit()


func _process(_d: float) -> void:
	# Held finger: keep re-issuing toward where it is now, so dragging steers
	# rather than requiring a tap per step. Re-pathing every frame would be
	# wasteful, so only when the target has moved meaningfully.
	if _holding and _hero != null and not _hero.is_busy():
		if not _hero.is_moving():
			_order_move(_hold_at)


func _order_move(screen: Vector2) -> void:
	var g: Vector2 = _cam.screen_to_ground(screen)
	if g == Vector2.INF:
		return
	_hero.move_to(g, true)


func _build_ui() -> void:
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ui)

	_status = Label.new()
	_status.position = Vector2(18, 14)
	_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	_status.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_status.add_theme_constant_override("shadow_offset_y", 2)
	_ui.add_child(_status)
