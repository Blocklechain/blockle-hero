extends SceneTree
# ------------------------------------------------------------------------------
# Does a campaign map actually have monsters in it?
#
# WHY THIS IS A SEPARATE TEST FROM encountertest.gd: that one proves
# Encounter.build() places packs and a boss correctly, and it passed, every
# time, while the shipping game loaded empty regions. It tests the generator.
# Nothing tested the CALLER — and the caller did not exist. Play.gd carried a
# comment reading "Nothing spawns enemies yet" for the entire life of the
# feature.
#
# So this test boots the REAL scene, scenes/Play.tscn, the same one UiShell
# hands the player, and counts bodies. It may not call Encounter directly: the
# moment it does, it stops being able to detect the bug it exists for.
#
#   godot --headless --path . --script tools/spawntest.gd
# ------------------------------------------------------------------------------

## Small enough to generate in a few seconds, big enough for a real lane.
##
## Counts here are NOT the shipping counts: the lane is shorter, so fewer packs
## fit on it, and map 0 comes out with only its boss. At the shipping 384 cells
## the same map places 17. This test asks whether the scene populates AT ALL,
## which is the bug it was written for; encountertest.gd owns how many.
const CELLS: int = 96
## Generation is threaded; this is the ceiling, not the expected wait.
const MAX_FRAMES: int = 2400

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-50s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	# Three maps across the campaign, because the cast, the pack count and the
	# boss placement all change with depth — map 0 working proves the least.
	# The last two are the same map at the bottom and top of the difficulty
	# ladder, which is what makes the kit assertion below mean anything.
	for spec in [[0, Campaign.Tier.NORMAL], [37, Campaign.Tier.NORMAL],
			[99, Campaign.Tier.NORMAL], [37, Campaign.Tier.OBLIVION]]:
		await _one(int(spec[0]), int(spec[1]))

	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


func _one(region: int, tier: int) -> void:
	print("\n=== region %d, %s ===" % [region, Campaign.tier_name(tier)])
	var play: Node = load("res://scenes/Play.tscn").instantiate()
	play.set("world_seed", Campaign.region_seed(4242, region))
	play.set("biome", Biome.tag(Campaign.biome_at(region),
		Campaign.dread(region)))
	play.set("hero", HeroRig.animated_heroes()[0])
	play.set("region_index", region)
	play.set("campaign_seed", 4242)
	play.set("tier", tier)
	play.set("region_cells", CELLS)
	get_root().add_child(play)

	var frames: int = 0
	while frames < MAX_FRAMES and _count(play) == 0:
		await process_frame
		frames += 1

	var foes: Array = _foes(play)
	check("the region has enemies in it", foes.size() > 0,
		"%d after %d frames" % [foes.size(), frames])

	if not foes.is_empty():
		# An enemy with no Combatant is a model standing in a field: it cannot
		# be targeted, hit, killed or looted, and on screen it is identical to
		# one that works.
		var bodied: int = 0
		var alive: int = 0
		var boss: bool = false
		for f in foes:
			if f.body != null:
				bodied += 1
				if f.body.alive:
					alive += 1
				if f.body.max_health <= 0.0:
					check("an enemy had no health", false, f.body.display_name)
			# EPSILON, because Vector3 stores float32 and the constant is a
			# GDScript float64: float32(1.55) is 1.54999995, so a bare >=
			# against BOSS_SIZE reports "no boss" on a map that has one.
			if f.scale.y >= Encounter.BOSS_SIZE - 0.001:
				boss = true
		check("...and every one of them has a combat body",
			bodied == foes.size(), "%d of %d" % [bodied, foes.size()])
		check("...and they are alive to begin with",
			alive == foes.size(), "%d of %d" % [alive, foes.size()])
		check("...and one of them is a boss", boss)

		# THE THING THE PLAYER NOTICES. "Has enemies" and "has enemies that do
		# anything" are different games, and the second is the one being
		# shipped. Put the champion next to the nearest foe and run the brain:
		# it has to close the gap on its own.
		var hero: HeroController = play.get("_hero")
		var near: HeroController = null
		var best: float = 1e9
		for f in foes:
			var d: float = f.ground_position().distance_to(
				hero.ground_position())
			if d < best:
				best = d
				near = f
		var opened: float = near.ground_position().distance_to(
			hero.ground_position())
		for i in range(240):
			play._think(0.05)
			await physics_frame
		var closed: float = near.ground_position().distance_to(
			hero.ground_position())
		# THE DIFFICULTY HAS TO REACH THE BRAIN. Campaign.enemy_actions() being
		# a correct table proves nothing on its own — the bug this guards is a
		# chooser that ignores it and swings the basic attack forever.
		#
		# Two separate claims, because they fail for different reasons. The
		# CEILING is absolute: no foe, at any range, may ever reach past what
		# the tier allows. REACHABILITY is conditional: the top allowed slot
		# has to actually get picked, but only by a foe that has it off
		# cooldown — the scene is live, the brain has already been thinking,
		# and an enemy that just cast is correctly holding its basic.
		var allowed: int = Campaign.enemy_actions(tier)
		var over: int = 0
		var reached: bool = false
		var eligible: int = 0
		for f in foes:
			for gap in [0.5, 3.0, 10.0, 25.0]:
				if play._choose_action(f, gap) >= allowed:
					over += 1
			var top_ab: Ability = f.ability_in_slot(allowed - 1)
			if top_ab != null and f.cooldown_left(allowed - 1) <= 0.0:
				eligible += 1
				if play._choose_action(f, 1.0) == allowed - 1:
					reached = true
		check("no enemy reaches past what %s allows"
			% Campaign.tier_name(tier), over == 0,
			"%d breaches over %d foes" % [over, foes.size()])
		check("...and the top action it does allow gets used",
			reached or eligible == 0,
			"slot %d, %d foes had it ready" % [allowed - 1, eligible])

		check("an enemy that notices you closes the distance",
			closed < opened - 1.0 or closed <= float(play.REACH) + 0.5,
			"%.1f m -> %.1f m" % [opened, closed])

	play.queue_free()
	await process_frame


func _foes(play: Node) -> Array:
	var out: Array = []
	for n in play.get_children():
		if n is HeroController and n != play.get("_hero"):
			out.append(n)
	return out


func _count(play: Node) -> int:
	return _foes(play).size()
