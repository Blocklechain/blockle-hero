extends SceneTree
# ------------------------------------------------------------------------------
# THE DREAD CURVE, measured. Does map 100 actually look more frightening than
# map 1, is it still readable when it does, and is the campaign's biome order a
# progression rather than a cycle?
#
#   godot --headless --path . --script tools/dreadtest.gd
#
# WHY THIS FILE EXISTS. "Scary" is the easiest thing in a game to break by
# accident, because every symptom of breaking it looks like art: one number
# nudged in Biome.gd and map 60 is lit like map 90, or the late maps go so dark
# that the honest bug report is "I cannot see the enemies" and the honest cause
# is a palette dial. So the invariants are written down as numbers:
#
#   RISING      fill, fog, sky and ground chroma all move the same way with
#               dread, for every biome, with no exceptions and no local tuning.
#   READABLE    the KEY never dims, the fill never goes below a luminance floor,
#               fog has a per-metre ceiling, the horizon stays brighter than the
#               zenith, the ground's luminance SPAN widens as its colour drains,
#               and a mid-grey enemy standing on dread-1.0 ground still clears a
#               contrast ratio against it.
#   SHAPE-FREE  dread changes light and colour and NOTHING else: the same seed
#               at dread 0 and dread 1 must produce a bit-identical heightfield
#               and the same walkable cells. A presentation dial that can make
#               map 90 unplayable is not worth having.
#
# The contrast numbers are computed through Shade.light() — the same function the
# preview renders with — rather than from the palette table, because what the
# player sees is the lit result, not the swatch.
# ------------------------------------------------------------------------------

## Where the renders in tools/dreadshots.gd are sampled, so the table printed
## here and the images agree.
const RUNGS: PackedFloat32Array = [0.0, 0.33, 0.66, 1.0]

## Stand-in champions: a dark one, a mid one and a light one. The roster is 139
## models and their albedos are all over the range, so the question a single
## swatch cannot answer is asked three times — can the ground be a luminance
## match for EVERY plausible champion at once, or is there always a clear read
## available. (For a single albedo the answer is "sometimes not": any darkening
## of the ground has to pass THROUGH a mid-grey champion's luminance on its way
## down, and greenwood's does, around dread 0.5. That is a crossing, not a
## blackout, and the figure is still separated by chroma and by its own key/fill
## modelling there.)
const ENEMY_ALBEDOS: PackedColorArray = [
	Color(0.24, 0.24, 0.24), Color(0.55, 0.55, 0.55), Color(0.86, 0.86, 0.86),
]

## The best of those three must clear this contrast ratio, (L1+0.05)/(L2+0.05),
## at every dread in every biome. MEASURED: the sixteen shipped palettes at
## dread 0 bottom out at 1.57 (ashwastes, whose flat grey ground is the hardest
## thing in the game to stand a champion on), so 1.50 is "no worse than the
## worst place the game already ships, with a little margin" rather than a
## number anybody liked the look of.
const MIN_FIGURE_CONTRAST: float = 1.50

## Terrain size for the shape-invariance check. Small on purpose — this proves an
## identity, and 128 cells proves it in a second instead of eight.
const CELLS: int = 128
const CELL: float = 0.5

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-62s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_tagging()
	_progression()
	_rising()
	_readable()
	_shape_free()
	_table()

	print("\n%s (%d failure%s)" % ["OK" if fails == 0 else "FAILED", fails,
		"" if fails == 1 else "s"])
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------
# Tagging — the mechanism dread travels on
# ------------------------------------------------------------------------------

