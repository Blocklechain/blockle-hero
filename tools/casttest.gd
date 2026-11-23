extends SceneTree
# ------------------------------------------------------------------------------
# CASTING NO LONGER PLANTS YOUR FEET.
#
# Every ability used to root the champion for the length of its clip. On a
# phone that reads as the game dropping inputs: the left thumb is still
# pushing, the hero stops dead in the middle of a pack, and the
# three-quarters of a second they spent standing still is how they died. It
# was not a design decision — `use_ability` called `stop()` and
# `_physics_process` returned early while busy, for every ability, with no way
# to say otherwise.
#
# What is asserted here is the DISPLACEMENT. Not that a flag is set, not that
# a function was called — that the champion is somewhere else at the end of a
# cast than at the start, because that is the only thing the player can feel.
#
# And the two things that must NOT have been traded away for it:
#
#   * A ROOTED ability still roots. Some abilities should cost you your
#     footing — that is the whole trade of a heavy wind-up — and anything
#     that moves you itself cannot also be steered, or the dash and the stick
#     fight over the same position every frame.
#   * THE AIM SURVIVES THE MOVEMENT. A cone lined up on a pack and then
#     strafed away from must still leave where it was aimed, or casting while
#     moving has made aiming worse than standing still.
# ------------------------------------------------------------------------------

const HC := preload("res://scripts/game/HeroController.gd")
const AB := preload("res://scripts/game/Ability.gd")

