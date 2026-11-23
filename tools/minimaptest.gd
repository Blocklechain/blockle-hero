extends SceneTree
# ------------------------------------------------------------------------------
# THE MINIMAP HAS TO BE RIGHT ABOUT WHERE THE BOSS IS.
#
# A map that is merely drawn is worse than none: the player trusts it, walks the
# wrong way across the region, and concludes the boss is missing. So every
# assertion here is made against a REAL GENERATED REGION — Terrain.plan_for plus
# Terrain.generate, the same pair tools/reachtest.gd uses — and against the
# marker positions the panel would actually paint, never against its inputs.
#
# WHAT IS CHECKED, and the failure each one catches:
#
#   1. the silhouette is rasterised ONCE, at configure(), and a hundred position
#      updates do not rebuild it. A per-frame rasterise of a 200k-cell walk mask
#      looks identical on screen and costs the whole frame; "is it fast" is not
#      something an eye can check, so it is asserted as a count AND as texture
#      identity.
#   2. the silhouette IS the walk mask — a known walkable cell is opaque, the
#      corners (which the terrain pass always blocks) are not, and the opaque
#      area covers the walkable area. A blank or stale image passes every other
#      test in this file.
#   3. the boss marker's normalised position matches the boss NODE's world
#      position, computed independently here from size x cell. This is the
#      assertion the player's whole route depends on.
#   4. the player dot tracks a moved champion, in normalised AND in panel pixels,
#      and clamps rather than being drawn outside the panel at the rim.
#   5. bearing_to_boss() agrees with an independent atan2, and answers INF rather
#      than 0 when there is nothing to point at — an arrow that defaults to the
#      origin points confidently at the middle of the map.
#   6. configure(null, plan) is a NO-OP. Play.tscn is launched standalone by
#      several harnesses with no world at all; a HUD element that faults without
#      one takes them all with it.
#   7. the panel does not land under UiShell's "Menu" / "Inventory" buttons or the
#      HUD's thumb arc at the SHIPPING viewport. A `--script` run has a 0x0 root
#      viewport, so this goes through the static geometry function — and it is not
#      hypothetical: the first pass at 300 px drew straight through an ability key.
#
# SECTIONS ARE COUNTED. A runtime error aborts the function it happens in and
# GDScript carries on to the next, so a crash would otherwise be reported as zero
# failures — the section tally is what turns that into a FAIL.
#
#   /opt/homebrew/bin/godot --headless --path . --script tools/minimaptest.gd
# ------------------------------------------------------------------------------

## Preloaded BY PATH. A new class_name is invisible until the editor rebuilds its
## global cache, and every consumer that names it then fails to parse.
const MiniMapS := preload("res://scripts/ui/MiniMap.gd")

## Small enough that a full terrain build is about a second, big enough that the
## mask is a real silhouette with a real route through it. `cell` matches the
## game's, so the metres-per-cell arithmetic under test is the shipping one.
const CELLS: int = 96
const CELL: float = 0.5
const SEED: int = 20261119

## project.godot's viewport — an iPhone at 3x, held landscape.
const SHIP_VIEW: Vector2 = Vector2(2532.0, 1170.0)

## Every section that must run to completion.
const SECTIONS: int = 9

var fails: int = 0
var done: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-56s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	var extent := Vector2(CELLS, CELLS) * CELL
	var plan: Layout = Terrain.plan_for(Terrain.Kind.ARENA, SEED, extent,
		Layout.Sym.ASYMMETRIC, 9)
	var t0: int = Time.get_ticks_usec()
	var ter: Terrain = Terrain.generate(SEED, "greenwood", CELLS, CELL, plan)
	print("\n%d x %d region, %.0f m across, %.0f%% walkable, built in %d ms"
		% [CELLS, CELLS, float(CELLS) * CELL, ter.walkable_fraction() * 100.0,
			(Time.get_ticks_usec() - t0) / 1000])

	_rasterised_once(ter, plan)
	_silhouette_is_the_mask(ter, plan)
	_boss_marker(ter, plan)
	_player_dot(ter, plan)
	_bearing(ter, plan)
	_no_world(plan)
	_clears_the_shell()
	_biggest_region()
	await _it_actually_draws(ter, plan)
	_it_is_wired_into_play()

	check("every section ran to completion", done == SECTIONS,
		"%d of %d" % [done, SECTIONS])
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


