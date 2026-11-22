class_name StagePlate
extends Control
# ------------------------------------------------------------------------------
# The concept art for the map you are about to enter.
#
# The plates are generated locally by tools/gen_concept_art.py, one per biome
# per DREAD BAND, so the same biome late in the campaign is a visibly more
# hostile picture than the same biome at the start. A map resolves to a plate
# by asking Campaign for both.
#
# IT DEGRADES TO NOTHING. A missing plate is not an error and must never be a
# broken-image placeholder: 100 maps resolve onto far fewer plates, bands get
# added, art gets regenerated. If the file is not there the panel simply shows
# the biome's own colour, which is already in Biome.gd and is never missing.
#
# ------------------------------------------------------------------------------
# IT SLIDES.
#
# The campaign is now browsed as a carousel rather than read as a list, which
# means the change of picture IS the navigation — it is the only thing that
# tells the player their tap did something, because the next map is often the
# same biome and so often the same plate. Two layers: the outgoing picture
# slides off while the incoming one slides on, both driven by one tween.
#
# A plate that cross-FADED would be wrong here. Fading says "this replaced
# that"; sliding says "this is the one to the right of that", which is the
# actual relationship between map 7 and map 8 and the thing a list used to
# say by putting them in a column.
# ------------------------------------------------------------------------------

const DIR: String = "res://assets/art/stages"
## Must match the band count gen_concept_art.py generated with.
const BANDS: int = 4

## How long a slide takes. Short enough that holding an arrow down still
## feels like paging rather than waiting, long enough to be seen at all.
const SLIDE_TIME: float = 0.22

var _panel: Panel
## Two art layers, so one can leave while the other arrives. `_art` is always
## the one currently showing; `_outgoing` only exists during a slide.
var _art: TextureRect
var _outgoing: TextureRect
var _wash: ColorRect
var _title: Label
var _sub: Label
var _slide: Tween

## Height reserved at the bottom for whatever the owner anchors over the
## plate. The caption sits above it rather than under it.
var reserve_bottom: int = 0:
	set(v):
		reserve_bottom = v
		_relayout_caption()

## How big the map's name is drawn. The carousel wants it large — it is the
## headline of the screen now, not a label on a thumbnail.
var title_size: int = HeroTheme.F_HEAD:
	set(v):
		title_size = v
		if _title != null:
			_title.add_theme_font_size_override("font_size", v)


# A plain Control, NOT a PanelContainer. A PanelContainer is a CONTAINER: it
# lays its children out itself and overrides their anchors, which put the
# caption across the TOP of the picture instead of the bottom and stacked the
# wash as a sibling block. Anchoring only works under a node that does not
# manage layout.
func _init() -> void:
	clip_contents = true
	custom_minimum_size = Vector2(HeroTheme.COL_W, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	_panel = Panel.new()
	_panel.add_theme_stylebox_override("panel",
		HeroTheme.panel_style(HeroTheme.PANEL, HeroTheme.LINE))
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	_art = _make_layer()
	add_child(_art)

	# A dark wash under the caption. Without it the type sits on whatever the
	# painting happens to be doing there, which on a bright sky is unreadable.
	_wash = ColorRect.new()
	_wash.color = Color(HeroTheme.BG.r, HeroTheme.BG.g, HeroTheme.BG.b, 0.72)
	_wash.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_wash)

	var caption := VBoxContainer.new()
	caption.name = "Caption"
	caption.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	caption.offset_left = HeroTheme.PAD
	caption.offset_right = -HeroTheme.PAD
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(caption)

	_title = HeroTheme.label("", title_size)
	# A long region title must end in an ellipsis, not mid-glyph: a letter
	# sliced in half reads as a rendering fault.
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	caption.add_child(_title)
	_sub = HeroTheme.label("", HeroTheme.F_SMALL, HeroTheme.DIM)
	_sub.clip_text = true
	_sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	caption.add_child(_sub)

	_relayout_caption()


func _make_layer() -> TextureRect:
	var t := TextureRect.new()
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# COVER, not stretch: a 16:9 plate in a taller panel must crop rather than
	# distort. A squashed matte painting reads as a rendering bug.
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	t.set_anchors_preset(Control.PRESET_FULL_RECT)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


