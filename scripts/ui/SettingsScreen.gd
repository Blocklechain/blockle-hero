class_name SettingsScreen
extends UiScreen

# Preloaded by path, never by bare class_name: a new script is absent from
# Godot's global class cache until the editor reimports, and every headless
# harness loads this file directly. See tools/classcheck.gd.
const Prefs := preload("res://scripts/game/Prefs.gd")
# ------------------------------------------------------------------------------
# SETTINGS, AND THE TWO THAT ARE NOT SETTINGS.
#
# Eight controls. Six of them are taste — how loud, which hand, numbers on or
# off. Two of them decide whether some people can play the game at all:
#
#   * SCREEN SHAKE. A shaking camera is the single most common cause of
#     motion sickness in an action game, and for a player with a vestibular
#     disorder it is not discomfort, it is ten minutes and then stop. So it
#     is not a row in an audio list: it is the first thing on the screen, it
#     has a one-tap OFF, and off means zero rather than "reduced".
#
#   * SUBTITLES. A spoken line nobody can hear is a line that did not
#     happen — muted phone, no headphones, a noisy bus, deaf. They default
#     ON, and the switch is beside the shake rather than three panels down
#     behind "Audio".
#
# Both live in the LEFT column, which in this shell is the column that does not
# scroll. Everything in the scrolling column can be missed by a player who
# never drags; nothing on the left can.
#
# ------------------------------------------------------------------------------
# IT WRITES THROUGH, AND IT NEVER TOUCHES THE ROSTER.
#
# Every control calls Prefs.set_value the moment it is used — there is no
# Apply button, because a settings screen with one has two states and the
# player cannot see which they are in. And this screen DELIBERATELY never
# emits state_changed: that signal means "the roster was mutated, persist it"
# and it is the shell's only trigger for writing user://roster.json. Wiring a
# volume slider to it would rewrite the campaign save on every frame of a
# drag. Preferences have their own file for exactly this reason (Prefs.gd).
#
# ------------------------------------------------------------------------------
# WHY refresh() DOES NOT REBUILD.
#
# Every other screen in this shell frees its rows and builds them again. This
# one cannot: the control under the player's finger during a drag would be
# freed mid-gesture, so the slider would move once and then die. So the nodes
# are built once and refresh() writes values into the ones it kept.
# ------------------------------------------------------------------------------

## How many cells a StepBar is divided into. Ten gives 10% steps, which is
## finer than anyone needs for volume and coarse enough that every step is a
## 70-odd pixel target.
const STEPS: int = 10

## key -> StepBar
var _bars: Dictionary = {}
## key -> Label showing the percentage
var _readouts: Dictionary = {}
## key -> Array[Button] of segments, in option order
var _picks: Dictionary = {}


func screen_title() -> String:
	return "Settings"


func build() -> void:
	var col: VBoxContainer = split_column(_comfort_panel())

	var sound: VBoxContainer = group(col, "SOUND")
	_slider_row(sound, Prefs.K_MASTER, "Everything",
		"The whole game's volume.")
	_slider_row(sound, Prefs.K_SFX, "Combat",
		"Hits, crits, casts, footsteps.")
	_slider_row(sound, Prefs.K_VOICE, "Voices", "")
	_pick_row(sound, Prefs.K_VOICE_ON, "Spoken lines", ["On", "Off"],
		"Turning voices off never hides the words — the line still appears "
		+ "as text.")

	var controls: VBoxContainer = group(col, "CONTROLS")
	_pick_row(controls, Prefs.K_HAND, "Movement stick",
		["Left side", "Right side"],
		"Which side of the glass the stick appears under your thumb.")
	_pick_row(controls, Prefs.K_DAMAGE, "Damage numbers", ["On", "Off"],
		"The figures that float off an enemy as it is hit.")

	# The reset is in the footer, where the one action a thumb should reach
	# without looking goes — and far away from the controls it undoes.
	var reset: Button = HeroTheme.button("Put everything back to default",
		HeroTheme.Btn.GHOST, HeroTheme.TAP)
	reset.pressed.connect(func() -> void:
		Prefs.reset()
		refresh()
		notified.emit("Settings are back to their defaults."))
	footer.add_child(reset)

	refresh()


