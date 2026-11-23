class_name UiGlyph
extends Control
# ------------------------------------------------------------------------------
# Every symbol in the shell, drawn in code.
#
# WHY NOT ICON FILES: the project ships no 2D art and no emoji in UI text (see
# the house rules), and a currency row needs a coin, a gem and a crystal that
# are distinguishable at 48 px. Drawing them from polygons keeps them crisp at
# any size, keeps the PCK free of nine more textures to re-import, and means
# the app mark in the title is the SAME geometry as branding/blockle-b-icon.svg
# rather than a screenshot of it.
# ------------------------------------------------------------------------------

enum Kind {
	MARK,        # the Blockle hexagon, as on the app icon
	GOLD,        # a coin
	GEM,         # a cut gem
	CRYSTAL,     # a spawn crystal
	BACK,        # a left chevron
	CHEVRON,     # a right chevron: "this row opens something"
	PLUS,        # spend a skill point
	CHECK,
	SPARK,       # an upgrade is waiting in the stash
	BLADE,       # Fighter
	ARROW,       # Ranger
	SIGIL,       # Mage
	# ---- the left navigation panel ----
	# One per destination. Drawn rather than lettered because three of the
	# seven destinations begin with C — Champions, Campaign, Contracts — so a
	# collapsed rail showing initials would be three identical buttons.
	MENU,        # three bars: open and close the panel
	ROSTER,      # a figure: Champions
	CHEST,       # a lidded box: Stash
	SCALES,      # a balance: Merchant
	BANNER,      # a pennant: Campaign
	PARTY,       # two figures: Party
	SCROLL,      # a contract
	HOURGLASS,   # Training, which is a thing that happens over time
	COG,         # Settings. Its own shape because the rail shows icons ONLY
	             # when collapsed, so two destinations sharing a glyph are two
	             # identical buttons — tools/navtest.gd asserts exactly that,
	             # and caught Settings borrowing Training's hourglass.
}

## The brand hexagon: pointed top and bottom, vertical sides. Taken from the
## outer path of branding/blockle-b-icon.svg, normalised to a unit square.
const HEX: PackedVector2Array = [
	Vector2(0.50, 0.02), Vector2(0.97, 0.26), Vector2(0.97, 0.74),
	Vector2(0.50, 0.98), Vector2(0.03, 0.74), Vector2(0.03, 0.26),
]

var kind: int = Kind.MARK:
	set(v):
		kind = v
		queue_redraw()

var tint: Color = HeroTheme.TEXT:
	set(v):
		tint = v
		queue_redraw()


static func make(k: int, px: float, colour: Color = HeroTheme.TEXT) -> UiGlyph:
	var g := UiGlyph.new()
	g.kind = k
	g.tint = colour
	g.custom_minimum_size = Vector2(px, px)
	# Glyphs are decoration; the row or button underneath owns the touch.
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return g


static func for_class(cls: int) -> int:
	match cls:
		HeroClass.Kind.FIGHTER: return Kind.BLADE
		HeroClass.Kind.RANGER: return Kind.ARROW
		_: return Kind.SIGIL


static func for_currency(currency: int) -> int:
	match currency:
		Wallet.Kind.GOLD: return Kind.GOLD
		Wallet.Kind.GEMS: return Kind.GEM
		_: return Kind.CRYSTAL


# ------------------------------------------------------------------------------

func _draw() -> void:
	var s: float = minf(size.x, size.y)
	if s <= 0.0:
		return
	var o: Vector2 = (size - Vector2(s, s)) * 0.5
	match kind:
		Kind.MARK: _mark(o, s)
		Kind.GOLD: _coin(o, s)
		Kind.GEM: _gem(o, s)
		Kind.CRYSTAL: _crystal(o, s)
		Kind.BACK: _chevron(o, s, -1.0)
		Kind.CHEVRON: _chevron(o, s, 1.0)
		Kind.PLUS: _plus(o, s)
		Kind.CHECK: _check(o, s)
		Kind.SPARK: _spark(o, s)
		Kind.BLADE: _blade(o, s)
		Kind.ARROW: _arrow(o, s)
		Kind.SIGIL: _sigil(o, s)
		Kind.MENU: _menu(o, s)
		Kind.ROSTER: _figure(o, s, 0.5, 0.78)
		Kind.CHEST: _chest(o, s)
		Kind.SCALES: _scales(o, s)
		Kind.BANNER: _banner(o, s)
		Kind.PARTY: _party(o, s)
		Kind.SCROLL: _scroll(o, s)
		Kind.HOURGLASS: _hourglass(o, s)
		Kind.COG: _cog(o, s)


