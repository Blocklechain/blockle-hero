class_name QuestScreen
extends UiScreen

# Preloaded by path — a new class_name is absent from Godot's global class
# cache until the editor reimports, and the headless harnesses load this
# script directly.
const Quest := preload("res://scripts/game/Quest.gd")
const GameMode := preload("res://scripts/game/GameMode.gd")
# ------------------------------------------------------------------------------
# THE BOARD.
#
# Three objectives, and the one job this screen has is to make each one
# ACTIONABLE. A quest the player has to go and work out how to do is a quest
# they do not do, so every row that names a map carries the button that takes
# them to it — the board is a launcher, not a to-do list.
#
# WHAT IT MUST NOT DO, because every one of these is a way to make an honest
# system read as a dishonest one:
#
#   * Show a quest without saying where. "Bring back Epic gear" with no map is
#     an instruction to grind blind.
#   * Hide the progress. 3/14 is encouraging; a bar with no number is not.
#   * Claim silently. The gold and crystals are stated on the row BEFORE the
#     press, and the message after it says what landed.
# ------------------------------------------------------------------------------

var _rows: VBoxContainer = null


func screen_title() -> String:
	return "Contracts"


func build() -> void:
	var col := scroll_column()
	col.add_child(context_strip())

	col.add_child(HeroTheme.prose(
		"Standing contracts. They scale to your best champion, and a finished "
		+ "one is replaced by another."))

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", HeroTheme.GAP)
	col.add_child(_rows)

	refresh()


func refresh() -> void:
	if _rows == null or roster == null:
		return
	for c in _rows.get_children():
		c.queue_free()
	var board: Array = roster.quest_board()
	for i in range(board.size()):
		var q := board[i] as Quest
		if q == null:
			continue
		_rows.add_child(_row(i, q))


func _row(index: int, q: Quest) -> Control:
	var done: bool = q.is_complete()
	var card := HeroTheme.panel(
		HeroTheme.PANEL_HI if done else HeroTheme.PANEL,
		HeroTheme.ACCENT if done else HeroTheme.LINE)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", HeroTheme.PAD)
	pad.add_theme_constant_override("margin_right", HeroTheme.PAD)
	pad.add_theme_constant_override("margin_top", 24)
	pad.add_theme_constant_override("margin_bottom", 24)
	card.add_child(pad)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pad.add_child(box)

	box.add_child(HeroTheme.label(q.title(), HeroTheme.F_BODY,
		HeroTheme.ACCENT if done else HeroTheme.TEXT))
	# WHERE, ALWAYS. The detail line is what turns a title into something a
	# player can act on without guessing.
	box.add_child(HeroTheme.label(q.detail(), HeroTheme.F_SMALL,
		HeroTheme.DIM))

	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", HeroTheme.GAP)
	stats.add_child(HeroTheme.label(q.progress_text(), HeroTheme.F_SMALL,
		HeroTheme.ACCENT if done else HeroTheme.TEXT))
	var pay: String = "%s gold" % _commas(q.reward_gold)
	if q.reward_crystals > 0:
		pay += "  ·  %d spawn crystal%s" % [q.reward_crystals,
			"" if q.reward_crystals == 1 else "s"]
	var pay_label: Label = HeroTheme.label(pay, HeroTheme.F_SMALL,
		HeroTheme.GOLD)
	pay_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stats.add_child(pay_label)
	box.add_child(stats)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	box.add_child(actions)

	if done:
		var claim: Button = HeroTheme.button("Collect",
			HeroTheme.Btn.PRIMARY, HeroTheme.TAP_SMALL)
		claim.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		claim.pressed.connect(func() -> void:
			var paid: Dictionary = roster.claim_quest(index)
			if paid.is_empty():
				notified.emit("Nothing to collect there.")
				refresh()
				return
			var line: String = "%s gold" % _commas(int(paid.get("gold", 0)))
			if int(paid.get("crystals", 0)) > 0:
				line += " and %d spawn crystal(s)" % int(paid["crystals"])
			notified.emit("Paid %s." % line)
			state_changed.emit()
			refresh())
		actions.add_child(claim)
		return card

	# ---- unfinished: the button that takes them to it ------------------------
	var go: Button = _go_button(q)
	if go != null:
		go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		actions.add_child(go)

	# A BOARD MUST NOT BE ABLE TO DEADLOCK. Free, because a Descent objective
	# offered to someone who only plays the campaign is our bad draw, not
	# theirs.
	var swap: Button = HeroTheme.button("Swap", HeroTheme.Btn.GHOST,
		HeroTheme.TAP_SMALL)
	swap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	swap.pressed.connect(func() -> void:
		if roster.reroll_quest(index):
			state_changed.emit()
			refresh())
	actions.add_child(swap)
	return card


## The button that starts the run this quest wants, or null when the quest
## does not name one place to go.
func _go_button(q: Quest) -> Button:
	match q.kind:
		Quest.Kind.CLEAR_MAP, Quest.Kind.FIND_RARITY, Quest.Kind.FIND_SLOT:
			if q.region < 0:
				return null
			var b: Button = HeroTheme.button("Go", HeroTheme.Btn.SECONDARY,
				HeroTheme.TAP_SMALL)
			# The quest's OWN tier, not whatever the campaign screen was last
			# set to: a Rare from Normal does not finish a Merciless contract,
			# and sending the player in on the wrong difficulty to find that
			# out afterwards is the cruellest version of this screen.
			b.pressed.connect(func() -> void:
				navigate.emit(UiRoute.LAUNCH, {"hero": hero,
					"region": q.region, "tier": q.tier,
					"mode": GameMode.Id.CAMPAIGN}))
			return b
		Quest.Kind.REACH_DEPTH:
			var d: Button = HeroTheme.button("Descend",
				HeroTheme.Btn.SECONDARY, HeroTheme.TAP_SMALL)
			d.pressed.connect(func() -> void:
				navigate.emit(UiRoute.LAUNCH, {"hero": hero, "region": 0,
					"tier": q.tier, "mode": GameMode.Id.DESCENT}))
			return d
	# SLAY_ELITES is "anywhere", so there is nowhere to send them.
	return null


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