## The side of the laid-out panel, so the pixel assertions use the real geometry
## rather than a round number.
func _side() -> float:
	return MiniMapS.MAP + MiniMapS.FRAME * 2.0


# ------------------------------------------------------------------------------
# 1. Once, and only once
# ------------------------------------------------------------------------------

func _rasterised_once(ter: Terrain, plan: Layout) -> void:
	print("\n=== the mask is rasterised once ===")
	var m := MiniMapS.new()
	check("nothing is rasterised before configure()", m.rasterised == 0
		and not m.active() and m.mask_texture() == null)

	var t0: int = Time.get_ticks_usec()
	m.configure(ter, plan)
	var cost_us: int = Time.get_ticks_usec() - t0
	check("configure() builds the silhouette", m.active() and m.rasterised == 1,
		"%d cells in %.1f ms" % [CELLS * CELLS, float(cost_us) / 1000.0])

	var tex: ImageTexture = m.mask_texture()
	check("the silhouette has a non-zero size", tex != null
		and tex.get_width() > 0 and tex.get_height() > 0,
		"%d x %d px" % [tex.get_width() if tex != null else 0,
			tex.get_height() if tex != null else 0])
	if tex == null:
		return
	check("the silhouette is capped, not one pixel per cell",
		tex.get_width() <= MiniMapS.MASK_MAX, "cap %d px" % MiniMapS.MASK_MAX)

	# THE PERFORMANCE ASSERTION, as an effect rather than as a stopwatch: move the
	# champion a hundred times and the mask must still be the same object, never
	# rebuilt and never re-read.
	var id_before: int = tex.get_instance_id()
	m.size = Vector2(_side(), _side())
	var half: float = float(CELLS) * CELL * 0.5
	for i in range(100):
		var k: float = float(i) / 99.0
		m.set_player(Vector2(lerpf(-half, half, k), lerpf(half, -half, k)))
	check("100 position updates do not rebuild the mask", m.rasterised == 1
		and m.mask_texture() != null
		and m.mask_texture().get_instance_id() == id_before,
		"rasterised %d time(s)" % m.rasterised)

	# A SECOND WORLD does rasterise again — the claim is "once per world", not
	# "once per process", and a region change has to replace the map.
	m.configure(ter, plan)
	check("a new world rasterises again", m.rasterised == 2)
	done += 1


# ------------------------------------------------------------------------------
# 2. The silhouette is the walk mask
# ------------------------------------------------------------------------------

