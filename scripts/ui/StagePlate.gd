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
# ------------------------------------------------------------------------------

const DIR: String = "res://assets/art/stages"
## Must match the band count gen_concept_art.py generated with.
const BANDS: int = 4

var _panel: Panel
var _art: TextureRect
var _wash: ColorRect
var _title: Label
var _sub: Label


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

	_art = TextureRect.new()
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# COVER, not stretch: a 16:9 plate in a taller panel must crop rather than
	# distort. A squashed matte painting reads as a rendering bug.
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_art)

	# A dark wash under the caption. Without it the type sits on whatever the
	# painting happens to be doing there, which on a bright sky is unreadable.
	_wash = ColorRect.new()
	_wash.color = Color(HeroTheme.BG.r, HeroTheme.BG.g, HeroTheme.BG.b, 0.72)
	_wash.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_wash.offset_top = -190
	_wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_wash)

	var caption := VBoxContainer.new()
	caption.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	caption.offset_top = -170
	caption.offset_left = HeroTheme.PAD
	caption.offset_right = -HeroTheme.PAD
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(caption)

	_title = HeroTheme.label("", HeroTheme.F_HEAD)
	# A long region title must end in an ellipsis, not mid-glyph: the map name
	# is also in the list beside this, so losing the tail costs nothing, while
	# a letter sliced in half reads as a rendering fault.
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	caption.add_child(_title)
	_sub = HeroTheme.label("", HeroTheme.F_SMALL, HeroTheme.DIM)
	caption.add_child(_sub)


## Show map `index` of the campaign.
func show_map(index: int) -> void:
	if _art == null:
		return
	var biome: String = Campaign.biome_at(index)
	var band: int = Campaign.dread_band(index, BANDS)

	# Walk DOWN from the map's own band: a biome that only has a calm plate
	# should show that rather than nothing, and a late map should never fall
	# back to a cheerier picture than one it already has.
	var tex: Texture2D = null
	for b in range(band, -1, -1):
		var path: String = "%s/%s_d%d.jpg" % [DIR, biome, b]
		if ResourceLoader.exists(path):
			tex = load(path) as Texture2D
			break
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
