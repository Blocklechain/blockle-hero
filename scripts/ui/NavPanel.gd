class_name NavPanel
extends Control
# ------------------------------------------------------------------------------
# WHERE YOU CAN GO, DOWN THE LEFT EDGE.
#
# This replaces a row of four tabs across the bottom of the glass. The row was
# wrong in two ways that got worse as the game grew:
#
#   * IT COST A HORIZONTAL BAND of a 1170 px-tall landscape screen, which is
#     the scarce direction. A left panel costs width, which in landscape is
#     the direction there is plenty of — and collapsed it costs almost none.
#
#   * IT ONLY HELD FOUR. Champions, Stash, Merchant, Campaign fitted; Party,
#     Contracts and Training did not, so they became quick links on the title
#     screen and were unreachable from anywhere else. A destination you can
#     only get to by backing all the way out is a destination players forget
#     exists. All seven are here.
#
# ------------------------------------------------------------------------------
# COLLAPSED IS THE DEFAULT, AND IT IS STILL USABLE.
#
# A panel that has to be opened before it can be used is a menu behind a menu.
# Collapsed, it is a rail of icons: every destination is still one tap, and
# the labels are what the expansion adds. That is also why the icons are
# DRAWN rather than lettered — three of the seven destinations begin with C
# (Champions, Campaign, Contracts), so a rail of initials would be three
# identical buttons.
#
# It remembers its state for the session but is not saved: which way a panel
# was left is not account data, and writing it to roster.json would mean a
# UI preference riding in the same file as the player's progress.
#
# ------------------------------------------------------------------------------
# IT SCROLLS, AND IT HAS TO.
#
# Ten destinations at a 132 px row is 1,452 px of rows. The glass is 1,170 px
# tall and the currency bar takes a row of that, so roughly seven fit and the
# rest were simply CLIPPED — the panel sets clip_contents, so Training, Store
# and Title were in the list, built, connected, and invisible. Nothing errored
# and nothing looked broken; three destinations just did not exist.
#
# The rows cannot be made shorter to fit. 132 px is 44 pt at this device
# scale, which is the smallest a touch target is allowed to be, and a
# navigation panel is the last place to go under it. So the rows scroll.
#
# THE TOGGLE STAYS PINNED outside the scroll: it is the control that makes
# the labels appear, and a player who has scrolled to the bottom must not
# have to scroll back up to find out what the icons mean.
#
# TouchScroll is required rather than optional — every row is a Button, and a
# Button consumes the whole gesture, so Godot's own touch dragging never sees
# it. See TouchScroll.gd; on a desktop the wheel works and this looks fine,
# which is how a dead list survives a screenshot pass.
# ------------------------------------------------------------------------------

## The player picked a destination.
signal chose(route: String)

const RAIL_W: int = 112
const OPEN_W: int = 430
const SLIDE: float = 0.18

## Every destination, in the order they are offered. ROUTE, LABEL, GLYPH.
##
## EVERY SCREEN IN THE GAME IS IN THIS LIST. That is now load-bearing rather
## than tidy: the back chevron above the panel is gone, so a screen missing
## from here is a screen with no way out of it except whatever route it
## happens to nominate. navtest asserts the list against UiShell's own
## routing table so one cannot drift from the other.
##
## Ordered by how often a player wants it on the way into a run rather than
## alphabetically or by when it was built: the campaign is what they came for,
## the party and the board are decided just before going, and the shops are
## housekeeping.
const ITEMS: Array = [
	[UiRoute.CAMPAIGN, "Campaign", UiGlyph.Kind.BANNER],
	[UiRoute.PARTY, "Party", UiGlyph.Kind.PARTY],
	[UiRoute.QUESTS, "Contracts", UiGlyph.Kind.SCROLL],
	[UiRoute.CHAMPIONS, "Champions", UiGlyph.Kind.ROSTER],
	# THE CHARACTER SHEET. It was reachable only by tapping a champion in the
	# roster and leavable only by the chevron that is now gone, so without a
	# row of its own it would be a screen you can enter and not leave.
	[UiRoute.SHEET, "Champion", UiGlyph.Kind.BLADE],
	[UiRoute.STASH, "Stash", UiGlyph.Kind.CHEST],
	[UiRoute.SHOP, "Merchant", UiGlyph.Kind.SCALES],
	[UiRoute.TRAINING, "Training", UiGlyph.Kind.HOURGLASS],
	# The store is placed late deliberately: putting it first is what a game
	# does when the purchase matters more than the game.
	[UiRoute.STORE, "Store", UiGlyph.Kind.GEM],
	# SETTINGS. Two of its eight controls decide whether some people can play
	# the game at all — screen shake and the damage numbers — so a settings
	# screen the panel does not list is an accessibility option nobody can
	# reach. It was built, tested and connected to nothing until this row.
	[UiRoute.SETTINGS, "Settings", UiGlyph.Kind.HOURGLASS],
	# The front door, last. With no back button this is the only way back to
	# the title screen, which is also the only way to pick a different save
	# ending or simply to stop.
	[UiRoute.TITLE, "Title", UiGlyph.Kind.MARK],
]

var _open: bool = false
var _rows: Dictionary = {}          # route -> Button
var _labels: Array[Label] = []
var _slide: Tween
var _route: String = ""


