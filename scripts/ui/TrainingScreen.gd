class_name TrainingScreen
extends UiScreen

# Preloaded by path — a new class_name is absent from Godot's global class
# cache until the editor reimports, and the headless harnesses load this
# script directly.
const Training := preload("res://scripts/game/Training.gd")
# ------------------------------------------------------------------------------
# THE BENCH.
#
# 139 champions and one of them gets played, because trying a different class
# means grinding it from level 1 while the one you have is level 30. Training
# is what keeps the other 138 worth fielding.
#
# ------------------------------------------------------------------------------
# WHY THIS SCREEN DID NOT WORK.
#
# Two faults, and together they made the feature look broken rather than slow:
#
#   * AN EMPTY SLOT COULD ONLY TAKE THE CHAMPION YOU HAD SELECTED. Every slot
#     offered one button, "Train <the current champion>", and a champion
#     cannot be in two slots — so the second, third and fourth slots were
#     unusable without leaving the screen, picking someone else in the
#     roster, and coming back. Four slots that can only hold one hero are
#     one slot and three refusals. There is a picker now, exactly like the
#     party screen's.
#
#   * THE NUMBERS NEVER MOVED. The screen had no timer and no _process, so it
#     rendered once and froze: you opened it, it said "0 xp waiting" and
#     "8h 00m until full", and nothing changed however long you watched. For
#     a feature whose entire subject is elapsed time, a frozen clock is
#     indistinguishable from a feature that does nothing. It ticks now.
#
# WHAT IT STILL HAS TO BE HONEST ABOUT, because an idle mechanic that is vague
# about its own numbers reads as a slot machine:
#
#   * How much is waiting, in XP, right now.
#   * That it STOPS. A slot that quietly capped four hours ago while the
#     player thought it was still earning is the thing that makes people
#     distrust idle systems. The bar fills and then says "Full".
#   * What the next slot costs, before they tap it.
# ------------------------------------------------------------------------------

## How often the numbers are redrawn. One second: the figures change by whole
## XP over minutes, so anything faster is work for no visible difference, and
## anything slower reads as a stuck clock.
const TICK: float = 1.0

var _rows: VBoxContainer = null
## Which slot the picker below is filling, or -1 when it is closed.
var _picking: int = -1
var _timer: Timer = null


func screen_title() -> String:
	return "Training"


func build() -> void:
	# A plain single column: this screen is a list of slots, with no art
	# panel to put beside it.
	var col := scroll_column()
	col.add_child(context_strip())

	# The cap is substituted into its OWN string: `%` binds tighter than `+`,
	# so a format spec in an earlier fragment of a `+` chain formats the LAST
	# fragment instead and the whole expression fails to parse.
	var cap: String = "%d hours" % int(Training.CAP_HOURS)
	col.add_child(HeroTheme.prose(
		"Champions on the bench keep training while the game is closed. "
		+ "A slot earns for up to " + cap + " and then stops, so there is "
		+ "nothing to gain by leaving it longer."))

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", HeroTheme.GAP)
	col.add_child(top)
	# COLLECT EVERYTHING AT ONCE. Four slots meant four taps on the one
	# action a player performs every single time they open this screen.
	var all: Button = HeroTheme.button("Collect all", HeroTheme.Btn.PRIMARY,
		HeroTheme.TAP_SMALL)
	all.name = "CollectAll"
	all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	all.pressed.connect(_collect_all)
	top.add_child(all)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", HeroTheme.GAP)
	col.add_child(_rows)

	# THE CLOCK. Without it this screen is a photograph of a timer.
	_timer = Timer.new()
	_timer.wait_time = TICK
	_timer.autostart = true
	_timer.timeout.connect(_on_tick)
	add_child(_timer)

	_refresh()