func _silhouette_is_the_mask(ter: Terrain, plan: Layout) -> void:
	print("\n=== the silhouette is the walk mask ===")
	var m := MiniMapS.new()
	m.size = Vector2(_side(), _side())
	m.configure(ter, plan)
	var img: Image = m.mask_texture().get_image()
	var w: int = img.get_width()

	var opaque: int = 0
	for y in range(w):
		for x in range(w):
			if img.get_pixel(x, y).a > 0.01:
				opaque += 1
	var frac: float = float(opaque) / float(w * w)
	var walk_frac: float = ter.walkable_fraction()

	check("the silhouette is not blank", opaque > 0,
		"%.1f%% of %d px opaque" % [frac * 100.0, w * w])
	# Block-max downsampling marks a block open if ANY cell in it is, so the drawn
	# area is a superset of the walkable area. A silhouette SMALLER than the mask
	# means cells were dropped, which is the dotted-corridor failure.
	check("the drawn area covers the walkable area", frac >= walk_frac - 0.01,
		"%.1f%% drawn vs %.1f%% walkable" % [frac * 100.0, walk_frac * 100.0])
	check("the silhouette is not simply filled in", frac < 0.995)

	# A CELL THE TERRAIN SAYS IS WALKABLE MUST BE PAINTED. Taken from the mask
	# itself rather than guessed, so this cannot pass by luck.
	var hit := Vector2i(-1, -1)
	for y in range(CELLS):
		for x in range(CELLS):
			if ter.walk[y * CELLS + x] == 1:
				hit = Vector2i(x, y)
				break
		if hit.x >= 0:
			break
	var painted: bool = false
	if hit.x >= 0:
		var n: Vector2 = m.norm_of(ter.pos_of(hit.x, hit.y))
		var px: int = clampi(int(n.x * float(w)), 0, w - 1)
		var py: int = clampi(int(n.y * float(w)), 0, w - 1)
		painted = img.get_pixel(px, py).a > 0.01
	check("a walkable cell lands on an opaque pixel", painted,
		"cell %s" % str(hit))

	# The terrain pass blocks a two-cell hard border on every edge, so the four
	# corners can never be walkable. Painted corners mean the mask was built from
	# the wrong array, or with the wrong stride.
	check("the blocked border is not painted",
		img.get_pixel(0, 0).a <= 0.01 and img.get_pixel(w - 1, 0).a <= 0.01
			and img.get_pixel(0, w - 1).a <= 0.01
			and img.get_pixel(w - 1, w - 1).a <= 0.01)
	done += 1


# ------------------------------------------------------------------------------
# 3. The objective marker
# ------------------------------------------------------------------------------

func _boss_marker(ter: Terrain, plan: Layout) -> void:
	print("\n=== the boss marker ===")
	var m := MiniMapS.new()
	m.size = Vector2(_side(), _side())
	m.configure(ter, plan)

	var boss: Dictionary = plan.node_of_kind(Layout.BOSS)
	check("the plan has a boss to mark", not boss.is_empty())
	if boss.is_empty():
		return

	var at: Vector2 = boss.get("pos", Vector2.ZERO)
	# INDEPENDENT ARITHMETIC. The region is centred on the origin and spans
	# size * cell metres, so a world point's normalised place on the map is its
	# offset from the lower corner over that span. Worked out here from `size` and
	# `cell`, not from anything the panel exposes.
	var span: float = float(CELLS) * CELL
	var want := Vector2((at.x + span * 0.5) / span, (at.y + span * 0.5) / span)
	var got: Vector2 = m.boss_norm()
	# Half a mask pixel. The silhouette is quantised into blocks and the markers
	# are normalised against that same block grid, so agreement finer than half a
	# pixel is not a claim this file should be making.
	var tol: float = 0.5 / float(m.mask_texture().get_width())
	check("the boss marker matches the boss node's world position",
		got != Vector2.INF and (got - want).length() <= tol,
		"want %.4f,%.4f got %.4f,%.4f (tol %.4f)"
			% [want.x, want.y, got.x, got.y, tol])
	# And it is somewhere the player can see it, rather than pinned to an edge by
	# a mapping that lost the half-extent.
	check("the boss marker is inside the map", got.x > 0.02 and got.x < 0.98
		and got.y > 0.02 and got.y < 0.98)

	var entry: Dictionary = plan.node_of_kind(Layout.ENTRY)
	var e_at: Vector2 = entry.get("pos", Vector2.ZERO)
	var e_want := Vector2((e_at.x + span * 0.5) / span,
		(e_at.y + span * 0.5) / span)
	var e_got: Vector2 = m.entry_norm()
	check("the entry marker matches the entry node", not entry.is_empty()
		and e_got != Vector2.INF and (e_got - e_want).length() <= tol,
		"want %.4f,%.4f got %.4f,%.4f" % [e_want.x, e_want.y, e_got.x, e_got.y])
	# They must not be the same dot, or the map cannot tell the player which way
	# to set off — which is the complaint this feature answers.
	check("the entry and the boss are different places on the map",
		(e_got - got).length() > 0.1,
		"%.2f apart, normalised" % (e_got - got).length())

	# A WORLD WITH NO PLAN IS NOT AN ERROR. The ground still draws; there is
	# simply nothing to point at.
	var bare := MiniMapS.new()
	bare.configure(ter, null)
	check("a world with no plan still draws, with no markers", bare.active()
		and bare.boss_norm() == Vector2.INF
		and bare.entry_norm() == Vector2.INF)
	done += 1