## The left column: the two controls that decide whether the game is playable.
func _comfort_panel() -> Control:
	# An accent border rather than the default line, because this panel is the
	# one thing on the screen a player who came here for a reason is looking
	# for.
	var card := HeroTheme.panel(HeroTheme.PANEL_HI, HeroTheme.ACCENT)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", HeroTheme.GAP)
	card.add_child(box)

	box.add_child(HeroTheme.label("COMFORT", HeroTheme.F_SMALL,
		HeroTheme.ACCENT))
	box.add_child(HeroTheme.label("Make it playable", HeroTheme.F_HEAD))
	box.add_child(HeroTheme.prose(
		"Nothing here is a difficulty setting and nothing here changes what "
		+ "you earn."))
	box.add_child(HeroTheme.rule())

	# OFF IS A REAL CHOICE AND IT IS FIRST. A player who needs no shake must
	# be able to reach zero in one tap rather than aim a slider at its end.
	_pick_row(box, Prefs.K_SHAKE, "Screen shake", ["Off", "Half", "Full"],
		"Off is completely still — the camera never kicks, not even on a "
		+ "boss landing.")
	_slider_row(box, Prefs.K_SHAKE, "How much shake", "")

	box.add_child(HeroTheme.rule())

	_pick_row(box, Prefs.K_SUBTITLES, "Subtitles", ["On", "Off"],
		"Everything said out loud, written out. On by default.")
	return card


# ------------------------------------------------------------------------------
# Rows
# ------------------------------------------------------------------------------

## Title, live percentage, and a bar flanked by step buttons.
##
## THE BUTTONS ARE NOT DECORATION. The bar is the quick way and the buttons are
## the reliable way: a 10% step is a 132 px target that cannot be missed, which
## is what a player with a tremor, or one on a bus, actually uses. They are
## also the only part of this screen a headless harness can drive, which is why
## tools/prefstest.gd asserts through them.
func _slider_row(parent: Container, key: String, title: String,
		note: String) -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", HeroTheme.GAP)
	var name_label: Label = HeroTheme.label(title, HeroTheme.F_BODY)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_label)
	var readout: Label = HeroTheme.label("", HeroTheme.F_BODY, HeroTheme.ACCENT,
		HORIZONTAL_ALIGNMENT_RIGHT)
	readout.custom_minimum_size = Vector2(160, 0)
	head.add_child(readout)
	parent.add_child(head)
	_readouts[key] = readout

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", HeroTheme.GAP)

	var down: Button = HeroTheme.button("−", HeroTheme.Btn.SECONDARY,
		HeroTheme.TAP_SMALL)
	down.name = "Down_" + key
	down.custom_minimum_size = Vector2(HeroTheme.TAP_SMALL, HeroTheme.TAP_SMALL)
	down.pressed.connect(func() -> void: _step(key, -1))
	line.add_child(down)

	var bar := StepBar.new()
	# Handed in rather than read off the outer class: an inner class that said
	# `SettingsScreen.STEPS` would be naming its own file by class_name, which
	# fails to parse until the editor has cached it — the failure this
	# project's preload rule exists to prevent.
	bar.cells = STEPS
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.custom_minimum_size = Vector2(0, HeroTheme.TAP_SMALL)
	# Live while dragging, written when the finger lifts: the player hears the
	# volume they are setting, and the file is written once instead of once a
	# frame. See Prefs.set_value's `write` argument.
	#
	# THE RELEASE IS NOT GUARANTEED, which is why _exit_tree flushes too.
	# TouchScroll watches raw touches in _input, ahead of GUI dispatch, and
	# once a drag has wandered 24 px vertically it calls set_input_as_handled
	# and takes the gesture — so the bar can stop hearing a drag it started
	# and never see the finger lift. Without the second flush, a value set
	# that way would be live for the session and absent on the next launch:
	# the player would set it twice and conclude the screen is broken.
	bar.slid.connect(func(v: float) -> void: _write(key, v, false))
	bar.settled.connect(func() -> void: Prefs.flush())
	line.add_child(bar)
	_bars[key] = bar

	var up: Button = HeroTheme.button("+", HeroTheme.Btn.SECONDARY,
		HeroTheme.TAP_SMALL)
	up.name = "Up_" + key
	up.custom_minimum_size = Vector2(HeroTheme.TAP_SMALL, HeroTheme.TAP_SMALL)
	up.pressed.connect(func() -> void: _step(key, 1))
	line.add_child(up)
	parent.add_child(line)

	if note != "":
		parent.add_child(HeroTheme.prose(note))