## Redraw the figures without rebuilding the rows.
##
## A full _refresh() every second would free and recreate every button on the
## screen, which eats a press that lands on the same frame — so the tick only
## touches the labels and the bar, and the rows are rebuilt only when
## something actually changes.
func _on_tick() -> void:
	if _rows == null or roster == null:
		return
	var now: int = _now()
	for i in range(Training.SLOTS_MAX):
		# FOUND FROM THE CARD, recursively, rather than by a path from here.
		# The labels sit inside an unnamed VBoxContainer, so "Slot0/Fill" is
		# not where Fill is — it is "Slot0/VBoxContainer/Fill", which is a
		# path that depends on Godot's auto-naming and would break the moment
		# another child was added. find_child is scoped to the card, so the
		# same names in four cards do not collide.
		var card := _rows.get_node_or_null("Slot%d" % i)
		if card == null:
			continue
		var bar := card.find_child("Fill", true, false) as ProgressBar
		var line := card.find_child("Waiting", true, false) as Label
		var claim := card.find_child("Collect", true, false) as Button
		var sl: Training.Slot = roster.slot(i)
		if sl == null or sl.is_empty() or not roster.slot_is_unlocked(i):
			continue
		var elapsed: float = float(sl.elapsed_at(now)[0])
		var pending: float = roster.pending_training(i, now)
		if bar != null:
			bar.value = Training.fill(elapsed)
		if line != null:
			line.text = "%s  ·  %s xp waiting" % [
				Training.remaining_text(elapsed), _commas(int(pending))]
			line.add_theme_color_override("font_color",
				HeroTheme.TEXT if Training.is_full(elapsed) else HeroTheme.DIM)
		if claim != null:
			claim.disabled = pending < Training.MIN_CLAIM_XP


func _now() -> int:
	return int(Time.get_unix_time_from_system())


## Bank every slot that has something in it. Reports one total rather than
## four messages.
func _collect_all() -> void:
	var now: int = _now()
	var total: float = 0.0
	var who: int = 0
	for i in range(Training.SLOTS_MAX):
		var got: float = roster.claim_training(i, now)
		if got > 0.0:
			total += got
			who += 1
	if total <= 0.0:
		notified.emit("Nothing is ready to collect yet.")
		_refresh()
		return
	notified.emit("Collected %s xp from %d champion%s."
		% [_commas(int(total)), who, "" if who == 1 else "s"])
	state_changed.emit()
	_refresh()


func refresh() -> void:
	_refresh()


func _refresh() -> void:
	if _rows == null or roster == null:
		return
	# REMOVED BEFORE FREED, not just freed.
	#
	# queue_free() is DEFERRED: the node stays in the tree, and keeps its
	# name, until the end of the frame. So a rebuild in the same frame added
	# a second "Slot0" beside the doomed one, Godot renamed the newcomer to
	# something auto-generated, and _on_tick's lookup by name then found the
	# node that was about to disappear — updating labels nobody would ever
	# see while the live ones stayed frozen at whatever they were built with.
	#
	# That is the whole "the numbers never move" symptom reappearing through
	# a different door, and it only shows up when a refresh and a tick land
	# close together, which on a screen with a one-second timer is often.
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()

	for i in range(Training.SLOTS_MAX):
		_rows.add_child(_slot_row(i))
		if _picking == i:
			_rows.add_child(_picker(i))