func _poly(pts: PackedVector2Array, o: Vector2, s: float, scale: float,
		colour: Color) -> void:
	var out := PackedVector2Array()
	var c := Vector2(0.5, 0.5)
	for p in pts:
		out.append(o + (c + (p - c) * scale) * s)
	draw_colored_polygon(out, colour)


func _mark(o: Vector2, s: float) -> void:
	_poly(HEX, o, s, 1.0, tint)
	# Punch the counter back out in the page colour, leaving a ring — the icon
	# reads as a hollow hexagon with a waist, not a filled blob.
	_poly(HEX, o, s, 0.60, HeroTheme.BG)
	var waist := PackedVector2Array([
		Vector2(0.20, 0.47), Vector2(0.80, 0.47),
		Vector2(0.80, 0.56), Vector2(0.20, 0.56),
	])
	_poly(waist, o, s, 1.0, tint)


func _coin(o: Vector2, s: float) -> void:
	var c: Vector2 = o + Vector2(s, s) * 0.5
	draw_circle(c, s * 0.46, tint)
	draw_circle(c, s * 0.30, Color(tint.r, tint.g, tint.b, 0.35))


func _gem(o: Vector2, s: float) -> void:
	_poly(PackedVector2Array([
		Vector2(0.50, 0.04), Vector2(0.94, 0.40),
		Vector2(0.50, 0.96), Vector2(0.06, 0.40),
	]), o, s, 1.0, tint)
	# One bright facet, so a gem is not just a diamond outline.
	_poly(PackedVector2Array([
		Vector2(0.50, 0.04), Vector2(0.94, 0.40), Vector2(0.50, 0.40),
	]), o, s, 1.0, Color(1, 1, 1, 0.35))


func _crystal(o: Vector2, s: float) -> void:
	_poly(PackedVector2Array([
		Vector2(0.50, 0.02), Vector2(0.84, 0.30), Vector2(0.72, 0.98),
		Vector2(0.28, 0.98), Vector2(0.16, 0.30),
	]), o, s, 1.0, tint)
	draw_line(o + Vector2(0.50, 0.06) * s, o + Vector2(0.50, 0.96) * s,
		Color(1, 1, 1, 0.38), maxf(s * 0.05, 2.0))


func _chevron(o: Vector2, s: float, dir: float) -> void:
	var w: float = maxf(s * 0.11, 3.0)
	var x0: float = 0.62 if dir > 0.0 else 0.38
	var x1: float = 0.32 if dir > 0.0 else 0.68
	draw_polyline(PackedVector2Array([
		o + Vector2(x1, 0.22) * s, o + Vector2(x0, 0.50) * s,
		o + Vector2(x1, 0.78) * s,
	]), tint, w)


func _plus(o: Vector2, s: float) -> void:
	var t: float = s * 0.14
	draw_rect(Rect2(o + Vector2(s * 0.5 - t * 0.5, s * 0.22),
		Vector2(t, s * 0.56)), tint)
	draw_rect(Rect2(o + Vector2(s * 0.22, s * 0.5 - t * 0.5),
		Vector2(s * 0.56, t)), tint)


func _check(o: Vector2, s: float) -> void:
	draw_polyline(PackedVector2Array([
		o + Vector2(0.18, 0.52) * s, o + Vector2(0.42, 0.76) * s,
		o + Vector2(0.84, 0.26) * s,
	]), tint, maxf(s * 0.12, 3.0))


