class_name CampaignScreen
extends UiScreen

# Preloaded by path — see UiShell.gd for why class_name is not enough
# for a script the headless harnesses load directly.
const GameMode := preload("res://scripts/game/GameMode.gd")
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
var _plate: StagePlate
var _list: VirtualList
var _region: int = 0
var _enter: Button


func screen_title() -> String:
	return "Campaign"


func back_route() -> String:
	return UiRoute.SHEET


func build() -> void:
	# LANDSCAPE SPLIT. Stacked, this screen gave the map list about one row of
	# the 1170 px height — one map visible out of a hundred, with the row below
	# it clipped. The art goes left (it is the one thing that wants a big fixed
	# area) and the list gets the full column height on the right.
	# THE LEFT COLUMN IS A STAGE CARD: the art, and the button that enters it.
	# Keeping "Enter" in the footer cost a whole row of the 1170 px height, and
	# the map list — a hundred entries — was getting about one row to show them
	# in. It also belongs here: the picture and the way in are one thing.
	# THE PLATE IS THE COLUMN. It used to share the column with the Enter
	# button stacked under it, so the painting — the whole reason a hundred of
	# them were generated — got whatever height was left. The button overlays
	# its lower edge instead: the picture and the way in are one thing, and
	# saying so costs the art nothing.
	_plate = StagePlate.new()
	_plate.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var col := split_fixed(_plate, HeroTheme.COL_SHOW)

	col.add_child(context_strip())
	_tier = roster.unlocked_tier
	# Open where the player stopped, not at region 1 — on a half-finished
	# campaign that is forty taps of scrolling away.
	_region = roster.furthest_unlocked(_tier)

	var tiers := HBoxContainer.new()
	tiers.add_theme_constant_override("separation", 10)
	col.add_child(tiers)
	var group := ButtonGroup.new()
	# Every difficulty the campaign declares, not a hand-listed four — the eighth
	# tier must not be unreachable because this row was never updated.
	for tier in range(Campaign.tier_count()):
		var b := HeroTheme.segment(Campaign.tier_name(tier), group)
		# Eight names across one column, so the type has to give. These are a
		# secondary control the player sets once a run, not something read at a
		# glance mid-fight — "Nightmare" fitting matters more than its size.
		# 24, not 28: the art column got wider and this row got narrower with
		# it, which clipped "Nightmare" to "Nightmar". Eight difficulty names
		# have to fit whole — a tier the player cannot read the name of is a
		# tier they will not choose.
		b.add_theme_font_size_override("font_size", 24)
		b.pressed.connect(_on_tier.bind(tier))
		_tier_buttons.append(b)
		tiers.add_child(b)

	# ONE LINE, BESIDE THE BUTTONS IT DESCRIBES.
	#
	# This was four lines of reference prose under the art, taking as much of
	# the column as the painting did — so the biggest art asset on the screen
	# was rendered as a thumbnail to make room for a paragraph nobody reads
	# twice. Clipped to a single line directly under the difficulty row, where
	# it reads as a caption to the button just pressed.
	_tier_note = HeroTheme.label("", HeroTheme.F_SMALL, HeroTheme.DIM)
	_tier_note.clip_text = true
	_tier_note.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(_tier_note)

	# THE OTHER WAYS TO PLAY, above the map list rather than behind a menu.
	# A mode nobody can find is a mode nobody plays, and this screen is
	# already the place a player comes to start a run.
	col.add_child(_mode_strip())

	_list = VirtualList.new()
	_list.configure(_make_row, _bind_row, 170)
	col.add_child(_list)

	_enter = HeroTheme.button("", HeroTheme.Btn.PRIMARY, 150)
	_enter.pressed.connect(_on_enter)
	# Anchored across the bottom of the plate rather than added beneath it, so
	# it covers the part of the painting the caption was already sitting on.
	_enter.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_enter.offset_top = -150 - HeroTheme.GAP
	_enter.offset_bottom = -HeroTheme.GAP
	_enter.offset_left = HeroTheme.GAP
	_enter.offset_right = -HeroTheme.GAP
	_plate.add_child(_enter)

	refresh()


