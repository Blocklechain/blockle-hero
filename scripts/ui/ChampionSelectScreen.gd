class_name ChampionSelectScreen
extends UiScreen
# ------------------------------------------------------------------------------
# The roster: who you own, who you could own, and who you are about to play.
#
# TWO SIZES AT ONCE is the whole problem this screen solves. A new account owns
# exactly three champions (Champion.starters) and a long-lived one can own all
# 139 — and the locked list is always the rest of the catalogue. So the rows are
# recycled through VirtualList and the list is rebuilt from
# Roster.owned_names()/all_known_names() on every refresh rather than kept in
# sync by hand.
#
# Gems and crystals are both SPENT here, which is why both balances are on
# screen above and the crystal odds are one tap away below: a randomised
# champion may not be offered without them (see IAPCatalog.gd and
# CrystalOdds.disclosure_text()).
# ------------------------------------------------------------------------------

enum Mode { OWNED, ALL }

var _mode: int = Mode.OWNED
var _names: PackedStringArray = PackedStringArray()
var _list: VirtualList
var _count_label: Label
var _crystal_button: Button
var _odds_panel: PanelContainer
var _preview: HeroPreview
var _caption: Label
var _caption_sub: Label
var _highlight: String = ""


func screen_title() -> String:
	return "Champions"


func show_back() -> bool:
	return true


func back_route() -> String:
	return UiRoute.TITLE


