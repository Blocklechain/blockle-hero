extends Control
# ------------------------------------------------------------------------------
# THE PLAYER CANNOT FIND THE BOSS.
#
# A region is cleared by killing its boss and region N+1 is sealed until N is
# cleared (see tools/reachtest.gd), so "where is it" is not a convenience
# question — it is the only question the player has to answer to keep playing.
# Until now the answer was the opening flyover and then nothing: a 400 m lane
# with nine packs on it (Terrain.gd's measurements), seen once, from a camera
# that then returns to a three-metre bubble around the champion's feet.
#
# So: a small map in the top right, with the walkable ground as a silhouette,
# the champion on it, the way in, and THE BOSS — which is the objective marker
# and the reason the rest of it is drawn at all.
#
# ------------------------------------------------------------------------------
# WHY THIS IS A TEXTURE AND NOT A POLYGON SOUP.
#
# The walk mask is up to 448x448 = 200,704 cells and this ships on a phone. A
# minimap that re-reads that mask in _draw() costs the whole frame: GDScript
# indexing of a PackedByteArray goes through Variant machinery per element, and
# 200k of those at 60 Hz is not a feature, it is a hang.
#
# WHAT IT COSTS, measured on an M2 by tools/minimaptest.gd (and re-runnable —
# MINIMAP_BIG=1 does the worst case):
#
#   96x96 arena, 9,216 cells, 81% walkable    ->  96x96 px   in 1.8 ms
#   448x448 lane, 200,704 cells, 28% walkable -> 112x112 px  in 6.9 ms
#
# ONCE, at configure(), next to a terrain build that costs 240 ms for the small
# region and seconds for the large one — so it is not in the frame budget at all.
# The big case is only 4x the small one rather than 22x because a block stops
# scanning at its first walkable cell, and most blocks on a lane are empty.
#
# Per FRAME the cost is one draw_texture_rect plus about six primitives for the
# dots, and `set_player()` does not even queue a redraw until the champion has
# moved half a minimap pixel.
#
# The silhouette is downsampled to at most MASK_MAX px per side by ANY-WALKABLE
# IN BLOCK rather than by point sampling. Point sampling is the obvious version
# and it erases the game: a lane corridor is 5 m of carved ground, which at
# cell 0.5 is ten cells, and a nearest-neighbour downsample of a thin diagonal
# corridor drops pixels until the route reads as a dotted line with gaps. Taking
# the max keeps the route connected, which is the entire point of showing it.
#
# ------------------------------------------------------------------------------
# OPTIONAL BY CONSTRUCTION.
#
# Nothing is drawn and nothing is read until configure() is called with a real
# Terrain, and configure(null, ...) is a no-op rather than an error. Play.tscn is
# launched standalone by several tools/ harnesses with no world at all, and a HUD
# element that hard-faults without one takes those harnesses with it.
#
# NOT REFERENCED BY `class_name`, deliberately: a new class_name is invisible
# until the Godot editor rebuilds its global cache, and every consumer that names
# it then fails to PARSE. Consumers preload it by path:
#
#     const MiniMapS := preload("res://scripts/ui/MiniMap.gd")
# ------------------------------------------------------------------------------

## The drawn square, in viewport pixels. The viewport is 2532x1170 (an iPhone at
## 3x, landscape — see project.godot), so this is about 16% of the screen height.
##
## IT IS BOUNDED, not chosen. The right-hand side of the screen is already spoken
## for twice: UiShell's "Menu" and "Inventory" occupy y 80..212, and the HUD's
## thumb arc puts an ability key's rim at y 468 (a 118 px circle 360 px above a
## basic-attack key that sits 224 px off the bottom). That leaves a 236 px band
## at 232..468 for this panel, and a first pass at 300 px drew the map straight
## through the top of the "up" ability key. tools/minimaptest.gd asserts both
## clearances against the shipping viewport, because a headless run has a 0x0
## root viewport and would never show it.
const MAP: float = 192.0
## Padding between the panel border and the silhouette.
const FRAME: float = 10.0
## Longest side of the rasterised mask. 128 px is already more than twice the
## drawn resolution of the panel on a 3x screen; going finer buys nothing a thumb
## can see and costs rasterise time linearly.
const MASK_MAX: int = 128

## Where the shell's own buttons end. UiShell parks "Menu" and "Inventory" in the
## top right at y = 80..80+TAP, and the HUD's health plate is top LEFT precisely
## because two panels fighting over that corner is how a player quits the region
## by accident. The map goes UNDER that row, not into it.
const SHELL_ROW_BOTTOM: float = 80.0 + HeroTheme.TAP
## Right edge, matching the shell buttons' own -40 so the map lines up with them.
const RIGHT_EDGE: float = 40.0

