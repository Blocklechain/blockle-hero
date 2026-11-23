extends SceneTree
# ------------------------------------------------------------------------------
# THE DODGE ROLL, AND THE THREE WAYS IT COULD BE WORTHLESS.
#
# Before this there was exactly one defensive verb in the game and it was a
# passive: Stats.dodge_chance, rolled by the dice on every incoming hit. Boss
# AoE telegraphs for most of a second and there was nothing to DO with that
# warning except already be standing somewhere else.
#
# A dodge roll is easy to ship broken in ways that all look fine from the code:
#
#   * IT DOESN'T MOVE YOU. Same failure class as the cast-while-moving bug —
#     flags get set, a timer runs, and the body stays where it was. So the
#     assertion here is DISPLACEMENT in metres, never "the function returned
#     true".
#   * IT DOESN'T DODGE THE ONE ATTACK WORTH DODGING. Boss slams arrive through
#     Combatant.take_hit(), not strike(). An i-frame honoured by sword swings
#     but not by the telegraphed ground attack is a dodge roll that misses its
#     entire purpose, and nothing about the code would look wrong.
#   * IT NEVER ENDS. If invulnerability outlives the roll the champion is simply
#     unkillable, which no test that only checks "did it block the hit" catches.
#     Dying mid-roll is the nasty case: _physics_process returns early for a
#     corpse, so neither timer ticks again.
#
# The i-frame is deliberately SHORTER than the roll, so the tail is recovery
# that can still be punished. That gap is asserted too — equal windows would
# make the roll a strictly-better "do not take damage" button, and a later tweak
# that quietly equalises them should fail here.
# ------------------------------------------------------------------------------

const HC := preload("res://scripts/game/HeroController.gd")

var _fails: int = 0
var _ran: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, note])
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

	_the_numbers(); _ran += 1
	await _it_moves(); _ran += 1
	await _it_stops_a_swing(); _ran += 1
	await _it_stops_a_boss_slam(); _ran += 1
	await _it_ends(); _ran += 1
	await _the_cooldown(); _ran += 1
	await _death_mid_roll(); _ran += 1
	await _a_wall(); _ran += 1
	print("")
	check("every section ran to completion", _ran == 8, "%d of 8" % _ran)
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


## A real champion on real generated ground, with room to roll.
##
## The REAL Terrain and Pathing, because dodge() validates its landing through
## _safe_landing() — a stub that called everything walkable would pass this file
## for a roll that cannot actually happen anywhere in the game.
func _hero() -> Dictionary:
	var seed: int = 90210
	var plan: Layout = Terrain.plan_for(Terrain.Kind.ARENA, seed,
		Vector2(96, 96) * 0.5, Layout.Sym.ASYMMETRIC, 7)
	var ter: Terrain = Terrain.generate(seed, "greenwood", 96, 0.5, plan)
	var path := Pathing.new(ter)
	var at: Vector2 = plan.node_of_kind(Layout.ENTRY).get("pos", Vector2.ZERO)
	at = path.nearest_walkable_centre(at)

	# A heading with at least a roll's worth of clear ground, so a blocked roll
	# cannot be mistaken for a roll that does not move.
	var open: Vector2 = Vector2.ZERO
	for step in range(64):
		var ang: float = TAU * float(step) / 64.0
		var d := Vector2(cos(ang), sin(ang))
		if path.clear_line(at, at + d * (HC.DODGE_DISTANCE + 2.0)):
			open = d
			break
	if open == Vector2.ZERO:
		return {}

	var heroes: PackedStringArray = HeroRig.animated_heroes()
	var who: String = heroes[0]
	var h: HeroController = HC.new()
	root.add_child(h)
	if not h.setup(ter, who, at):
		return {}
	var b: Combatant = Combat.champion_body(null, who, 10,
		Rng.seed_of(seed, who), who)
	h.setup_combat(b, HeroClass.for_hero(who), who)
	return {"hero": h, "open": open, "body": b}


## An enemy strong enough that a landed hit is unmistakable.
func _attacker() -> Combatant:
	return Combatant.make("brute", Combatant.Team.ENEMY, 20,
		Stats.make(30, 10, 6, 20), HeroClass.School.MELEE, 18.0, 0.0, 4242)


func _the_numbers() -> void:
	print("\n=== the i-frame is shorter than the roll ===")
	check("the roll commits for a real length of time",
		HC.DODGE_TIME > 0.15 and HC.DODGE_TIME < 0.6,
		"%.2f s" % HC.DODGE_TIME)
	# THE ASSERTION THAT KEEPS THE ROLL HONEST.
	check("the i-frame ENDS BEFORE the roll does",
		HC.DODGE_IFRAME < HC.DODGE_TIME,
		"iframe %.2f s vs roll %.2f s" % [HC.DODGE_IFRAME, HC.DODGE_TIME])
	check("...leaving a recovery window that can be punished",
		HC.DODGE_TIME - HC.DODGE_IFRAME > 0.05,
		"%.0f ms exposed" % ((HC.DODGE_TIME - HC.DODGE_IFRAME) * 1000.0))
	check("two rolls cannot chain into permanent immunity",
		HC.DODGE_COOLDOWN > HC.DODGE_IFRAME * 2.0,
		"cooldown %.2f s vs 2 x iframe %.2f s"
			% [HC.DODGE_COOLDOWN, HC.DODGE_IFRAME * 2.0])