func build() -> void:
	# LANDSCAPE: the champion on the left, the roster on the right.
	#
	# Stacked, the list got whatever height was left after the mode tabs, the
	# count, the crystal row and the tab bar — about two of 139 entries. It also
	# gave the player no reason to scroll: a column of names tells you nothing
	# about a champion you have not unlocked. Showing the highlighted one, alive
	# and turning, is what makes browsing a roster worth doing.
	_preview = HeroPreview.new()
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", HeroTheme.GAP)
	card.add_child(_preview)
	_caption = HeroTheme.label("", HeroTheme.F_HEAD)
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.clip_text = true
	_caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	card.add_child(_caption)
	_caption_sub = HeroTheme.label("", HeroTheme.F_SMALL, HeroTheme.DIM)
	_caption_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(_caption_sub)
	_count_label = HeroTheme.label("", HeroTheme.F_SMALL, HeroTheme.DIM)
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(_count_label)
	var col := split_fixed(card)

	var group := ButtonGroup.new()
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 14)
	col.add_child(tabs)

	var owned_tab := HeroTheme.segment("Yours", group)
	owned_tab.button_pressed = true
	owned_tab.pressed.connect(func() -> void: _set_mode(Mode.OWNED))
	tabs.add_child(owned_tab)

	var all_tab := HeroTheme.segment("Every champion", group)
	all_tab.pressed.connect(func() -> void: _set_mode(Mode.ALL))
	tabs.add_child(all_tab)

	_list = VirtualList.new()
	_list.configure(_make_row, _bind_row)
	col.add_child(_list)

	# --- crystals, with the odds the App Store requires before they are used --
	_odds_panel = HeroTheme.panel(HeroTheme.BG_LIFT, HeroTheme.CRYSTAL)
	_odds_panel.visible = false
	var odds_col := VBoxContainer.new()
	odds_col.add_theme_constant_override("separation", 10)
	_odds_panel.add_child(odds_col)
	odds_col.add_child(HeroTheme.prose(CrystalOdds.disclosure_text(),
		HeroTheme.F_SMALL, HeroTheme.TEXT))
	footer.add_child(_odds_panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	card.add_child(row)

	# The crystal lives UNDER THE CHAMPION, not in a full-width band across the
	# bottom. As a footer it cost the whole screen 132px of height and the list
	# was left showing one and a half champions out of 139 — and it belongs
	# beside the roster anyway, since opening one is how the roster grows.
	_crystal_button = HeroTheme.button("", HeroTheme.Btn.SECONDARY)
	_crystal_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_crystal_button.pressed.connect(_open_crystal)
	row.add_child(_crystal_button)

	var odds_button := HeroTheme.button("Odds", HeroTheme.Btn.GHOST)
	odds_button.custom_minimum_size = Vector2(240, HeroTheme.TAP)
	odds_button.pressed.connect(func() -> void:
		_odds_panel.visible = not _odds_panel.visible)
	row.add_child(odds_button)

	refresh()


func _set_mode(m: int) -> void:
	_mode = m
	refresh()


func refresh() -> void:
	if roster == null:
		return
	_names = _sorted_names()
	var owned: int = roster.owned.size()
	var known: int = roster.all_known_names().size()
	# One line, not a paragraph. The rule it used to explain — that levels and
	# skill points belong to each champion while the stash is shared — is on the
	# champion sheet, where it matters at the moment you are spending a point.
	_count_label.text = "%d of %d owned" % [owned, known]
	if _list != null:
		_list.set_count(_names.size())
	# The preview shows whichever champion the list is headed by, so the left
	# column is never an empty box and browsing has something to browse.
	_show(_highlight if _highlight != "" else (
		_names[0] if not _names.is_empty() else ""))
	var crystals: int = roster.wallet.balance(Wallet.Kind.CRYSTALS)
	# Short enough to survive the narrow column. The old label clipped its own
	# count off the end, which is the one part of it the player needs.
	_crystal_button.text = "Spawn Crystal · %d" % crystals
	_crystal_button.disabled = crystals <= 0


# Display order, not id order: the ids are model filenames ("g044") and the
# player is reading names.
func _sorted_names() -> PackedStringArray:
	var raw: PackedStringArray = roster.owned_names() if _mode == Mode.OWNED \
		else roster.all_known_names()
	var list: Array[String] = []
	for n in raw:
		list.append(n)
	list.sort_custom(func(a: String, b: String) -> bool:
		return ChampionName.of(a).naturalnocasecmp_to(ChampionName.of(b)) < 0)
	var out := PackedStringArray()
	for n in list:
		out.append(n)
	return out


func _make_row() -> Control:
	var row := UiListRow.new()
	row.row_pressed.connect(_on_row)
	row.action_pressed.connect(_on_action)
	return row


func _bind_row(node: Control, i: int) -> void:
	var row := node as UiListRow
	row.index = i
	if i < 0 or i >= _names.size():
		return
	var id: String = _names[i]
	var rarity_colour: Color = Champion.colour(id)
	var p: HeroProgress = roster.progress(id)

	if p != null:
		var pts: int = p.unspent_points()
		row.configure(ChampionName.of(id),
			"%s · %s" % [Champion.rarity_name(id), p.class_name_str()],
			"L %d" % p.level, rarity_colour, UiGlyph.for_class(p.hero_class),
			"%d skill point%s to spend" % [pts, "" if pts == 1 else "s"] if pts > 0 else "")
		row.title_colour(HeroTheme.ACCENT if id == _highlight else HeroTheme.TEXT)
		row.value_colour(HeroTheme.TEXT)
		row.note_colour(HeroTheme.ACCENT)
		row.show_chevron(id == _highlight)
		return

	# Locked: the gem price is the action, and it says why it is refused rather
	# than going grey with no explanation.
	var cost: int = Champion.gem_cost(id)
	var gems: int = roster.wallet.balance(Wallet.Kind.GEMS)
	var cls: int = HeroClass.for_hero(id)
	row.configure(ChampionName.of(id),
		"%s · %s · locked" % [Champion.rarity_name(id),
			HeroClass.display_name(cls)],
		"", rarity_colour, UiGlyph.for_class(cls),
		"%d gems — you have %d" % [cost, gems],
		PackedStringArray(["Unlock"]))
	row.title_colour(HeroTheme.ACCENT if id == _highlight else HeroTheme.DIM)
	row.note_colour(HeroTheme.GEM if gems >= cost else HeroTheme.FAINT)
	row.set_action_disabled(0, gems < cost)
	row.show_chevron(false)


func _on_row(i: int) -> void:
	if i < 0 or i >= _names.size():
		return
	var id: String = _names[i]
	# TAP TO LOOK, TAP AGAIN TO OPEN. A roster of 139 is browsed, not picked
	# off a menu: the first tap puts the champion in the preview so you can see
	# what you are considering, and only the second commits. It also means a
	# LOCKED champion is viewable — seeing the thing is the whole argument for
	# spending the gems on it.
	if id != _highlight:
		_show(id)
		_list.rebind()
		return
	if roster.owns(id):
		navigate.emit(UiRoute.SHEET, id)
	else:
		notified.emit("%s is locked. %d gems unlocks this champion."
			% [ChampionName.of(id), Champion.gem_cost(id)])


func _on_action(i: int, _which: int) -> void:
	if i < 0 or i >= _names.size():
		return
	var id: String = _names[i]
	var reason: String = roster.unlock_with_gems(id)
	if reason != "":
		notified.emit(reason)
		return
	notified.emit("%s joins your roster at level 1." % ChampionName.of(id))
	mutated()


func _open_crystal() -> void:
	var result: Dictionary = roster.open_crystal()
	if result.is_empty():
		notified.emit("No spawn crystals to open.")
		return
	var id: String = String(result.get("hero", ""))
	# THE ARRIVAL IS THE PRODUCT. This used to be a line in the toast strip:
	# the most exciting thing that can happen in the game, announced with less
	# ceremony than picking up a sword.
	reveal_champion.emit(id, bool(result.get("duplicate", false)),
		int(result.get("gold", 0)))
	# No mutated() here — the reveal refreshes when it closes, so the list
	# behind it does not visibly gain a row while the player is still being
	# told what they got.


## Put `id` in the preview. Called on refresh and whenever a row is touched, so
## tapping down the roster turns it into a gallery rather than a list of names.
func _show(id: String) -> void:
	if id == "" or _preview == null:
		return
	_highlight = id
	_preview.show_hero(id)
	_caption.text = ChampionName.of(id)
	_caption.add_theme_color_override("font_color", Champion.colour(id))
	var p: HeroProgress = roster.progress(id)
	var cls: int = HeroClass.for_hero(id)
	_caption_sub.text = "%s · %s · %s" % [
		Champion.rarity_name(id), HeroClass.display_name(cls),
		("level %d" % p.level) if p != null else "locked"]