func _spark(o: Vector2, s: float) -> void:
	_poly(PackedVector2Array([
		Vector2(0.50, 0.00), Vector2(0.60, 0.40), Vector2(1.00, 0.50),
		Vector2(0.60, 0.60), Vector2(0.50, 1.00), Vector2(0.40, 0.60),
		Vector2(0.00, 0.50), Vector2(0.40, 0.40),
	]), o, s, 1.0, tint)


func _blade(o: Vector2, s: float) -> void:
	_poly(PackedVector2Array([
		Vector2(0.46, 0.04), Vector2(0.58, 0.16), Vector2(0.58, 0.62),
		Vector2(0.46, 0.70),
	]), o, s, 1.0, tint)
	draw_rect(Rect2(o + Vector2(0.28, 0.62) * s, Vector2(0.48, 0.09) * s), tint)
	draw_rect(Rect2(o + Vector2(0.47, 0.71) * s, Vector2(0.10, 0.25) * s), tint)


func _arrow(o: Vector2, s: float) -> void:
	draw_line(o + Vector2(0.14, 0.86) * s, o + Vector2(0.86, 0.14) * s, tint,
		maxf(s * 0.09, 2.0))
	_poly(PackedVector2Array([
		Vector2(0.86, 0.14), Vector2(0.86, 0.46), Vector2(0.54, 0.14),
	]), o, s, 1.0, tint)


func _sigil(o: Vector2, s: float) -> void:
	var c: Vector2 = o + Vector2(s, s) * 0.5
	draw_arc(c, s * 0.40, 0.0, TAU, 40, tint, maxf(s * 0.08, 2.0))
	_poly(PackedVector2Array([
		Vector2(0.50, 0.22), Vector2(0.72, 0.60), Vector2(0.28, 0.60),
	]), o, s, 1.0, tint)


# ------------------------------------------------------------------------------
# The navigation panel's icons.
#
# All of them are built from the same primitives as the rest of this file and
# all of them have to survive being drawn at the rail's size (about 54 px) in
# one flat colour, so none of them leans on fine detail or on more than one
# tone.
# ------------------------------------------------------------------------------

func _menu(o: Vector2, s: float) -> void:
	var t: float = maxf(s * 0.11, 3.0)
	for y in [0.26, 0.50, 0.74]:
		draw_rect(Rect2(o + Vector2(0.16, float(y)) * s - Vector2(0.0, t * 0.5),
			Vector2(0.68 * s, t)), tint)


## A head and a pair of shoulders. `cx` is the centre and `scale` shrinks the
## whole figure, so the party icon can draw two of these smaller.
func _figure(o: Vector2, s: float, cx: float, scale: float) -> void:
	var head_r: float = 0.15 * scale
	draw_circle(o + Vector2(cx, 0.30) * s, head_r * s, tint)
	# A trapezoid rather than a rectangle: square shoulders read as a bottle.
	_poly(PackedVector2Array([
		Vector2(cx - 0.055 * scale, 0.52), Vector2(cx + 0.055 * scale, 0.52),
		Vector2(cx + 0.24 * scale, 0.86), Vector2(cx - 0.24 * scale, 0.86),
	]), o, s, 1.0, tint)


func _party(o: Vector2, s: float) -> void:
	_figure(o, s, 0.33, 0.58)
	_figure(o, s, 0.67, 0.58)


func _chest(o: Vector2, s: float) -> void:
	# Body, then the lid band punched through in the page colour, which is
	# what makes it read as a chest and not a filled rectangle.
	draw_rect(Rect2(o + Vector2(0.14, 0.30) * s, Vector2(0.72, 0.52) * s), tint)
	draw_rect(Rect2(o + Vector2(0.14, 0.44) * s, Vector2(0.72, 0.07) * s),
		HeroTheme.BG)
	# The clasp.
	draw_rect(Rect2(o + Vector2(0.45, 0.40) * s, Vector2(0.10, 0.16) * s),
		HeroTheme.BG)