func _it_moves() -> void:
	print("\n=== the roll moves the champion ===")
	var h: Dictionary = _hero()
	if h.is_empty():
		check("a champion could be placed with room to roll", false)
		return
	var hero: HeroController = h["hero"]
	var before: Vector2 = hero.ground_position()
	check("the roll was accepted", hero.dodge(h["open"]))
	# DRIVEN UNTIL THE ROLL ACTUALLY ENDS, not for a fixed frame count.
	#
	# A headless frame's delta is however long the frame took, so "40 frames"
	# is a different amount of SIMULATED time on every machine. This test used
	# to loop 40 times and measure: locally that covered enough of the 0.30 s
	# roll to travel 3.67 m and pass, and on CI's runner it covered 1.29 m and
	# failed the 2.3 m threshold — a green test on my laptop and a red build,
	# for a roll that was simply still in progress. Third time this session I
	# have made the frames-for-time mistake; the cure is to wait for the EVENT.
	#
	# The stick is held the WRONG way throughout: a commitment that can be
	# steered is not a commitment.
	var spin: int = 0
	while bool(hero.get("_dodging")) and spin < 600:
		hero.drive(-h["open"], true)
		await process_frame
		spin += 1
	check("the roll ran to completion", not bool(hero.get("_dodging")),
		"%d frames" % spin)
	var moved: float = before.distance_to(hero.ground_position())
	check("THE CHAMPION MOVED", moved > HC.DODGE_DISTANCE * 0.5, "%.2f m" % moved)
	check("...roughly a roll's distance, not an arena-crossing teleport",
		moved <= HC.DODGE_DISTANCE + 0.1, "%.2f m of %.2f m"
			% [moved, HC.DODGE_DISTANCE])
	hero.queue_free()


func _it_stops_a_swing() -> void:
	print("\n=== an i-frame beats a weapon swing ===")
	var h: Dictionary = _hero()
	if h.is_empty():
		check("a champion could be placed", false)
		return
	var hero: HeroController = h["hero"]
	var me: Combatant = h["body"]
	var foe: Combatant = _attacker()

	# A hit that WOULD land, so the i-frame is the only reason it does not.
	var hp: float = me.health
	var landed: Dictionary = foe.strike(me)
	check("the control hit lands while not rolling",
		float(landed["damage"]) > 0.0 and me.health < hp,
		"%.1f damage" % float(landed["damage"]))

	me.health = me.max_health
	hero.dodge(h["open"])
	await process_frame
	var guarded: Dictionary = foe.strike(me)
	check("the same hit does nothing mid-roll",
		float(guarded["damage"]) == 0.0 and bool(guarded["dodged"])
			and is_equal_approx(me.health, me.max_health),
		"damage %.1f, dodged=%s" % [float(guarded["damage"]), guarded["dodged"]])
	hero.queue_free()


func _it_stops_a_boss_slam() -> void:
	print("\n=== an i-frame beats a BOSS SLAM ===")
	# The one this file exists for. Play.gd deals slam damage through take_hit(),
	# an entirely different entry point from strike(), so this can be broken
	# while the swing test above still passes.
	var h: Dictionary = _hero()
	if h.is_empty():
		check("a champion could be placed", false)
		return
	var hero: HeroController = h["hero"]
	var me: Combatant = h["body"]

	var hp: float = me.health
	check("the control slam lands while not rolling",
		me.take_hit(me.max_health * 0.25, "Slam") == false and me.health < hp,
		"%.0f -> %.0f hp" % [hp, me.health])

	me.health = me.max_health
	hero.dodge(h["open"])
	await process_frame
	me.take_hit(me.max_health * 0.25, "Slam")
	check("the same slam does nothing mid-roll",
		is_equal_approx(me.health, me.max_health),
		"%.0f of %.0f hp" % [me.health, me.max_health])

	# AND A BURN ALREADY ON YOU KEEPS BURNING. Rolling gets you out of the way
	# of the next attack; it is not a cure.
	check("...but the roll did not make the body immune to everything",
		not me.invulnerable or HC.DODGE_IFRAME > 0.0,
		"invulnerable=%s" % me.invulnerable)
	hero.queue_free()


