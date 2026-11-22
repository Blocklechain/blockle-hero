class_name CampaignScreen
extends UiScreen

# Preloaded by path — see UiShell.gd for why class_name is not enough
# for a script the headless harnesses load directly.
const GameMode := preload("res://scripts/game/GameMode.gd")
# ------------------------------------------------------------------------------
# WHERE TO GO, AND HOW HARD IT WILL BE.
#
# This was a hundred-row list beside a thumbnail. A list is the right shape
# for choosing between things you have to read and compare; it is the wrong
# shape for choosing between a hundred PAINTINGS, which is what a campaign map
# actually is. The art was generated to be looked at and was being shown at
# the size of a postage stamp next to a column of names that all say roughly
# the same thing.
#
# So the picture is the screen, and the campaign is paged through: one plate
# at a time, filling the glass, with an arrow on each edge and the map's name
# across it. The change of picture IS the feedback for the tap, which is why
# StagePlate slides rather than cross-fades — sliding says "this is the one to
# the right of that", which is the relationship a column used to express by
# putting them in order.
#
# ------------------------------------------------------------------------------
# WHAT A LIST GAVE US THAT A CAROUSEL HAS TO GIVE BACK.
#
# Dropping the list drops three things, and all three are load-bearing:
#
#   * REACH. A scrollbar gets to map 60 in one flick. One arrow per map is
#     sixty taps. The act row is the answer: ten buttons, so anywhere in the
#     campaign is at most one act tap plus nine arrows — and the screen still
#     opens on the furthest map unlocked, which is the common case and costs
#     nothing at all.
#
#   * WHY A MAP IS SHUT. The list wrote "Clear region N first" on every locked
#     row. The carousel says it under the one map being shown, and the plate
#     is dimmed. A refusal with no reason is the thing this screen must never
#     go back to.
#
#   * WHERE YOU ARE. A column shows your place in it implicitly. A single
#     plate does not, so the caption carries "map N of 100" and the act row
#     marks which act is open.
#
# Campaign.entry_blocked_reason() still supplies the difficulty refusals
# verbatim, so a greyed tier always says WHY it is grey — "Clear Normal to
# unlock" or "Requires level 18" — instead of leaving the player to guess
# which of the two it is.
# ------------------------------------------------------------------------------

## Horizontal drag, in pixels, that counts as a page. Generous: this gesture
## shares the screen with nothing else, and a swipe that needs precision is a
## swipe that gets read as a tap on the art.
const SWIPE: float = 90.0

## How wide the edge arrows are. A full-height column on each side of the
## plate, because the thumb that holds a phone in landscape is already there.
const ARROW_W: int = 150

var _tier: int = Campaign.Tier.NORMAL
var _tier_buttons: Array[Button] = []
var _tier_note: Label
var _plate: StagePlate
var _region: int = 0
var _enter: Button
var _prev: Button
var _next: Button
var _act_buttons: Array[Button] = []

## Live horizontal drag on the art, in pixels. NAN when no drag is in
## progress, so a press that never moves is not treated as a zero-length
## swipe.
var _drag_from: float = NAN


func screen_title() -> String:
	return "Campaign"


func back_route() -> String:
	return UiRoute.SHEET


func build() -> void:
	_tier = roster.unlocked_tier
	# Open where the player stopped, not at region 1 — on a half-finished
	# campaign that is forty arrow taps away.
	_region = roster.furthest_unlocked(_tier)

	# THE PLATE IS THE SCREEN. Not a column of it: `content` is the whole area
	# between the currency bar and the bottom of the glass, and the plate
	# takes all of it. Everything else is anchored OVER the picture.
	_plate = StagePlate.new()
	_plate.title_size = HeroTheme.F_TITLE
	_plate.custom_minimum_size = Vector2(0, 0)
	_plate.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_plate.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# The bottom strip — Enter and the two other modes — sits on the plate, so
	# the caption has to be told to keep clear of it.
	_plate.reserve_bottom = HeroTheme.TAP + HeroTheme.GAP
	content.add_child(_plate)

	_plate.add_child(_top_bar())
	_plate.add_child(_bottom_bar())
	_prev = _edge_arrow(-1)
	_plate.add_child(_prev)
	_next = _edge_arrow(1)
	_plate.add_child(_next)

	refresh()


