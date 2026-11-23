class_name ClearScreen
extends Control
# ------------------------------------------------------------------------------
# The boss is down.
#
# This is the most important screen in the game and it did not exist. The boss
# died, loot fell, and the player stood in an empty field with no idea they had
# finished anything — the one moment the whole map was built to deliver, and it
# delivered nothing.
#
# WHAT MAKES IT PULL. Not the congratulation, which is cheap and which players
# see through immediately. Three things, in this order:
#
#   1. PROOF OF WHAT JUST HAPPENED. What you killed, what you earned, what you
#      gained. Specific numbers, because specific numbers are what make the
#      last ten minutes feel like they counted.
#   2. THE BAR MOVED. "14 of 100 cleared" with a bar that visibly fills. A
#      number going up is the oldest hook there is and it works because it is
#      honest — the bar is the real save data.
#   3. THE NEXT ONE IS NAMED AND ONE TAP AWAY. The strongest pull is not
#      "well done", it is already knowing where you are going and not having
#      to walk back through three menus to get there.
#
# It animates in rather than appearing: the rows fade up one after another and
# the bar then fills. A stat block that is simply THERE reads as a receipt. The
# same block arriving a beat at a time reads as a reward.
# ------------------------------------------------------------------------------

## Seconds before the first row lands, then between each one.
const LEAD: float = 0.22
const STEP: float = 0.13
## How long the progress bar takes to run to its new value.
const BAR_TIME: float = 0.7

signal next_stage()
signal back_to_camp()

var _summary: Dictionary = {}
var _rows: Array[Control] = []
var _bar_fill: ColorRect
var _bar_to: float = 0.0
var _bar_from: float = 0.0
var _bar_t: float = 0.0
var _elapsed: float = 0.0


func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


