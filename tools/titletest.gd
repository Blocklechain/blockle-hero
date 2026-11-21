extends SceneTree
# ------------------------------------------------------------------------------
# The front door behaves differently for the two people who open it.
#
# A player on their first run and a player on their fortieth want opposite
# things from a title screen: one wants to be told what the game is, the other
# wants their own game back without reading anything. The screen now serves
# both, which means there are two states to get wrong and no way to notice
# from a single screenshot — whichever save the capture tool happened to have
# is the only one anyone ever looks at.
#
#   godot --headless --path . --script tools/titletest.gd
# ------------------------------------------------------------------------------

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-52s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	var design := Vector2i(2532, 1170)
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_size = design
	get_root().size = design
	await process_frame

	await _fresh()
	await _returning()

	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


## Build a title screen against `account` and report what it says.
func _words(account: Roster) -> PackedStringArray:
	var screen := TitleScreen.new()
	screen.roster = account
	get_root().add_child(screen)
	screen.build()
	for i in range(4):
		await process_frame
	var out: PackedStringArray = _strings(screen)
	screen.queue_free()
	await process_frame
	return out


func _fresh() -> void:
	print("\n=== a new player is told what the game is ===")
	var account: Roster = Roster.create(HeroRig.animated_heroes())
	var words: PackedStringArray = await _words(account)

	check("the button invites them to start",
		_has(words, "Begin"), _first(words, "Begin"))
	check("...and does not promise to continue something",
		not _has(words, "Continue"))
	check("the pitch is on screen", _has(words, "difficulties"),
		_first(words, "difficulties"))
	# The counts in the pitch are DERIVED. A hardcoded number here said
	# "Sixteen regions" for months after the campaign became a hundred.
	check("...with the real campaign size in it",
		_has(words, "%d regions" % Campaign.map_count()),
		"%d regions" % Campaign.map_count())
	# Shortcuts to empty rooms are a worse first impression than no shortcuts.
	check("no shortcuts to rooms with nothing in them",
		not _has(words, "Merchant"))


func _returning() -> void:
	print("\n=== a returning player gets their own game back ===")
	var account: Roster = Roster.create(HeroRig.animated_heroes())
	var who: String = String(account.owned.keys()[0])
	# Play a bit: clear three regions and level somebody.
	for i in range(3):
		account.record_map_cleared(Campaign.Tier.NORMAL, i)
	account.progress(who).gain_xp(5000.0)

	var words: PackedStringArray = await _words(account)
	var region: int = account.furthest_unlocked(Campaign.Tier.NORMAL)

	check("the button offers to continue", _has(words, "Continue"),
		_first(words, "Continue"))
	check("...and NAMES where they are going",
		_has(words, Campaign.region_title(region)),
		Campaign.region_title(region))
	check("...which is the first region they have not cleared",
		region == 3, "region %d" % (region + 1))

	check("their progress replaces the pitch",
		_has(words, "regions cleared") and not _has(words, "difficulties"),
		_first(words, "regions cleared"))
	check("...with the count they earned",
		_has(words, "3/%d" % Campaign.map_count()),
		"3/%d" % Campaign.map_count())

	check("the shortcuts are there now",
		_has(words, "Champions") and _has(words, "Stash")
			and _has(words, "Merchant"))

	# THE CHAMPION IT RESUMES WITH has to be the one being played, not
	# whichever sorts first — the roster is keyed by model id, so alphabetical
	# order is meaningless to the player.
	var screen := TitleScreen.new()
	screen.roster = account
	get_root().add_child(screen)
	var resume: Dictionary = screen._resume()
	check("it resumes with the furthest-levelled champion",
		String(resume.get("hero", "")) == who,
		"%s (level %d)" % [ChampionName.of(who),
			account.progress(who).level])
	check("...straight to the campaign, not back to the roster",
		String(resume.get("route", "")) == UiRoute.CAMPAIGN)
	screen.queue_free()
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