# ------------------------------------------------------------------------------
# 4. The player dot
# ------------------------------------------------------------------------------

func _player_dot(ter: Terrain, plan: Layout) -> void:
	print("\n=== the player dot tracks the champion ===")
	var m := MiniMapS.new()
	m.size = Vector2(_side(), _side())
	m.configure(ter, plan)
	var span: float = float(CELLS) * CELL
	var tol: float = 0.5 / float(m.mask_texture().get_width())

	check("there is no dot before the champion is placed",
		m.player_norm() == Vector2.INF)

	var a := Vector2(-span * 0.25, span * 0.10)
	m.set_player(a)
	var want_a := Vector2((a.x + span * 0.5) / span, (a.y + span * 0.5) / span)
	var got_a: Vector2 = m.player_norm()
	check("the dot lands where the champion stands", got_a != Vector2.INF
		and (got_a - want_a).length() <= tol,
		"want %.4f,%.4f got %.4f,%.4f" % [want_a.x, want_a.y, got_a.x, got_a.y])

	var b := Vector2(span * 0.30, -span * 0.35)
	m.set_player(b)
	var want_b := Vector2((b.x + span * 0.5) / span, (b.y + span * 0.5) / span)
	var got_b: Vector2 = m.player_norm()
	check("the dot MOVED when the champion did",
		(got_b - want_b).length() <= tol and (got_b - got_a).length() > 0.2,
		"%.3f of the map travelled" % (got_b - got_a).length())

	# The PIXEL positions move too, not only the normalised pair: a panel that
	# stores the position and never maps it is the same bug one layer down.
	var sa: Vector2 = m.screen_of(a)
	var sb: Vector2 = m.screen_of(b)
	var r: Rect2 = m.map_rect()
	check("both positions fall inside the drawn square",
		r.has_point(sa) and r.has_point(sb),
		"%s and %s in %s" % [str(sa.round()), str(sb.round()), str(r)])
	check("the drawn positions move the same way the champion did",
		signf(sb.x - sa.x) == signf(b.x - a.x)
			and signf(sb.y - sa.y) == signf(b.y - a.y))

	# OUT OF BOUNDS IS CLAMPED, NOT DRAWN OUTSIDE THE PANEL. The rim is
	# unwalkable, but the flyover camera and a knockback can both hand over a
	# position past it.
	m.set_player(Vector2(span * 4.0, -span * 4.0))
	check("a position outside the region clamps onto the panel",
		m.player_norm() == Vector2(1.0, 0.0), str(m.player_norm()))
	done += 1


# ------------------------------------------------------------------------------
# 5. The bearing the off-screen arrow will use
# ------------------------------------------------------------------------------