func _init() -> void:
	custom_minimum_size = Vector2(RAIL_W, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true


func _ready() -> void:
	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel",
		HeroTheme.panel_style(HeroTheme.PANEL, HeroTheme.LINE))
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# A fixed top (the toggle) and a scrolling remainder (the destinations).
	var frame := VBoxContainer.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.add_theme_constant_override("separation", 8)
	add_child(frame)

	# THE TOGGLE IS THE FIRST THING, at the top where a hamburger is expected
	# — and it is a destination-shaped row like the others so the rail reads
	# as one column rather than a button with a list under it. It is OUTSIDE
	# the scroll: it is what makes the labels appear, so it must not be the
	# thing you have to scroll back up to reach.
	var toggle: Button = _row("", "Menu", UiGlyph.Kind.MENU)
	toggle.name = "NavToggle"
	toggle.pressed.connect(func() -> void: set_open(not _open))
	frame.add_child(toggle)

	frame.add_child(HeroTheme.rule())

	var sc := ScrollContainer.new()
	sc.name = "NavScroll"
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Without this the drag dies on whichever row the finger landed on and the
	# panel never moves. Not optional — see the header.
	TouchScroll.attach(sc)
	frame.add_child(sc)

	var col := VBoxContainer.new()
	col.name = "NavRows"
	col.add_theme_constant_override("separation", 8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(col)

	for item in ITEMS:
		var route: String = String(item[0])
		var b: Button = _row(route, String(item[1]), int(item[2]))
		b.pressed.connect(func() -> void:
			chose.emit(route)
			# A TAP ON A DESTINATION CLOSES THE PANEL. Expanded it covers a
			# third of the screen, and leaving it open over the screen the
			# player just asked for means every navigation needs two taps.
			if _open:
				set_open(false))
		_rows[route] = b
		col.add_child(b)

	_apply_width(RAIL_W)


## One row: a glyph that is always visible and a label that only is when the
## panel is open.
func _row(route: String, text: String, glyph: int) -> Button:
	var b: Button = HeroTheme.button("", HeroTheme.Btn.GHOST, HeroTheme.TAP)
	b.name = "Nav_" + (route if route != "" else text)
	b.tooltip_text = text
	# The glyph is positioned by hand rather than put in a container, so it
	# stays in the SAME PLACE when the panel widens. A row laid out by an
	# HBox re-centres its icon as the row grows, so the whole rail of icons
	# would drift right as the labels appear.
	var g := UiGlyph.make(glyph, 54, HeroTheme.TEXT)
	g.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	g.offset_left = (RAIL_W - 54) * 0.5
	g.offset_right = g.offset_left + 54
	g.offset_top = 0
	g.offset_bottom = 0
	g.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_child(g)

	var l: Label = HeroTheme.label(text, HeroTheme.F_BODY, HeroTheme.TEXT)
	l.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	l.offset_left = RAIL_W
	l.offset_right = OPEN_W - HeroTheme.GAP
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.visible = false
	b.add_child(l)
	_labels.append(l)
	return b


# ------------------------------------------------------------------------------
# Opening and closing
# ------------------------------------------------------------------------------

func is_open() -> bool:
	return _open


func set_open(open: bool) -> void:
	if open == _open:
		return
	_open = open
	# THE LABELS GO AWAY BEFORE THE PANEL NARROWS and come back only once it
	# is wide. Tying their visibility to the tween's end instead would show
	# text wider than the panel for a fifth of a second on every close, which
	# clips mid-word and reads as a glitch.
	if not open:
		_show_labels(false)
	if _slide != null and _slide.is_valid():
		_slide.kill()
	var want: float = float(OPEN_W if open else RAIL_W)
	# No tween before the node is in a tree with a size — during build, and in
	# the headless harnesses, where an animated width would simply never
	# arrive and every assertion would read the rail width.
	if not is_inside_tree() or size.x <= 0.0:
		_apply_width(want)
		_show_labels(open)
		return
	_slide = create_tween()
	_slide.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_slide.tween_method(_apply_width, size.x, want, SLIDE)
	if open:
		_slide.chain().tween_callback(func() -> void: _show_labels(true))


func _apply_width(w: float) -> void:
	custom_minimum_size = Vector2(w, 0)
	# Set as well as requested: custom_minimum_size only takes effect when the
	# parent container re-sorts, so without this the panel does not move until
	# something else changes.
	size.x = w


func _show_labels(on: bool) -> void:
	for l in _labels:
		l.visible = on


## Mark which destination is on screen, so the panel says where the player is
## as well as where they can go.
func mark(route: String) -> void:
	_route = route
	for key in _rows.keys():
		var b := _rows[key] as Button
		var here: bool = String(key) == route
		b.add_theme_color_override("font_color",
			HeroTheme.ACCENT if here else HeroTheme.DIM)
		for c in b.get_children():
			var g := c as UiGlyph
			if g != null:
				g.tint = HeroTheme.ACCENT if here else HeroTheme.TEXT
			var l := c as Label
			if l != null:
				l.add_theme_color_override("font_color",
					HeroTheme.ACCENT if here else HeroTheme.TEXT)