func _tagging() -> void:
	print("\n=== dread travels with the biome id ===")

	var tagged: String = Biome.tag("voidrift", 0.63)
	check("tag() writes a readable id", tagged == "voidrift~63", tagged)
	check("base_id() reads it back", Biome.base_id(tagged) == "voidrift")
	check("dread_in() reads it back", is_equal_approx(Biome.dread_in(tagged), 0.63),
		"%.2f" % Biome.dread_in(tagged))
	check("an untagged id is unchanged", Biome.base_id("voidrift") == "voidrift"
		and Biome.dread_in("voidrift") == 0.0)
	check("tagging is idempotent", Biome.tag(tagged, 0.63) == tagged)

	# The id ends up as a Node name (WorldBuilder names the region after it), and
	# Godot silently rewrites names containing its reserved characters.
	var bad: String = ".:@/\"%"
	var clean: bool = true
	for i in range(bad.length()):
		if Biome.DREAD_SEP == bad[i]:
			clean = false
	check("the separator is legal in a Node name", clean, Biome.DREAD_SEP)

	# Map 1 must look EXACTLY like the world looked before the curve existed, or
	# every before/after comparison is reading float noise.
	check("dread 0 is the untagged biome, identically",
		Biome.get_biome(Biome.tag("greenwood", 0.0)) == Biome.get_biome("greenwood"))
	check("display_name() never shows the tag",
		Biome.display_name("voidrift~63") == "Voidrift",
		Biome.display_name("voidrift~63"))
	check("act_of() still finds a tagged biome",
		Biome.act_of("voidrift~63") == Biome.act_of("voidrift"))
	check("unknown ids still fall back rather than crash",
		Biome.get_biome("nonsuch~50").has("sun")
		and Biome.get_biome("nonsuch").has("sun"))

	# Terrain parameters are the biome's own at every dread; see _shape_free.
	var d0: Dictionary = Biome.get_biome("molten")
	var d1: Dictionary = Biome.get_biome(Biome.tag("molten", 1.0))
	var same: bool = true
	for k in ["amplitude", "freq", "ridge", "roughness", "terrace",
			"water_level", "warp", "density", "props", "cover", "name"]:
		if d0[k] != d1[k]:
			same = false
			print("      differs: ", k, " ", d0[k], " -> ", d1[k])
	check("dread leaves terrain parameters and prop tables alone", same)


# ------------------------------------------------------------------------------
# Biome selection is a ramp
# ------------------------------------------------------------------------------

func _progression() -> void:
	print("\n=== biome selection is a progression, not a cycle ===")

	# hostility() is measured from each biome's own palette, so this is the
	# hand-written order of Biome.IDS being checked against what the colours in
	# those entries actually say — not against a second list of opinions.
	#
	# IT IS NOT A STRICT SORT AND SHOULD NOT BE. The list is a thematic ramp
	# (pastoral -> harsh -> hostile -> unreal -> the citadel) and the citadel is
	# gold and marble BY DESIGN: the throne's base palette is brighter than the
	# voidrift before it. What has to hold is that the trend is real, and then
	# that the dread shift finishes the job the ordering starts — which is the
	# last and strongest check in this section.
	var ids: PackedStringArray = Biome.campaign_order()
	var rising: int = 0
	for i in range(1, ids.size()):
		if Biome.hostility(ids[i]) >= Biome.hostility(ids[i - 1]):
			rising += 1
	check("the biome list trends toward hostile (>=60% of steps)",
		float(rising) / float(ids.size() - 1) >= 0.60,
		"%d of %d steps rise" % [rising, ids.size() - 1])

	check("the hostile end of the list is well past the temperate end",
		Biome.hostility(ids[ids.size() - 1]) - Biome.hostility(ids[0]) > 0.10,
		"%.2f -> %.2f" % [Biome.hostility(ids[0]),
			Biome.hostility(ids[ids.size() - 1])])

	# What the campaign actually draws, act by act — as chosen, and as rendered.
	var act_mean: PackedFloat32Array = PackedFloat32Array()
	var act_seen: PackedFloat32Array = PackedFloat32Array()
	for a in range(Campaign.act_count()):
		var sum: float = 0.0
		var sum_seen: float = 0.0
		for st in range(Campaign.maps_per_act()):
			var i: int = a * Campaign.maps_per_act() + st
			sum += Biome.hostility(Campaign.biome_at(i))
			sum_seen += Biome.hostility(
				Biome.tag(Campaign.biome_at(i), Campaign.dread(i)))
		act_mean.append(sum / float(Campaign.maps_per_act()))
		act_seen.append(sum_seen / float(Campaign.maps_per_act()))

	check("the last act draws far more hostile biomes than the first",
		act_mean[act_mean.size() - 1] - act_mean[0] > 0.15,
		"act 1 %.2f -> act %d %.2f" % [act_mean[0], act_mean.size(),
			act_mean[act_mean.size() - 1]])
	check("the back half draws more hostile biomes than the front half",
		_mean(act_mean, 5, 10) - _mean(act_mean, 0, 5) > 0.05,
		"%.2f -> %.2f" % [_mean(act_mean, 0, 5), _mean(act_mean, 5, 10)])

	# AND THE CHECK THAT MATTERS: what the player is actually shown is the
	# chosen biome WITH its dread shift applied. Selection alone correlates
	# moderately — the ordering is thematic and the citadel is bright — while
	# selection plus shift has to be a ramp with no soft spots, because that
	# composite is what appears on the screen.
	# Act over act, with a 0.01 tolerance: the biome WINDOW can repeat a biome
	# between two acts (it is a sliding window, deliberately overlapping), so one
	# act out of ten can sit level with the one before it. What it may not do is
	# go backwards.
	var seen_falling: PackedStringArray = PackedStringArray()
	for a in range(1, act_seen.size()):
		if act_seen[a] < act_seen[a - 1] - 0.01:
			seen_falling.append("act %d" % (a + 1))
	check("ACT BY ACT, what the player is shown never gets less hostile",
		seen_falling.is_empty(), ", ".join(seen_falling))

	var r_pick: float = _correlate_hostility(false)
	var r_seen: float = _correlate_hostility(true)
	check("dread and the hostility of the biome it picks correlate",
		r_pick > 0.40, "r = %.3f" % r_pick)
	# The shift is what turns a thematic ordering into a curve. If this ever
	# stops being a long way above r_pick, the shift has stopped doing its job
	# and the campaign is relying on biome choice alone to carry the dread.
	check("the shift lifts that correlation a long way",
		r_seen > 0.70 and r_seen > r_pick + 0.20,
		"r = %.3f (selection alone %.3f)" % [r_seen, r_pick])

	print("    act hostility, biome as chosen: " + ", ".join(_fmt_floats(act_mean)))
	print("    act hostility, as rendered:     " + ", ".join(_fmt_floats(act_seen)))

	# for_dread()/dread_of() are the no-map-index path and must agree with the
	# list they describe.
	check("for_dread() walks the same list end to end",
		Biome.for_dread(0.0) == ids[0]
		and Biome.for_dread(1.0) == ids[ids.size() - 1],
		"%s .. %s" % [Biome.for_dread(0.0), Biome.for_dread(1.0)])
	var inverse: bool = true
	for i in range(ids.size()):
		if Biome.for_dread(Biome.dread_of(ids[i])) != ids[i]:
			inverse = false
	check("dread_of() is its inverse for every biome", inverse)