## Build the screen for one cleared map. `summary` comes from Play.
func show_summary(summary: Dictionary) -> void:
	_summary = summary

	var veil := ColorRect.new()
	veil.color = Color(HeroTheme.BG.r, HeroTheme.BG.g, HeroTheme.BG.b, 0.86)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(veil)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", HeroTheme.SAFE_X)
	pad.add_theme_constant_override("margin_right", HeroTheme.SAFE_X)
	pad.add_theme_constant_override("margin_top", 50)
	pad.add_theme_constant_override("margin_bottom", 40)
	add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", HeroTheme.GAP)
	pad.add_child(col)

	var region: int = int(_summary.get("region", 0))
	# THE SAME SCREEN REPORTS A LOSS. A champion's death now ends the run
	# (Play._on_champion_died), and it arrives here rather than through a second
	# screen that would have to be kept in step with this one forever — so the
	# headline and its colour are the one thing that has to change. Telling a
	# player "REGION CLEARED" over a run they died in would be a lie the stats
	# underneath it immediately contradict.
	var lost: bool = bool(_summary.get("defeat", false))
	var title := HeroTheme.label(
		"YOUR CHAMPION FELL" if lost else "REGION CLEARED",
		HeroTheme.F_TITLE,
		HeroTheme.DANGER if lost else HeroTheme.ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)
	_rows.append(title)

	var who := HeroTheme.label("%s  ·  %s" % [
		Campaign.region_title(region),
		Campaign.tier_name(int(_summary.get("tier", 0)))],
		HeroTheme.F_HEAD, HeroTheme.TEXT)
	who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	who.clip_text = true
	who.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(who)
	_rows.append(who)

	col.add_child(HeroTheme.rule())
	# A spacer above as well as below, so the numbers sit in the middle of the
	# screen rather than crowding the title with a hole beneath them.
	col.add_child(_spacer())

	# --- what the run earned -------------------------------------------------
	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", HeroTheme.GAP * 2)
	stats.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(stats)
	_rows.append(stats)
	_stat(stats, "%d" % int(_summary.get("kills", 0)), "defeated")
	_stat(stats, HeroTheme.money(int(_summary.get("gold", 0))), "gold",
		HeroTheme.GOLD)
	var items: int = int(_summary.get("items", 0))
	if items > 0:
		_stat(stats, "%d" % items, "items found")
	var levels: int = int(_summary.get("levels", 0))
	if levels > 0:
		_stat(stats, "+%d" % levels,
			"level" if levels == 1 else "levels", HeroTheme.ACCENT)

	# --- the bar that moved --------------------------------------------------
	var cleared: int = int(_summary.get("cleared", 0))
	var total: int = maxi(int(_summary.get("total", 1)), 1)
	var progress := HeroTheme.label(
		"%d of %d regions cleared on %s" % [cleared, total,
			Campaign.tier_name(int(_summary.get("tier", 0)))],
		HeroTheme.F_SMALL, HeroTheme.DIM)
	progress.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(progress)
	_rows.append(progress)

	var track := Panel.new()
	track.add_theme_stylebox_override("panel",
		HeroTheme.panel_style(HeroTheme.PANEL, HeroTheme.LINE))
	track.custom_minimum_size = Vector2(0, 26)
	col.add_child(track)
	_rows.append(track)
	_bar_fill = ColorRect.new()
	_bar_fill.color = HeroTheme.ACCENT
	_bar_fill.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_bar_fill.offset_top = 4
	_bar_fill.offset_bottom = -4
	_bar_fill.offset_left = 4
	_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.add_child(_bar_fill)
	# From the value BEFORE this clear, so the bar is seen to move. A bar that
	# is already full when it fades in has not rewarded anything.
	_bar_from = float(maxi(cleared - 1, 0)) / float(total)
	_bar_to = float(cleared) / float(total)

	# CONTRACTS FINISHED BY THIS RUN. Said here, on the screen the player is
	# already looking at, rather than left to be found later on the board: a
	# reward nobody is told about is a reward nobody collects.
	for line in _summary.get("quests_done", PackedStringArray()):
		var qd := HeroTheme.label("CONTRACT COMPLETE — %s" % String(line),
			HeroTheme.F_BODY, HeroTheme.ACCENT)
		qd.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		qd.clip_text = true
		qd.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col.add_child(qd)
		_rows.append(qd)

	# The one-time payout for finishing a whole difficulty.
	var crystals: int = int(_summary.get("crystals", 0))
	if crystals > 0:
		var prize := HeroTheme.label(
			"DIFFICULTY COMPLETE — %d spawn crystal%s awarded"
			% [crystals, "" if crystals == 1 else "s"],
			HeroTheme.F_BODY, HeroTheme.CRYSTAL)
		prize.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(prize)
		_rows.append(prize)

	col.add_child(_spacer())

	# --- where you are going next --------------------------------------------
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 18)
	col.add_child(buttons)
	_rows.append(buttons)

	var camp := HeroTheme.button("Back to camp", HeroTheme.Btn.SECONDARY, 150)
	camp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	camp.pressed.connect(func() -> void: back_to_camp.emit())
	buttons.add_child(camp)

	var next: int = int(_summary.get("next", -1))
	if next >= 0:
		# NAMED, not "Continue". Knowing where you are going is most of the
		# reason to go, and it costs one string.
		var go := HeroTheme.button("Next: %s"
			% Campaign.region_title(next), HeroTheme.Btn.PRIMARY, 150)
		go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		go.size_flags_stretch_ratio = 2.0
		go.pressed.connect(func() -> void: next_stage.emit())
		buttons.add_child(go)

	# Everything starts hidden and arrives on the clock below.
	for r in _rows:
		r.modulate.a = 0.0
	set_process(true)
	# The same cue the loot pickup borrows, pitched higher again. This project
	# synthesises five cues and deliberately does not ship a sixth.
	Audio.play(Audio.Cue.CAST, 2.1)


func _spacer() -> Control:
	var s := Control.new()
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return s


func _stat(into: HBoxContainer, value: String, label: String,
		colour: Color = HeroTheme.TEXT) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var v := HeroTheme.label(value, HeroTheme.F_HEAD, colour)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(v)
	var l := HeroTheme.label(label, HeroTheme.F_SMALL, HeroTheme.DIM)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(l)
	into.add_child(box)


func _process(delta: float) -> void:
	_elapsed += delta

	# Rows arrive one after another, each sliding the last few pixels up.
	var all_in: bool = true
	for i in range(_rows.size()):
		var at: float = LEAD + float(i) * STEP
		var k: float = clampf((_elapsed - at) / 0.26, 0.0, 1.0)
		if k < 1.0:
			all_in = false
		# ALPHA ONLY. These are children of a VBoxContainer, and a container
		# re-places its children every layout pass — writing position.y here
		# fought it frame by frame and scrambled the whole screen, putting the
		# buttons above the title. The stagger alone still reads as arriving.
		_rows[i].modulate.a = k

	# The bar runs once the rows are down, so the eye is on it when it moves.
	if all_in and _bar_fill != null:
		_bar_t = minf(_bar_t + delta / BAR_TIME, 1.0)
		var e: float = 1.0 - pow(1.0 - _bar_t, 3.0)
		var f: float = lerpf(_bar_from, _bar_to, e)
		_bar_fill.anchor_right = clampf(f, 0.0, 1.0)
		if _bar_t >= 1.0:
			set_process(false)