func _scales(o: Vector2, s: float) -> void:
	var t: float = maxf(s * 0.075, 2.0)
	# Post and beam.
	draw_rect(Rect2(o + Vector2(0.48, 0.20) * s, Vector2(t, 0.62 * s)), tint)
	draw_rect(Rect2(o + Vector2(0.14, 0.26) * s, Vector2(0.72 * s, t)), tint)
	# Foot, so it stands rather than floats.
	draw_rect(Rect2(o + Vector2(0.32, 0.80) * s, Vector2(0.36 * s, t)), tint)
	# Two pans.
	for cx in [0.22, 0.78]:
		_poly(PackedVector2Array([
			Vector2(float(cx) - 0.13, 0.42), Vector2(float(cx) + 0.13, 0.42),
			Vector2(float(cx), 0.60),
		]), o, s, 1.0, tint)


func _banner(o: Vector2, s: float) -> void:
	var t: float = maxf(s * 0.085, 2.0)
	draw_rect(Rect2(o + Vector2(0.24, 0.10) * s, Vector2(t, 0.80 * s)), tint)
	# A swallow-tailed pennant: the notch is what tells it apart from a plain
	# triangle at rail size.
	_poly(PackedVector2Array([
		Vector2(0.28, 0.14), Vector2(0.86, 0.26), Vector2(0.70, 0.38),
		Vector2(0.86, 0.50), Vector2(0.28, 0.56),
	]), o, s, 1.0, tint)


func _scroll(o: Vector2, s: float) -> void:
	draw_rect(Rect2(o + Vector2(0.24, 0.14) * s, Vector2(0.52, 0.72) * s), tint)
	# Three lines of writing, punched out.
	for y in [0.30, 0.46, 0.62]:
		draw_rect(Rect2(o + Vector2(0.34, float(y)) * s,
			Vector2(0.32 * s, maxf(s * 0.055, 2.0))), HeroTheme.BG)
	# The rolled ends.
	for y in [0.10, 0.82]:
		draw_rect(Rect2(o + Vector2(0.18, float(y)) * s,
			Vector2(0.64 * s, 0.08 * s)), tint)


## A COG: eight teeth around a ring with a hole in it.
##
## Drawn rather than lettered, like every other glyph here — this project ships
## no 2D textures and no emoji in UI text. Eight teeth because at the 92 px the
## rail draws these, six reads as a flower and twelve closes into a disc.
func _cog(o: Vector2, s: float) -> void:
	var c := Vector2(0.5, 0.5)
	var teeth: int = 8
	var r_in: float = 0.30
	var r_out: float = 0.46
	# The teeth, as wedges off the ring.
	for i in range(teeth):
		var a: float = TAU * float(i) / float(teeth)
		var half: float = TAU / float(teeth) * 0.22
		_poly(PackedVector2Array([
			c + Vector2(cos(a - half), sin(a - half)) * r_in,
			c + Vector2(cos(a - half), sin(a - half)) * r_out,
			c + Vector2(cos(a + half), sin(a + half)) * r_out,
			c + Vector2(cos(a + half), sin(a + half)) * r_in,
		]), o, s, 1.0, tint)
	# The ring itself, and the hole: an annulus drawn as a thick arc so the
	# centre stays empty at any size rather than filling in on a small rail.
	draw_arc(o + c * s, (r_in + 0.09) * s, 0.0, TAU, 28, tint, 0.17 * s, true)


func _hourglass(o: Vector2, s: float) -> void:
	_poly(PackedVector2Array([
		Vector2(0.24, 0.14), Vector2(0.76, 0.14), Vector2(0.50, 0.50),
	]), o, s, 1.0, tint)
	_poly(PackedVector2Array([
		Vector2(0.50, 0.50), Vector2(0.76, 0.86), Vector2(0.24, 0.86),
	]), o, s, 1.0, tint)
	# Caps, so the sand has somewhere to be.
	for y in [0.08, 0.84]:
		draw_rect(Rect2(o + Vector2(0.18, float(y)) * s,
			Vector2(0.64 * s, 0.08 * s)), tint)
