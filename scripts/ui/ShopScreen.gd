class_name ShopScreen
extends UiScreen
# ------------------------------------------------------------------------------
# The merchant: turn loot into gold, and gold into the slot the loot table has
# refused to fill.
#
# Shop.gd is deliberate about the spread — buying costs BUY_MARKUP times what
# selling the same piece returns — and a shop screen that hides that is the
# reason players feel cheated by a store they chose to use. Both numbers are on
# screen: the Sell tab shows what each piece is worth, and the Buy tab shows the
# price next to a rating computed the same way the stash rates gear.
#
# WHERE THE STOCK COMES FROM: Shop.offers() is deterministic in (seed, refresh),
# so a list that reshuffles on every open would invite savescumming and one that
# never moved would be dead. The refresh index here is a six-hour slice of the
# clock, which gives a shop that rolls over on its own and needs no new field in
# the save file — the save is exactly Roster.to_dict() (see Roster.gd) and this
# screen has no business adding to it.
# ------------------------------------------------------------------------------

enum Tab { BUY, SELL }

const REFRESH_SECONDS: int = 6 * 60 * 60

var _tab: int = Tab.BUY
var _offers: Array[Item] = []
var _buy_box: VBoxContainer
var _buy_scroll: ScrollContainer
var _sell_list: VirtualList
var _sell_ids: Array[int] = []
var _sell_tab_button: Button
var _bulk: Button
var _bulk_armed: bool = false
var _preview: HeroPreview
var _for_label: Label
var _purse: Label


func screen_title() -> String:
	return "Merchant"


func back_route() -> String:
	return UiRoute.SHEET


func build() -> void:
	# NO CONTEXT STRIP. It was a full-width band naming the champion directly
	# above a column that shows that champion, in their rarity colour, turning.
	# Saying it twice is what "cluttered" means.

	# WHO YOU ARE SHOPPING FOR, on the left. Stacked, the stock list got about
	# 190 px of a 940 px screen — one item and the top of the next — because
	# the tabs, the restock note and the bulk-sell button were all full-width
	# bands above and below it. The champion belongs here anyway: every price,
	# every item level and every "fills an empty slot" on the right is relative
	# to them.
	_preview = HeroPreview.new()
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", HeroTheme.GAP)
	card.add_child(_preview)
	_for_label = HeroTheme.label("", HeroTheme.F_HEAD)
	_for_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_for_label.clip_text = true
	_for_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	card.add_child(_for_label)
	_purse = HeroTheme.label("", HeroTheme.F_SMALL, HeroTheme.GOLD)
	_purse.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(_purse)
	var col := split_fixed(card)

	var group := ButtonGroup.new()
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 14)
	col.add_child(tabs)
	var buy_tab := HeroTheme.segment("Buy", group)
	buy_tab.button_pressed = true
	buy_tab.pressed.connect(func() -> void: _set_tab(Tab.BUY))
	tabs.add_child(buy_tab)
	_sell_tab_button = HeroTheme.segment("Sell", group)
	_sell_tab_button.pressed.connect(func() -> void: _set_tab(Tab.SELL))
	tabs.add_child(_sell_tab_button)

	_buy_scroll = ScrollContainer.new()
	TouchScroll.attach(_buy_scroll)
	_buy_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_buy_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_buy_scroll)
	_buy_box = VBoxContainer.new()
	_buy_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_buy_box.add_theme_constant_override("separation", 12)
	_buy_scroll.add_child(_buy_box)

	_sell_list = VirtualList.new()
	_sell_list.configure(_make_row, _bind_sell_row)
	_sell_list.visible = false
	col.add_child(_sell_list)

	_bulk = HeroTheme.button("", HeroTheme.Btn.SECONDARY)
	_bulk.pressed.connect(_on_bulk)
	card.add_child(_bulk)

	refresh()


func _set_tab(t: int) -> void:
	_tab = t
	_bulk_armed = false
	refresh()


# ------------------------------------------------------------------------------

## The merchant stocks at the level the chosen champion is actually fighting at,
## at the highest tier the account has unlocked — a level-3 champion should not
## be shown Eternal-grade prices it cannot use.
func _offer_level() -> int:
	var p: HeroProgress = roster.progress(hero)
	var level: int = p.level if p != null else 1
	return maxi(level, 1)


func _refresh_index() -> int:
	return int(Time.get_unix_time_from_system()) / REFRESH_SECONDS