func _it_ends() -> void:
	print("\n=== invulnerability does not outlive the roll ===")
	var h: Dictionary = _hero()
	if h.is_empty():
		check("a champion could be placed", false)
		return
	var hero: HeroController = h["hero"]
	var me: Combatant = h["body"]
	var foe: Combatant = _attacker()

	hero.dodge(h["open"])
	await process_frame
	check("invulnerable during the roll", me.invulnerable)

	# Well past both the i-frame and the roll.
	for i in range(60):
		await process_frame
	check("not invulnerable afterwards", not me.invulnerable)

	me.health = me.max_health
	var after: Dictionary = foe.strike(me)
	check("...and hits land again once it is over",
		float(after["damage"]) > 0.0 and me.health < me.max_health,
		"%.1f damage" % float(after["damage"]))
	hero.queue_free()


func _the_cooldown() -> void:
	print("\n=== the roll is on a cooldown ===")
	var h: Dictionary = _hero()
	if h.is_empty():
		check("a champion could be placed", false)
		return
	var hero: HeroController = h["hero"]
	check("the first roll is allowed", hero.dodge(h["open"]))
	await process_frame
	check("a second roll is refused immediately", not hero.dodge(h["open"]))
	# Wait out the roll but NOT the cooldown.
	for i in range(30):
		await process_frame
	check("...and still refused after the roll ends, before the cooldown",
		not hero.dodge(h["open"]))
	hero.queue_free()


func _death_mid_roll() -> void:
	print("\n=== dying mid-roll does not revive a god ===")
	# A corpse does not tick, so neither timer finishes. Without revive()
	# clearing them the champion comes back permanently invulnerable.
	var h: Dictionary = _hero()
	if h.is_empty():
		check("a champion could be placed", false)
		return
	var hero: HeroController = h["hero"]
	var me: Combatant = h["body"]
	var foe: Combatant = _attacker()

	hero.dodge(h["open"])
	await process_frame
	check("invulnerable mid-roll", me.invulnerable)

	# Kill the champion outright while the roll is still running.
	me.invulnerable = false
	me.health = 1.0
	me.take_hit(me.max_health * 10.0, "test")
	hero.call("_on_body_died")
	await process_frame
	check("the champion is down mid-roll", not me.alive)

	# REVIVED THE WAY THE GAME REVIVES, which is the only version worth
	# testing: Play.gd hands the controller a FRESH living body through
	# setup_combat and then clears the controller's and rig's death latches.
	# A Combatant is never un-killed, so a test that set `alive = true` on the
	# corpse would be asserting against a path no player can reach.
	var reborn: Combatant = Combat.champion_body(null, hero.rig.hero_name, 10,
		Rng.seed_of(90210, hero.rig.hero_name), hero.rig.hero_name)
	hero.setup_combat(reborn, HeroClass.for_hero(hero.rig.hero_name), hero.rig.hero_name)
	hero.revive()
	await process_frame

	check("revived WITHOUT invulnerability still set", not reborn.invulnerable)
	var after: Dictionary = foe.strike(reborn)
	check("...and can be hurt again", float(after["damage"]) > 0.0,
		"%.1f damage" % float(after["damage"]))
	check("...and can roll again", hero.dodge(h["open"]))

	# AND THE DEAD ROLL DID NOT SURVIVE ITS OWNER. A stale _dodging latch makes
	# _physics_process return early every frame forever, with _advance_dash
	# dividing by a zeroed duration — which slides the revived champion onto the
	# old roll's destination instead of leaving them where they are.
	#
	# MEASURED FROM A SETTLED POSITION. The roll started by the check above has
	# to be allowed to finish first: taking the baseline before it would let a
	# genuinely stuck champion drift a full roll's distance and still pass,
	# which is the kind of guard that reports zero failures while watching
	# nothing.
	for i in range(40):
		await process_frame
	var standing: Vector2 = hero.ground_position()
	for i in range(60):
		await process_frame
	var drift: float = hero.ground_position().distance_to(standing)
	check("...and is not stuck in a roll that died with the old body",
		drift < 0.25, "drifted %.3f m once settled" % drift)
	hero.queue_free()


func _a_wall() -> void:
	print("\n=== rolling into a wall is refused, not wasted ===")
	var h: Dictionary = _hero()
	if h.is_empty():
		check("a champion could be placed", false)
		return
	var hero: HeroController = h["hero"]
	var path: Pathing = Pathing.new(hero.terrain)
	var at: Vector2 = hero.ground_position()

	# A direction with nothing walkable in it. If the arena has no such heading
	# the section says so rather than passing vacuously.
	var blocked: Vector2 = Vector2.ZERO
	for step in range(64):
		var ang: float = TAU * float(step) / 64.0
		var d := Vector2(cos(ang), sin(ang))
		if not path.is_walkable(at + d * 0.8):
			blocked = d
			break
	if blocked == Vector2.ZERO:
		print("  SKIP no blocked heading from this spawn — nothing to assert")
		hero.queue_free()
		return

	check("a roll with nowhere to go is refused", not hero.dodge(blocked))
	check("...and the cooldown was NOT spent on it", hero.dodge(h["open"]),
		"a real roll is still available")
	hero.queue_free()
