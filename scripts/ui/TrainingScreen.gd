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
# WHAT THIS SCREEN HAS TO BE HONEST ABOUT, because an idle mechanic that is
# vague about its own numbers reads as a slot machine:
#
#   * How much is waiting, in XP, right now.
#   * That it STOPS. A slot that quietly capped four hours ago while the
#     player thought it was still earning is the thing that makes people
#     distrust idle systems. The bar fills and then says "Full".
#   * What the next slot costs, before they tap it.
# ------------------------------------------------------------------------------

var _rows: VBoxContainer = null


func build() -> void:
	# A plain single column: this screen is a list of slots, with no art
	# panel to put beside it.
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", HeroTheme.GAP)
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(col)
	col.add_child(context_strip())

	col.add_child(HeroTheme.label(
		"Champions on the bench keep training while the game is closed.",
		HeroTheme.F_SMALL, HeroTheme.DIM))

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", HeroTheme.GAP)
	col.add_child(_rows)

	_refresh()


func _now() -> int:
	return int(Time.get_unix_time_from_system())


func _refresh() -> void:
	if _rows == null:
		return
	for c in _rows.get_children():
		c.queue_free()

	for i in range(Training.SLOTS_MAX):
		_rows.add_child(_slot_row(i))


func _slot_row(index: int) -> Control:
	var card := PanelContainer.new()
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
			HeroTheme.F_BODY, HeroTheme.TEXT))
		var put: Button = HeroTheme.button("Train %s"
			% ChampionName.of(hero), HeroTheme.Btn.GHOST, HeroTheme.TAP)
		put.pressed.connect(func():
			if roster.begin_training(index, hero, _now()):
				state_changed.emit()
				_refresh()
			else:
				notified.emit("%s is already training."
					% ChampionName.of(hero)))
		box.add_child(put)
		return card

	# Occupied.
	var elapsed: float = float(sl.elapsed_at(_now())[0])
	var pending: float = roster.pending_training(index, _now())
	var p: HeroProgress = roster.progress(sl.hero)

	box.add_child(HeroTheme.label("%s — level %d"
		% [ChampionName.of(sl.hero), p.level if p != null else 1],
		HeroTheme.F_BODY, HeroTheme.TEXT))

	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = Training.fill(elapsed)
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 18)
	box.add_child(bar)

	# SAYS WHEN IT STOPS. A bar that silently capped is the thing that makes
	# players stop trusting an idle system.
	box.add_child(HeroTheme.label(
		"%s  ·  %s xp waiting" % [Training.remaining_text(elapsed),
			_commas(int(pending))],
		HeroTheme.F_SMALL,
		HeroTheme.DIM if not Training.is_full(elapsed) else HeroTheme.TEXT))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", HeroTheme.GAP)

	var claim: Button = HeroTheme.button("Collect", HeroTheme.Btn.PRIMARY,
		HeroTheme.TAP)
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