## A segmented choice. Used for every boolean as well as for shake, because
## "On | Off" says which state you are in and a switch does not — a checkbox
## at arm's length is a small square that may or may not have a tick.
func _pick_row(parent: Container, key: String, title: String,
		options: Array, note: String) -> void:
	parent.add_child(HeroTheme.label(title, HeroTheme.F_BODY))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var group_ref := ButtonGroup.new()
	var buttons: Array[Button] = []
	for i in range(options.size()):
		var b: Button = HeroTheme.segment(String(options[i]), group_ref)
		b.name = "Pick_%s_%d" % [key, i]
		# `pressed` rather than `toggled`: refresh() sets button_pressed to
		# show the stored state, and toggled would fire from that and write
		# the value straight back — a loop with the store in the middle of it.
		# pressed only comes from a finger.
		var picked: int = i
		b.pressed.connect(func() -> void: _choose(key, picked, options.size()))
		buttons.append(b)
		row.add_child(b)
	parent.add_child(row)
	_picks[key] = buttons
	if note != "":
		parent.add_child(HeroTheme.prose(note))


# ------------------------------------------------------------------------------
# Writing
# ------------------------------------------------------------------------------

## Leaving the screen commits anything a drag left in memory. See _slider_row:
## the finger's release can be swallowed by TouchScroll, so "the drag ended"
## is not a reliable moment and "the screen went away" is.
func _exit_tree() -> void:
	Prefs.flush()


## iOS can suspend the app without ever sending a close request, and the
## player who switched away mid-drag must not come back to the old value.
## UiShell does the same thing for the roster.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED \
			or what == NOTIFICATION_WM_CLOSE_REQUEST:
		Prefs.flush()


func _write(key: String, value: Variant, commit: bool = true) -> void:
	Prefs.set_value(key, value, commit)
	refresh()


func _step(key: String, dir: int) -> void:
	var now: float = Prefs.num(key)
	_write(key, snappedf(now + float(dir) / float(STEPS), 1.0 / float(STEPS)))


## Turn segment `index` of `count` into a stored value.
##
## Booleans are two segments with "On" first, so index 0 is true. Shake is
## three, mapped to the ends and the middle of its range; the joystick side is
## the enum's own order.
func _choose(key: String, index: int, count: int) -> void:
	var spec: Dictionary = Prefs.SPEC.get(key, {})
	var kind: int = int(spec.get("kind", TYPE_BOOL))
	if kind == TYPE_BOOL:
		_write(key, index == 0)
	elif kind == TYPE_INT:
		_write(key, index)
	else:
		_write(key, float(index) / float(maxi(count - 1, 1)))


# ------------------------------------------------------------------------------
# Showing
# ------------------------------------------------------------------------------

func refresh() -> void:
	for key in _bars.keys():
		var bar := _bars[key] as StepBar
		if bar != null:
			bar.set_fraction(Prefs.num(String(key)))
	for key in _readouts.keys():
		var l := _readouts[key] as Label
		if l != null:
			l.text = _readout_text(String(key))
	for key in _picks.keys():
		var buttons: Array = _picks[key]
		var want: int = _segment_for(String(key), buttons.size())
		for i in range(buttons.size()):
			(buttons[i] as Button).button_pressed = i == want


func _readout_text(key: String) -> String:
	var spec: Dictionary = Prefs.SPEC.get(key, {})
	if int(spec.get("kind", TYPE_FLOAT)) != TYPE_FLOAT:
		return ""
	var v: float = Prefs.num(key)
	# "Off" rather than "0%": zero is a state the player chose, and naming it
	# is how they know the control reached the end rather than nearly.
	return "Off" if v <= 0.0 else "%d%%" % int(round(v * 100.0))


