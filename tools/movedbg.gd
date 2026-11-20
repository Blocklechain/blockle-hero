extends Node3D
# Is the hero moving at all, and is _physics_process even firing?

var _b: WorldBuilder
var _h: HeroController
var ticks: int = 0

func _ready() -> void:
	_b = WorldBuilder.new(); add_child(_b)
	_b.finished.connect(_go)
	_b.build(7000, "greenwood", 384, 0.5)

func _go(root: Node3D, ter: Terrain, plan: Layout) -> void:
	add_child(root)
	var entry: Dictionary = plan.node_of_kind(Layout.ENTRY)
	var boss: Dictionary = plan.node_of_kind(Layout.BOSS)
	_h = HeroController.new(); add_child(_h)
	_h.setup(ter, "aldous", entry.get("pos", Vector2.ZERO))

	var from: Vector2 = _h.ground_position()
	var to: Vector2 = boss.get("pos", Vector2.ZERO)
	print("from (%.1f, %.1f) to (%.1f, %.1f)  dist %.1f m" % [
		from.x, from.y, to.x, to.y, from.distance_to(to)])

	var raw: PackedVector2Array = _h.pathing.find(from, to)
	print("path waypoints: %d" % raw.size())
	for i in range(mini(raw.size(), 5)):
		print("   wp%d (%.1f, %.1f)  walkable=%s" % [i, raw[i].x, raw[i].y,
			str(_h.pathing.is_walkable(raw[i]))])

	HeroController.debug_stalls = true
	var ok: bool = _h.move_to(to, true)
	print("move_to returned %s, is_moving=%s" % [str(ok), str(_h.is_moving())])

	for s in range(3):
		for f in range(30):
			await get_tree().process_frame
		print("  t+%ds  pos (%.1f, %.1f)  moving=%s  physics ticks=%d" % [
			s, _h.ground_position().x, _h.ground_position().y,
			str(_h.is_moving()), ticks])
	get_tree().quit()

func _physics_process(_d: float) -> void:
	ticks += 1