func _bearing(ter: Terrain, plan: Layout) -> void:
	print("\n=== bearing_to_boss ===")
	var m := MiniMapS.new()
	m.size = Vector2(_side(), _side())
	m.configure(ter, plan)
	var boss: Vector2 = plan.node_of_kind(Layout.BOSS).get("pos", Vector2.ZERO)
	var entry: Vector2 = plan.node_of_kind(Layout.ENTRY).get("pos", Vector2.ZERO)

	check("no champion, no bearing",
		m.bearing_to_boss() == INF and m.metres_to_boss() == INF)

	m.set_player(entry)
	var want: float = atan2(boss.y - entry.y, boss.x - entry.x)
	check("the bearing is the world-space angle to the boss",
		absf(angle_difference(m.bearing_to_boss(), want)) < 0.0001,
		"%.1f deg" % rad_to_deg(m.bearing_to_boss()))
	check("the distance is the world-space distance",
		absf(m.metres_to_boss() - entry.distance_to(boss)) < 0.001,
		"%.1f m" % m.metres_to_boss())

	# Walking must swing the bearing, or an arrow built on it would point the same
	# way for the whole region.
	var aside: Vector2 = entry + (boss - entry) * 0.5 \
		+ (boss - entry).orthogonal().normalized() * 8.0
	m.set_player(aside)
	check("the bearing follows the champion",
		absf(angle_difference(m.bearing_to_boss(), want)) > 0.02,
		"%.1f deg, from the entry's %.1f deg"
			% [rad_to_deg(m.bearing_to_boss()), rad_to_deg(want)])

	# STANDING ON IT IS NOT A DIRECTION. atan2(0, 0) is 0.0, which would point an
	# arrow confidently along +X at the moment the player has arrived.
	m.set_player(boss)
	check("standing on the boss answers INF rather than 0",
		m.bearing_to_boss() == INF, "%.1f m away" % m.metres_to_boss())
	done += 1


# ------------------------------------------------------------------------------
# 6. No world, no crash
# ------------------------------------------------------------------------------

func _no_world(plan: Layout) -> void:
	print("\n=== configure(null) is a no-op ===")
	var m := MiniMapS.new()
	m.size = Vector2(_side(), _side())
	m.configure(null, plan)
	check("a null terrain leaves the map inactive",
		not m.active() and m.mask_texture() == null)
	check("a null terrain draws no markers", m.boss_norm() == Vector2.INF
		and m.entry_norm() == Vector2.INF and m.player_norm() == Vector2.INF)
	check("norm_of() answers INF rather than dividing by zero",
		m.norm_of(Vector2(12.0, -7.0)) == Vector2.INF
			and m.screen_of(Vector2(12.0, -7.0)) == Vector2.INF)

	# The per-frame calls a consumer makes unconditionally all have to survive it.
	m.set_player(Vector2(3.0, 4.0))
	check("set_player() on an unconfigured map is harmless",
		not m.active() and m.rasterised == 0)
	check("bearing_to_boss() on an unconfigured map is INF",
		m.bearing_to_boss() == INF and m.metres_to_boss() == INF)

	# A terrain whose mask was never built is the same situation arriving by a
	# different route: a world that failed to generate. Indexing its empty `walk`
	# would be the crash.
	var empty := Terrain.new()
	empty.size = 64
	var m2 := MiniMapS.new()
	m2.configure(empty, plan)
	check("a terrain with no walk mask is refused, not indexed",
		not m2.active() and m2.rasterised == 0)
	done += 1


# ------------------------------------------------------------------------------
# 7. It does not sit under anything else on the glass
# ------------------------------------------------------------------------------

