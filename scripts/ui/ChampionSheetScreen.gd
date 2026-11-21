class_name ChampionSheetScreen
extends UiScreen
# ------------------------------------------------------------------------------
# One champion: what they are, what they are worth, and where their skill
# points go.
#
# THE POINT THIS SCREEN HAS TO MAKE is that skill points are not an account
# resource. HeroProgress keeps them per champion deliberately — it is the whole
# reason a 139-hero roster is a reason to replay rather than 139 identical
# grinds — and a player who spends six levels of points expecting them back on
# another hero has been lied to by the UI. So the spend panel is titled with the
# champion's own name, says it in words, and the respec button says that it only
# refunds this champion's points.
#
# Every number here comes from Roster.effective_stats()/effective_damage()/
# effective_health() — the same functions combat reads. Stats.gd's header is
# explicit that a sheet which estimates its own numbers starts lying, so this
# screen computes nothing of its own except the difference between two calls.
# ------------------------------------------------------------------------------

const ATTR_ORDER: Array = [Stats.Attr.STRENGTH, Stats.Attr.AGILITY,
	Stats.Attr.INTELLECT, Stats.Attr.CONSTITUTION]

var _xp_bar: ProgressBar
var _xp_text: Label
var _points_title: Label
var _points_note: Label
var _attr_value: Dictionary = {}       # attr -> Label (total)
var _attr_break: Dictionary = {}       # attr -> Label (where it came from)
var _attr_plus: Dictionary = {}        # attr -> Button
var _derived: Dictionary = {}          # key -> Label
var _respec: Button
## A respec is irreversible and now costs gold, so the button asks twice: the
## first press turns it into the warning, the second spends. Same arm-then-
## confirm the merchant's bulk sell uses, and it needs no modal on a screen
## that has no room for one.
var _respec_armed: bool = false
var _gear_line: Label
var _preview: HeroPreview


func screen_title() -> String:
	return ChampionName.of(hero)


func back_route() -> String:
	return UiRoute.CHAMPIONS


