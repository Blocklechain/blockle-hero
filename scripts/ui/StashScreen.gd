class_name StashScreen
extends UiScreen
# ------------------------------------------------------------------------------
# The pooled stash, and the only place the player can see what their gear does.
#
# Item.gd states the constraint plainly: gear is NEVER drawn on the character,
# because the hero models have no sockets to hang a sword from. Every other
# action-RPG lets a player read their build off the silhouette; here the numbers
# are the entire presentation. So this screen leads with the difference the gear
# makes — damage and health WITH it against WITHOUT it, attribute by attribute —
# before it shows a single list.
#
# The stash itself is shared across the whole roster (Stash.gd) while what is
# EQUIPPED belongs to one champion, so the screen always names the champion it
# is equipping and the "stash" tab is explicitly labelled as shared.
# ------------------------------------------------------------------------------

enum Tab { EQUIPPED, POOL }

var _tab: int = Tab.EQUIPPED
var _summary: VBoxContainer
var _equipped_box: VBoxContainer
var _pool_list: VirtualList
var _pool_ids: Array[int] = []
var _pool_tab_button: Button
var _worn_scroll: ScrollContainer
var _auto: Button


func screen_title() -> String:
	return "Stash"


func back_route() -> String:
	return UiRoute.SHEET


func build() -> void:
	# NO CONTEXT STRIP — the gear panel's heading names the champion instead,
	# which is where the player is already looking to read the numbers it is
	# talking about.

	# THE GEAR GOES ON THE RIGHT, THE EXPLANATION ON THE LEFT.
	#
	# Stacked, the "what your gear is doing" panel asked for 700 px of a 1170 px
	# screen before anything else was measured, so opening the Stash showed the
	# player a paragraph about gear and not one item. It is reference material —
	# useful while you compare two swords, worthless as the thing you see
	# instead of the swords.
	var scroll := ScrollContainer.new()
	TouchScroll.attach(scroll)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_summary = VBoxContainer.new()
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary.add_theme_constant_override("separation", HeroTheme.GAP)
	scroll.add_child(_summary)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# The auto-equip button goes under the summary it acts on, not in a
	# full-width band across the bottom: as a footer it cost BOTH columns a row
	# of height, and what it does — "equip the best in every slot" — is exactly
	# what the numbers above it are showing.
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", HeroTheme.GAP)
	card.add_child(scroll)
	_auto = HeroTheme.button("", HeroTheme.Btn.PRIMARY)
	_auto.pressed.connect(_on_auto_equip)
	card.add_child(_auto)
	var col := split_fixed(card)

	var group := ButtonGroup.new()
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 14)
	col.add_child(tabs)
	var worn_tab := HeroTheme.segment("Worn", group)
	worn_tab.button_pressed = true
	worn_tab.pressed.connect(func() -> void: _set_tab(Tab.EQUIPPED))
	tabs.add_child(worn_tab)
	_pool_tab_button = HeroTheme.segment("Stash", group)
	_pool_tab_button.pressed.connect(func() -> void: _set_tab(Tab.POOL))
	tabs.add_child(_pool_tab_button)

	# Worn is seven rows at most, so it is a plain column; the pool is up to
	# Stash.CAPACITY and has to recycle.
	_worn_scroll = ScrollContainer.new()
	TouchScroll.attach(_worn_scroll)
	_worn_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_worn_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_worn_scroll)
	_equipped_box = VBoxContainer.new()
	_equipped_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_equipped_box.add_theme_constant_override("separation", 12)
	_worn_scroll.add_child(_equipped_box)

	_pool_list = VirtualList.new()
	_pool_list.configure(_make_row, _bind_pool_row)
	_pool_list.visible = false
	col.add_child(_pool_list)


	refresh()


func _set_tab(t: int) -> void:
	_tab = t
	refresh()


# ------------------------------------------------------------------------------
# The summary: the only answer to "what is my gear doing?"
# ------------------------------------------------------------------------------