# ------------------------------------------------------------------------------
# The chrome over the picture
# ------------------------------------------------------------------------------

## Difficulty, its one-line consequence, and the act row — all of it across
## the top of the plate on a wash, so the painting keeps the middle.
func _top_bar() -> Control:
	var holder := Control.new()
	holder.set_anchors_preset(Control.PRESET_TOP_WIDE)
	holder.offset_bottom = 250
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var wash := ColorRect.new()
	wash.color = Color(HeroTheme.BG.r, HeroTheme.BG.g, HeroTheme.BG.b, 0.74)
	wash.set_anchors_preset(Control.PRESET_FULL_RECT)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(wash)

	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", HeroTheme.GAP)
	pad.add_theme_constant_override("margin_right", HeroTheme.GAP)
	pad.add_theme_constant_override("margin_top", 10)
	pad.add_theme_constant_override("margin_bottom", 10)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	pad.add_child(col)

	var tiers := HBoxContainer.new()
	tiers.add_theme_constant_override("separation", 10)
	col.add_child(tiers)
	var group := ButtonGroup.new()
	# Every difficulty the campaign declares, not a hand-listed four — the
	# eighth tier must not be unreachable because this row was never updated.
	for tier in range(Campaign.tier_count()):
		var b := HeroTheme.segment(Campaign.tier_name(tier), group)
		b.custom_minimum_size = Vector2(0, HeroTheme.TAP_SMALL)
		# Eight names across the full width now rather than a narrow column,
		# so they can be read at the size they were designed at.
		b.add_theme_font_size_override("font_size", 28)
		b.pressed.connect(_on_tier.bind(tier))
		_tier_buttons.append(b)
		tiers.add_child(b)

	# ONE LINE, BESIDE THE BUTTONS IT DESCRIBES. This was four lines of
	# reference prose; clipped to a single line directly under the difficulty
	# row, where it reads as a caption to the button just pressed.
	_tier_note = HeroTheme.label("", HeroTheme.F_SMALL, HeroTheme.DIM)
	_tier_note.clip_text = true
	_tier_note.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(_tier_note)

	col.add_child(_act_row())
	return holder


## Ten buttons, one per act. THIS IS THE SCROLLBAR: without it, map 60 is
## sixty arrow taps, and a carousel over a hundred items with no way to jump
## is strictly worse than the list it replaced.
func _act_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for act in range(Campaign.act_count()):
		var b: Button = HeroTheme.button("%d" % (act + 1), HeroTheme.Btn.GHOST,
			HeroTheme.TAP_SMALL - 30)
		b.tooltip_text = Campaign.act_name(act)
		b.add_theme_font_size_override("font_size", HeroTheme.F_SMALL)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# The act's FIRST map, which is where a player jumping to act 5 means
		# to land. Clamped against the seal on the way in, like everything
		# else here.
		b.pressed.connect(_go_to.bind(act * Campaign.maps_per_act()))
		_act_buttons.append(b)
		row.add_child(b)
	return row


## Enter, the two other modes, and the position counter.
func _bottom_bar() -> Control:
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	row.offset_top = -HeroTheme.TAP - HeroTheme.GAP
	row.offset_bottom = -HeroTheme.GAP
	row.offset_left = ARROW_W
	row.offset_right = -ARROW_W
	row.add_theme_constant_override("separation", HeroTheme.GAP)

	_enter = HeroTheme.button("", HeroTheme.Btn.PRIMARY, HeroTheme.TAP)
	_enter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_enter.size_flags_stretch_ratio = 2.0
	_enter.pressed.connect(_on_enter)
	row.add_child(_enter)

	# THE OTHER WAYS TO PLAY, on the screen rather than behind a menu. A mode
	# nobody can find is a mode nobody plays, and this is already the place a
	# player comes to start a run.
	for id in GameMode.all():
		if id == GameMode.Id.CAMPAIGN:
			continue
		var best: int = 0
		if roster != null:
			best = roster.best_in_mode(GameMode.record_key(id))
		var label: String = GameMode.name_of(id)
		if best > 0:
			label += "  ·  %d" % best
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


