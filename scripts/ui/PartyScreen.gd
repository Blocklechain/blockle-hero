class_name PartyScreen
extends UiScreen

# Preloaded by path — a new class_name is absent from Godot's global class
# cache until the editor reimports, and the headless harnesses load this
# script directly.
const Party := preload("res://scripts/game/Party.gd")
# ------------------------------------------------------------------------------
# WHO ELSE IS COMING.
#
# Three slots, each one of the player's own champions. The screen is a picker
# and nothing more, but it has to be honest about two things that a party
# screen in most games is not:
#
#   * PARTNERS FIGHT AT A FRACTION of their strength. If that is not said
#     here, a player fields their level-40 and reasonably concludes the game
#     is lying when it hits for half what their sheet says.
#
#   * THEY CAN GO DOWN. Said here, because a partner lying on the ground
#     halfway through a wave with no warning that it could happen reads as a
#     bug.
#
# The champion currently being driven is excluded from the list rather than
# shown greyed out: it is not a choice the player can make, and a row that
# exists only to refuse is worse than no row.
# ------------------------------------------------------------------------------

var _rows: VBoxContainer = null
## Which slot the picker below is filling, or -1 when it is closed.
var _picking: int = -1


func screen_title() -> String:
	return "Party"


func build() -> void:
	var col := scroll_column()
	col.add_child(context_strip())

	# The percentage is substituted into its OWN string rather than into a
	# concatenation: `%` binds tighter than `+`, so a `%d` in an earlier
	# fragment of a `+` chain formats the LAST fragment instead and the whole
	# expression fails to parse.
	var share: String = "%d%%" % int(Party.CONTRIBUTION * 100.0)
	col.add_child(HeroTheme.prose(
		"Up to three of your champions fight alongside you. They follow, they "
		+ "pick their own targets, and they level — at " + share
		+ " of their own strength, so they help rather than play for you. "
		+ "They can be knocked down, and they get back up between waves."))

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", HeroTheme.GAP)
	col.add_child(_rows)

	refresh()


func refresh() -> void:
	if _rows == null or roster == null:
		return
	for c in _rows.get_children():
		c.queue_free()
	for i in range(Party.SLOTS_MAX):
		_rows.add_child(_slot_row(i))
		if _picking == i:
			_rows.add_child(_picker(i))


func _slot_row(index: int) -> Control:
	var card := HeroTheme.panel()
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", HeroTheme.PAD)
	pad.add_theme_constant_override("margin_right", HeroTheme.PAD)
	pad.add_theme_constant_override("margin_top", 24)
	pad.add_theme_constant_override("margin_bottom", 24)
	card.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pad.add_child(box)

	if not roster.party_slot_is_unlocked(index):
		var cost: int = Party.cost_of(index)
		box.add_child(HeroTheme.label("Slot %d — locked" % (index + 1),
			HeroTheme.F_BODY, HeroTheme.TEXT))
		box.add_child(HeroTheme.label("%s gold to open" % _commas(cost),
			HeroTheme.F_SMALL, HeroTheme.DIM))
		# Only the NEXT slot is buyable: offering slot 3 before slot 2 just
		# means a confusing refusal.
		if index == roster.party_unlocked:
			var buy: Button = HeroTheme.button("Open slot",
				HeroTheme.Btn.PRIMARY, HeroTheme.TAP_SMALL)
			buy.pressed.connect(func() -> void:
				if roster.unlock_party_slot():
					state_changed.emit()
					refresh()
				else:
					notified.emit("That costs %s gold." % _commas(cost)))
			box.add_child(buy)
		return card

	var who: String = roster.party_slot(index)
	# A slot naming a champion who is no longer owned, or the one being
	# driven, is treated as empty — the same rule Roster.companions() applies
	# when the party actually takes the field, so the screen cannot promise a
	# partner the run will not field.
	var usable: bool = not who.is_empty() and roster.owns(who) and who != hero
	if not usable:
		box.add_child(HeroTheme.label("Slot %d — empty" % (index + 1),
			HeroTheme.F_BODY, HeroTheme.DIM))
		if not who.is_empty() and who == hero:
			box.add_child(HeroTheme.label(
				"%s is the champion you are playing." % ChampionName.of(who),
				HeroTheme.F_SMALL, HeroTheme.DIM))
		var pick: Button = HeroTheme.button(
			"Close" if _picking == index else "Choose a champion",
			HeroTheme.Btn.GHOST, HeroTheme.TAP_SMALL)
		pick.pressed.connect(func() -> void:
			_picking = -1 if _picking == index else index
			refresh())
		box.add_child(pick)
		return card

	var p: HeroProgress = roster.progress(who)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", HeroTheme.GAP)
	head.add_child(UiGlyph.make(UiGlyph.for_class(
		p.hero_class if p != null else HeroClass.Kind.FIGHTER), 54,
		Champion.colour(who)))
	var name_label: Label = HeroTheme.label("%s  ·  level %d"
		% [ChampionName.of(who), p.level if p != null else 1],
		HeroTheme.F_BODY, HeroTheme.TEXT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_label)
	box.add_child(head)

	# WHAT THEY WILL ACTUALLY HIT FOR. The sheet figure times the
	# contribution, because the sheet figure is what the player will compare
	# it against and the difference is otherwise unexplained.
	box.add_child(HeroTheme.label(
		"fights at %.0f damage  ·  %.0f health"
		% [roster.effective_damage(who) * Party.CONTRIBUTION,
			roster.effective_health(who) * Party.CONTRIBUTION],
		HeroTheme.F_SMALL, HeroTheme.DIM))

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	var swap: Button = HeroTheme.button("Replace", HeroTheme.Btn.GHOST,
		HeroTheme.TAP_SMALL)
	swap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	swap.pressed.connect(func() -> void:
		_picking = -1 if _picking == index else index
		refresh())
	actions.add_child(swap)
	var out: Button = HeroTheme.button("Remove", HeroTheme.Btn.GHOST,
		HeroTheme.TAP_SMALL)
	out.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	out.pressed.connect(func() -> void:
		roster.clear_companion(index)
		_picking = -1
		state_changed.emit()
		refresh())
	actions.add_child(out)
	box.add_child(actions)
	return card


## The list of champions that may go into [slot].
##
## EXCLUDES the champion being driven and anyone already in another slot, so
## every row in it is a choice that will be accepted. A picker that lists
## options it then refuses is the thing this screen must not be.
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

	var taken: Dictionary = {}
	for i in range(Party.SLOTS_MAX):
		if i != slot:
			var other: String = roster.party_slot(i)
			if not other.is_empty():
				taken[other] = true

	var offered: int = 0
	for who in roster.owned_names():
		if who == hero or taken.has(who):
			continue
		offered += 1
		var p: HeroProgress = roster.progress(who)
		var b: Button = HeroTheme.button("%s  ·  level %d"
			% [ChampionName.of(who), p.level if p != null else 1],
			HeroTheme.Btn.SECONDARY, HeroTheme.TAP_SMALL)
		b.pressed.connect(func() -> void:
			if roster.set_companion(slot, who, hero):
				_picking = -1
				state_changed.emit()
				refresh()
			else:
				notified.emit("%s cannot join." % ChampionName.of(who)))
		box.add_child(b)

	if offered == 0:
		box.add_child(HeroTheme.label(
			"No other champions yet — open a spawn crystal or unlock one "
			+ "with gems.", HeroTheme.F_SMALL, HeroTheme.DIM))
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
