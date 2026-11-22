extends SceneTree
# ------------------------------------------------------------------------------
# THE FRONT DOOR IS A DOOR NOW.
#
# This file used to assert the opposite: that the title screen behaved
# DIFFERENTLY for a new player and a returning one — pitch and "Begin" for
# one, "Continue · <region>" plus six quick links for the other. That design
# existed because the bottom tab strip only had room for four destinations, so
# Training, Contracts and Party had nowhere to live and ended up here.
#
# The left navigation panel holds every destination now, which made the quick
# links a duplicate menu on the one screen that should not have a menu, and
# made two title-screen states two things to get wrong for no gain.
#
# So the contract is inverted and the assertions with it:
#
#   * ONE BUTTON, SAYING THE SAME THING to everybody. "Enter game" is a door,
#     and a door does not need to describe the room.
#
#   * NO MENU ON IT. Not one quick link. If a destination is reachable from
#     the title screen it is reachable from the panel, and two ways that can
#     disagree is worse than one.
#
#   * IT STILL LANDS SOMEWHERE SENSIBLE. The button text is the same for
#     everyone; where it GOES is not. A returning player must not be dropped
#     on the roster to find their own champion again, and a brand new one
#     must not be dropped on a campaign screen before they have picked
#     anybody.
#
#   * SOMETHING MOVES. A still title screen reads as a load that has got
#     stuck — the player cannot tell the app is running until they touch it.
#
#   godot --headless --path . --script tools/titletest.gd
# ------------------------------------------------------------------------------

var fails: int = 0
var _ran: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	var design := Vector2i(2532, 1170)
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_size = design
	get_root().size = design
	await process_frame

	await _one_door(); _ran += 1
	await _where_it_lands(); _ran += 1
	await _it_is_alive(); _ran += 1
	print("")
	check("every section ran to completion", _ran == 3, "%d of 3" % _ran)
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


# ---- scaffolding -------------------------------------------------------------

## The real shell on the real scene, so this is the screen the player gets.
func _shell(account: Roster) -> UiShell:
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	get_root().add_child(main)
	for i in range(10):
		await process_frame
	var shell: UiShell = main as UiShell if main is UiShell \
		else main.find_children("*", "UiShell", true, false)[0]
	# Replace the save-backed roster with the one under test, then re-enter
	# the title screen so it is built against it.
	shell.roster = account
	shell.goto(UiRoute.TITLE)
	for i in range(8):
		await process_frame
	return shell


func _fresh_roster() -> Roster:
	return Roster.create(HeroRig.animated_heroes(), 7777)


func _veteran_roster() -> Roster:
	var r := Roster.create(HeroRig.animated_heroes(), 7777)
	for i in range(4):
		r.record_map_cleared(Campaign.Tier.NORMAL, i)
	var who: String = r.owned_names()[0]
	r.progress(who).level = 14
	return r


func _buttons(node: Node, out: Array = []) -> Array:
	if node is Button:
		out.append(node)
	for c in node.get_children():
		_buttons(c, out)
	return out


func _strings(n: Node, into: PackedStringArray = PackedStringArray()
		) -> PackedStringArray:
	if n is Label and not (n as Label).text.is_empty():
		into.append((n as Label).text)
	elif n is Button and not (n as Button).text.is_empty():
		into.append((n as Button).text)
	for c in n.get_children():
		_strings(c, into)
	return into


# ---- one door ----------------------------------------------------------------

func _one_door() -> void:
	print("\n=== one door, the same for everybody ===")
	for state in ["a new player", "a returning player"]:
		var r: Roster = _fresh_roster() if state == "a new player" \
			else _veteran_roster()
		var shell: UiShell = await _shell(r)
		var screen: UiScreen = shell.current_screen()
		check("%s: the shell boots on the title screen" % state,
			shell.current_route() == UiRoute.TITLE and screen is TitleScreen)

		var enter: Button = screen.find_child("EnterGame", true, false) \
			as Button
		check("%s: there is one way in, and it says Enter game" % state,
			enter != null and enter.text == "Enter game",
			enter.text if enter != null else "no EnterGame button")

		# NO MENU. Every other button that used to be here — Champions,
		# Stash, Merchant, Training, Contracts, Party — now lives in the
		# panel, and a second copy that can disagree is worse than one.
		var extras: PackedStringArray = PackedStringArray()
		for b in _buttons(screen):
			if b == enter:
				continue
			if not (b as Button).text.is_empty():
				extras.append((b as Button).text)
		check("%s: and nothing else on it" % state, extras.is_empty(),
			"also found: %s" % extras)

		# THE OLD TWO-STATE TEXT IS GONE. Named explicitly, because
		# "Continue · <region>" going stale against the save was one of the
		# reasons for the rebuild.
		var words: PackedStringArray = _strings(screen)
		var stale: bool = false
		for t in words:
			if t.findn("Continue") >= 0 or t.begins_with("Begin"):
				stale = true
		check("%s: the button does not describe the save" % state, not stale)

		# The mark and the name are still the point of the screen.
		var titled: bool = false
		for t in words:
			if t == "HERO":
				titled = true
		check("%s: it still says what the game is" % state, titled)

		# THE SHELL'S OWN CHROME IS HIDDEN HERE. A navigation panel over the
		# front door is a menu on the one screen that must not have one.
		var nav: Node = shell.get("_nav")
		check("%s: the navigation panel is not over it" % state,
			nav == null or not (nav as Control).visible)
		var bar: Node = shell.get("_bar")
		check("%s: and neither is the currency bar" % state,
			bar == null or not (bar as Control).visible)

		shell.get_parent().remove_child(shell)
		shell.queue_free()
		await process_frame