func build() -> void:
	# A screen entered fresh is never half-way through confirming something.
	# Leaving and coming back has to cancel the arm, or a stale confirm from
	# five minutes ago fires on the first tap.
	_respec_armed = false
	# THE LOADOUT VIEW: the champion on the left, their numbers on the right.
	# Gear is deliberately invisible on the champion in play — it moves stats,
	# not the silhouette — so this screen carries that weight, and seeing the
	# actual body the player is about to walk out with anchors the numbers to
	# something. The preview is a live HeroRig, not a portrait; see
	# HeroPreview.gd for why 139 pre-rendered portraits were not the answer.
	_preview = HeroPreview.new()
	_preview.show_hero(hero)
	var col := split_column(_preview)

	var p: HeroProgress = roster.progress(hero)
	if p == null:
		col.add_child(HeroTheme.prose(
			"This champion is not on your roster.", HeroTheme.F_BODY))
		return

	# --- identity -------------------------------------------------------------
	var id_col := UiScreen.group(col, "", Champion.colour(hero))
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", HeroTheme.GAP)
	id_col.add_child(head)
	head.add_child(UiGlyph.make(UiGlyph.for_class(p.hero_class), 110,
		Champion.colour(hero)))
	var id_stack := VBoxContainer.new()
	id_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_stack.add_theme_constant_override("separation", 8)
	head.add_child(id_stack)
	id_stack.add_child(HeroTheme.label(ChampionName.of(hero), HeroTheme.F_SUPER))
	var tags := HBoxContainer.new()
	tags.add_theme_constant_override("separation", 12)
	id_stack.add_child(tags)
	tags.add_child(HeroTheme.chip(Champion.rarity_name(hero),
		Champion.colour(hero)))
	tags.add_child(HeroTheme.chip(p.class_name_str(), HeroTheme.ACCENT))
	tags.add_child(HeroTheme.chip("Level %d" % p.level, HeroTheme.TEXT))

	_xp_bar = HeroTheme.bar(p.xp_fraction())
	id_col.add_child(_xp_bar)
	_xp_text = HeroTheme.label("", HeroTheme.F_SMALL, HeroTheme.DIM)
	id_col.add_child(_xp_text)
	id_col.add_child(HeroTheme.prose(
		"Rarity multiplies this champion's own attributes by x%.2f. It never "
		% Champion.stat_multiplier(hero)
		+ "touches gear, so a common champion in good gear still outfights a "
		+ "legendary in none."))

	# --- skill points ---------------------------------------------------------
	var sp_col := UiScreen.group(col, "", HeroTheme.ACCENT)
	_points_title = HeroTheme.label("", HeroTheme.F_HEAD, HeroTheme.ACCENT)
	sp_col.add_child(_points_title)
	_points_note = HeroTheme.prose("")
	sp_col.add_child(_points_note)
	sp_col.add_child(HeroTheme.rule())

	for a in ATTR_ORDER:
		sp_col.add_child(_attr_row(a))

	_respec = HeroTheme.button("", HeroTheme.Btn.GHOST, HeroTheme.TAP_SMALL)
	_respec.pressed.connect(_on_respec)
	sp_col.add_child(_respec)

	# --- what the numbers come out as ----------------------------------------
	var d_col := UiScreen.group(col, "IN A FIGHT")
	for key in ["Damage", "Health", "Mana", "Critical hit", "Dodge",
			"Attack speed"]:
		var line := UiScreen.stat_line(key, "", HeroTheme.TEXT)
		_derived[key] = line.get_child(1)
		d_col.add_child(line)
	_gear_line = HeroTheme.prose("")
	d_col.add_child(HeroTheme.rule())
	d_col.add_child(_gear_line)

	# --- where to go next -----------------------------------------------------
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 14)
	footer.add_child(nav)
	# STASH AND MERCHANT ARE NOT HERE. They were, as two secondary buttons —
	# directly above a permanent tab bar whose second and third tabs are Stash
	# and Merchant and go to the same two places. Offering the same destination
	# twice in two visually different controls teaches the player that the two
	# rows mean different things, and costs a row of height to do it.
	#
	# What is left is the one action the tab bar CANNOT do: this screen knows
	# which champion you are looking at, so it is the only place that can send
	# that champion into the campaign.
	var go := HeroTheme.button("Take %s into the campaign"
		% ChampionName.of(hero), HeroTheme.Btn.PRIMARY)
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	go.pressed.connect(func() -> void:
		navigate.emit(UiRoute.CAMPAIGN, hero))
	nav.add_child(go)

	refresh()


func _attr_row(attr: int) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", HeroTheme.GAP)

	var stack := VBoxContainer.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.add_theme_constant_override("separation", 4)
	h.add_child(stack)
	stack.add_child(HeroTheme.label(String(Stats.ATTR_NAMES[attr]),
		HeroTheme.F_BODY, HeroTheme.attr_colour(attr)))
	var breakdown := HeroTheme.label("", HeroTheme.F_SMALL, HeroTheme.DIM)
	stack.add_child(breakdown)
	_attr_break[attr] = breakdown

	var total := HeroTheme.label("", HeroTheme.F_NUM, HeroTheme.TEXT,
		HORIZONTAL_ALIGNMENT_RIGHT)
	total.custom_minimum_size = Vector2(170, 0)
	total.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(total)
	_attr_value[attr] = total

	var plus := HeroTheme.button("", HeroTheme.Btn.PRIMARY, HeroTheme.TAP)
	plus.custom_minimum_size = Vector2(HeroTheme.TAP, HeroTheme.TAP)
	var glyph := UiGlyph.make(UiGlyph.Kind.PLUS, 48, Color("eafff2"))
	glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
	plus.add_child(glyph)
	plus.pressed.connect(_on_spend.bind(attr))
	h.add_child(plus)
	_attr_plus[attr] = plus
	return h