const BG: Color = Color(0.043, 0.043, 0.078, 0.78)      # HeroTheme.BG, lifted off
const GROUND: Color = Color(0.36, 0.40, 0.50, 0.85)
const BOSS_COL: Color = HeroTheme.DANGER
const ENTRY_COL: Color = HeroTheme.GOLD
const PLAYER_COL: Color = HeroTheme.ACCENT

## How many times the mask has been rasterised. DIAGNOSTIC, and the only honest
## way to assert "once": a per-frame rasterise is a performance bug that looks
## exactly like a correct minimap until the device thermals. tools/minimaptest.gd
## asserts this stays at 1 across a hundred position updates.
var rasterised: int = 0

var _mask: ImageTexture = null
## Cells the mask spans per side — w * step, which is >= terrain.size when the
## block size does not divide it evenly. Markers normalise against THIS and not
## against terrain.size, or the dots drift off the silhouette by up to a block.
var _span_cells: float = 0.0
var _cell: float = 1.0
var _half: float = 0.0

var _player: Vector2 = Vector2.INF
var _boss: Vector2 = Vector2.INF
var _entry: Vector2 = Vector2.INF
## Normalised player position at the last repaint, so a champion that has not
## moved a visible distance does not dirty the canvas item.
var _painted: Vector2 = Vector2.INF


func _ready() -> void:
	# A PICTURE, NOT A BUTTON. A Control in the corner with the default mouse
	# filter swallows every tap that lands on it, and a swallowed tap in this game
	# is a champion that will not walk — the same bug Hud.gd documents at length.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var inset: Dictionary = _insets()
	var r: Rect2 = frame_rect(get_viewport().get_visible_rect().size,
		float(inset["right"]), float(inset["top"]))
	position = r.position
	size = r.size


## The device's insets, from UiShell — the one place that computes them. In
## landscape the cut-out is on a SIDE, which is exactly where this panel lives.
func _insets() -> Dictionary:
	return UiShell.safe_margins(DisplayServer.window_get_size(),
		DisplayServer.get_display_safe_area(),
		get_viewport().get_visible_rect().size)


## Where the panel goes, as pure geometry, for a given viewport and insets.
##
## STATIC AND PURE so it can be checked against the SHIPPING viewport rather than
## against whatever a harness happens to run at — a `--script` run gets a 0x0
## root viewport, so a layout asserted only on live nodes proves nothing about the
## phone. tools/minimaptest.gd evaluates this for the real screen and for the
## shell buttons it must not collide with.
static func frame_rect(view: Vector2, right_inset: float,
		top_inset: float) -> Rect2:
	var side: float = MAP + FRAME * 2.0
	var top: float = maxf(top_inset, SHELL_ROW_BOTTOM) + float(HeroTheme.GAP)
	return Rect2(Vector2(view.x - maxf(right_inset, RIGHT_EDGE) - side, top),
		Vector2(side, side))


# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

## Hand the map the world it is describing. Call it when the world arrives; the
## mask is rasterised HERE, once, and never again.
##
## `terrain` null clears the map and draws nothing, which is what keeps a scene
## with no world from breaking. `plan` null is also fine — the silhouette still
## draws, there are simply no markers to put on it.
func configure(terrain: Terrain, plan: Layout) -> void:
	_mask = null
	_boss = Vector2.INF
	_entry = Vector2.INF
	_painted = Vector2.INF
	if terrain == null or terrain.size <= 0 \
			or terrain.walk.size() != terrain.size * terrain.size:
		queue_redraw()
		return

	_cell = terrain.cell
	_half = float(terrain.size) * terrain.cell * 0.5
	_rasterise(terrain)

	if plan != null:
		var boss: Dictionary = plan.node_of_kind(Layout.BOSS)
		if not boss.is_empty():
			_boss = boss.get("pos", Vector2.INF)
		var entry: Dictionary = plan.node_of_kind(Layout.ENTRY)
		if not entry.is_empty():
			_entry = entry.get("pos", Vector2.INF)
	queue_redraw()


## Is there a world on the map? False before configure() and after a null one.
func active() -> bool:
	return _mask != null


## The silhouette, for tests and for anyone who wants to draw it bigger.
func mask_texture() -> ImageTexture:
	return _mask