func refresh() -> void:
	if roster == null or _summary == null:
		return
	var p: HeroProgress = roster.progress(hero)
	if p == null:
		return

	for child in _summary.get_children():
		_summary.remove_child(child)
		child.queue_free()

	var gear: Stats = roster.stash.gear_stats(hero)
	# The same champion with an empty stash: everything Roster.effective_*
	# does, minus what is worn. Unarmed damage is 2.0 and armour is 0 by
	# Stash.weapon_power()/armour(), so this is the honest "naked" baseline.
	var bare: Stats = p.base_stats().scaled(Champion.stat_multiplier(hero))
	var bare_damage: float = bare.damage_for(p.school()) + 2.0
	var bare_health: float = bare.max_health(p.level)
	var damage: float = roster.effective_damage(hero)
	var health: float = roster.effective_health(hero)

	# NAMES THE CHAMPION, because the strip that used to do that is gone and
	# these numbers are meaningless without knowing whose they are.
	var col := UiScreen.group(_summary,
		"%s — WHAT THE GEAR IS DOING" % ChampionName.of(hero).to_upper(),
		Champion.colour(hero))
	col.add_child(_delta_line("Damage", bare_damage, damage))
	col.add_child(_delta_line("Health", bare_health, health))
	col.add_child(HeroTheme.rule())
	var attr_row := HBoxContainer.new()
	attr_row.add_theme_constant_override("separation", 12)
	col.add_child(attr_row)
	for a in [Stats.Attr.STRENGTH, Stats.Attr.AGILITY, Stats.Attr.INTELLECT,
			Stats.Attr.CONSTITUTION]:
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_constant_override("separation", 2)
		var v: float = gear.get_attr(a)
		cell.add_child(HeroTheme.label(
			("+%.0f" % v) if v > 0.0 else "—", HeroTheme.F_NUM,
			HeroTheme.attr_colour(a) if v > 0.0 else HeroTheme.FAINT,
			HORIZONTAL_ALIGNMENT_CENTER))
		cell.add_child(HeroTheme.label(String(Stats.ATTR_SHORT[a]),
			HeroTheme.F_SMALL, HeroTheme.DIM, HORIZONTAL_ALIGNMENT_CENTER))
		attr_row.add_child(cell)
	# ONE LINE. This was three lines of rules that are true on every visit and
	# change with nothing — so after the first read it was a paragraph the
	# player scrolled past to reach the numbers it was explaining, and it was
	# clipping mid-sentence to do it. The part worth keeping is the part a
	# player gets wrong: the stash is shared, the gear is not.
	# Two short lines, not a wrapped paragraph. The first is a DISCLOSURE and
	# has to stay: a player who buys a legendary and sees their champion look
	# identical will assume the purchase failed. The second is the rule people
	# actually get wrong.
	for line in ["Gear is never drawn on your champion — numbers only",
			"Stash shared · what is worn is %s's" % ChampionName.of(hero)]:
		var note := HeroTheme.label(line, HeroTheme.F_SMALL, HeroTheme.FAINT)
		note.clip_text = true
		note.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col.add_child(note)

	_pool_tab_button.text = "Stash (%d)" % roster.stash.count()
	_rebuild_equipped(p)
	_pool_ids = _pool_order(p.hero_class)
	_pool_list.set_count(_pool_ids.size())
	_pool_list.visible = _tab == Tab.POOL
	_worn_scroll.visible = _tab == Tab.EQUIPPED

	var upgrades: int = roster.stash.all_upgrades(hero, p.hero_class).size()
	# Short enough for the column it now sits in. The long form clipped to
	# "Equip the best in every slot (6 bett" — losing the count, which is the
	# only part of it that changes.
	_auto.text = "Equip best · %d better" % upgrades \
		if upgrades > 0 else "Nothing beats what is worn"
	_auto.disabled = upgrades <= 0


func _delta_line(key: String, without: float, with_gear: float) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	var k := HeroTheme.label(key, HeroTheme.F_BODY, HeroTheme.DIM)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(k)
	h.add_child(HeroTheme.label("%.0f" % without, HeroTheme.F_BODY,
		HeroTheme.FAINT))
	h.add_child(UiGlyph.make(UiGlyph.Kind.CHEVRON, 34, HeroTheme.FAINT))
	h.add_child(HeroTheme.label("%.0f" % with_gear, HeroTheme.F_NUM,
		HeroTheme.TEXT))
	var delta: float = with_gear - without
	h.add_child(HeroTheme.label("(%s)" % HeroTheme.signed(delta),
		HeroTheme.F_BODY,
		HeroTheme.ACCENT if delta > 0.0 else HeroTheme.FAINT))
	return h


# ------------------------------------------------------------------------------
# Worn
# ------------------------------------------------------------------------------