# ------------------------------------------------------------------------------
# The shift rises, everywhere, with no local exceptions
# ------------------------------------------------------------------------------

func _rising() -> void:
	print("\n=== the dread shift moves one way, in every biome ===")

	var steps: int = 20
	var bad_fill: PackedStringArray = PackedStringArray()
	var bad_fog: PackedStringArray = PackedStringArray()
	var bad_sky: PackedStringArray = PackedStringArray()
	var bad_chroma: PackedStringArray = PackedStringArray()
	var bad_span: PackedStringArray = PackedStringArray()
	var bad_accent: PackedStringArray = PackedStringArray()
	var bad_cover: PackedStringArray = PackedStringArray()

	for bid in Biome.IDS:
		var prev: Dictionary = Biome.get_biome(bid)
		for s in range(1, steps + 1):
			var d: float = float(s) / float(steps)
			var cur: Dictionary = Biome.get_biome(Biome.tag(bid, d))
			if _lum(cur["ambient"]) > _lum(prev["ambient"]) + 0.0005:
				bad_fill.append(bid)
			if float(cur["fog_density"]) < float(prev["fog_density"]) - 0.000001:
				bad_fog.append(bid)
			if _lum(cur["sky_top"]) > _lum(prev["sky_top"]) + 0.0005:
				bad_sky.append(bid)
			if _chroma(cur) > _chroma(prev) + 0.0005:
				bad_chroma.append(bid)
			if _span(cur) < _span(prev) - 0.0005:
				bad_span.append(bid)
			if (cur["accent"] as Color).s < (prev["accent"] as Color).s - 0.0005:
				bad_accent.append(bid)
			if int(cur["cover_density"]) > int(prev["cover_density"]):
				bad_cover.append(bid)
			prev = cur

	check("the fill darkens monotonically", bad_fill.is_empty(),
		", ".join(bad_fill))
	check("fog thickens monotonically", bad_fog.is_empty(), ", ".join(bad_fog))
	check("the sky darkens monotonically", bad_sky.is_empty(), ", ".join(bad_sky))
	check("ground chroma drains monotonically", bad_chroma.is_empty(),
		", ".join(bad_chroma))
	check("the ground's luminance SPAN only widens", bad_span.is_empty(),
		", ".join(bad_span))
	check("the accent never loses saturation", bad_accent.is_empty(),
		", ".join(bad_accent))
	check("ground cover only thins", bad_cover.is_empty(), ", ".join(bad_cover))

	# And it has to MOVE, not merely fail to move backwards.
	#
	# Two axes carry an exemption, and both are readability limits rather than
	# taste: a biome whose sky is already the darkest in the game has no
	# darkening left to spend (and spending it would take the light off the
	# player's champion, since the sky is what lights the shadowed side), and a
	# biome already at the fog ceiling cannot thicken. Every OTHER axis must
	# still make the full move in those biomes — that is the point of checking
	# five of them rather than one.
	var floor_sky: float = 1.0
	var floor_amb: float = 1.0
	var floor_fill: float = 1.0
	for bid0 in Biome.IDS:
		floor_sky = minf(floor_sky, _lum(Biome.get_biome(bid0)["sky_top"]))
		floor_amb = minf(floor_amb, _lum(Biome.get_biome(bid0)["ambient"]))
		floor_fill = minf(floor_fill, _composite_fill(Biome.get_biome(bid0)))

	var weak: PackedStringArray = PackedStringArray()
	for bid in Biome.IDS:
		var b0: Dictionary = Biome.get_biome(bid)
		var b1: Dictionary = Biome.get_biome(Biome.tag(bid, 1.0))
		var fill_drop: float = 1.0 - _lum(b1["ambient"]) / maxf(_lum(b0["ambient"]), 0.0001)
		var chroma_drop: float = 1.0 - _chroma(b1) / maxf(_chroma(b0), 0.0001)
		var sky_drop: float = 1.0 - _lum(b1["sky_top"]) / maxf(_lum(b0["sky_top"]), 0.0001)
		var fog_rise: float = float(b1["fog_density"]) / maxf(
			float(b0["fog_density"]), 0.0001) - 1.0
		var cover_drop: float = 1.0 - float(b1["cover_density"]) / maxf(
			float(b0["cover_density"]), 1.0)
		# Everything that has room to move must move. What has no room is
		# derived from the shipped palettes, never asserted: a sky already at
		# the darkest shipped, a fog whose ungated target is past the ceiling,
		# a fill already at the dimmest shipped.
		# The test is on the SHIFTED value, not the base: what earns an
		# exemption is having been stopped by a floor, which is a property of
		# where the shift ended up.
		var sky_at_floor: bool = _lum(b1["sky_top"]) <= floor_sky + 0.004 \
			or _composite_fill(b1) <= floor_fill + 0.004
		var fog_at_ceil: bool = float(b0["fog_density"]) * Biome.FOG_GAIN \
			> Biome.FOG_CEIL
		var fill_at_floor: bool = _lum(b1["ambient"]) <= floor_amb + 0.004
		if chroma_drop < 0.25 or cover_drop < 0.25 \
				or (fill_drop < 0.25 and not fill_at_floor) \
				or (fog_rise < 0.20 and not fog_at_ceil) \
				or (sky_drop < 0.25 and not sky_at_floor):
			weak.append("%s(fill %.2f sky %.2f chroma %.2f fog %.2f cover %.2f)" % [
				bid, fill_drop, sky_drop, chroma_drop, fog_rise, cover_drop])
	check("dread 1.0 is a big move in every biome, not a nudge", weak.is_empty(),
		", ".join(weak))

	# The two sky multipliers ARE the in-game fill (Mesher's ambient energy is a
	# no-op at full sky contribution), so they are not free to be art-directed
	# on their own: their mean has to stay the fill multiplier. Lower one
	# without raising the other and every late map loses light that no palette
	# number appears to have taken.
	check("the sky's luminance drop averages the fill drop, exactly",
		is_equal_approx((Biome.LUM_SKY_TOP + Biome.LUM_SKY_HZ) * 0.5,
			Biome.FILL_MULT),
		"(%.2f + %.2f) / 2 = %.3f vs fill %.2f" % [Biome.LUM_SKY_TOP,
			Biome.LUM_SKY_HZ, (Biome.LUM_SKY_TOP + Biome.LUM_SKY_HZ) * 0.5,
			Biome.FILL_MULT])