## Keep the caption and its wash clear of whatever the owner has anchored over
## the bottom of the plate.
func _relayout_caption() -> void:
	if _wash == null:
		return
	var band: int = 150 + reserve_bottom
	_wash.offset_top = -band - 40
	var caption := get_node_or_null("Caption") as Control
	if caption != null:
		caption.offset_top = -band - 20
		caption.offset_bottom = -reserve_bottom - HeroTheme.GAP


# ------------------------------------------------------------------------------
# Showing a map
# ------------------------------------------------------------------------------

## The plate for `index`, or null when there is no art for its biome at all.
##
## Walks DOWN from the map's own band: a biome that only has a calm plate
## should show that rather than nothing, and a late map must never fall back
## to a cheerier picture than one it already has.
static func texture_for(index: int) -> Texture2D:
	var biome: String = Campaign.biome_at(index)
	var band: int = Campaign.dread_band(index, BANDS)
	for b in range(band, -1, -1):
		var path: String = "%s/%s_d%d.jpg" % [DIR, biome, b]
		if ResourceLoader.exists(path):
			return load(path) as Texture2D
	return null


## Show map `index` immediately, with no transition.
func show_map(index: int) -> void:
	if _art == null:
		return
	_kill_slide()
	_apply(index)


## Show map `index`, sliding in from `direction` (+1 = the next map arrives
## from the right, -1 = the previous arrives from the left).
##
## Falls back to an instant swap when the node has no width yet — during
## build, and in the headless harnesses, where tweening a zero-width control
## would animate nothing and just delay the content by SLIDE_TIME.
func slide_to(index: int, direction: int) -> void:
	if _art == null:
		return
	var span: float = size.x
	if span <= 1.0 or direction == 0:
		show_map(index)
		return

	_kill_slide()
	# The picture that is leaving becomes its own layer, so the one arriving
	# can be positioned independently of it.
	var leaving: TextureRect = _art
	_outgoing = leaving
	_art = _make_layer()
	# BEHIND the wash and caption, so the type never slides with the art —
	# the caption is already showing the new map's name by the time the
	# pictures move.
	add_child(_art)
	move_child(_art, leaving.get_index() + 1)
	_apply(index)

	var sign: float = 1.0 if direction > 0 else -1.0
	_art.position.x = span * sign
	_slide = create_tween()
	_slide.set_parallel(true)
	_slide.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_slide.tween_property(_art, "position:x", 0.0, SLIDE_TIME)
	_slide.tween_property(leaving, "position:x", -span * sign, SLIDE_TIME)
	# Captured by name rather than by closure over `_outgoing`, which the next
	# slide will have reassigned by the time this runs.
	_slide.chain().tween_callback(func() -> void:
		if leaving != null and is_instance_valid(leaving):
			leaving.queue_free()
		if _outgoing == leaving:
			_outgoing = null)


func _kill_slide() -> void:
	if _slide != null and _slide.is_valid():
		_slide.kill()
	_slide = null
	# A slide interrupted part-way leaves its outgoing layer sitting on the
	# plate at whatever offset it had reached. Freeing it here rather than
	# only in the tween's callback is what keeps rapid arrow taps from
	# stacking half-slid pictures.
	if _outgoing != null and is_instance_valid(_outgoing):
		_outgoing.queue_free()
	_outgoing = null
	if _art != null:
		_art.position.x = 0.0


func _apply(index: int) -> void:
	var biome: String = Campaign.biome_at(index)
	var tex: Texture2D = texture_for(index)
	_art.texture = tex
	_art.visible = tex != null
	if tex == null:
		# The biome's own ground colour, which always exists.
		var c: Color = Biome.get_biome(biome).get("ground_lo", HeroTheme.PANEL)
		_panel.add_theme_stylebox_override("panel",
			HeroTheme.panel_style(c.darkened(0.55), HeroTheme.LINE))

	_title.text = Campaign.region_title(index)
	_sub.text = "%s  ·  map %d of %d  ·  dread %d%%" % [
		String(Biome.get_biome(biome).get("name", biome)),
		index + 1, Campaign.map_count(),
		int(round(Campaign.dread(index) * 100.0))]


## Dim the picture for a map the player cannot enter.
##
## The art of a sealed map is still shown — it is the reason to want to get
## there — but it must not look enterable. A dim pass is the whole cue; the
## caption says why in words.
func set_sealed(sealed: bool) -> void:
	modulate = Color(0.46, 0.46, 0.52) if sealed else Color.WHITE