func _rasterise(t: Terrain) -> void:
	var step: int = maxi(int(ceil(float(t.size) / float(MASK_MAX))), 1)
	var w: int = int(ceil(float(t.size) / float(step)))
	_span_cells = float(w * step)

	# resize() zero-fills, so every pixel starts fully transparent and only
	# walkable blocks are written. One pass, no clear.
	var px := PackedByteArray()
	px.resize(w * w * 4)
	var r: int = int(GROUND.r * 255.0)
	var g: int = int(GROUND.g * 255.0)
	var b: int = int(GROUND.b * 255.0)
	var a: int = int(GROUND.a * 255.0)

	var walk: PackedByteArray = t.walk
	var sz: int = t.size
	for by in range(w):
		var y0: int = by * step
		var y1: int = mini(y0 + step, sz)
		for bx in range(w):
			var x0: int = bx * step
			var x1: int = mini(x0 + step, sz)
			var open: bool = false
			for y in range(y0, y1):
				var row: int = y * sz
				for x in range(x0, x1):
					if walk[row + x] == 1:
						open = true
						break
				if open:
					break
			if not open:
				continue
			var o: int = (by * w + bx) * 4
			px[o] = r
			px[o + 1] = g
			px[o + 2] = b
			px[o + 3] = a

	_mask = ImageTexture.create_from_image(
		Image.create_from_data(w, w, false, Image.FORMAT_RGBA8, px))
	rasterised += 1


# ------------------------------------------------------------------------------
# Per-frame state
# ------------------------------------------------------------------------------

## Where the champion is, in world XZ — the same space Layout node positions are
## in. Cheap enough to call every frame: it stores the position and repaints only
## when the dot would actually land on a different pixel.
func set_player(world: Vector2) -> void:
	_player = world
	if _mask == null:
		return
	var n: Vector2 = norm_of(world)
	if n == Vector2.INF:
		return
	# Half a drawn pixel. Below that the repaint is invisible and a canvas item
	# redrawn every frame for nothing is the cost this whole file exists to avoid.
	if _painted != Vector2.INF \
			and (n - _painted).length() * maxf(size.x, 1.0) < 0.5:
		return
	queue_redraw()


# ------------------------------------------------------------------------------
# Geometry
# ------------------------------------------------------------------------------

## A world XZ point as 0..1 across the mask, y running with +Z. Vector2.INF when
## there is no world. Clamped, so a champion standing on the rim still has a dot
## on the map rather than one drawn outside the panel.
func norm_of(world: Vector2) -> Vector2:
	if _mask == null or _span_cells <= 0.0:
		return Vector2.INF
	return Vector2(
		clampf((world.x + _half) / _cell / _span_cells, 0.0, 1.0),
		clampf((world.y + _half) / _cell / _span_cells, 0.0, 1.0))


## The square the silhouette is drawn in, in this Control's local space. Exposed
## so an off-screen arrow can be clipped to the same edge the map uses.
func map_rect() -> Rect2:
	var side: float = maxf(minf(size.x, size.y) - FRAME * 2.0, 1.0)
	return Rect2(Vector2(FRAME, FRAME), Vector2(side, side))


## A world point in this Control's local pixels, or Vector2.INF.
func screen_of(world: Vector2) -> Vector2:
	var n: Vector2 = norm_of(world)
	if n == Vector2.INF:
		return Vector2.INF
	var r: Rect2 = map_rect()
	return r.position + n * r.size


func player_norm() -> Vector2:
	return norm_of(_player) if _player != Vector2.INF else Vector2.INF


func boss_norm() -> Vector2:
	return norm_of(_boss) if _boss != Vector2.INF else Vector2.INF


func entry_norm() -> Vector2:
	return norm_of(_entry) if _entry != Vector2.INF else Vector2.INF


## WHICH WAY IS THE BOSS, in radians, measured in world XZ from +X toward +Z —
## the same convention as atan2(dz, dx), because that is the space Layout nodes
## and HeroController positions are already in.
##
## Exposed ahead of the off-screen arrow that will use it, and deliberately NOT
## camera-relative: the camera orbits, so composing this with the camera's yaw is
## the caller's job. Baking a camera in here would give the arrow a second,
## disagreeing idea of where north is.
##
## INF when there is no boss or the player has not been placed yet — the same
## "no answer" sentinel the HUD uses for an unprojectable point, so a caller that
## forgets to check draws nothing rather than pointing at the origin.
func bearing_to_boss() -> float:
	if _boss == Vector2.INF or _player == Vector2.INF:
		return INF
	var d: Vector2 = _boss - _player
	if d.length_squared() < 0.000001:
		return INF
	return atan2(d.y, d.x)


## Metres from the champion to the boss, or INF. Paired with the bearing because
## an arrow without a distance tells the player a direction they already walked.
func metres_to_boss() -> float:
	if _boss == Vector2.INF or _player == Vector2.INF:
		return INF
	return _player.distance_to(_boss)


# ------------------------------------------------------------------------------
# Draw
# ------------------------------------------------------------------------------

