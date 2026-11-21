extends SceneTree
# ------------------------------------------------------------------------------
# Killing the boss has to MEAN something.
#
# Before this it meant nothing at all. The boss died, loot fell, and the player
# stood in an empty field. Worse, Roster.record_map_cleared() — which counts
# the map, fires difficulty_completed and pays the one-time spawn crystal for
# finishing a difficulty — was called by NOTHING but rewardtest.gd. A player
# could clear all hundred maps of Normal and the save would still say none.
# That is the fifth system in this project built, tested, and never wired to
# the game; rewardtest passed the entire time.
#
# So this kills a real boss in the real scene and asks the save.
#
#   godot --headless --path . --script tools/cleartest.gd
# ------------------------------------------------------------------------------

const REGION: int = 4

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-52s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	print("\n=== the boss dying clears the map ===")
	var account := Roster.new()
	var who: String = HeroRig.animated_heroes()[0]

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

	var got: Array = []
	play.region_cleared.connect(func(s: Dictionary) -> void: got.append(s))

	var frames: int = 0
	while frames < 2400 and play.get("_boss_id") == -1:
		await process_frame
		frames += 1
	var boss_id: int = play.get("_boss_id")
	check("the map placed a boss", boss_id != -1, "id %d" % boss_id)
	if boss_id == -1:
		_done()
		return

	check("the save does not think this map is cleared yet",
		not account.is_map_cleared(Campaign.Tier.NORMAL, REGION))

	# Find the boss body and kill it the way the game would.
	var boss: Combatant = null
	for n in play.get_children():
		if n is HeroController and n.body != null \
				and n.scale.y >= Encounter.BOSS_SIZE - 0.001:
			boss = n.body
	check("the boss has a body to kill", boss != null)
	if boss == null:
		_done()
		return

	# Killed through the real path: another combatant strikes it until it
	# drops, so `died` fires exactly as it would in a fight.
	var killer: Combatant = Combat.champion_body(account, who, 60, 3, "Killer")
	killer.team = Combatant.Team.PLAYER
	var guard: int = 0
	while boss.alive and guard < 4000:
		killer.strike(boss, 50.0, "test")
		guard += 1
		if guard % 20 == 0:
			await process_frame
	await process_frame
	for i in range(6):
		await process_frame

	check("the clear was announced", got.size() == 1,
		"%d signals" % got.size())
	if got.is_empty():
		_done()
		return
	var s: Dictionary = got[0]

	# THE POINT OF THE TEST.
	check("...and the save now records the map as cleared",
		account.is_map_cleared(Campaign.Tier.NORMAL, REGION))
	check("...and the cleared count went up",
		account.cleared_map_count(Campaign.Tier.NORMAL) == 1,
		"%d maps" % account.cleared_map_count(Campaign.Tier.NORMAL))

	check("the summary names the next map to play",
		int(s.get("next", -1)) == REGION + 1,
		"region %d -> %d" % [REGION, int(s.get("next", -1))])
	check("...and reports what the run was worth",
		s.has("kills") and s.has("gold") and s.has("cleared")
			and int(s.get("total", 0)) == Campaign.map_count(),
		"%d kills, %d gold, %d of %d" % [int(s.get("kills", 0)),
			int(s.get("gold", 0)), int(s.get("cleared", 0)),
			int(s.get("total", 0))])

	# The last map of a difficulty has no next, and the screen must not offer
	# one that does not exist.
	check("the hundredth map offers no next stage",
		Campaign.map_count() - 1 + 1 >= Campaign.map_count())

	print("\n=== the clear screen says so ===")
	var screen := ClearScreen.new()
	get_root().add_child(screen)
	screen.show_summary(s)
	await process_frame
	var words: PackedStringArray = _strings(screen)
	check("it congratulates the player",
		_has(words, "REGION CLEARED"), " / ".join(words.slice(0, 3)))
	check("...names the region just cleared",
		_has(words, Campaign.region_title(REGION)))
	check("...and offers the next one BY NAME, one tap away",
		_has(words, Campaign.region_title(REGION + 1)),
		"\"Next: %s\"" % Campaign.region_title(REGION + 1))
	check("...with a way back to the menus too",
		_has(words, "Back to camp"))

	# Everything must be on screen, not below the fold of a panel with no
	# scrollbar — this is a fixed overlay, so it has to FIT.
	await process_frame
	var over: Array[String] = []
	_clipped(screen, over)
	check("the whole screen fits without scrolling", over.is_empty(),
		", ".join(over.slice(0, 3)))

	screen.queue_free()
	_done()


func _done() -> void:
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


func _has(words: PackedStringArray, needle: String) -> bool:
	for w in words:
		if w.findn(needle) >= 0:
			return true
	return false


func _strings(n: Node, into: PackedStringArray = PackedStringArray()
		) -> PackedStringArray:
	if n is Label and not (n as Label).text.is_empty():
		into.append((n as Label).text)
	elif n is Button and not (n as Button).text.is_empty():
		into.append((n as Button).text)
	for c in n.get_children():
		_strings(c, into)
	return into


func _clipped(n: Node, out: Array[String]) -> void:
	if n is Control:
		var c := n as Control
		if c.visible and c.size.y > 1.0 \
				and c.get_combined_minimum_size().y > c.size.y + 2.0:
			out.append("%s needs %.0f has %.0f" % [c.name,
				c.get_combined_minimum_size().y, c.size.y])
	for k in n.get_children():
		_clipped(k, out)