## One edge arrow. `step` is -1 for the left, +1 for the right.
##
## A FULL-HEIGHT COLUMN, not a small round button. In landscape the thumbs are
## already at the left and right edges holding the phone, so the whole edge is
## the easiest thing on the screen to hit — and a tall thin target cannot be
## missed vertically, which a 90 px circle can.
func _edge_arrow(step: int) -> Control:
	var b: Button = HeroTheme.button("", HeroTheme.Btn.GHOST, 0)
	# NAMED, because they carry a drawn glyph and no text, and the glyph alone
	# is not enough to find them by: UiScreen puts a BACK glyph on the
	# header's own back button too, so a search for "the button with a back
	# chevron" finds that one first and pages nothing.
	b.name = "PageBack" if step < 0 else "PageNext"
	b.set_anchors_preset(Control.PRESET_LEFT_WIDE if step < 0
		else Control.PRESET_RIGHT_WIDE)
	if step < 0:
		b.offset_right = ARROW_W
	else:
		b.offset_left = -ARROW_W
	# Clear of the top bar and the bottom strip, so the arrow never sits on
	# top of a difficulty button or Enter.
	b.offset_top = 250 + HeroTheme.GAP
	b.offset_bottom = -HeroTheme.TAP - HeroTheme.GAP * 2

	var glyph := UiGlyph.make(UiGlyph.Kind.BACK if step < 0
		else UiGlyph.Kind.CHEVRON, 92, HeroTheme.TEXT)
	glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
	b.add_child(glyph)
	b.pressed.connect(_step.bind(step))
	return b


# ------------------------------------------------------------------------------
# Paging
# ------------------------------------------------------------------------------

## Move one map. Clamped rather than wrapped: wrapping from map 100 back to
## map 1 would silently throw away a player's place in the campaign, and the
## arrows are disabled at the ends so the clamp is never a surprise.
func _step(by: int) -> void:
	_go_to(_region + by)


func _go_to(index: int) -> void:
	var want: int = clampi(index, 0, Campaign.region_count() - 1)
	if want == _region:
		return
	var dir: int = 1 if want > _region else -1
	_region = want
	if _plate != null:
		_plate.slide_to(_region, dir)
	# refresh() would re-show the plate instantly and cancel the slide, so the
	# chrome is updated on its own.
	_refresh_chrome()


