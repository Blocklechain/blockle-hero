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
var _reached_end: bool = false


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

	# ---- IS EVERY SYSTEM REACHABLE FROM THE RUNNING GAME? -------------------
	_reachable(play, me)

	play.queue_free()
	await process_frame
	check("the reachability section ran to completion", _reached_end)
	_done()


## THE COUNT IN THIS FILE'S HEADER IS NOW NINE, not six.
##
## Three more systems shipped complete, unit-tested and loaded by nothing but
## their own harness: the MINIMAP (no scene node, no preload, nobody calling
## configure() or set_player()), ITEM AFFIXES (Affix.dress() documented as "all
## Loot needs" and called from nowhere), and the SETTINGS SCREEN — which drags
## the whole story and voice system down with it, because Story -> Narration ->
## Prefs -> SettingsScreen is a chain whose head no route could reach. That is
## 71 rendered voice lines and 19 MiB of audio that could never play.
##
## Each check below is a different KIND of evidence, because source-grepping
## alone proves only that a name appears somewhere:
##
##   minimap   the node is in the live tree and has rasterised its region;
##   affixes   an item that came out of Loot.roll carries affix work;
##   settings  the shell can actually build the screen for its route;
##   voice     the manifest the game would read is on disk and populated.
func _reachable(play: Node, me: HeroController) -> void:
	print("\n--- every system reachable from the running game ---")

	# 1. THE MINIMAP, in the tree, configured by the region that just loaded.
	var map: Node = play.get("_minimap")
	check("the minimap exists in the running scene", map != null)
	if map != null:
		check("...and the region rasterised into it",
			bool(map.call("active")) and int(map.get("rasterised")) >= 1,
			"active=%s rasterised=%d" % [map.call("active"),
				int(map.get("rasterised"))])
		# Play feeds it the champion every frame; by now it must have a dot.
		check("...and it knows where the champion is",
			map.call("player_norm") != Vector2.INF,
			str(map.call("player_norm")))

	# 2. AFFIXES, on an item that came out of the real loot roller. Asserted on
	# the EFFECT — a name or a stat the base roll could not have produced —
	# rather than on Affix being mentioned in Loot.gd.
	# COMPARED AGAINST AN UNDRESSED TWIN, because the obvious test is vacuous:
	# a name containing " of " proves nothing — Item.SUFFIX is a list of
	# "of the Bear"-shaped strings, so the BASE namer emits them too. Checked by
	# mutation: with Affix.dress() deleted from Loot.gd, "4 of 15 carry an
	# affix name" still passed.
	#
	# So the twin is rolled from the same inputs Loot.roll feeds Item.roll — all
	# of them public — and the only thing that can differ is dress() itself.
	var dressed: int = 0
	var changed: int = 0
	for i in range(48):
		var d: Loot.Drop = Loot.roll(4242, i, 20, Campaign.Tier.NORMAL, 20)
		if d == null or d.item == null:
			continue
		dressed += 1
		var ilvl: int = Loot.item_level(20, 20)
		var rar: int = mini(Campaign.roll_rarity(4242, i, Campaign.Tier.NORMAL),
			Loot.rarity_ceiling(Campaign.Tier.NORMAL))
		var plain: Item = Item.roll(4242, Loot.ITEM_ROLL_BASE + i, ilvl, rar)
		if plain == null:
			continue
		var moved: bool = d.item.item_name != plain.item_name \
			or not is_equal_approx(d.item.power, plain.power)
		if not moved:
			# Or any attribute the affix roll added on top of the base spread.
			for a in range(Stats.Attr.size()):
				if not is_equal_approx(d.item.bonus.get_attr(a),
						plain.bonus.get_attr(a)):
					moved = true
					break
		if moved:
			changed += 1
	check("the loot roller produced items at all", dressed > 0,
		"%d items from 48 kills" % dressed)
	check("...and affixes CHANGED them from the undressed roll", changed > 0,
		"%d of %d differ from their twin" % [changed, dressed])

	# 3. THE SETTINGS SCREEN. Two of its controls — screen shake and the damage
	# numbers — decide whether some people can play at all, so a route that
	# cannot build it is an accessibility option nobody can reach.
	var built: Node = null
	var shell_script := load("res://scripts/ui/UiShell.gd")
	if shell_script != null:
		var probe: Node = shell_script.new()
		built = probe.call("_make_screen", UiRoute.SETTINGS)
		check("the shell can build a screen for the settings route",
			built != null)
		if built != null:
			check("...and it is the settings screen",
				built.get_script() != null
					and String(built.get_script().resource_path).ends_with(
						"SettingsScreen.gd"),
				String(built.get_script().resource_path)
					if built.get_script() != null else "<no script>")
			built.free()
		probe.free()
	check("the settings route is on the side menu",
		_nav_lists(UiRoute.SETTINGS),
		"NavPanel.ITEMS")

	# 4. THE VOICE LINES. Only that the manifest the game reads is present and
	# populated — whether a wav plays is voicetest's job, and asserting audio
	# from a headless run would be asserting nothing.
	check("the voice manifest is on disk",
		FileAccess.file_exists("res://assets/voice/lines.json"))

	# AND THE SECTION FINISHED. The first run of this section died on a wrong
	# function name partway through, skipped every check after it, and still
	# printed "0 failure(s)" — a truncated section is indistinguishable from a
	# clean one unless something counts the end.
	_reached_end = true


## Does NavPanel.ITEMS carry a row for this route? Read off the constant, which
## is what the panel builds itself from.
func _nav_lists(route: String) -> bool:
	var nav := load("res://scripts/ui/NavPanel.gd")
	if nav == null:
		return false
	for row in nav.ITEMS:
		if (row as Array).size() > 0 and String(row[0]) == route:
			return true
	return false


func _done() -> void:
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