## Every primitive this panel would draw, as data, in paint order.
##
## SPLIT OUT OF _draw() SO IT CAN BE ASSERTED. Under `--headless` there is no
## rasteriser, so nothing can read back what a draw_*() call did — which meant
## every visual claim about this panel was unasserted, and an adversarial review
## proved it the obvious way: replacing the body of _draw() with `return`
## deleted the panel, the silhouette, the entry ring, the boss diamond, the halo,
## the player dot and the chevron, and tools/minimaptest.gd still reported
## "0 failure(s)" on all of it.
##
## `_draw()` below is now nothing but a renderer for this list, and it records
## how many primitives it emitted (see `painted`), so gutting either half fails.
func draw_plan() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _mask == null:
		return out                            # no world: no panel, no border

	var r: Rect2 = map_rect()
	out.append({"op": "panel", "rect": Rect2(Vector2.ZERO, size), "colour": BG})
	out.append({"op": "border", "rect": Rect2(Vector2.ZERO, size),
		"colour": HeroTheme.LINE, "width": 2.0})
	# ONE texture blit for 200,704 cells of walk mask. This is the line the whole
	# file is arranged around.
	out.append({"op": "mask", "rect": r})

	# Marker scale. A fraction of the panel rather than a pixel count, so the
	# whole thing survives being drawn at another size — but a generous fraction:
	# at 3x, a 5 px dot is under 2 pt on the glass and simply is not there.
	var mark: float = r.size.x * 0.048

	if _entry != Vector2.INF:
		# A ring rather than a disc: the way in matters once, and it must not read
		# as loud as the two things that move or kill you.
		out.append({"op": "entry", "at": screen_of(_entry), "r": mark * 0.9,
			"colour": ENTRY_COL, "width": 3.0})

	if _boss != Vector2.INF:
		var b: Vector2 = screen_of(_boss)
		# A DIAMOND, not a bigger dot. Colour alone does not survive a molten
		# biome's orange wash, and this is the one marker the player is hunting
		# for, so it is a different SHAPE from everything else on the panel.
		var d: float = mark * 1.6
		out.append({"op": "boss", "at": b, "r": d, "colour": BOSS_COL,
			"points": PackedVector2Array([
				b + Vector2(0.0, -d), b + Vector2(d, 0.0),
				b + Vector2(0.0, d), b + Vector2(-d, 0.0)])})
		out.append({"op": "boss_halo", "at": b, "r": d * 1.5, "width": 2.0,
			"colour": Color(BOSS_COL.r, BOSS_COL.g, BOSS_COL.b, 0.45)})

	if _player != Vector2.INF:
		var p: Vector2 = screen_of(_player)
		# Drawn LAST so the champion is never hidden under a marker, and with a
		# dark backing ring so the dot is still findable where the silhouette
		# happens to be the same brightness as the accent green.
		out.append({"op": "player_backing", "at": p, "r": mark * 1.25,
			"colour": Color(0.02, 0.02, 0.05, 0.9)})
		out.append({"op": "player", "at": p, "r": mark, "colour": PLAYER_COL})
		# A chevron off the dot toward the boss. The bearing is already computed
		# for the future off-screen arrow; on the panel it answers "which way do I
		# set off" without the player having to find a red diamond first.
		if _boss != Vector2.INF:
			var to: Vector2 = screen_of(_boss) - p
			if to.length() > mark * 2.0:
				var u: Vector2 = to.normalized()
				var side: Vector2 = Vector2(-u.y, u.x)
				var tip: Vector2 = p + u * mark * 3.2
				out.append({"op": "chevron", "at": p,
					"colour": Color(BOSS_COL.r, BOSS_COL.g, BOSS_COL.b, 0.85),
					"points": PackedVector2Array([
						tip, p + u * mark * 1.7 + side * mark * 0.9,
						p + u * mark * 1.7 - side * mark * 0.9])})
	return out


## How many primitives the last _draw() actually emitted. DIAGNOSTIC, and the
## only thing that can tell a headless harness the renderer still runs: a
## draw_plan() full of shapes nobody paints looks identical from here otherwise.
var painted: int = 0


func _draw() -> void:
	var plan: Array[Dictionary] = draw_plan()
	painted = 0
	for d in plan:
		match String(d["op"]):
			"panel":
				draw_rect(d["rect"], d["colour"], true)
			"border":
				draw_rect(d["rect"], d["colour"], false, float(d["width"]))
			"mask":
				draw_texture_rect(_mask, d["rect"], false)
			"entry", "boss_halo":
				draw_arc(d["at"], float(d["r"]), 0.0, TAU, 20, d["colour"],
					float(d["width"]), true)
			"boss", "chevron":
				draw_colored_polygon(d["points"], d["colour"])
			"player", "player_backing":
				draw_circle(d["at"], float(d["r"]), d["colour"])
			_:
				continue
		painted += 1
	if _player != Vector2.INF and _mask != null:
		_painted = norm_of(_player)