func _rebuild_equipped(p: HeroProgress) -> void:
	for child in _equipped_box.get_children():
		_equipped_box.remove_child(child)
		child.queue_free()

	for slot in Item.Slot.values():
		var it: Item = roster.stash.equipped_in(hero, slot)
		var better: Item = roster.stash.best_upgrade(hero, p.hero_class, slot)
		var row := UiListRow.new()
		row.index = slot
		# NOT pinned to ROW_H here. configure() works out how tall the row has
		# to be for what is in it — a slot with a "better item waiting" note is
		# a line taller — and overwriting that afterwards is what made the note
		# draw over the slot below it.
		if it == null:
			row.configure(String(Item.SLOT_NAMES[slot]), "Empty", "",
				HeroTheme.LINE, -1,
				"" if better == null else "%s is waiting in the stash"
					% better.item_name)
			row.title_colour(HeroTheme.DIM)
		else:
			row.configure(it.item_name, ItemText.summary(it),
				ItemText.rating(it, p.hero_class), it.colour(), -1,
				"" if better == null else "%s is better by %.0f" % [
					better.item_name,
					better.score_for(p.hero_class) - it.score_for(p.hero_class)],
				PackedStringArray(["Take off"]))
			row.title_colour(it.colour())
			row.action_pressed.connect(_on_unequip)
		row.note_colour(HeroTheme.ACCENT)
		row.show_chevron(false)
		_equipped_box.add_child(row)


func _on_unequip(slot: int, _which: int) -> void:
	if not roster.stash.unequip(hero, slot):
		notified.emit("The stash is full — sell something first.")
		return
	notified.emit("Returned to the shared stash.")
	mutated()


# ------------------------------------------------------------------------------
# The pool
# ------------------------------------------------------------------------------

## Item ids, best first for the class that would wear them. Sorting by
## Item.score_for() is the same ranking the upgrade marker uses, so the top of
## the list and the "better available" note can never disagree.
func _pool_order(cls: int) -> Array[int]:
	var sorted: Array[Item] = []
	for it in roster.stash.items:
		sorted.append(it)
	sorted.sort_custom(func(a: Item, b: Item) -> bool:
		return a.score_for(cls) > b.score_for(cls))
	var out: Array[int] = []
	for it in sorted:
		out.append(it.id)
	return out


func _make_row() -> Control:
	var row := UiListRow.new()
	row.action_pressed.connect(_on_pool_action)
	return row


func _bind_pool_row(node: Control, i: int) -> void:
	var row := node as UiListRow
	row.index = i
	if i < 0 or i >= _pool_ids.size():
		return
	var idx: int = roster.stash.find_index(_pool_ids[i])
	if idx < 0:
		return
	var it: Item = roster.stash.items[idx]
	var p: HeroProgress = roster.progress(hero)
	var cls: int = p.hero_class if p != null else HeroClass.Kind.FIGHTER
	var current: Item = roster.stash.equipped_in(hero, it.slot)
	row.configure(it.item_name, ItemText.summary(it),
		ItemText.rating(it, cls), it.colour(), -1,
		ItemText.delta_text(it, current, cls),
		PackedStringArray(["Equip", "Sell %d" % Shop.sell_value(it)]))
	row.title_colour(it.colour())
	row.note_colour(ItemText.delta_colour(it, current, cls))
	row.value_colour(HeroTheme.DIM)
	row.show_chevron(false)


func _on_pool_action(i: int, which: int) -> void:
	if i < 0 or i >= _pool_ids.size():
		return
	var item_id: int = _pool_ids[i]
	var idx: int = roster.stash.find_index(item_id)
	if idx < 0:
		return
	var it: Item = roster.stash.items[idx]
	if which == 0:
		if roster.stash.equip(hero, item_id):
			notified.emit("%s equipped on %s." % [it.item_name,
				ChampionName.of(hero)])
			mutated()
		return
	var gold: int = Shop.sell(roster, item_id)
	notified.emit("Sold %s for %s gold." % [it.item_name,
		HeroTheme.money(gold)])
	mutated()


func _on_auto_equip() -> void:
	var p: HeroProgress = roster.progress(hero)
	if p == null:
		return
	var changed: int = roster.stash.auto_equip(hero, p.hero_class)
	if changed <= 0:
		notified.emit("Nothing in the stash is an upgrade.")
		return
	notified.emit("Equipped %d better piece%s on %s."
		% [changed, "" if changed == 1 else "s", ChampionName.of(hero)])
	mutated()