func _on_tier(tier: int) -> void:
	_tier = tier
	# Each difficulty has its own progress, so the chosen region has to move
	# with it or the player is left pointing at a map this tier has sealed.
	_region = roster.furthest_unlocked(_tier)
	if _list != null:
		_list.rebind()
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
		# The facts that change with the tier, and nothing else. The rules it
		# used to recite — that difficulty unlocks account-wide while levels
		# belong to one champion — are the same on every tier, so repeating
		# them under every press taught nobody anything after the first.
		_tier_note.text = "%s · enemies level %d to %d · richer loot" % [
			Campaign.tier_name(_tier),
			Campaign.enemy_level(0, _tier),
			Campaign.enemy_level(Campaign.region_count() - 1, _tier)]
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
	# The art follows the selection, so picking down the list is a slideshow of
	# where the campaign is taking you rather than a column of names.
	if _plate != null:
		_plate.show_map(_region)


func _make_row() -> Control:
	var row := UiListRow.new()
	row.row_pressed.connect(_on_row)
	return row


func _bind_row(node: Control, i: int) -> void:
	var row := node as UiListRow
	row.index = i
	var chosen: bool = i == _region
	var cleared: bool = roster.is_map_cleared(_tier, i)
	var open: bool = roster.is_map_unlocked(_tier, i)

	# A locked map says WHAT opens it. "Locked" on its own leaves the player
	# guessing whether it is the difficulty, the champion's level or the map
	# before it, and two of those three are wrong.
	var note: String = ""
	if not open:
		note = "Clear region %d first" % i
	elif cleared:
		note = "Cleared"
	elif chosen:
		note = "Chosen"

	row.configure(Biome.display_name(Campaign.biome_at(i)),
		"%s · region %d of %d" % [Campaign.act_name(Campaign.act_of(i)), i + 1,
			Campaign.region_count()],
		"L %d" % Campaign.enemy_level(i, _tier),
		HeroTheme.ACCENT if chosen else (
			HeroTheme.LINE if open else HeroTheme.FAINT),
		-1, note)
	row.title_colour(HeroTheme.TEXT if open else HeroTheme.FAINT)
	row.note_colour(HeroTheme.GOLD if cleared else (
		HeroTheme.ACCENT if open else HeroTheme.FAINT))
	row.value_colour(HeroTheme.DIM if open else HeroTheme.FAINT)
	row.show_chevron(open and not chosen)


func _on_row(i: int) -> void:
	var want: int = clampi(i, 0, Campaign.region_count() - 1)
	if not roster.is_map_unlocked(_tier, want):
		notified.emit("Region %d is sealed until you clear region %d."
			% [want + 1, want])
		return
	_region = want
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
	# Checked again on the way in, not only when the row was tapped: the tier
	# can be changed after a region is chosen, and region 40 being open on
	# Normal says nothing about region 40 on Infernal.
	if not roster.is_map_unlocked(_tier, _region):
		notified.emit("Region %d is sealed until you clear region %d on %s."
			% [_region + 1, _region, Campaign.tier_name(_tier)])
		return
	navigate.emit(UiRoute.LAUNCH, {"hero": hero, "region": _region,
		"tier": _tier, "mode": GameMode.Id.CAMPAIGN})


## One button per non-campaign mode, each showing the player's best run so
## the number is the reason to tap it.
func _mode_strip() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	for id in GameMode.all():
		if id == GameMode.Id.CAMPAIGN:
			continue
		var best: int = 0
		if roster != null:
			best = roster.best_in_mode(GameMode.record_key(id))
		var label: String = GameMode.name_of(id)
		if best > 0:
			label += "  ·  best %d" % best
		var b: Button = HeroTheme.button(label, HeroTheme.Btn.GHOST,
			HeroTheme.TAP)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = GameMode.blurb_of(id)
		# Region 0 and the chosen tier: a mode is not a map, so it is not
		# gated on campaign progress — UiShell skips the seal check for
		# anything that is not the campaign.
		b.pressed.connect(func():
			navigate.emit(UiRoute.LAUNCH, {"hero": hero, "region": 0,
				"tier": _tier, "mode": id}))
		row.add_child(b)
	return row
