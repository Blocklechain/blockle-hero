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

	# The locked rows have to explain themselves on screen.
	var words: PackedStringArray = _strings(shell)
	check("a locked region tells the player what opens it",
		_has(words, "Clear region"),
		_first(words, "Clear region"))

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