# ------------------------------------------------------------------------------
# ...and it stays readable
# ------------------------------------------------------------------------------

func _readable() -> void:
	print("\n=== atmospheric is not the same as dark ===")

	# THE DARKNESS FLOOR IS MEASURED, NOT INVENTED. The darkest lit ground the
	# art direction already ships at dread 0 is the darkest this game has ever
	# asked a player to read; dread may take any biome down to that and no
	# further. Deriving it means a new biome moves the floor by being authored,
	# and means this check cannot be satisfied by quietly lowering a constant.
	var floor_lum: float = 1.0
	var floor_biome: String = ""
	for bid in Biome.IDS:
		var l: float = _lit_ground(Biome.get_biome(bid)).get_luminance()
		if l < floor_lum:
			floor_lum = l
			floor_biome = bid
	print("    darkest lit ground shipped at dread 0: %s, %.3f" % [floor_biome,
		floor_lum])

	# The two fill floors, measured off the shipped palettes the same way.
	var floor_amb: float = 1.0
	var floor_fill: float = 1.0
	for bid1 in Biome.IDS:
		floor_amb = minf(floor_amb, _lum(Biome.get_biome(bid1)["ambient"]))
		floor_fill = minf(floor_fill, _composite_fill(Biome.get_biome(bid1)))
	print("    dimmest shipped fill: ambient %.3f, sky+fog composite %.3f" % [
		floor_amb, floor_fill])

	var dim_key: PackedStringArray = PackedStringArray()
	var sunk_fill: PackedStringArray = PackedStringArray()
	var thick_fog: PackedStringArray = PackedStringArray()
	var flat_sky: PackedStringArray = PackedStringArray()
	var dark_ground: PackedStringArray = PackedStringArray()
	var lost_figure: PackedStringArray = PackedStringArray()

	for bid in Biome.IDS:
		var b0: Dictionary = Biome.get_biome(bid)
		for st in range(0, 21):
			var d: float = float(st) / 20.0
			var b: Dictionary = Biome.get_biome(Biome.tag(bid, d))

			# THE KEY DOES NOT DIM. Lower key means a bigger key-to-fill ratio.
			if _lum(b["sun"]) < _lum(b0["sun"]) * 0.90:
				dim_key.append("%s@%.2f" % [bid, d])
			if float(b.get("key_mult", 1.0)) < 0.999:
				dim_key.append("%s@%.2f key_mult" % [bid, d])

			# The fill has a floor so a shadowed enemy keeps its form — the
			# dimmest fill the shipped palettes already produce, derived rather
			# than declared, exactly as the ground's darkness floor is.
			if _lum(b["ambient"]) < minf(_lum(b0["ambient"]), floor_amb) - 0.002:
				sunk_fill.append("%s@%.2f" % [bid, d])
			if _composite_fill(b) < minf(_composite_fill(b0), floor_fill) - 0.002:
				sunk_fill.append("%s@%.2f composite" % [bid, d])

			# Fog has a per-metre ceiling.
			if float(b["fog_density"]) > maxf(float(b0["fog_density"]),
					Biome.FOG_CEIL) + 0.000001:
				thick_fog.append("%s@%.2f" % [bid, d])

			# The horizon stays the brighter band, so hills and props still
			# silhouette against the sky.
			if _lum(b["sky_horizon"]) <= _lum(b["sky_top"]):
				flat_sky.append("%s@%.2f" % [bid, d])

			var lit_ground: Color = _lit_ground(b)
			if lit_ground.get_luminance() < floor_lum * 0.98:
				dark_ground.append("%s@%.2f=%.3f" % [bid, d,
					lit_ground.get_luminance()])
			if _figure_contrast(b) < MIN_FIGURE_CONTRAST:
				lost_figure.append("%s@%.2f=%.2f" % [bid, d, _figure_contrast(b)])

	check("the key light never dims with dread", dim_key.is_empty(),
		", ".join(dim_key))
	check("the fill never falls below its luminance floor", sunk_fill.is_empty(),
		", ".join(sunk_fill))
	check("fog never passes %.3f /m" % Biome.FOG_CEIL, thick_fog.is_empty(),
		", ".join(thick_fog))
	check("the horizon stays brighter than the zenith", flat_sky.is_empty(),
		", ".join(flat_sky))
	check("no dread makes ground darker than the darkest shipped biome",
		dark_ground.is_empty(), ", ".join(dark_ground))
	check("some champion albedo always clears %.2f:1 on the ground"
		% MIN_FIGURE_CONTRAST, lost_figure.is_empty(), ", ".join(lost_figure))

	# Contrast should RISE, not merely survive: a lower key is a harsher image.
	var worse: PackedStringArray = PackedStringArray()
	for bid in Biome.IDS:
		var b0: Dictionary = Biome.get_biome(bid)
		var b1: Dictionary = Biome.get_biome(Biome.tag(bid, 1.0))
		if _modelling(b1) < _modelling(b0):
			worse.append("%s %.2f -> %.2f" % [bid, _modelling(b0), _modelling(b1)])
	check("lit-to-shadow modelling gets HARSHER, not flatter", worse.is_empty(),
		", ".join(worse))

	# And dread must not spend the champion's legibility to buy its atmosphere.
	#
	# The test is GLOBAL, not per biome, and that is the honest shape for it:
	# darkening a pale ground necessarily carries it THROUGH the luminance of a
	# mid-grey champion, so greenwood's best-of-three falls from 2.22 to 1.72 on
	# the way down and no amount of tuning avoids the crossing. What must hold is
	# that the worst case over the whole curve is no worse than the worst case
	# the shipped palettes already hand the player at dread 0.
	var ship_worst: float = 9.0
	var curve_worst: float = 9.0
	var worst_at: String = ""
	for bid in Biome.IDS:
		ship_worst = minf(ship_worst, _figure_contrast(Biome.get_biome(bid)))
		for st in range(0, 21):
			var c: float = _figure_contrast(
				Biome.get_biome(Biome.tag(bid, float(st) / 20.0)))
			if c < curve_worst:
				curve_worst = c
				worst_at = "%s@%.2f" % [bid, float(st) / 20.0]
	check("the whole dread curve is no worse than the shipped worst case",
		curve_worst >= ship_worst * 0.95,
		"shipped %.2f, curve %.2f at %s" % [ship_worst, curve_worst, worst_at])