func refresh() -> void:
	if roster == null or _buy_box == null:
		return
	_offers = Shop.offers(roster.crystal_seed, _refresh_index(),
		_offer_level(), roster.unlocked_tier)
	_rebuild_offers()

	if _preview != null:
		_preview.show_hero(hero)
		_for_label.text = ChampionName.of(hero)
		_for_label.add_theme_color_override("font_color", Champion.colour(hero))
		# HeroTheme.money(), the same grouping the currency bar uses — a bare
		# int reads "250250" and the player has to count digits.
		_purse.text = "%s gold · stocked for level %d" % [
			HeroTheme.money(roster.wallet.balance(Wallet.Kind.GOLD)),
			_offer_level()]

	_sell_ids = []
	for it in roster.stash.items:
		_sell_ids.append(it.id)
	_sell_tab_button.text = "Sell (%d)" % _sell_ids.size()
	_sell_list.set_count(_sell_ids.size())

	_buy_scroll.visible = _tab == Tab.BUY
	_sell_list.visible = _tab == Tab.SELL

	if _tab == Tab.BUY:
		_bulk.text = "Stock changes every few hours"
		_bulk.disabled = true
		return
	var total: int = 0
	var count: int = 0
	for it in roster.stash.items:
		if it.rarity < Item.Rarity.RARE:
			total += Shop.sell_value(it)
			count += 1
	_bulk.disabled = count <= 0
	if not _bulk_armed:
		_bulk.text = "Sell everything below Rare (%d piece%s)" % [count,
			"" if count == 1 else "s"]
	else:
		_bulk.text = "Tap again to sell %d piece%s for %s gold" % [count,
			"" if count == 1 else "s", HeroTheme.money(total)]


func _rebuild_offers() -> void:
	for child in _buy_box.get_children():
		_buy_box.remove_child(child)
		child.queue_free()

	var p: HeroProgress = roster.progress(hero)
	var cls: int = p.hero_class if p != null else HeroClass.Kind.FIGHTER
	var gold: int = roster.wallet.balance(Wallet.Kind.GOLD)

	for i in range(_offers.size()):
		var it: Item = _offers[i]
		var price: int = Shop.buy_price(it)
		var current: Item = roster.stash.equipped_in(hero, it.slot)
		var row := UiListRow.new()
		row.index = i
		row.configure(it.item_name, ItemText.summary(it),
			"%s gold" % HeroTheme.money(price), it.colour(), -1,
			ItemText.delta_text(it, current, cls),
			PackedStringArray(["Buy"]))
		row.title_colour(it.colour())
		row.value_colour(HeroTheme.GOLD if gold >= price else HeroTheme.FAINT)
		row.note_colour(ItemText.delta_colour(it, current, cls))
		row.set_action_disabled(0, gold < price)
		row.show_chevron(false)
		row.action_pressed.connect(_on_buy)
		_buy_box.add_child(row)

	_buy_box.add_child(HeroTheme.prose(
		"Stock is the same for everyone and rolls over through the day. "
		+ "Buying costs several times what selling the same piece returns — "
		+ "gold is a floor under bad luck, not a way around the loot table."))


func _on_buy(i: int, _which: int) -> void:
	if i < 0 or i >= _offers.size():
		return
	var it: Item = _offers[i]
	var reason: String = Shop.buy(roster, it)
	if reason != "":
		notified.emit(reason)
		return
	# The offer list is deterministic, so a bought piece is still listed. Mark
	# it by name in the message rather than removing it, which would make the
	# next refresh look like the shop had restocked.
	notified.emit("%s bought for %s gold — it is in the stash."
		% [it.item_name, HeroTheme.money(Shop.buy_price(it))])
	mutated()


# ------------------------------------------------------------------------------
# Selling
# ------------------------------------------------------------------------------

func _make_row() -> Control:
	var row := UiListRow.new()
	row.action_pressed.connect(_on_sell)
	return row


func _bind_sell_row(node: Control, i: int) -> void:
	var row := node as UiListRow
	row.index = i
	if i < 0 or i >= _sell_ids.size():
		return
	var idx: int = roster.stash.find_index(_sell_ids[i])
	if idx < 0:
		return
	var it: Item = roster.stash.items[idx]
	var p: HeroProgress = roster.progress(hero)
	var cls: int = p.hero_class if p != null else HeroClass.Kind.FIGHTER
	row.configure(it.item_name, ItemText.summary(it),
		"%s gold" % HeroTheme.money(Shop.sell_value(it)), it.colour(), -1,
		"Rated %s for a %s" % [ItemText.rating(it, cls),
			HeroClass.display_name(cls)],
		PackedStringArray(["Sell"]))
	row.title_colour(it.colour())
	row.value_colour(HeroTheme.GOLD)
	row.note_colour(HeroTheme.DIM)
	row.show_chevron(false)


func _on_sell(i: int, _which: int) -> void:
	if i < 0 or i >= _sell_ids.size():
		return
	var item_id: int = _sell_ids[i]
	var idx: int = roster.stash.find_index(item_id)
	if idx < 0:
		return
	var sold: String = roster.stash.items[idx].item_name
	var gold: int = Shop.sell(roster, item_id)
	notified.emit("Sold %s for %s gold." % [sold, HeroTheme.money(gold)])
	mutated()


# Two taps, deliberately. Selling the whole bottom of the stash is the one
# action here that cannot be undone, and a single mis-tap should not do it.
func _on_bulk() -> void:
	if not _bulk_armed:
		_bulk_armed = true
		refresh()
		return
	_bulk_armed = false
	var p: HeroProgress = roster.progress(hero)
	var gold: int = Shop.sell_all_below(roster,
		p.hero_class if p != null else HeroClass.Kind.FIGHTER,
		Item.Rarity.RARE)
	if gold <= 0:
		notified.emit("Nothing below Rare to sell.")
		refresh()
		return
	notified.emit("Sold for %s gold." % HeroTheme.money(gold))
	mutated()