func refresh() -> void:
	var p: HeroProgress = roster.progress(hero)
	if p == null or _points_title == null:
		return

	_xp_bar.value = p.xp_fraction()
	if p.level >= HeroProgress.MAX_LEVEL:
		_xp_text.text = "Level %d — the highest there is." % p.level
	else:
		_xp_text.text = "%.0f of %.0f experience toward level %d" % [
			p.xp, p.xp_to_next(), p.level + 1]

	var unspent: int = p.unspent_points()
	_points_title.text = "%d skill point%s to spend" % [unspent,
		"" if unspent == 1 else "s"]
	_points_note.text = ("These points are %s's own. They are earned by " \
		+ "levelling THIS champion and they cannot be moved to another one — " \
		+ "every champion levels alone. %d of %d earned so far.") % [
			ChampionName.of(hero), p.spent_points(), p.total_skill_points()]

	var innate: Stats = p.innate_stats()
	var allocated: Stats = p.allocated_stats()
	var gear: Stats = roster.stash.gear_stats(hero)
	var effective: Stats = roster.effective_stats(hero)

	for a in ATTR_ORDER:
		(_attr_value[a] as Label).text = "%.0f" % effective.get_attr(a)
		(_attr_break[a] as Label).text = \
			"class and level %.0f · your points %.0f · gear %.0f" % [
				innate.get_attr(a), allocated.get_attr(a), gear.get_attr(a)]
		(_attr_plus[a] as Button).disabled = unspent <= 0

	var spent: int = p.spent_points()
	var cost: int = roster.respec_cost(hero)
	var purse: int = roster.wallet.balance(Wallet.Kind.GOLD)
	if spent <= 0:
		_respec_armed = false
		_respec.text = "No points spent to refund"
	elif _respec_armed:
		# The warning IS the button. It names the price, the number of points
		# and the fact that it cannot be taken back.
		_respec.text = "Confirm: spend %s gold to undo all %d point%s — " \
			% [HeroTheme.money(cost), spent, "" if spent == 1 else "s"] \
			+ "this cannot be undone"
	else:
		_respec.text = "Refund %s's %d spent point%s · %s gold" % [
			ChampionName.of(hero), spent, "" if spent == 1 else "s",
			HeroTheme.money(cost)]
	_respec.disabled = spent <= 0
	# Shown in the warning colour once armed, and in the gold colour when the
	# player cannot pay — a button that looks ready and then refuses is worse
	# than one that says so first.
	_respec.add_theme_color_override("font_color",
		HeroTheme.CRYSTAL if _respec_armed else (
			HeroTheme.TEXT if purse >= cost else HeroTheme.FAINT))

	(_derived["Damage"] as Label).text = "%.0f" % roster.effective_damage(hero)
	(_derived["Health"] as Label).text = "%.0f" % roster.effective_health(hero)
	(_derived["Mana"] as Label).text = "%.0f" % effective.max_mana()
	(_derived["Critical hit"] as Label).text = "%.0f%%" \
		% (effective.crit_chance() * 100.0)
	(_derived["Dodge"] as Label).text = "%.0f%%" \
		% (effective.dodge_chance() * 100.0)
	(_derived["Attack speed"] as Label).text = "x%.2f" % effective.haste()

	var worn: int = roster.stash.gear_of(hero).keys().size()
	_gear_line.text = ("%d of %d slots filled. Gear is never drawn on a " \
		+ "champion — the stash screen shows exactly what it is adding.") % [
			worn, Item.Slot.size()]


func _on_spend(attr: int) -> void:
	var p: HeroProgress = roster.progress(hero)
	if p == null:
		return
	if not p.spend(attr, 1):
		notified.emit("No skill points left to spend.")
		return
	mutated()


func _on_respec() -> void:
	var p: HeroProgress = roster.progress(hero)
	if p == null or p.spent_points() <= 0:
		return
	if not _respec_armed:
		# FIRST PRESS IS THE WARNING, never the act. Undoing a build the
		# player spent twenty levels assembling, by mis-tapping a button next
		# to the four they use constantly, is the kind of loss that ends a
		# save.
		_respec_armed = true
		var cost: int = roster.respec_cost(hero)
		if roster.wallet.balance(Wallet.Kind.GOLD) < cost:
			notified.emit("That costs %s gold. You have %s."
				% [HeroTheme.money(cost),
					HeroTheme.money(roster.wallet.balance(Wallet.Kind.GOLD))])
		else:
			notified.emit("Press again to undo %s's build for %s gold."
				% [ChampionName.of(hero), HeroTheme.money(cost)])
		refresh()
		return

	_respec_armed = false
	var n: int = p.spent_points()
	var reason: String = roster.respec(hero)
	if reason != "":
		notified.emit(reason)
		refresh()
		return
	notified.emit("%d point%s returned to %s."
		% [n, "" if n == 1 else "s", ChampionName.of(hero)])
	mutated()