func _clears_the_shell() -> void:
	print("\n=== the panel clears the shell, at the shipping viewport ===")
	# UiShell's "Menu" and "Inventory", verbatim from UiShell.gd: anchored top
	# right, offset_left -300 / -640, offset_right -40 / -320, y 80..80+TAP.
	var menu := Rect2(SHIP_VIEW.x - 300.0, 80.0, 260.0, float(HeroTheme.TAP))
	var bag := Rect2(SHIP_VIEW.x - 640.0, 80.0, 320.0, float(HeroTheme.TAP))

	# The insets a phone with no cut-out reports, and a generous one that has.
	for inset in [Vector2(UiShell.MIN_INSET, UiShell.MIN_INSET),
			Vector2(132.0, 48.0)]:
		var pos: Vector2 = inset
		var r: Rect2 = MiniMapS.frame_rect(SHIP_VIEW, pos.x, pos.y)
		var tag: String = "inset %.0f,%.0f" % [pos.x, pos.y]
		check("below the shell's button row (%s)" % tag,
			not r.intersects(menu) and not r.intersects(bag), "panel %s" % str(r))
		check("fully on screen (%s)" % tag, r.position.x >= 0.0
			and r.position.y >= 0.0 and r.end.x <= SHIP_VIEW.x
			and r.end.y <= SHIP_VIEW.y,
			"ends %.0f,%.0f of %.0f,%.0f"
				% [r.end.x, r.end.y, SHIP_VIEW.x, SHIP_VIEW.y])
		check("clear of the reported cut-out (%s)" % tag,
			r.end.x <= SHIP_VIEW.x - pos.x + 0.01)

	# AND CLEAR OF THE THUMB ARC. Hud's basic attack is a 150 px circle in the
	# bottom right with three 118 px abilities arcing 360 px off it, and the one
	# straight above it reaches up to y 468 — which a 300 px panel overlapped.
	var r2: Rect2 = MiniMapS.frame_rect(SHIP_VIEW, UiShell.MIN_INSET,
		UiShell.MIN_INSET)
	var clear: bool = true
	var nearest: float = 1e9
	for spec in Hud.key_layout(SHIP_VIEW, UiShell.MIN_INSET, UiShell.MIN_INSET):
		var c: Vector2 = spec["centre"]
		var rad: float = float(spec["radius"])
		if r2.grow(rad).has_point(c):
			clear = false
		nearest = minf(nearest, c.y - rad - r2.end.y)
	check("clear of the HUD's four ability keys", clear,
		"panel %s, %.0f px to the nearest key rim" % [str(r2), nearest])
	done += 1


# ------------------------------------------------------------------------------
# The worst case, on demand
# ------------------------------------------------------------------------------

## The 448-cell LANE — the largest map and the thinnest silhouette, which is the
## pair that stresses both the rasterise cost and the block downsample. OPT-IN,
## because it is one more full terrain build (seconds, not milliseconds) and the
## assertions above do not need it:
##
##   MINIMAP_BIG=1 godot --headless --path . --script tools/minimaptest.gd
##
## It prints no PASS lines and counts no section — it is the measurement the cost
## comment in MiniMap.gd quotes, kept runnable so that number can be re-checked
## rather than trusted.
func _biggest_region() -> void:
	if OS.get_environment("MINIMAP_BIG") == "":
		return
	print("\n=== the worst case: a 448-cell lane ===")
	var cells: int = 448
	var plan: Layout = Terrain.plan_for(Terrain.Kind.LANE, SEED,
		Vector2(cells, cells) * CELL)
	var ter: Terrain = Terrain.generate(SEED, "greenwood", cells, CELL, plan)
	var m := MiniMapS.new()
	var t0: int = Time.get_ticks_usec()
	m.configure(ter, plan)
	var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	var tex: ImageTexture = m.mask_texture()
	print("  %d cells (%.0f%% walkable) rasterised to %d x %d px in %.1f ms"
		% [cells * cells, ter.walkable_fraction() * 100.0,
			tex.get_width(), tex.get_height(), ms])


