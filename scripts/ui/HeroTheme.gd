class_name HeroTheme
extends RefCounted
# ------------------------------------------------------------------------------
# The look of the menu shell, in one place.
#
# The palette is not invented. It is the one the app icon is built from —
# branding/make_icon.py names #0B0B14 as the ground and #71F98C -> #00D08C as
# the mark — so the menus read as the same product as the icon on the home
# screen. Rarity colours are NOT redefined here: they come from
# Item.RARITY_COLOURS, because a player must learn one colour language for
# champions, loot and shop stock alike.
#
# SIZES ARE IN VIEWPORT PIXELS, and the viewport is 1170x2532 — an iPhone at 3x
# (see project.godot). That is why every number below looks enormous written
# down: TAP = 132 px is Apple's 44 pt minimum touch target at that scale, and
# F_BODY = 40 px is about 13 pt on the glass. Anything smaller than TAP is not
# allowed to be tappable, and anything smaller than F_SMALL is not allowed to
# carry information the player needs.
# ------------------------------------------------------------------------------

# --- ground and structure -----------------------------------------------------
const BG: Color = Color("0b0b14")           # icon background
const BG_LIFT: Color = Color("16162a")      # icon background, lifted centre
const PANEL: Color = Color("16162a")
const PANEL_HI: Color = Color("1f1f38")
const LINE: Color = Color("2d2d4a")

# --- text ---------------------------------------------------------------------
# TEXT on BG is roughly 15:1 contrast and DIM is still above 5:1, which is what
# "legible at arm's length" has to mean on a phone held in sunlight.
const TEXT: Color = Color("f2f4f8")
const DIM: Color = Color("9aa3bb")
const FAINT: Color = Color("6b7490")

# --- the mark's greens --------------------------------------------------------
const ACCENT: Color = Color("71f98c")
const ACCENT_DEEP: Color = Color("00d08c")
const ACCENT_SHADE: Color = Color("0e8a5f")

# --- currencies ---------------------------------------------------------------
const GOLD: Color = Color("ffc24a")
const GEM: Color = Color("7cd0ff")
const CRYSTAL: Color = Color("c06bff")

const DANGER: Color = Color("ff6b6b")

## Attribute colours. Deliberately distinct from each other at a glance, since
## the character sheet and every item line are read as a four-way comparison.
const ATTR_COLOUR: Dictionary = {
	Stats.Attr.STRENGTH: Color("ff8f6b"),
	Stats.Attr.AGILITY: Color("71f98c"),
	Stats.Attr.INTELLECT: Color("7cd0ff"),
	Stats.Attr.CONSTITUTION: Color("ffc24a"),
}

# --- type scale ---------------------------------------------------------------
const F_TITLE: int = 128
const F_SUPER: int = 72
const F_HEAD: int = 54
const F_NUM: int = 60
const F_BODY: int = 40
const F_BUTTON: int = 42
const F_SMALL: int = 32

# --- metrics ------------------------------------------------------------------
const TAP: int = 132                        # 44 pt at 3x; the floor for anything tappable
const TAP_SMALL: int = 112                  # secondary actions inside a row
const GAP: int = 22
const PAD: int = 30
const RADIUS: int = 20
const ROW_H: int = 190                      # one list row, three lines of text


# ------------------------------------------------------------------------------
# Style boxes
# ------------------------------------------------------------------------------

static func panel_style(fill: Color = PANEL, border: Color = LINE,
		radius: int = RADIUS, border_px: int = 2) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(radius)
	sb.set_border_width_all(border_px)
	sb.border_color = border
	sb.set_content_margin_all(PAD)
	return sb


## A panel with one accent edge down its left side — used to colour a row by
## rarity without tinting the text, which would wreck contrast.
static func edge_style(fill: Color, edge: Color, radius: int = RADIUS) -> StyleBoxFlat:
	var sb := panel_style(fill, LINE, radius, 0)
	sb.border_width_left = 10
	sb.border_color = edge
	return sb


static func panel(fill: Color = PANEL, border: Color = LINE) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", panel_style(fill, border))
	return p


# ------------------------------------------------------------------------------
# Text
# ------------------------------------------------------------------------------

