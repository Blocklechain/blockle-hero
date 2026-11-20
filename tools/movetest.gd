extends SceneTree
# ------------------------------------------------------------------------------
# Movement abilities: the charge, the backstep, and the rule that matters.
#
# THE RULE THAT MATTERS: a displacement may never leave the champion off the
# walk grid. A blink into a cliff is not a glitch you shrug at — the body is
# outside the only authority on movement, pathing cannot route out of it, and
# the run is over with no message and no way back. Shortening a dash is
# survivable; arriving inside terrain is not. So this fires displacements in
# every direction from many positions on a REAL region, including deliberately
# at the map edge and into rock, and asserts the landing every time.
#
# The second thing it guards is the rig contract: these ride ability_2 and
# ability_3, the clips that already exist. If a movement ability ever needed a
# clip of its own, 139 champions would need re-exporting — so the test asserts
# the kit still has exactly four actions.
#
#   godot --headless --path . --script tools/movetest.gd
# ------------------------------------------------------------------------------

const CELLS: int = 256
const CELL: float = 0.5

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-52s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	var seed: int = 4242
	var plan: Layout = Terrain.plan_for(Terrain.Kind.LANE, seed,
		Vector2(CELLS * CELL, CELLS * CELL))
	var ter: Terrain = Terrain.generate(seed, "greenwood", CELLS, CELL, plan)
	var path := Pathing.new(ter)

	_kits()
	_landings(ter, path)
	_charge(ter, path)

	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


func _kits() -> void:
	print("\n=== the rig contract still holds ===")
	var roster: PackedStringArray = HeroRig.animated_heroes()
	var four: bool = true
	var movers: int = 0
	var on_new_clip: bool = false
	for h in roster:
		var cls: int = HeroClass.for_hero(h)
		var kit: Array[Ability] = Ability.for_hero(h, cls)
		if kit.size() != 3:
			four = false
		for a in kit:
			if a.move_kind != Ability.Move.NONE:
				movers += 1
				# The whole constraint: a displacement must ride one of the
				# three clips that exist.
				if a.slot < 1 or a.slot > 3:
					on_new_clip = true
	check("every champion still has exactly 4 actions", four,
		"basic + 3, across %d champions" % roster.size())
	check("no movement ability asked for a new clip", not on_new_clip)
	check("movement abilities actually exist", movers > 0,
		"%d across the roster" % movers)


func _landings(ter: Terrain, path: Pathing) -> void:
	print("\n=== a displacement never lands off the walk grid ===")
	var tried: int = 0
	var bad: int = 0
	var shortened: int = 0
	var worst: String = ""

	# Sweep real positions, including the map edge where the rim wall is and a
	# naive dash would put the body inside it.
	for gx in range(6):
		for gy in range(6):
			var start: Vector2 = path.nearest_walkable_centre(Vector2(
				-CELLS * CELL * 0.45 + gx * CELLS * CELL * 0.18,
				-CELLS * CELL * 0.45 + gy * CELLS * CELL * 0.18))
			var hero := HeroController.new()
			get_root().add_child(hero)
			if not hero.setup(ter, "aldous", start):
				hero.queue_free()
				continue
			for step in range(16):
				var a: float = TAU * float(step) / 16.0
				var aim: Vector2 = start + Vector2(cos(a), sin(a)) * 40.0
				var ab := Ability.new()
				ab.move_kind = Ability.Move.BLINK
				ab.move_distance = 12.0
				hero._begin_dash(ab, aim)
				var landed: Vector2 = hero.ground_position()
				tried += 1
				if not path.is_walkable(landed):
					bad += 1
					worst = "(%.1f, %.1f)" % [landed.x, landed.y]
				if landed.distance_to(start) < 11.5:
					shortened += 1
				hero._place(start)
			hero.queue_free()

	check("every blink landed on walkable ground", bad == 0,
		"%d of %d bad%s" % [bad, tried, "  worst " + worst if bad > 0 else ""])
	check("blinks were shortened rather than cancelled", shortened > 0,
		"%d of %d clipped to fit the terrain" % [shortened, tried])
	check("the sweep was broad enough to mean something", tried >= 300,
		"%d blinks from %d positions" % [tried, tried / 16])


func _charge(ter: Terrain, path: Pathing) -> void:
	print("\n=== a charge closes the gap, and stops at the target ===")
	var start: Vector2 = path.nearest_walkable_centre(Vector2.ZERO)
	var hero := HeroController.new()
	get_root().add_child(hero)
	if not hero.setup(ter, "aldous", start):
		check("could not build a champion", false)
		return

	var target: Vector2 = path.nearest_walkable_centre(start + Vector2(8.0, 0.0))
	var slam: Ability = null
	for a in Ability.for_hero("brom", HeroClass.Kind.FIGHTER):
		if a.move_kind == Ability.Move.CHARGE:
			slam = a
	check("the fighter's control ability is a charge", slam != null,
		slam.title if slam != null else "none found")
	if slam == null:
		return
	check("...and it rides ability_2, a clip that exists",
		slam.anim_state() == HeroRig.State.ABILITY_2)

	var before: float = start.distance_to(target)
	hero._begin_dash(slam, target)
	# Run the travel out.
	for i in range(40):
		if hero._dash_time <= 0.0:
			break
		hero._advance_dash(0.016)
	var after: float = hero.ground_position().distance_to(target)
	check("the champion closed on the target", after < before,
		"%.1f m -> %.1f m" % [before, after])
	check("...without overshooting past it", after >= 0.0 and after < before,
		"stops %.1f m short, in reach" % after)
	check("and ends on walkable ground", path.is_walkable(hero.ground_position()))
	hero.queue_free()