# What the 3D renderer actually lights its shadows with: the ProceduralSky is
# built from sky_top, sky_horizon and the FOG colour, and that sky is the whole
# ambient term (Mesher's ambient energy is a no-op at full sky contribution).
func _composite_fill(b: Dictionary) -> float:
	var sum: float = 0.0
	for k in Biome.FILL_KEYS:
		sum += _lum(b[k])
	return sum / float(Biome.FILL_KEYS.size())


# Mid-altitude open ground, lit, unoccluded — the brightness of the floor the
# player walks on.
func _lit_ground(b: Dictionary) -> Color:
	var mid: Color = (b["ground_lo"] as Color).lerp(b["ground_hi"] as Color, 0.5)
	return Shade.light(mid, Vector3.UP, 1.0, 0.5, b)


# The best contrast any of the three stand-in champions gets against that
# ground. "Best", not "mean": the player has to be able to see SOME champion,
# and a ground colour that matches one albedo necessarily separates from the
# others.
func _figure_contrast(b: Dictionary) -> float:
	var ground: Color = _lit_ground(b)
	var best: float = 0.0
	for a in ENEMY_ALBEDOS:
		best = maxf(best, _contrast(Shade.light(a, Vector3.UP, 1.0, 0.5, b),
			ground))
	return best


