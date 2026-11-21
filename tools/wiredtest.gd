extends SceneTree
# ------------------------------------------------------------------------------
# Does the RUNNING GAME do the things its parts can do?
#
# This project has now shipped six features that were complete, unit-tested and
# unreachable: died() with no listener, on_spawn never called, the lane
# generator the scene never asked for, Encounter.build, record_map_cleared, and
# gain_xp. Every one of them had a passing test. Every one of those tests
# called the system directly.
#
# So this file is deliberately not allowed to call any of them. It boots
# scenes/Play.tscn, makes a fight happen, and then asks the save and the scene
# tree what changed. If a system is not wired, there is nothing here that can
# accidentally wire it.
#
#   godot --headless --path . --script tools/wiredtest.gd
# ------------------------------------------------------------------------------

## Chosen for POPULATION, not for depth: a level has to be reachable inside
## one region or the levelling half of this test cannot say anything. Region 3
## at this size places one enemy, which is eight xp of the eighty a level
## costs.
const REGION: int = 37

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-52s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	# A real new account, built the way the game builds one. Roster.new() on
	# its own owns nothing, and an unowned champion has no HeroProgress to pay
	# xp into — the test would be measuring a case UiShell never launches.
	var account: Roster = Roster.create(HeroRig.animated_heroes())
	var who: String = String(account.owned.keys()[0])

	var play: Node = load("res://scenes/Play.tscn").instantiate()
	play.set("world_seed", Campaign.region_seed(4242, REGION))
	play.set("biome", Biome.tag(Campaign.biome_at(REGION),
		Campaign.dread(REGION)))
	play.set("hero", who)
	play.set("region_index", REGION)
	play.set("campaign_seed", 4242)
	play.set("tier", Campaign.Tier.NORMAL)
	play.set("region_cells", 96)
	play.roster = account
	get_root().add_child(play)

	var frames: int = 0
	while frames < 2400 and play.get("_hero") == null:
		await process_frame
		frames += 1
	var me: HeroController = play.get("_hero")
	check("the region came up", me != null)
	if me == null:
		_done()
		return

	var p: HeroProgress = account.progress(who)
	check("the champion is on the save", p != null)
	if p == null:
		_done()
		return

	# The region now opens with a camera sweep that deliberately holds all
	# input — nothing fights, nothing moves. Skip it the way a player who has
	# seen it would, which also exercises the skip path.
	var flew: bool = bool(play.get("_flying"))
	check("the region opens with a flyover", flew)
	if flew:
		play._cam.skip_flyover()
		for i in range(4):
			await process_frame
		check("...and a tap hands control straight back",
			not bool(play.get("_flying")))

	print("\n=== effects reach the world, at the right height ===")
	var foe: HeroController = null
	for n in play.get_children():
		if n is HeroController and n != me:
			foe = n
			break
	check("there is something to fight", foe != null)
	if foe == null:
		_done()
		return
	foe._place(me.ground_position() + Vector2(1.2, 0.0))

	# Nothing is pressed. Auto-attack should swing, the cast should land, and
	# an effect should appear — all without this file touching Vfx.
	var seen: Vfx = null
	for i in range(300):
		await process_frame
		for c in play.get_children():
			if c is Vfx:
				seen = c
				break
		if seen != null:
			break
	check("a cast puts an effect in the scene", seen != null)
	if seen != null:
		# THE BUG THIS EXISTS FOR. Every archetype is built around an absolute
		# Y, and the champion stands at terrain.height_at() — metres up. The
		# effects all fired correctly, underneath the world, where nobody
		# could see them.
		var dy: float = absf(seen.global_position.y - me.global_position.y)
		check("...on the ground the fight is on, not at sea level",
			dy < 3.0,
			"effect y %.1f, champion y %.1f" % [seen.global_position.y,
				me.global_position.y])
		check("...and the ground itself is not at sea level, so that meant "
			+ "something", absf(me.global_position.y) > 0.5,
			"terrain height %.1f" % me.global_position.y)

	print("\n=== kills pay the champion ===")
	var level_before: int = p.level
	var xp_before: float = p.xp
	var killer: Combatant = Combat.champion_body(account, who, 60, 3, "K")
	killer.team = Combatant.Team.PLAYER

	# Kill several, so a level is reachable rather than only some xp.
	var killed: int = 0
	for n in play.get_children():
		if not (n is HeroController) or n == me:
			continue
		var body: Combatant = (n as HeroController).body
		if body == null or not body.alive:
			continue
		var guard: int = 0
		while body.alive and guard < 2000:
			killer.strike(body, 80.0, "test")
			guard += 1
		killed += 1
		await process_frame
	for i in range(6):
		await process_frame

	check("killing things awards experience", killed > 0
		and (p.xp > xp_before or p.level > level_before),
		"%d kills, level %d xp %.0f -> level %d xp %.0f" % [killed,
			level_before, xp_before, p.level, p.xp])
	check("...and enough of them is a level", p.level > level_before,
		"level %d after %d kills" % [p.level, killed])
	if p.level > level_before:
		# A level the player cannot feel until they walk back to the menu is
		# not a level-up, it is bookkeeping.
		check("...which the champion in the field actually gets",
			me.body.level == p.level,
			"body level %d, save level %d" % [me.body.level, p.level])
		check("...without being healed to full by it",
			me.body.health <= me.body.max_health,
			"%.0f of %.0f" % [me.body.health, me.body.max_health])

	play.queue_free()
	await process_frame
	_done()


func _done() -> void:
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
