class_name RevealScreen
extends Control
# ------------------------------------------------------------------------------
# A champion arrives.
#
# THE ROSTER IS THIS GAME'S LARGEST ASSET AND NOBODY EVER SEES IT. 139 rigged
# champions, each with their own rarity, class, spell element and effect
# signature — and opening a spawn crystal produced a line of text in the toast
# strip. The single most exciting thing that can happen in the game had less
# presentation than picking up a sword.
#
# The sequence is four beats, and it is deliberately short — this plays every
# time a crystal opens, and the fifth viewing has to be as skippable as the
# first:
#
#   1. The screen goes dark and the rarity colour gathers in the middle.
#   2. It cracks: the gather snaps outward as a ring.
#   3. The champion is standing there, turning, lit in their own colour.
#   4. Name, rarity and class punch in underneath.
#
# A DUPLICATE IS NOT A FAILURE and must not be presented as one. It is the same
# arrival with a different caption — the crystal still opened, the champion
# still appeared, and the gold is a consolation shown after the reveal rather
# than instead of it.
#
# TAP ANYWHERE SKIPS TO THE END. Not "closes": skipping to the end means a
# player who has seen it fifty times still gets the name and the rarity, which
# is the information the screen exists to deliver.
# ------------------------------------------------------------------------------

## Beat boundaries, in seconds from the start.
const GATHER: float = 0.45
const CRACK: float = 0.62
const STAND: float = 0.95
const CAPTION: float = 1.25
## When the dismiss button becomes pressable. Before it, a tap skips instead.
const DONE_AT: float = 1.55

signal dismissed()

var _hero: String = ""
var _duplicate: bool = false
var _gold: int = 0

var _veil: ColorRect
var _burst: Panel
var _preview: HeroPreview
var _name: Label
var _sub: Label
var _note: Label
var _go: Button
var _t: float = 0.0
var _skipped: bool = false


func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


## Show `hero` arriving. `duplicate` and `gold` describe a crystal that rolled
## a champion already owned.
func reveal(hero: String, duplicate: bool = false, gold: int = 0) -> void:
	_hero = hero
	_duplicate = duplicate
	_gold = gold
	var tint: Color = Champion.colour(hero)

	_veil = ColorRect.new()
	_veil.color = Color(0.0, 0.0, 0.0, 0.0)
	_veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_veil)

	# The gather and the crack are the same node at different sizes: one is a
	# tight disc of the rarity colour, the other is that disc thrown outward.
	_burst = Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(tint, 0.0)
	style.corner_radius_top_left = 400
	style.corner_radius_top_right = 400
	style.corner_radius_bottom_left = 400
	style.corner_radius_bottom_right = 400
	_burst.add_theme_stylebox_override("panel", style)
	_burst.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_burst)

	_preview = HeroPreview.new()
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_preview)
	# Tighter than the roster thumbnail. This is the champion's one moment on
	# a whole display, not a row in a list.
	_preview.zoom = 0.88
	_preview.show_hero(hero)

	var col := VBoxContainer.new()
	# ABOVE the Continue button, which is anchored to the bottom 190px. The
	# first pass put the caption in the same band and the rarity, class and
	# element were all drawn underneath it.
	col.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	col.offset_top = -500
	col.offset_bottom = -200
	col.offset_left = HeroTheme.SAFE_X
	col.offset_right = -HeroTheme.SAFE_X
	col.add_theme_constant_override("separation", 6)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)

	_name = HeroTheme.label(ChampionName.of(hero), HeroTheme.F_TITLE, tint)
	_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name.clip_text = true
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(_name)

	var cls: int = HeroClass.for_hero(hero)
	var line: String = "%s  ·  %s" % [Champion.rarity_name(hero),
		HeroClass.display_name(cls)]
	# A mage's element is the most interesting fact about them and it was
	# never surfaced anywhere. This is the moment to say it.
	if HeroClass.school_of(cls) == HeroClass.School.SPELL:
		line += "  ·  %s" % MageSpells.element_name(hero)
	_sub = HeroTheme.label(line, HeroTheme.F_HEAD, HeroTheme.TEXT)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_sub)

	_note = HeroTheme.label("", HeroTheme.F_SMALL, HeroTheme.GOLD)
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if duplicate:
		_note.text = "Already yours — the crystal paid out %s gold instead." \
			% HeroTheme.money(gold)
	else:
		_note.text = "Joins your roster."
		_note.add_theme_color_override("font_color", HeroTheme.DIM)
	col.add_child(_note)

	_go = HeroTheme.button("Continue", HeroTheme.Btn.PRIMARY, 150)
	_go.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_go.offset_top = -150 - 40
	_go.offset_bottom = -40
	_go.offset_left = HeroTheme.SAFE_X
	_go.offset_right = -HeroTheme.SAFE_X
	_go.pressed.connect(func() -> void: dismissed.emit())
	add_child(_go)

	for n in [_preview, _name, _sub, _note, _go]:
		(n as CanvasItem).modulate.a = 0.0
	set_process(true)
	Audio.play(Audio.Cue.CAST, 0.7)


func _gui_input(e: InputEvent) -> void:
	# Tap anywhere to SKIP TO THE END, never to close. A player on their
	# fiftieth crystal still needs to read which champion they got.
	if _t >= DONE_AT:
		return
	var tapped: bool = (e is InputEventScreenTouch and (e as
		InputEventScreenTouch).pressed) \
		or (e is InputEventMouseButton and (e as
			InputEventMouseButton).pressed)
	if tapped:
		_skipped = true
		accept_event()


func _process(delta: float) -> void:
	_t += delta * (6.0 if _skipped else 1.0)

	_veil.color.a = minf(_t / GATHER, 1.0) * 0.93

	# Beat 1-2: gather, then crack outward and fade.
	var mid: Vector2 = size * 0.5
	var style: StyleBoxFlat = _burst.get_theme_stylebox("panel")
	if _t < CRACK:
		var k: float = clampf(_t / CRACK, 0.0, 1.0)
		var r: float = lerpf(420.0, 60.0, k)
		_burst.position = mid - Vector2(r, r)
		_burst.size = Vector2(r, r) * 2.0
		style.bg_color.a = k * 0.9
	else:
		var k2: float = clampf((_t - CRACK) / 0.5, 0.0, 1.0)
		var r2: float = lerpf(60.0, maxf(size.x, size.y) * 0.75, k2)
		_burst.position = mid - Vector2(r2, r2)
		_burst.size = Vector2(r2, r2) * 2.0
		style.bg_color.a = (1.0 - k2) * 0.55

	# Beat 3: the champion is standing there.
	var stand: float = clampf((_t - STAND) / 0.35, 0.0, 1.0)
	_preview.modulate.a = stand
	# Wide and short: HeroPreview frames by camera distance, so a tall thin
	# viewport renders a small champion in a lot of empty space.
	var pw: float = minf(size.x * 0.52, 780.0)
	var ph: float = size.y * 0.60
	_preview.position = Vector2((size.x - pw) * 0.5,
		size.y * 0.02 + (1.0 - stand) * 40.0)
	_preview.size = Vector2(pw, ph)

	# Beat 4: who they are.
	var cap: float = clampf((_t - CAPTION) / 0.3, 0.0, 1.0)
	_name.modulate.a = cap
	_sub.modulate.a = cap
	_note.modulate.a = cap

	_go.modulate.a = clampf((_t - DONE_AT) / 0.25, 0.0, 1.0)
	_go.disabled = _t < DONE_AT
	if _t > DONE_AT + 0.4:
		set_process(false)