## SWIPE, because this is a phone and a carousel that can only be driven by
## its arrows is a carousel that feels like a form. The arrows stay: they are
## what makes the gesture discoverable.
func _gui_input(e: InputEvent) -> void:
	var press := e as InputEventScreenTouch
	if press != null:
		if press.pressed:
			_drag_from = press.position.x
		else:
			_drag_from = NAN
		return
	var mouse := e as InputEventMouseButton
	if mouse != null and mouse.button_index == MOUSE_BUTTON_LEFT:
		_drag_from = mouse.position.x if mouse.pressed else NAN
		return

	var moved: float = NAN
	var drag := e as InputEventScreenDrag
	if drag != null:
		moved = drag.position.x
	var motion := e as InputEventMouseMotion
	if motion != null and (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		moved = motion.position.x
	if is_nan(moved) or is_nan(_drag_from):
		return
	var travel: float = moved - _drag_from
	if absf(travel) < SWIPE:
		return
	# Dragging the picture LEFT brings the next map in from the right, which
	# is the direction every photo gallery on the device already uses.
	_step(-1 if travel > 0.0 else 1)
	# Re-anchored rather than cleared, so one long drag pages more than once.
	_drag_from = moved


func _on_tier(tier: int) -> void:
	_tier = tier
	# Each difficulty has its own progress, so the chosen map has to move with
	# it or the player is left pointing at one this tier has sealed.
	_region = roster.furthest_unlocked(_tier)
	refresh()


# ------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------

func refresh() -> void:
	if roster == null or _plate == null:
		return
	_region = clampi(_region, 0, Campaign.region_count() - 1)
	_plate.show_map(_region)
	_refresh_chrome()


## Everything except the picture. Split out because paging animates the plate
## and must not then re-show it instantly.
func _refresh_chrome() -> void:
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
		# used to recite are the same on every tier, so repeating them under
		# every press taught nobody anything after the first.
		_tier_note.text = "%s · enemies level %d to %d · richer loot" % [
			Campaign.tier_name(_tier),
			Campaign.enemy_level(0, _tier),
			Campaign.enemy_level(Campaign.region_count() - 1, _tier)]
		_tier_note.add_theme_color_override("font_color", HeroTheme.DIM)
	else:
		_tier_note.text = "%s is closed to %s — %s." % [
			Campaign.tier_name(_tier), ChampionName.of(hero), blocked]
		_tier_note.add_theme_color_override("font_color", HeroTheme.GOLD)

	# Which act the open map belongs to, so a single plate still says where in
	# the campaign it sits.
	var act: int = Campaign.act_of(_region)
	for i in range(_act_buttons.size()):
		_act_buttons[i].add_theme_color_override("font_color",
			HeroTheme.ACCENT if i == act else HeroTheme.DIM)

	# The arrows stop at the ends rather than wrapping, and SAY SO by going
	# dim — an arrow that silently does nothing reads as a dead button.
	var last: int = Campaign.region_count() - 1
	if _prev != null:
		_prev.disabled = _region <= 0
		_prev.modulate = Color(1, 1, 1, 0.25 if _prev.disabled else 1.0)
	if _next != null:
		_next.disabled = _region >= last
		_next.modulate = Color(1, 1, 1, 0.25 if _next.disabled else 1.0)

	# ---- can this map be entered? -------------------------------------------
	var sealed: bool = not roster.is_map_unlocked(_tier, _region)
	_plate.set_sealed(sealed)
	if blocked != "":
		_enter.disabled = true
		_enter.text = "Choose a difficulty you can enter"
	elif sealed:
		_enter.disabled = true
		# THE WORDS THE LIST USED TO PUT ON EVERY LOCKED ROW. A refusal with
		# no reason leaves the player guessing between the difficulty, their
		# champion's level and the map before it, and two of those three are
		# wrong.
		_enter.text = "Clear region %d first" % _region
	else:
		_enter.disabled = false
		var cleared: bool = roster.is_map_cleared(_tier, _region)
		_enter.text = "%s %s" % ["Replay" if cleared else "Enter",
			Biome.display_name(Campaign.biome_at(_region))]


func _on_enter() -> void:
	var p: HeroProgress = roster.progress(hero)
	if p == null:
		return
	if not Campaign.can_enter(_tier, p, roster.unlocked_tier):
		notified.emit(Campaign.entry_blocked_reason(_tier, p,
			roster.unlocked_tier))
		return
	# Checked again on the way in, not only when the map was paged to: the
	# tier can be changed after a map is chosen, and region 40 being open on
	# Normal says nothing about region 40 on Infernal.
	if not roster.is_map_unlocked(_tier, _region):
		notified.emit("Region %d is sealed until you clear region %d on %s."
			% [_region + 1, _region, Campaign.tier_name(_tier)])
		return
	navigate.emit(UiRoute.LAUNCH, {"hero": hero, "region": _region,
		"tier": _tier, "mode": GameMode.Id.CAMPAIGN})