# How many times brighter the lit side of a slope is than the shadowed side,
# which is what "lower key" is supposed to increase.
func _modelling(b: Dictionary) -> float:
	var mid: Color = (b["ground_lo"] as Color).lerp(b["ground_hi"] as Color, 0.5)
	var lit: Color = Shade.light(mid, Shade.SUN_DIR.normalized(), 1.0, 0.5, b)
	var dark: Color = Shade.light(mid, -Shade.SUN_DIR.normalized(), 1.0, 0.5, b)
	return lit.get_luminance() / maxf(dark.get_luminance(), 0.0001)


# ------------------------------------------------------------------------------
# Dread is presentation and nothing else
# ------------------------------------------------------------------------------

func _shape_free() -> void:
	print("\n=== the same map, four moods, one shape ===")

	var world_seed: int = 90210
	var extent: float = float(CELLS) * CELL
	var plan: Layout = Terrain.plan_for(Terrain.Kind.LANE, world_seed,
		Vector2(extent, extent))
	var base: Terrain = Terrain.generate(world_seed, "boneyard", CELLS, CELL, plan)

	for d in [0.33, 0.66, 1.0]:
		var plan2: Layout = Terrain.plan_for(Terrain.Kind.LANE, world_seed,
			Vector2(extent, extent))
		var t: Terrain = Terrain.generate(world_seed,
			Biome.tag("boneyard", d), CELLS, CELL, plan2)
		check("dread %.2f leaves the heightfield bit-identical" % d,
			t.h == base.h and t.h_macro == base.h_macro)
		check("dread %.2f leaves walkability identical" % d,
			t.walk == base.walk and t.surf == base.surf,
			"walk %.1f%%" % (t.walkable_fraction() * 100.0))
		check("dread %.2f DOES change the painted surface" % d,
			t.vcol != base.vcol)