## EVERY VISUAL CLAIM ABOVE WAS UNASSERTED UNTIL THIS SECTION EXISTED.
##
## An adversarial review replaced the body of MiniMap._draw() with `return` —
## deleting the panel, the silhouette blit, the entry ring, the boss diamond,
## its halo, the player dot and the chevron — and this harness still reported
## "0 failure(s)" on all of it. Under --headless there is no rasteriser, so a
## draw_*() call leaves nothing any test can read back.
##
## So MiniMap.draw_plan() returns the primitives as DATA and _draw() is a
## renderer for that list which counts what it emitted. This section asserts
## both halves, because either one alone can be gutted:
##
##   * the plan contains the markers, at the right places; and
##   * _draw() consumed it (`painted`), so a plan nobody paints still fails.
func _it_actually_draws(ter: Terrain, plan: Layout) -> void:
	print("\n=== the panel actually draws what it claims ===")
	var m := MiniMapS.new()
	# LAID OUT AT THE REAL PANEL SIZE, like every other section here. A default
	# Control is 0x0, which makes map_rect() about a pixel across — and then
	# "the dot moved further than half the panel" passes on a 1 px panel, which
	# is the same species of vacuous assertion this section was added to fix.
	m.size = Vector2(_side(), _side())
	root.add_child(m)
	m.configure(ter, plan)
	m.set_player(Vector2.ZERO)

	var ops: Array[String] = []
	for d in m.draw_plan():
		ops.append(String(d["op"]))

	check("the panel and its border are drawn",
		ops.has("panel") and ops.has("border"))
	check("the silhouette is blitted", ops.has("mask"))
	check("the player dot is drawn, over its backing ring",
		ops.has("player") and ops.has("player_backing")
			and ops.find("player_backing") < ops.find("player"),
		" ".join(ops))

	# The boss marker, which is the one the player is hunting for.
	if m.boss_norm() != Vector2.INF:
		check("the boss diamond and halo are drawn",
			ops.has("boss") and ops.has("boss_halo"))
		check("...the diamond is a POLYGON, not another circle",
			_op_of(m, "boss").get("points", PackedVector2Array()).size() == 4,
			"%d points" % _op_of(m, "boss").get("points",
				PackedVector2Array()).size())
		# And the player is painted after it, or the champion hides under it.
		check("...and the player is painted after the boss",
			ops.find("player") > ops.find("boss"))
	else:
		print("  SKIP this layout has no boss node")

	# THE DOT FOLLOWS THE CHAMPION. Same claim _player_dot makes, but made
	# against the thing that gets painted rather than against a getter.
	var half: float = float(CELLS) * CELL * 0.5
	m.set_player(Vector2(-half * 0.8, -half * 0.8))
	var a: Vector2 = _op_of(m, "player").get("at", Vector2.ZERO)
	m.set_player(Vector2(half * 0.8, half * 0.8))
	var b: Vector2 = _op_of(m, "player").get("at", Vector2.ZERO)
	check("the drawn dot moves when the champion does",
		a.distance_to(b) > m.map_rect().size.x * 0.5,
		"%.0f px apart on a %.0f px panel" % [a.distance_to(b),
			m.map_rect().size.x])

	# AND THE RENDERER RUNS. This is the assertion whose absence let a gutted
	# _draw() pass: a plan full of shapes that nobody paints is invisible from
	# a headless harness unless the painter says how many it emitted.
	var want: int = m.draw_plan().size()
	m.queue_redraw()
	await process_frame
	await process_frame
	check("_draw() EMITTED every primitive in the plan",
		m.painted == want and want > 0,
		"painted %d of %d" % [m.painted, want])

	m.queue_free()
	done += 1


## And the panel the player never saw.
##
## MiniMap.gd was loaded by exactly one file — this one — which is the project's
## signature bug and the sixth time it has shipped: record_map_cleared, quests,
## partners, training and the IAP store were each built, tested, and connected
## to nothing. A minimap that only its own test can see is not a minimap.
func _it_is_wired_into_play() -> void:
	print("\n=== the game itself builds one ===")
	var src: String = FileAccess.get_file_as_string("res://scripts/game/Play.gd")
	check("Play.gd loads MiniMap", src.contains("scripts/ui/MiniMap.gd"),
		"preloaded by path, not by class_name")
	check("...builds one", src.contains("MiniMapC.new()"))
	check("...hands it the terrain it rasterises", src.contains(".configure(ter, plan)"))
	check("...and feeds it the champion every frame",
		src.contains(".set_player(_hero.ground_position())"))
	done += 1


## The first primitive with this op, or an empty Dictionary.
func _op_of(m, op: String) -> Dictionary:
	for d in m.draw_plan():
		if String(d["op"]) == op:
			return d
	return {}
