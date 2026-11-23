extends SceneTree
# ------------------------------------------------------------------------------
# The campaign is a sequence, not a menu.
#
# Until now every one of the hundred maps was tappable from a standing start.
# A new player could open region 100, walk into enemies forty levels above
# them, and never see the curve the whole campaign is built out of — and the
# mercy ramp, the dread bands and the levelling all assume you arrive in order.
#
# Three places have to agree, and the one that matters is the last:
#
#   1. The rule itself.
#   2. The campaign screen, which must SAY what opens a locked map.
#   3. UiShell, which is where every launch actually lands — including the
#      clear screen's "next stage", which never touches the campaign screen.
#      A rule enforced only in the UI that happens to be on screen is not a
#      rule.
#
#   godot --headless --path . --script tools/gatetest.gd
# ------------------------------------------------------------------------------

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	_rule()
	await _screen()
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


func _rule() -> void:
	print("\n=== one at a time ===")
	var r: Roster = Roster.create(HeroRig.animated_heroes())
	var t: int = Campaign.Tier.NORMAL

	check("the first region is open on a brand new account",
		r.is_map_unlocked(t, 0))
	check("...and the second is not", not r.is_map_unlocked(t, 1))
	check("...nor is anything further in",
		not r.is_map_unlocked(t, 7) and not r.is_map_unlocked(t, 99))
	check("the campaign opens on region 1", r.furthest_unlocked(t) == 0,
		"region %d" % (r.furthest_unlocked(t) + 1))

	r.record_map_cleared(t, 0)
	check("clearing the first opens the second", r.is_map_unlocked(t, 1))
	check("...and only the second", not r.is_map_unlocked(t, 2))
	check("...and the campaign now opens there",
		r.furthest_unlocked(t) == 1, "region %d" % (r.furthest_unlocked(t) + 1))

	# THE CASE THAT BREAKS THIS. Progress is per difficulty, so clearing a
	# stretch of Normal must not hand the player the same stretch of a harder
	# tier they have never played.
	for i in range(6):
		r.record_map_cleared(t, i)
	check("six cleared on Normal opens the seventh",
		r.is_map_unlocked(t, 6))
	check("...and opens NOTHING on another difficulty",
		not r.is_map_unlocked(Campaign.Tier.MERCILESS, 1)
			and r.is_map_unlocked(Campaign.Tier.MERCILESS, 0),
		"Merciless still starts at region 1")

	# Nothing past the end of the campaign is ever enterable.
	check("there is no region 101", not r.is_map_unlocked(t,
		Campaign.map_count()))

	# It survives a save round trip, or the gate reopens every launch.
	var back: Roster = Roster.from_dict(r.to_dict(), HeroRig.animated_heroes())
	check("the gate survives being saved and loaded",
		back.is_map_unlocked(t, 6) and not back.is_map_unlocked(t, 7),
		"furthest region %d" % (back.furthest_unlocked(t) + 1))