var _fails: int = 0
var _ran: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-56s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _init() -> void:
	var design := Vector2i(
		ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height"))
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_size = design
	get_root().size = design
	await process_frame

	await _defaults(); _ran += 1
	await _moves_while_casting(); _ran += 1
	await _rooted_still_roots(); _ran += 1
	await _aim_survives(); _ran += 1
	print("")
	check("every section ran to completion", _ran == 4, "%d of 4" % _ran)
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


# ---- a real champion on real ground -----------------------------------------

## A hero standing on a generated region, with a combat body and its kit.
##
## The REAL Terrain and Pathing, because _drive_step consults walkability every
## step — a stub that says "everything is walkable" would pass this test for a
## champion who cannot actually move anywhere.
func _hero() -> Dictionary:
	var shape: Dictionary = {}
	var seed: int = 4242
	var plan: Layout = Terrain.plan_for(Terrain.Kind.ARENA, seed,
		Vector2(96, 96) * 0.5, Layout.Sym.ASYMMETRIC, 7)
	var ter: Terrain = Terrain.generate(seed, "greenwood", 96, 0.5, plan)
	var path := Pathing.new(ter)
	# Stood somewhere with room on every side, so a blocked step cannot be
	# mistaken for a root.
	var at: Vector2 = plan.node_of_kind(Layout.ENTRY).get("pos", Vector2.ZERO)
	at = path.nearest_walkable_centre(at)
	var open: Vector2 = Vector2.ZERO
	for step in range(32):
		var ang: float = TAU * float(step) / 32.0
		var d := Vector2(cos(ang), sin(ang))
		if path.clear_line(at, at + d * 8.0):
			open = d
			break

	var heroes: PackedStringArray = HeroRig.animated_heroes()
	var who: String = heroes[0]
	var h: HeroController = HC.new()
	root.add_child(h)
	if not h.setup(ter, who, at):
		return {}
	var body: Combatant = Combat.champion_body(null, who, 10,
		Rng.seed_of(seed, who), who)
	h.setup_combat(body, HeroClass.for_hero(who), who)
	return {"hero": h, "open": open, "path": path, "at": at}


func _defaults() -> void:
	print("\n=== the default is to keep moving ===")
	var a: Ability = AB.new()
	check("a plain ability does not root", not a.rooted)
	# Every real ability in the game, so a hero's actual kit is checked rather
	# than a constructed one.
	var heroes: PackedStringArray = HeroRig.animated_heroes()
	var rooted: int = 0
	var total: int = 0
	var self_moving_rooted: int = 0
	var self_moving: int = 0
	for i in range(mini(30, heroes.size())):
		var cls: int = HeroClass.for_hero(heroes[i])
		for ab in Ability.for_hero(heroes[i], cls):
			total += 1
			if (ab as Ability).rooted:
				rooted += 1
			if (ab as Ability).move_kind != Ability.Move.NONE:
				self_moving += 1
	check("most of the real kit is castable on the move",
		total > 0 and rooted < total / 2,
		"%d of %d abilities root" % [rooted, total])
	check("...and there are self-moving abilities to protect",
		self_moving > 0, "%d dash-likes" % self_moving)


# ---- THE ASSERTION THIS FILE EXISTS FOR -------------------------------------

func _moves_while_casting() -> void:
	print("\n=== the champion moves during a cast ===")
	var h: Dictionary = _hero()
	if h.is_empty():
		check("a champion could be placed on real ground", false)
		return
	var hero: HeroController = h["hero"]
	var dir: Vector2 = h["open"]

	# A non-rooted ability. Built rather than taken from a hero's kit so the
	# test is about the mechanism, not about which ability a given hero rolled.
	var ab: Ability = AB.new()
	ab.id = "test_cast"
	ab.slot = 1
	ab.rooted = false
	ab.move_kind = Ability.Move.NONE
	ab.cooldown = 0.0
	hero.abilities = [ab, ab, ab] as Array[Ability]

	hero.drive(dir, true)
	await process_frame
	var before: Vector2 = hero.ground_position()
	check("the ability was accepted", hero.use_ability(1, before + dir * 10.0))
	check("...and the champion is busy casting", hero.is_busy())

	# Hold the stick through the cast, as a player would.
	# MEASURED AS A RATE OVER REAL TIME, not as a distance over a frame count.
	#
	# This used to drive 30 frames and compare the result against
	# `RUN_SPEED * 30.0 * (1.0 / 60.0)` — which assumes 60 fps. A headless
	# frame takes however long it takes, so both halves of that were a
	# different measurement on every machine. The same mistake in
	# tools/dodgetest.gd shipped a red CI build (run 45141721284: "THE CHAMPION
	# MOVED  1.29 m" on the runner where this laptop measured 3.67 m), so it is
	# worth correcting here before it does the same.
	#
	# Speed is the property under test anyway: the champion must move, and move
	# SLOWER than a free run, and neither statement needs a frame count.
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 350:
		hero.drive(dir, true)
		await process_frame
	var elapsed: float = float(Time.get_ticks_msec() - t0) / 1000.0
	var after: Vector2 = hero.ground_position()
	var moved: float = before.distance_to(after)
	var rate: float = moved / maxf(elapsed, 0.001)
	check("THE CHAMPION MOVED while the cast played", moved > 0.05,
		"%.2f m in %.2f s" % [moved, elapsed])
	# It should be SLOWER than a free run, not equal to it — the slide has to
	# read as a committed stride rather than ice-skating.
	check("...but slower than running free", rate < HeroController.RUN_SPEED,
		"%.2f m/s vs a %.2f m/s run" % [rate, HeroController.RUN_SPEED])

	hero.queue_free()


func _rooted_still_roots() -> void:
	print("\n=== a rooted ability still costs you your footing ===")
	var h: Dictionary = _hero()
	if h.is_empty():
		check("a champion could be placed on real ground", false)
		return
	var hero: HeroController = h["hero"]
	var dir: Vector2 = h["open"]

	var heavy: Ability = AB.new()
	heavy.id = "test_rooted"
	heavy.slot = 1
	heavy.rooted = true
	heavy.cooldown = 0.0
	hero.abilities = [heavy, heavy, heavy] as Array[Ability]

	# THE START POSITION IS TAKEN ONCE THE ROOT IS ALREADY IN EFFECT.
	#
	# Movement happens in _physics_process, and this harness advances on
	# `process_frame`. Taking `before` on a process frame and then casting
	# leaves one physics step of RESIDUAL VELOCITY unaccounted for — at run
	# speed on a slow runner that is about 0.3 m, which is how this read
	# "0.310 m" in CI (run 45211840476) and 0.000 m on this laptop. The
	# champion was not failing to root; the test was measuring the handover
	# into the root rather than the root.
	#
	# So: start the cast, let a PHYSICS frame settle it, and only then take the
	# baseline. What is under test is whether a rooted cast holds the champion
	# still, not how fast they were going a moment before it began.
	hero.drive(dir, true)
	await physics_frame
	hero.use_ability(1, hero.ground_position() + dir * 10.0)
	await physics_frame
	var before: Vector2 = hero.ground_position()
	for i in range(30):
		hero.drive(dir, true)
		await physics_frame
	var moved: float = before.distance_to(hero.ground_position())
	check("a rooted cast does NOT move the champion", moved < 0.25,
		"%.3f m over 30 physics frames" % moved)
	hero.queue_free()

	# And a self-moving ability is rooted whatever it declares, because the
	# dash and the stick would otherwise both write the position each frame.
	var h2: Dictionary = _hero()
	if h2.is_empty():
		return
	var hero2: HeroController = h2["hero"]
	var dash: Ability = AB.new()
	dash.id = "test_dash"
	dash.slot = 1
	dash.rooted = false          # declares itself free to move…
	dash.move_kind = Ability.Move.CHARGE   # …but moves the hero itself
	dash.move_distance = 6.0
	dash.cooldown = 0.0
	hero2.abilities = [dash, dash, dash] as Array[Ability]
	hero2.drive(h2["open"], true)
	await process_frame
	hero2.use_ability(1, hero2.ground_position() + h2["open"] * 8.0)
	check("a self-moving ability is rooted despite declaring otherwise",
		bool(hero2.get("_cast_rooted")),
		"_cast_rooted=%s" % hero2.get("_cast_rooted"))
	hero2.queue_free()


func _aim_survives() -> void:
	print("\n=== the aim survives the movement ===")
	var h: Dictionary = _hero()
	if h.is_empty():
		check("a champion could be placed on real ground", false)
		return
	var hero: HeroController = h["hero"]
	var dir: Vector2 = h["open"]
	var at: Vector2 = hero.ground_position()

	var ab: Ability = AB.new()
	ab.id = "test_aim"
	ab.slot = 1
	ab.rooted = false
	ab.cooldown = 0.0
	hero.abilities = [ab, ab, ab] as Array[Ability]

	# Aim OPPOSITE to the direction of travel: the hardest case, and the one a
	# player hits whenever they kite backwards while firing.
	var aim: Vector2 = at - dir * 10.0
	hero.drive(dir, true)
	await process_frame
	hero.use_ability(1, aim)
	var want: float = atan2((aim - at).x, (aim - at).y)
	for i in range(20):
		hero.drive(dir, true)
		await process_frame
	var held: float = float(hero.get("_facing"))
	check("the cast's aim is still held while strafing away from it",
		absf(wrapf(held - want, -PI, PI)) < 0.2,
		"held %.2f rad, aimed %.2f" % [held, want])

	# …and released afterwards, or the champion would walk sideways forever.
	# END THE CAST THE WAY THE GAME DOES.
	#
	# _busy_until is a 10-second SAFETY CEILING, not the cast length — the real
	# release is the rig reporting its clip finished. Waiting the ceiling out
	# takes ~1400 headless frames and tests the fallback rather than the path
	# every cast actually takes, so this fires the handler the rig fires.
	hero.call("_on_rig_state_finished", HeroRig.State.ABILITY_1)
	await process_frame
	check("the cast ended", not hero.is_busy())
	for i in range(10):
		hero.drive(dir, true)
		await process_frame
	var travel: float = atan2(dir.x, dir.y)
	check("...and the facing returns to the direction of travel",
		absf(wrapf(float(hero.get("_facing")) - travel, -PI, PI)) < 0.2,
		"facing %.2f, travelling %.2f" % [float(hero.get("_facing")), travel])
	hero.queue_free()