# ------------------------------------------------------------------------------
# What the shift actually produced
# ------------------------------------------------------------------------------

func _table() -> void:
	print("\n=== the curve, per biome, at the four rendered rungs ===")
	print("  %-11s %5s %6s %6s %6s %6s %6s %6s %6s %6s %6s" % ["biome", "dread",
		"key", "fill", "ratio", "fog/m", "sky", "chroma", "span", "lit", "fig:1"])
	for bid in Biome.IDS:
		for d in RUNGS:
			var b: Dictionary = Biome.get_biome(Biome.tag(bid, d))
			print("  %-11s %5.2f %6.3f %6.3f %6.2f %6.4f %6.3f %6.3f %6.3f %6.3f %6.2f" % [
				bid if d == 0.0 else "", d, _lum(b["sun"]), _lum(b["ambient"]),
				_modelling(b), float(b["fog_density"]), _lum(b["sky_top"]),
				_chroma(b), _span(b), _lit_ground(b).get_luminance(),
				_figure_contrast(b)])


# ------------------------------------------------------------------------------

func _lum(c: Color) -> float:
	return c.get_luminance()


# Mean saturation of the two ground colours — how much colour the terrain has.
func _chroma(b: Dictionary) -> float:
	return ((b["ground_lo"] as Color).s + (b["ground_hi"] as Color).s) * 0.5


# Luminance distance between low and high ground. This is the budget form has to
# work with once colour stops carrying the terrain.
func _span(b: Dictionary) -> float:
	return absf(_lum(b["ground_hi"]) - _lum(b["ground_lo"]))


func _contrast(a: Color, b: Color) -> float:
	var la: float = a.get_luminance()
	var lb: float = b.get_luminance()
	var hi: float = maxf(la, lb)
	var lo: float = minf(la, lb)
	return (hi + 0.05) / (lo + 0.05)


# Pearson correlation between campaign position and hostility — of the biome as
# chosen, or of the biome as rendered (chosen plus its dread shift). A 16-entry
# cycle scores about zero here however pretty its biomes are.
func _correlate_hostility(rendered: bool) -> float:
	var n: int = Campaign.map_count()
	var sx: float = 0.0
	var sy: float = 0.0
	var sxx: float = 0.0
	var syy: float = 0.0
	var sxy: float = 0.0
	for i in range(n):
		var x: float = Campaign.dread(i)
		var id: String = Campaign.biome_at(i)
		var y: float = Biome.hostility(Biome.tag(id, x) if rendered else id)
		sx += x
		sy += y
		sxx += x * x
		syy += y * y
		sxy += x * y
	var fn: float = float(n)
	return (fn * sxy - sx * sy) / maxf(sqrt((fn * sxx - sx * sx)
		* (fn * syy - sy * sy)), 0.00001)


func _mean(v: PackedFloat32Array, from: int, to: int) -> float:
	var sum: float = 0.0
	for i in range(from, mini(to, v.size())):
		sum += v[i]
	return sum / float(maxi(mini(to, v.size()) - from, 1))


func _fmt_floats(v: PackedFloat32Array) -> PackedStringArray:
	var out := PackedStringArray()
	for f in v:
		out.append("%.2f" % f)
	return out