func _slot_row(index: int) -> Control:
	var card := PanelContainer.new()
	card.name = "Slot%d" % index
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	card.add_child(box)

	if not roster.slot_is_unlocked(index):
		var cost: int = Training.cost_of(index)
		box.add_child(HeroTheme.label("Slot %d — locked" % (index + 1),
			HeroTheme.F_BODY, HeroTheme.TEXT))
		box.add_child(HeroTheme.label(
			"%s gold to open" % _commas(cost), HeroTheme.F_SMALL,
			HeroTheme.DIM))
		# Only the NEXT slot is buyable — offering slot 4 before slot 2 just
		# means a confusing refusal.
		if index == roster.slots_unlocked:
			var buy: Button = HeroTheme.button("Open slot",
				HeroTheme.Btn.PRIMARY, HeroTheme.TAP)
			buy.pressed.connect(func():
				if roster.unlock_slot():
					state_changed.emit()
					_refresh()
				else:
					notified.emit("That costs %s gold." % _commas(cost)))
			box.add_child(buy)
		return card

	var sl: Training.Slot = roster.slot(index)
	if sl == null or sl.is_empty():
		box.add_child(HeroTheme.label("Slot %d — empty" % (index + 1),
			HeroTheme.F_BODY, HeroTheme.DIM))
		# A PICKER, NOT ONE NAMED BUTTON. This offered "Train <the champion
		# you currently have selected>" and nothing else, so with one hero
		# selected all four slots wanted the same champion — and a champion
		# cannot be in two slots, so three of them simply refused.
		var pick: Button = HeroTheme.button(
			"Close" if _picking == index else "Choose a champion",
			HeroTheme.Btn.GHOST, HeroTheme.TAP)
		pick.name = "Choose"
		pick.pressed.connect(func():
			_picking = -1 if _picking == index else index
			_refresh())
		box.add_child(pick)
		return card

	# Occupied.
	var elapsed: float = float(sl.elapsed_at(_now())[0])
	var pending: float = roster.pending_training(index, _now())
	var p: HeroProgress = roster.progress(sl.hero)

	box.add_child(HeroTheme.label("%s — level %d"
		% [ChampionName.of(sl.hero), p.level if p != null else 1],
		HeroTheme.F_BODY, HeroTheme.TEXT))

	var bar := ProgressBar.new()
	bar.name = "Fill"
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = Training.fill(elapsed)
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 18)
	box.add_child(bar)

	# SAYS WHEN IT STOPS. A bar that silently capped is the thing that makes
	# players stop trusting an idle system.
	var waiting: Label = HeroTheme.label(
		"%s  ·  %s xp waiting" % [Training.remaining_text(elapsed),
			_commas(int(pending))],
		HeroTheme.F_SMALL,
		HeroTheme.DIM if not Training.is_full(elapsed) else HeroTheme.TEXT)
	waiting.name = "Waiting"
	box.add_child(waiting)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", HeroTheme.GAP)

	var claim: Button = HeroTheme.button("Collect", HeroTheme.Btn.PRIMARY,
		HeroTheme.TAP)
	claim.name = "Collect"
	claim.disabled = pending < Training.MIN_CLAIM_XP
	claim.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	claim.pressed.connect(func():
		var got: float = roster.claim_training(index, _now())
		if got > 0.0:
			notified.emit("%s gained %s xp."
				% [ChampionName.of(sl.hero), _commas(int(got))])
			state_changed.emit()
		_refresh())
	row.add_child(claim)

	var clear: Button = HeroTheme.button("Remove", HeroTheme.Btn.GHOST,
		HeroTheme.TAP)
	clear.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear.pressed.connect(func():
		# Collect first, so taking a champion out never silently bins what
		# they had already earned.
		roster.claim_training(index, _now())
		sl.hero = ""
		sl.since = 0
		state_changed.emit()
		_refresh())
	row.add_child(clear)

	box.add_child(row)
	return card


## Who may go into [slot].
##
## EXCLUDES ANYONE ALREADY TRAINING, so every row offered is a choice that
## will be accepted. A picker that lists options it then refuses is the fault
## this screen had in its first form.
func _picker(slot: int) -> Control:
	var card := HeroTheme.panel(HeroTheme.PANEL_HI, HeroTheme.ACCENT)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", HeroTheme.PAD)
	pad.add_theme_constant_override("margin_right", HeroTheme.PAD)
	pad.add_theme_constant_override("margin_top", 18)
	pad.add_theme_constant_override("margin_bottom", 18)
	card.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pad.add_child(box)

	var busy: Dictionary = {}
	for i in range(Training.SLOTS_MAX):
		var other: Training.Slot = roster.slot(i)
		if i != slot and other != null and not other.is_empty():
			busy[other.hero] = true

	var offered: int = 0
	for who in roster.owned_names():
		if busy.has(who):
			continue
		var p: HeroProgress = roster.progress(who)
		# A MAXED CHAMPION EARNS NOTHING (Training.xp_for), so offering them
		# is offering a slot that will sit at zero forever.
		if p != null and p.level >= HeroProgress.MAX_LEVEL:
			continue
		offered += 1
		var b: Button = HeroTheme.button("%s  ·  level %d"
			% [ChampionName.of(who), p.level if p != null else 1],
			HeroTheme.Btn.SECONDARY, HeroTheme.TAP_SMALL)
		b.pressed.connect(func() -> void:
			if roster.begin_training(slot, who, _now()):
				_picking = -1
				state_changed.emit()
				_refresh()
			else:
				notified.emit("%s cannot train right now."
					% ChampionName.of(who)))
		box.add_child(b)

	if offered == 0:
		box.add_child(HeroTheme.label(
			"Every champion you own is already training.",
			HeroTheme.F_SMALL, HeroTheme.DIM))
	return card


static func _commas(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	var c: int = 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if n < 0 else "") + out
