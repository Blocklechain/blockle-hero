extends SceneTree
# ------------------------------------------------------------------------------
# THE LEFT PANEL IS NOW THE ONLY WAY AROUND THE GAME.
#
# It replaced a row of four tabs. That makes it load-bearing in a way the tabs
# were not, because the tabs only ever held four destinations and the other
# three were reachable from the title screen as well — so a broken tab was an
# inconvenience. A broken panel row is a screen the player cannot open at all.
#
# Three things this has to hold, and every one of them fails silently:
#
#   * EVERY DESTINATION IS LISTED, and the list is the one the shell can
#     actually route to. A row naming a route UiShell does not know about is a
#     button that does nothing — no error, no log line.
#
#   * COLLAPSED IS USABLE. A panel that has to be opened before it can be
#     used is a menu behind a menu. Every row must be one tap in either
#     state, which means the glyph has to be hittable at rail width.
#
#   * IT DOES NOT EAT THE SCREEN. Expanded it covers a third of the glass; if
#     it does not close on a choice, every navigation costs two taps and the
#     screen the player asked for is half-hidden when they get there.
# ------------------------------------------------------------------------------

const NavPanelS := preload("res://scripts/ui/NavPanel.gd")

var _fails: int = 0
var _ran: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _init() -> void:
	# THE PROJECT'S OWN VIEWPORT, read rather than typed.
	#
	# A hardcoded size here measured a panel 2160 px tall — nearly twice the
	# real screen — so the overflow this harness exists to catch did not
	# happen and the reachability assertions were being made against a
	# geometry no device has. The aspect mode matters too: "expand" is what
	# the project ships, and it is what decides how much height the panel
	# actually gets.
	var design := Vector2i(
		ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height"))
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	get_root().content_scale_size = design
	get_root().size = design
	await process_frame
	await process_frame

	await _destinations(); _ran += 1
	await _collapsing(); _ran += 1
	await _in_the_shell(); _ran += 1
	print("")
	check("every section ran to completion", _ran == 3, "%d of 3" % _ran)
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


func _buttons(node: Node, out: Array = []) -> Array:
	if node is Button:
		out.append(node)
	for c in node.get_children():
		_buttons(c, out)
	return out


# ---- what it offers ----------------------------------------------------------

func _destinations() -> void:
	print("\n=== every destination ===")
	var nav: NavPanelS = NavPanelS.new()
	root.add_child(nav)
	await process_frame

	# EVERY ROW MUST NAME A ROUTE THE SHELL CAN BUILD. A row pointing at a
	# route UiShell's match statement does not handle is a dead button, and
	# UiShell._make_screen returns null for one without complaining.
	# THE REAL SHELL, from the scene. UiShell.new() on its own pushes "missing
	# Ui/Safe or Overlay" and comes up half-built, because the shell expects
	# the node structure Main.tscn gives it — and a half-built shell is not
	# what the question "can it route to this?" is about.
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	get_root().add_child(main)
	for i in range(10):
		await process_frame
	var shell: UiShell = main as UiShell if main is UiShell \
		else main.find_children("*", "UiShell", true, false)[0]

	var routable: int = 0
	for item in NavPanelS.ITEMS:
		var made: UiScreen = shell.call("_make_screen", String(item[0]))
		if made != null:
			routable += 1
			made.queue_free()
	check("every row names a route the shell can build",
		routable == NavPanelS.ITEMS.size(),
		"%d of %d" % [routable, NavPanelS.ITEMS.size()])

	# And it offers MORE than the four tabs did — that is the reason for the
	# rebuild, not a side effect of it. Party, Contracts and Training were
	# reachable only from the title screen before.
	check("it holds more than the old four tabs",
		NavPanelS.ITEMS.size() >= 7, "%d destinations" % NavPanelS.ITEMS.size())

	# EVERY SCREEN THE SHELL CAN BUILD HAS A ROW.
	#
	# This is load-bearing now rather than tidy: the back chevron above the
	# panel is gone, so a screen missing from the panel is a screen with no
	# way out of it. Checked against UiShell's own routing table — every
	# route it will build a screen for must be offered — so the two cannot
	# drift apart.
	var routes: Dictionary = {}
	for item in NavPanelS.ITEMS:
		routes[String(item[0])] = true
	var orphans: PackedStringArray = PackedStringArray()
	for route in [UiRoute.TITLE, UiRoute.CHAMPIONS, UiRoute.SHEET,
			UiRoute.STASH, UiRoute.SHOP, UiRoute.CAMPAIGN, UiRoute.TRAINING,
			UiRoute.QUESTS, UiRoute.PARTY, UiRoute.STORE]:
		var made: UiScreen = shell.call("_make_screen", route)
		if made == null:
			continue
		made.queue_free()
		if not routes.has(route):
			orphans.append(route)
	check("every screen the shell can build has a row in the panel",
		orphans.is_empty(), "missing: %s" % orphans)

	var names: Dictionary = {}
	var glyphs: Dictionary = {}
	for item in NavPanelS.ITEMS:
		names[String(item[0])] = true
		glyphs[int(item[2])] = true
	check("no destination is listed twice",
		names.size() == NavPanelS.ITEMS.size(), "%d routes" % names.size())
	# A SHARED ICON IS AN AMBIGUOUS RAIL. Collapsed, the glyph is the only
	# thing distinguishing the rows, and three destinations begin with C — so
	# two rows wearing the same icon would be indistinguishable.
	check("every destination has its own icon",
		glyphs.size() == NavPanelS.ITEMS.size(), "%d icons" % glyphs.size())

	# Each row really exists, and really is a button.
	var found: int = 0
	for item in NavPanelS.ITEMS:
		var b: Button = _row_of(nav, String(item[0]))
		if b != null and not b.disabled:
			found += 1
	check("every destination has a row that can be pressed",
		found == NavPanelS.ITEMS.size(),
		"%d of %d" % [found, NavPanelS.ITEMS.size()])

	# ------------------------------------------------------------------------
	# AND EVERY ROW HAS TO BE REACHABLE, which is not the same question.
	#
	# Ten rows at a 132 px touch target is 1,452 px of rows in a 1,170 px
	# screen that also carries a currency bar. The panel sets clip_contents,
	# so Training, Store and Title were built, connected, listed — and
	# CLIPPED. Every assertion above passed. Nothing errored. Three
	# destinations simply did not exist, and the only way to find out was to
	# look at the device and count.
	#
	# The rows cannot be made shorter: 132 px is 44 pt here, the smallest a
	# touch target may be. So they scroll, and this is the check that the
	# scrolling actually reaches the end of them.
	# ------------------------------------------------------------------------
	# The rows live in a scroll container with finger scrolling attached.
	# WHETHER IT REACHES THEM is asserted in _in_the_shell(), where the panel
	# has a real height — a bare NavPanel added to the root is laid out by
	# nothing, so its scroll is zero pixels tall and any reachability claim
	# measured here would be measuring nothing.
	var sc := nav.find_child("NavScroll", true, false) as ScrollContainer
	var rows := nav.find_child("NavRows", true, false) as Control
	check("the rows are in a scroll container", sc != null)
	check("...which holds them", rows != null and sc != null
		and rows.get_parent() == sc)
	check("...with finger scrolling attached, because every row is a Button",
		sc != null and sc.find_child("TouchScroll", true, false) != null)

	main.queue_free()
	nav.queue_free()


func _row_of(nav: Node, route: String) -> Button:
	return nav.find_child("Nav_" + route, true, false) as Button


# ---- collapsing --------------------------------------------------------------

func _collapsing() -> void:
	print("\n=== collapsed, and expanded ===")
	var nav: NavPanelS = NavPanelS.new()
	nav.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(nav)
	await process_frame

	check("it starts collapsed", not nav.is_open())
	var rail: float = nav.size.x
	check("...at rail width", rail <= NavPanelS.RAIL_W + 1.0,
		"%.0f px" % rail)

	# COLLAPSED IS USABLE. The whole point of a rail rather than a drawer: a
	# destination must be one tap in either state.
	var chosen: Array = []
	nav.chose.connect(func(route: String) -> void: chosen.append(route))
	var campaign: Button = _row_of(nav, UiRoute.CAMPAIGN)
	check("a destination can be chosen while collapsed", campaign != null)
	if campaign != null:
		campaign.pressed.emit()
		check("...and it reports the route", chosen.size() == 1
			and String(chosen[0]) == UiRoute.CAMPAIGN, "%s" % chosen)
		check("...without having to open the panel first", not nav.is_open())
		# The glyph has to be inside the row's own rect, or the icon is
		# drawn somewhere the tap does not land.
		var glyph: UiGlyph = null
		for c in campaign.get_children():
			if c is UiGlyph:
				glyph = c
		check("...and its icon sits inside the row that is tappable",
			glyph != null and glyph.position.x >= -1.0
				and glyph.position.x + glyph.size.x <= rail + 1.0,
			"icon at %.0f..%.0f of %.0f" % [glyph.position.x if glyph != null
				else -1.0, (glyph.position.x + glyph.size.x) if glyph != null
				else -1.0, rail])

	# THE TOGGLE.
	var toggle: Button = nav.find_child("NavToggle", true, false) as Button
	check("there is a toggle", toggle != null)
	if toggle != null:
		toggle.pressed.emit()
		# Let the slide finish.
		for i in range(40):
			await process_frame
		check("pressing it opens the panel", nav.is_open())
		check("...which actually gets wider",
			nav.size.x > rail + 50.0, "%.0f -> %.0f px" % [rail, nav.size.x])

		# The labels are what expanding BUYS. If they never appear, the
		# panel is just a wider rail.
		var labelled: int = 0
		for item in NavPanelS.ITEMS:
			var b: Button = _row_of(nav, String(item[0]))
			if b == null:
				continue
			for c in b.get_children():
				var l := c as Label
				if l != null and l.visible and l.text == String(item[1]):
					labelled += 1
		check("...and the rows are labelled when it is open",
			labelled == NavPanelS.ITEMS.size(),
			"%d of %d labelled" % [labelled, NavPanelS.ITEMS.size()])

		# CHOOSING CLOSES IT. Expanded it covers a third of the screen.
		var stash: Button = _row_of(nav, UiRoute.STASH)
		if stash != null:
			stash.pressed.emit()
			for i in range(40):
				await process_frame
			check("choosing a destination closes the panel again",
				not nav.is_open())
			check("...back to rail width", nav.size.x <= NavPanelS.RAIL_W + 1.0,
				"%.0f px" % nav.size.x)
			# AND THE LABELS GO WITH IT. A label left visible at rail width
			# is text wider than the panel, clipped mid-word.
			var showing: int = 0
			for item in NavPanelS.ITEMS:
				var b2: Button = _row_of(nav, String(item[0]))
				if b2 == null:
					continue
				for c in b2.get_children():
					var l2 := c as Label
					if l2 != null and l2.visible:
						showing += 1
			check("...and no label is left hanging outside it", showing == 0,
				"%d still visible" % showing)

		# Toggling twice in a row must not leave it half-open: the tween is
		# killed and restarted, and a width left mid-slide is a panel that
		# neither reads as a rail nor as a drawer.
		toggle.pressed.emit()
		toggle.pressed.emit()
		for i in range(40):
			await process_frame
		check("toggling twice settles at one of the two widths",
			nav.size.x <= NavPanelS.RAIL_W + 1.0
				or nav.size.x >= NavPanelS.OPEN_W - 1.0,
			"%.0f px" % nav.size.x)

	nav.queue_free()


# ---- in the real shell -------------------------------------------------------

func _in_the_shell() -> void:
	print("\n=== in the shell ===")
	# DRIVEN THROUGH THE REAL SHELL by pressing real rows, because a panel
	# that emits the right signal into a shell that is not listening is the
	# failure this project produces by default.
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	get_root().add_child(main)
	for i in range(10):
		await process_frame
	var shell: UiShell = main as UiShell if main is UiShell \
		else main.find_children("*", "UiShell", true, false)[0]

	var nav: Node = shell.get("_nav")
	check("the shell has the panel", nav != null)
	if nav == null:
		main.queue_free()
		return

	# The old bottom strip must be gone, not merely hidden behind the new one.
	check("the bottom tab strip is gone", shell.get("_tabs") == null)

	# AND SO IS THE BACK CHEVRON ABOVE THE PANEL. Two ways around the game
	# that disagree is worse than one: "back" went wherever the screen
	# nominated — the roster from the sheet, the sheet from the campaign — so
	# the same control meant something different on every screen while the
	# panel beside it always meant the same thing.
	shell.goto(UiRoute.SHEET)
	for i in range(6):
		await process_frame
	var bar: Node = shell.get("_bar")
	var back: Node = bar.get("_back") if bar != null else null
	check("there is no back button above the panel",
		back == null or not (back as Control).visible)

	shell.goto(UiRoute.CHAMPIONS)
	for i in range(6):
		await process_frame
	check("the panel is visible on a menu screen", nav.visible)

	# EVERY ROW ACTUALLY NAVIGATES. One press each, through the shell.
	var worked: int = 0
	for item in NavPanelS.ITEMS:
		var route: String = String(item[0])
		var b: Button = _row_of(nav, route)
		if b == null:
			continue
		b.pressed.emit()
		for i in range(6):
			await process_frame
		if shell.current_route() == route and shell.current_screen() != null:
			worked += 1
		else:
			print("    %s went to '%s'" % [route, shell.current_route()])
	check("every row opens its screen through the shell",
		worked == NavPanelS.ITEMS.size(),
		"%d of %d" % [worked, NavPanelS.ITEMS.size()])

	# ------------------------------------------------------------------------
	# EVERY ROW HAS TO BE REACHABLE, which is not the same question as
	# "every row exists" — and the difference is what shipped.
	#
	# Ten rows at a 132 px touch target is 1,392 px of rows. The glass is
	# 1,170 px tall and the currency bar takes a row of it, so about seven
	# fit and the rest were CLIPPED: the panel sets clip_contents, so
	# Training, Store and Title were built, connected, listed by every
	# assertion above — and invisible. Nothing errored. Three destinations
	# simply did not exist, and the only way to find out was to look at a
	# device and count.
	#
	# The rows cannot be shortened: 132 px is 44 pt at this device scale,
	# which is the floor for a touch target. So they scroll, and this is the
	# check that the scrolling reaches the end.
	# ------------------------------------------------------------------------
	var sc := nav.find_child("NavScroll", true, false) as ScrollContainer
	var rows := nav.find_child("NavRows", true, false) as Control
	check("the panel has a scroll and rows in the live shell",
		sc != null and rows != null)
	if sc == null or rows == null:
		main.queue_free()
		return

	# ---- DOES IT OVERFLOW ON THE DEVICE? ------------------------------------
	#
	# Measured against the PROJECT'S configured viewport, not against this
	# harness's window. A headless root does not honour a size assignment, so
	# the panel measures around 2,160 px here — nearly twice the real screen
	# — and an overflow assertion made against that is a claim about a
	# geometry no device has. The shipping viewport is the only height worth
	# asserting about.
	var need: float = rows.get_combined_minimum_size().y
	var screen_h: float = float(ProjectSettings.get_setting(
		"display/window/size/viewport_height"))
	# What the panel actually gets: the glass, less the safe-area margins the
	# shell applies top and bottom, less the currency bar and the gap under
	# it, less the toggle row and its rule which sit outside the scroll.
	var chrome: float = HeroTheme.SAFE_Y * 2 + HeroTheme.GAP * 3 \
		+ HeroTheme.TAP * 2 + 8.0
	var avail: float = screen_h - chrome
	check("the rows do not fit on the real screen, so scrolling is required",
		need > avail,
		"%.0f px of rows, about %.0f px of room at %.0f px tall"
			% [need, avail, screen_h])
	check("...and every row is still a legal touch target",
		HeroTheme.TAP >= 132, "%d px = %d pt" % [HeroTheme.TAP,
			HeroTheme.TAP / 3])

	# ---- AND CAN THE SCROLL REACH THE END? ----------------------------------
	# Asserted at whatever height this harness gives the panel, which is the
	# honest thing a runtime check can say: if the rows overflow here the
	# scroll must cover it, and if they fit here they are already on screen.
	var vbar: VScrollBar = sc.get_v_scroll_bar()
	var reach: float = maxf(vbar.max_value - vbar.page, 0.0)
	var overflow: float = maxf(need - sc.size.y, 0.0)
	check("the scroll covers whatever does not fit",
		reach >= overflow - 2.0,
		"reaches %.0f px, overflow %.0f px" % [reach, overflow])

	# THE LAST ROW, SPECIFICALLY. "The scrollbar has a range" is not the same
	# claim as "the tenth destination can be tapped".
	sc.scroll_vertical = int(reach)
	for i in range(4):
		await process_frame
	var tail: String = String(NavPanelS.ITEMS[NavPanelS.ITEMS.size() - 1][0])
	var last: Button = _row_of(nav, tail)
	check("the LAST destination can be brought into view", last != null
		and sc.get_global_rect().intersects(last.get_global_rect()),
		"%s at %s" % [tail, last.get_global_rect() if last != null else "?"])

	# AND THE ONE THE REPORT WAS ABOUT. Training is eighth of ten — past the
	# fold on the real screen, so it was listed, built, connected, and not
	# on the glass.
	var training: Button = _row_of(nav, UiRoute.TRAINING)
	check("...and so can Training, which was the one that went missing",
		training != null
			and sc.get_global_rect().intersects(training.get_global_rect()),
		"%s" % (training.get_global_rect() if training != null else "?"))
	sc.scroll_vertical = 0
	await process_frame

	# WHERE YOU ARE, not only where you can go. The sheet is pushed on top of
	# the champion list, so the list's row stays lit rather than leaving the
	# whole panel dark.
	shell.goto(UiRoute.SHEET)
	for i in range(6):
		await process_frame
	var lit: String = String(nav.get("_route"))
	check("the character sheet keeps the Champions row lit",
		lit == UiRoute.CHAMPIONS, "lit '%s'" % lit)

	# THE TITLE SCREEN IS FULL-BLEED. A panel left over it would cover the
	# art the screen exists to show.
	shell.goto(UiRoute.TITLE)
	for i in range(6):
		await process_frame
	check("the panel is hidden on the title screen", not nav.visible)
	check("...and is left closed, so it does not reopen over it",
		not nav.call("is_open"))

	main.queue_free()
