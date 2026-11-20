class_name CampaignScreen
extends UiScreen
# ------------------------------------------------------------------------------
# Where to go, and how hard it will be.
#
# The region list is Campaign's own structure (sixteen regions in four acts,
# read off Biome.IDS), and the tier row is the account-wide difficulty unlock.
# Campaign.entry_blocked_reason() supplies the refusals verbatim, so a greyed
# tier always says WHY it is grey — "Clear Normal to unlock" or "Requires
# level 18" — instead of leaving the player to guess which of the two it is.
#
# Choosing here is what the Play button on the title screen was always for:
# UiShell hands scenes/Play.tscn the region's seed, its biome and the chosen
# champion, and Campaign.region_seed() does not depend on the tier, so a region
# revisited at a higher difficulty is the same ground (see Campaign.gd).
# ------------------------------------------------------------------------------

var _tier: int = Campaign.Tier.NORMAL
var _tier_buttons: Array[Button] = []
var _tier_note: Label
var _list: VirtualList
var _region: int = 0
var _enter: Button


func screen_title() -> String:
	return "Campaign"


func back_route() -> String:
	return UiRoute.SHEET


func build() -> void:
	content.add_child(context_strip())
	_tier = roster.unlocked_tier

	var tiers := HBoxContainer.new()
	tiers.add_theme_constant_override("separation", 10)
	content.add_child(tiers)
	var group := ButtonGroup.new()
	# Every difficulty the campaign declares, not a hand-listed four — the eighth
	# tier must not be unreachable because this row was never updated.
	for tier in range(Campaign.tier_count()):
		var b := HeroTheme.segment(Campaign.tier_name(tier), group)
		b.add_theme_font_size_override("font_size", HeroTheme.F_SMALL)
		b.pressed.connect(_on_tier.bind(tier))
		_tier_buttons.append(b)
		tiers.add_child(b)

	_tier_note = HeroTheme.prose("")
	content.add_child(_tier_note)

	_list = VirtualList.new()
	_list.configure(_make_row, _bind_row, 170)
	content.add_child(_list)

	_enter = HeroTheme.button("", HeroTheme.Btn.PRIMARY, 150)
	_enter.pressed.connect(_on_enter)
	footer.add_child(_enter)

	refresh()


func _on_tier(tier: int) -> void:
	_tier = tier
	refresh()


func refresh() -> void:
	if roster == null or _list == null:
		return
	var p: HeroProgress = roster.progress(hero)
	if p == null:
		return

	for i in range(_tier_buttons.size()):
		var locked: bool = i > roster.unlocked_tier
		_tier_buttons[i].disabled = locked
		_tier_buttons[i].button_pressed = i == _tier
	var blocked: String = Campaign.entry_blocked_reason(_tier, p,
		roster.unlocked_tier)
	if blocked == "":
		_tier_note.text = ("%s: enemies at level %d to %d, and better loot. " \
			+ "Difficulty is unlocked for every champion at once; the levels " \
			+ "you earn are %s's alone.") % [Campaign.tier_name(_tier),
				Campaign.enemy_level(0, _tier),
				Campaign.enemy_level(Campaign.region_count() - 1, _tier),
				ChampionName.of(hero)]
		_tier_note.add_theme_color_override("font_color", HeroTheme.DIM)
	else:
		_tier_note.text = "%s is closed to %s — %s." % [
			Campaign.tier_name(_tier), ChampionName.of(hero), blocked]
		_tier_note.add_theme_color_override("font_color", HeroTheme.GOLD)

	_list.set_count(Campaign.region_count())
	_region = clampi(_region, 0, Campaign.region_count() - 1)
	_enter.disabled = blocked != ""
	_enter.text = "Enter %s" % Biome.display_name(Campaign.biome_at(_region)) \
		if blocked == "" else "Choose a difficulty you can enter"


func _make_row() -> Control:
	var row := UiListRow.new()
	row.row_pressed.connect(_on_row)
	return row


func _bind_row(node: Control, i: int) -> void:
	var row := node as UiListRow
	row.index = i
	var chosen: bool = i == _region
	row.configure(Biome.display_name(Campaign.biome_at(i)),
		"%s · region %d of %d" % [Campaign.act_name(Campaign.act_of(i)), i + 1,
			Campaign.region_count()],
		"L %d" % Campaign.enemy_level(i, _tier),
		HeroTheme.ACCENT if chosen else HeroTheme.LINE,
		-1, "Chosen" if chosen else "")
	row.note_colour(HeroTheme.ACCENT)
	row.value_colour(HeroTheme.DIM)
	row.show_chevron(not chosen)


func _on_row(i: int) -> void:
	_region = clampi(i, 0, Campaign.region_count() - 1)
	_list.rebind()
	refresh()


func _on_enter() -> void:
	var p: HeroProgress = roster.progress(hero)
	if p == null:
		return
	if not Campaign.can_enter(_tier, p, roster.unlocked_tier):
		notified.emit(Campaign.entry_blocked_reason(_tier, p,
			roster.unlocked_tier))
		return
	navigate.emit(UiRoute.LAUNCH, {"hero": hero, "region": _region,
		"tier": _tier})