## Which segment is lit for the stored value.
##
## A float key can hold a value no segment names — 37% shake, set with the
## step buttons — so the nearest is lit rather than none. A row of three dark
## buttons reads as "no setting", which is never true.
func _segment_for(key: String, count: int) -> int:
	var spec: Dictionary = Prefs.SPEC.get(key, {})
	var kind: int = int(spec.get("kind", TYPE_BOOL))
	if kind == TYPE_BOOL:
		return 0 if Prefs.flag(key) else 1
	if kind == TYPE_INT:
		return clampi(Prefs.choice(key), 0, count - 1)
	var v: float = Prefs.num(key)
	return clampi(int(round(v * float(count - 1))), 0, count - 1)


# ------------------------------------------------------------------------------
# The bar
# ------------------------------------------------------------------------------

## A drawn, chunky value bar: cells rather than a line and a knob.
##
## An HSlider was the obvious thing and it is the wrong thing here. Its grabber
## comes from Godot's default theme at about 20 px, and this viewport is
## 2532 px wide — so the only part of it that looks like a handle is a sixth
## the width of a fingertip, on a screen where the documented minimum target
## is 132 px. Cells are drawn from maths like everything else in this project,
## every cell is a target, and the fill reads from across a room.
class StepBar extends Control:
	## Dragged to a new value, which must be applied but not yet written.
	signal slid(value: float)
	## The finger lifted. Whoever deferred the write should commit it now.
	signal settled()

	const CELL_GAP: float = 6.0

	## How many cells wide. Set by the owner; see _slider_row.
	var cells: int = 10
	var _value: float = 1.0
	var _dragging: bool = false

	func _init() -> void:
		# STOP, not PASS: this control is the target. With PASS the drag is
		# claimed by the ScrollContainer above it and the bar never moves —
		# the same gesture fight TouchScroll.gd exists to settle.
		mouse_filter = Control.MOUSE_FILTER_STOP

	func set_fraction(v: float) -> void:
		var want: float = clampf(v, 0.0, 1.0)
		if is_equal_approx(want, _value):
			return
		_value = want
		queue_redraw()

	func fraction() -> float:
		return _value

	func _gui_input(e: InputEvent) -> void:
		# Touch arrives here as mouse input: Godot's "emulate mouse from
		# touch" is on by default and this project does not turn it off, so
		# handling the mouse covers the phone as well as the editor.
		var mb := e as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_pick_at(mb.position.x)
			elif _dragging:
				_dragging = false
				settled.emit()
			accept_event()
			return
		var mm := e as InputEventMouseMotion
		if mm != null and _dragging:
			_pick_at(mm.position.x)
			accept_event()

	## Snap to the cell under x. Snapped rather than continuous so the value
	## the player sets is the value they can set again.
	func _pick_at(x: float) -> void:
		if size.x <= 0.0 or cells <= 0:
			return
		var raw: float = clampf(x / size.x, 0.0, 1.0)
		var v: float = round(raw * float(cells)) / float(cells)
		if is_equal_approx(v, _value):
			return
		_value = v
		queue_redraw()
		slid.emit(v)

	func _draw() -> void:
		if cells <= 0:
			return
		var w: float = (size.x - CELL_GAP * float(cells - 1)) / float(cells)
		if w <= 0.0:
			return
		# Inset vertically: the control is a touch target 112 px tall, but a
		# 112 px-tall bar of green is a wall rather than a reading.
		var h: float = minf(size.y, 46.0)
		var top: float = (size.y - h) * 0.5
		# The filled count rounds so the last cell lights at 100% and the
		# first goes dark at 0 — a bar showing one lit cell at "Off" is the
		# kind of detail that makes a player distrust the whole screen.
		var lit: int = int(round(_value * float(cells)))
		for i in range(cells):
			var r := Rect2(float(i) * (w + CELL_GAP), top, w, h)
			draw_rect(r, HeroTheme.ACCENT_DEEP if i < lit
				else Color(HeroTheme.LINE.r, HeroTheme.LINE.g,
					HeroTheme.LINE.b, 0.75))