static func label(text: String, size: int = F_BODY, colour: Color = TEXT,
		align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A paragraph that wraps. Explanatory copy is load-bearing in this shell —
## gear is invisible and skill points are not shared, and neither fact can be
## shown with an icon.
static func prose(text: String, size: int = F_SMALL, colour: Color = DIM) -> Label:
	var l := label(text, size, colour)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_constant_override("line_spacing", 8)
	return l


static func clipped(text: String, size: int = F_BODY, colour: Color = TEXT) -> Label:
	var l := label(text, size, colour)
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l


# ------------------------------------------------------------------------------
# Buttons
# ------------------------------------------------------------------------------

enum Btn { PRIMARY, SECONDARY, GHOST, DANGER_BTN }


static func button(text: String, kind: int = Btn.SECONDARY,
		height: int = TAP) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, height)
	b.add_theme_font_size_override("font_size", F_BUTTON)
	b.clip_text = true
	# A focus ring is meaningless without a keyboard and leaves a stuck
	# highlight on the last thing a finger touched.
	b.focus_mode = Control.FOCUS_NONE

	var fill: Color = PANEL_HI
	var edge: Color = LINE
	var ink: Color = TEXT
	match kind:
		Btn.PRIMARY:
			fill = ACCENT_SHADE
			edge = ACCENT
			ink = Color("eafff2")
		Btn.GHOST:
			fill = Color(PANEL.r, PANEL.g, PANEL.b, 0.0)
			edge = LINE
			ink = DIM
		Btn.DANGER_BTN:
			fill = Color("3a1420")
			edge = DANGER
			ink = Color("ffd9d9")

	var normal := panel_style(fill, edge, RADIUS, 2)
	normal.set_content_margin_all(18)
	var pressed := panel_style(fill.lerp(Color.WHITE, 0.14), edge, RADIUS, 2)
	pressed.set_content_margin_all(18)
	var disabled := panel_style(fill.lerp(BG, 0.55), LINE.lerp(BG, 0.4), RADIUS, 2)
	disabled.set_content_margin_all(18)

	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", normal)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", normal)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_color_override("font_color", ink)
	b.add_theme_color_override("font_hover_color", ink)
	b.add_theme_color_override("font_pressed_color", ink)
	b.add_theme_color_override("font_disabled_color", FAINT)
	return b


## One tab of a segmented control: a toggle whose selected state is obvious at
## arm's length, which the default pressed tint is not.
static func segment(text: String, group: ButtonGroup) -> Button:
	var b := button(text, Btn.SECONDARY, TAP)
	b.toggle_mode = true
	b.button_group = group
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var on := panel_style(ACCENT_SHADE, ACCENT, RADIUS, 2)
	on.set_content_margin_all(18)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_color_override("font_pressed_color", Color("eafff2"))
	b.add_theme_color_override("font_hover_pressed_color", Color("eafff2"))
	return b


# ------------------------------------------------------------------------------
# Small compositions
# ------------------------------------------------------------------------------

## A non-interactive tag: rarity, tier, slot name.
static func chip(text: String, colour: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := panel_style(Color(colour.r, colour.g, colour.b, 0.14),
		Color(colour.r, colour.g, colour.b, 0.55), 14, 2)
	sb.set_content_margin_all(12)
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	p.add_theme_stylebox_override("panel", sb)
	p.add_child(label(text, F_SMALL, colour))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


static func bar(fraction: float, colour: Color = ACCENT_DEEP,
		height: int = 18) -> ProgressBar:
	var pb := ProgressBar.new()
	pb.min_value = 0.0
	pb.max_value = 1.0
	pb.value = clampf(fraction, 0.0, 1.0)
	pb.show_percentage = false
	pb.custom_minimum_size = Vector2(0, height)
	var back := StyleBoxFlat.new()
	back.bg_color = Color("101020")
	back.set_corner_radius_all(height / 2)
	var fill := StyleBoxFlat.new()
	fill.bg_color = colour
	fill.set_corner_radius_all(height / 2)
	pb.add_theme_stylebox_override("background", back)
	pb.add_theme_stylebox_override("fill", fill)
	return pb


static func spacer(px: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, px)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func rule() -> Control:
	var c := ColorRect.new()
	c.color = LINE
	c.custom_minimum_size = Vector2(0, 2)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# ------------------------------------------------------------------------------
# Formatting
# ------------------------------------------------------------------------------

## Thousands separators. Gold reaches five and six figures, and "45000" is a
## number the player has to squint at while "45,000" is one they can read.
static func money(n: int) -> String:
	var digits: String = str(absi(n))
	var out: String = ""
	var run: int = 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		run += 1
		if run % 3 == 0 and i > 0:
			out = "," + out
	return ("-" + out) if n < 0 else out


static func signed(v: float) -> String:
	return "%+.0f" % v


static func currency_colour(kind: int) -> Color:
	match kind:
		Wallet.Kind.GOLD: return GOLD
		Wallet.Kind.GEMS: return GEM
		_: return CRYSTAL


static func attr_colour(attr: int) -> Color:
	return ATTR_COLOUR.get(attr, TEXT)