func _screen() -> void:
	print("\n=== the game refuses, and says why ===")
	var design := Vector2i(2532, 1170)
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_size = design
	get_root().size = design
	await process_frame

	var main: Node = load("res://scenes/Main.tscn").instantiate()
	get_root().add_child(main)
	for i in range(8):
		await process_frame
	var shell: UiShell = main as UiShell if main is UiShell \
		else main.find_children("*", "UiShell", true, false)[0]

	shell.goto(UiRoute.CAMPAIGN)
	for i in range(8):
		await process_frame

	# A SEALED MAP HAS TO EXPLAIN ITSELF ON SCREEN.
	#
	# This used to read the words straight off the screen, because the
	# campaign was a hundred-row list and every locked row carried its own
	# reason. It is a carousel now: the screen opens on the FURTHEST MAP
	# UNLOCKED, which by definition is not sealed, so the reason is not
	# visible until the player pages into one that is.
	#
	# The property is unchanged — a map the player cannot enter must say what
	# opens it — so the test pages right, the way a player would, until it
	# finds a sealed one, and then looks.
	# PICK A CHAMPION FIRST, because the screen genuinely cannot answer the
	# question without one: _refresh_chrome() starts with
	# `roster.progress(hero)` and there is no progress for hero == "". This
	# section used to go straight to CAMPAIGN from a cold boot, so the Enter
	# button it then searched for had never been given any text at all — the
	# words it was hunting for could not appear no matter how far it paged.
	#
	# The missing label was a real bug too and is fixed in CampaignScreen
	# (a blank ENABLED button that reads as pressable), but a test that only
	# ever saw that state was never testing the gate.
	# A COLD HEADLESS BOOT HANDS THE SHELL AN EMPTY ROSTER — owned_names() is 0,
	# so selected_hero is "" and there is no champion for the screen to say
	# anything about. Every assertion below needs one: the campaign screen reads
	# roster.progress(hero) before it will label a region, and _launch() reads
	# shell.selected_hero.
	#
	# Granted on the SHELL, which is the source of truth — UiShell pushes both
	# `roster` and `hero` down into the screen when a route is entered — and
	# then the route is re-entered so the screen receives them the way it does
	# in the game, rather than having its fields poked from outside.
	if shell.roster != null and shell.roster.owned_names().size() == 0:
		var starters: PackedStringArray = Champion.starters(
			HeroRig.animated_heroes())
		if starters.size() > 0:
			shell.roster.call("_grant_champion", starters[0])
	if shell.roster != null:
		var owned: PackedStringArray = shell.roster.owned_names()
		if owned.size() > 0 and not shell.roster.owns(shell.selected_hero):
			shell.selected_hero = owned[0]
	shell.goto(UiRoute.CAMPAIGN)
	for i in range(8):
		await process_frame

	var screen: UiScreen = shell.current_screen()
	var right: Button = _arrow(screen, false)
	check("the carousel has an arrow to page forward", right != null)
	var sealed_found: bool = false
	for i in range(Campaign.region_count()):
		if right == null or right.disabled:
			break
		right.pressed.emit()
		for f in range(3):
			await process_frame
		if _has(_strings(shell), "Clear region"):
			sealed_found = true
			break
	check("a sealed region tells the player what opens it", sealed_found,
		_first(_strings(shell), "Clear region"))

	# THE REAL GATE. Ask the launcher for a region nobody has earned. It must
	# refuse — this is the path the clear screen's "next stage" uses, which
	# never goes near the campaign screen.
	var before: bool = shell.get("_play") != null
	shell._launch({"hero": shell.selected_hero, "region": 60,
		"tier": Campaign.Tier.NORMAL})
	for i in range(4):
		await process_frame
	check("launching an unearned region is refused",
		shell.get("_play") == null and not before,
		"no region was built")

	# And the first region still launches, or the gate has locked the game.
	shell._launch({"hero": shell.selected_hero, "region": 0,
		"tier": Campaign.Tier.NORMAL})
	for i in range(4):
		await process_frame
	check("...while region 1 still starts normally",
		shell.get("_play") != null)
	shell._return_to_menu()
	await process_frame


func _first(words: PackedStringArray, needle: String) -> String:
	for w in words:
		if w.findn(needle) >= 0:
			return w
	return ""


func _has(words: PackedStringArray, needle: String) -> bool:
	return _first(words, needle) != ""


func _strings(n: Node, into: PackedStringArray = PackedStringArray()
		) -> PackedStringArray:
	if n is Label and not (n as Label).text.is_empty():
		into.append((n as Label).text)
	elif n is Button and not (n as Button).text.is_empty():
		into.append((n as Button).text)
	for c in n.get_children():
		_strings(c, into)
	return into


## The campaign carousel's edge arrows, found BY NAME — they carry a drawn
## chevron and no label, and the header's own back button carries the same
## BACK glyph, so searching by glyph finds the wrong one.
func _arrow(node: Node, want_back: bool) -> Button:
	var plate: Node = node.get("_plate")
	if plate == null:
		return null
	return plate.get_node_or_null(
		"PageBack" if want_back else "PageNext") as Button