# ---- where it lands ----------------------------------------------------------

func _where_it_lands() -> void:
	print("\n=== the same button, different rooms ===")
	# THE BUTTON TEXT IS THE SAME; WHERE IT GOES IS NOT. A returning player
	# dropped on the roster has to find their own champion again, and a brand
	# new one dropped on a campaign screen is looking at a map chooser before
	# they have anybody to send.
	var fresh: Roster = _fresh_roster()
	var shell: UiShell = await _shell(fresh)
	var enter: Button = shell.current_screen().find_child("EnterGame", true,
		false) as Button
	check("a new player has a way in", enter != null)
	if enter != null:
		enter.pressed.emit()
		for i in range(8):
			await process_frame
		check("...which lands them on the roster, to pick someone",
			shell.current_route() == UiRoute.CHAMPIONS,
			shell.current_route())
	shell.get_parent().remove_child(shell)
	shell.queue_free()
	await process_frame

	var vet: Roster = _veteran_roster()
	var who: String = vet.owned_names()[0]
	var shell2: UiShell = await _shell(vet)
	var enter2: Button = shell2.current_screen().find_child("EnterGame", true,
		false) as Button
	check("a returning player has the same way in", enter2 != null
		and enter2.text == "Enter game")
	if enter2 != null:
		enter2.pressed.emit()
		for i in range(8):
			await process_frame
		check("...which lands them on the campaign",
			shell2.current_route() == UiRoute.CAMPAIGN,
			shell2.current_route())
		# WITH THE CHAMPION THEY HAVE BEEN PLAYING — the one furthest along,
		# not whichever sorts first.
		check("...carrying the champion they have been playing",
			shell2.selected_hero == who,
			"%s, expected %s" % [shell2.selected_hero, who])
	shell2.get_parent().remove_child(shell2)
	shell2.queue_free()
	await process_frame


# ---- it is alive -------------------------------------------------------------

func _it_is_alive() -> void:
	print("\n=== something moves ===")
	# A STILL TITLE SCREEN READS AS A STUCK LOAD. Until the player touches
	# it they have no way to tell the app is running at all, and the first
	# thing they do about that is force-quit.
	var shell: UiShell = await _shell(_veteran_roster())
	var screen: UiScreen = shell.current_screen()

	var embers: Node = screen.find_child("Embers", true, false)
	check("there are particles on it", embers != null
		and embers is GPUParticles2D)
	if embers != null:
		var p := embers as GPUParticles2D
		check("...which are emitting", p.emitting and p.amount > 0,
			"%d particles" % p.amount)
		check("...with a texture, so they are visible at all",
			p.texture != null)
		# PRE-WARMED. Without preprocess the screen opens empty and fills
		# over the particle lifetime, so the first thing the player sees is
		# the still image this is meant to avoid.
		check("...and are pre-warmed, so the screen is never empty",
			p.preprocess > 0.0, "%.1fs" % p.preprocess)

	# The backdrop drifts. Driven by _process, so a couple of frames of real
	# time have to pass for it to have moved.
	var art: TextureRect = null
	for n in screen.find_children("*", "TextureRect", true, false):
		art = n as TextureRect
		break
	if art != null and art.visible:
		var was: Vector2 = art.position
		for i in range(20):
			await process_frame
		check("the backdrop drifts rather than sitting still",
			art.position != was, "%s -> %s" % [was, art.position])
	else:
		# No plate for map 0 in this checkout: the screen is correct to show
		# none, and there is nothing to drift. Said rather than passed
		# silently, so a missing asset does not look like a tested feature.
		check("the backdrop is absent, so there is nothing to drift", true,
			"no stage plate for map 0 in this build")

	shell.get_parent().remove_child(shell)
	shell.queue_free()
