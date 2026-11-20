class_name Shade
extends RefCounted
# ------------------------------------------------------------------------------
# THE ONE SURFACE SHADER. Both the headless preview and the in-game 3D mesher
# call into here, so what I judge in a preview is what actually ships.
#
# On Blockle Idle the preview and the game drifted apart and the preview stopped
# predicting anything. One function, two callers.
#
# Everything is vertex colour. There is not a single texture in the terrain, and
# that is a deliberate choice for a phone: no texture memory, no sampler cost, no
# UV seams, and an art style that stays coherent because every colour descends
# from the biome table in Biome.gd.
# ------------------------------------------------------------------------------

# Key light direction, shared by preview and game so they agree. Upper-left,
# which is the convention the ARPG camera is built around.
const SUN_DIR: Vector3 = Vector3(-0.55, 0.72, -0.42)


# ------------------------------------------------------------------------------
# Albedo: the unlit colour of the ground at one cell.
# ------------------------------------------------------------------------------

static func albedo(t: Terrain, x: int, y: int) -> Color:
	var i: int = t.idx(x, y)
	var b: Dictionary = Biome.get_biome(t.biome_id)
	var span: float = maxf(t.h_max - t.h_min, 0.0001)
	var alt: float = clampf((t.h[i] - t.h_min) / span, 0.0, 1.0)
	var p: Vector2 = t.pos_of(x, y)

	match t.surf[i]:
		Terrain.Surf.WATER:
			var depth: float = clampf((t.water_h - t.h[i]) / 2.5, 0.0, 1.0)
			return (b["water"] as Color).lerp(b["water_deep"] as Color, depth)

		Terrain.Surf.SAND:
			return (b["soil"] as Color).lerp(_ground(t, b, p, alt), 0.30)

		Terrain.Surf.PATH:
			# Worn earth, slightly lighter than the soil it was cut from, with
			# enough noise that it reads as a trodden track rather than a decal.
			var wear: float = (t.fields["path"] as Field).at01(p.x, p.y)
			return (b["soil"] as Color).lerp(b["ground_lo"] as Color,
				0.12 + wear * 0.22)

		Terrain.Surf.FLOOR:
			# Mostly ground, lightly worn toward soil. At a 50/50 blend the
			# arena floors read as bare dirt, and since the camera spends most
			# of its time standing in an arena that made the whole game brown.
			return (b["soil"] as Color).lerp(_ground(t, b, p, alt), 0.78)

		Terrain.Surf.ROCK:
			return _rock(t, b, p, alt)

		_:
			# Ground, blended toward exposed rock as the slope steepens. This is
			# what puts stone on hillsides instead of grass clinging to a cliff.
			var g: Color = _ground(t, b, p, alt)
			var rocky: float = Rng.smoothstep01(0.30, 0.62, t.slope[i])
			return g.lerp(_rock(t, b, p, alt), rocky)


# Ground colour with large-scale variation. A single flat green over 192 metres
# reads as a billiard table; two noise fields at different scales break it into
# meadow, dry patch and shaded hollow without any extra art.
static func _ground(t: Terrain, b: Dictionary, p: Vector2, alt: float) -> Color:
	# Fields come from the Terrain, built once per region. This function used to
	# call Rng.seed_of() twice PER VERTEX — hashing a string, 147k times, before
	# doing any actual noise work.

	# Broad patches: shifts the altitude read so colour bands wander rather than
	# forming perfect contour lines.
	var patch: float = (t.fields["patch"] as Field).at(p.x, p.y) * 0.30
	var c: Color = Biome.ground_at(t.biome_id, clampf(alt + patch, 0.0, 1.0))

	# Dry/bare patches pulling toward soil, at a finer scale.
	var dry: float = Rng.smoothstep01(0.18, 0.72,
		(t.fields["dry"] as Field).at01(p.x, p.y))
	# Only a light touch toward soil. At 0.28 the dry patches desaturated the
	# whole surface and turned grass into mud.
	c = c.lerp(b["soil"] as Color, dry * 0.14)

	# Fine mottle USED to be computed here and is now done per-pixel in
	# terrain.gdshader. Per-vertex it cost an fbm evaluation for every one of
	# 147k vertices and still only resolved to one metre; in the shader it is a
	# texture lookup that resolves to a pixel.
	return c


static func _rock(t: Terrain, b: Dictionary, p: Vector2, alt: float) -> Color:
	# Strata: a banded field sampled mostly on height, so rock faces show layers
	# the way real cliffs do.
	var band: float = (t.fields["strata"] as Field).at01(p.x, p.y)
	var c: Color = Biome.rock_at(t.biome_id, clampf(alt * 0.6 + band * 0.4, 0.0, 1.0))
	var grain: float = (t.fields["grain"] as Field).at(p.x, p.y) * 0.06
	return Color(clampf(c.r + grain, 0.0, 1.0), clampf(c.g + grain, 0.0, 1.0),
		clampf(c.b + grain, 0.0, 1.0))


# ------------------------------------------------------------------------------
# Lighting. Baked into vertex colour: the phone then draws the terrain with an
# unlit material, which is close to free.
# ------------------------------------------------------------------------------

static func light(base: Color, nrm: Vector3, ao: float, alt: float,
		b: Dictionary) -> Color:
	var sun_col: Color = b["sun"]
	var amb_col: Color = b["ambient"]
	var fog_col: Color = b["fog"]

	# Half-lambert on the key. Straight lambert crushes every shadowed slope to
	# black, which is unreadable on a phone held outdoors; this keeps form
	# visible in shadow while still giving a strong lit side.
	var ndl: float = nrm.dot(SUN_DIR.normalized())
	var key: float = pow(clampf(ndl * 0.5 + 0.5, 0.0, 1.0), 1.4)

	var lit: Color = base * (amb_col * 0.55 + sun_col * key * 0.95)
	lit = lit * ao

	# Aerial perspective — low ground hazes toward the fog colour, high ground
	# stays crisp. Cheap depth cue, and it ties the terrain to the sky.
	var haze: float = clampf((1.0 - alt) * float(b["fog_density"]) * 26.0, 0.0, 0.42)
	return lit.lerp(fog_col, haze).clamp()


# Surface normal from the heightfield gradient.
static func normal_at(t: Terrain, x: int, y: int) -> Vector3:
	var dx: float = (t.height_at_cell(x + 1, y) - t.height_at_cell(x - 1, y)) \
		/ (2.0 * t.cell)
	var dy: float = (t.height_at_cell(x, y + 1) - t.height_at_cell(x, y - 1)) \
		/ (2.0 * t.cell)
	return Vector3(-dx, 1.0, -dy).normalized()


# ------------------------------------------------------------------------------
# Baked surface — the fast path the mesher uses
# ------------------------------------------------------------------------------

# Compute vertex colour and normal for EVERY CELL once, in a single loop with
# the biome lookups hoisted out.
#
# The per-vertex path below is correct but was costing a third of all generation
# time, because `albedo()` called `Biome.get_biome()` on every vertex and
# `Biome.ground_at()` called it AGAIN — two dictionary lookups plus a pile of
# Color temporaries, 153,664 times. Hoisting them turns that into array reads.
#
# Baking per CELL rather than per VERTEX also removes the duplicate work at
# chunk seams, where neighbouring chunks share an edge row.
static func bake(t: Terrain) -> void:
	var n: int = t.size * t.size
	t.vcol = PackedColorArray()
	t.vnrm = PackedVector3Array()
	t.vcol.resize(n)
	t.vnrm.resize(n)

	var b: Dictionary = Biome.get_biome(t.biome_id)
	var g_lo: Color = b["ground_lo"]
	var g_hi: Color = b["ground_hi"]
	var soil: Color = b["soil"]
	var rock: Color = b["rock"]
	var rock_hi: Color = b["rock_hi"]
	var water: Color = b["water"]
	var water_deep: Color = b["water_deep"]

	var f_patch: Field = t.fields["patch"]
	var f_dry: Field = t.fields["dry"]
	var f_strata: Field = t.fields["strata"]
	var f_grain: Field = t.fields["grain"]
	var f_path: Field = t.fields["path"]

	var span: float = maxf(t.h_max - t.h_min, 0.0001)
	var half: float = float(t.size) * t.cell * 0.5
	var inv_cell2: float = 1.0 / (2.0 * t.cell)
	var sz: int = t.size

	for y in range(sz):
		var pz: float = float(y) * t.cell - half
		for x in range(sz):
			var i: int = y * sz + x
			var px: float = float(x) * t.cell - half
			var alt: float = clampf((t.h[i] - t.h_min) / span, 0.0, 1.0)

			# --- ground / rock, with every palette read already in a local ---
			var patch: float = f_patch.at(px, pz) * 0.30
			var gc: Color = g_lo.lerp(g_hi, clampf(alt + patch, 0.0, 1.0))
			var dry: float = Rng.smoothstep01(0.18, 0.72, f_dry.at01(px, pz))
			gc = gc.lerp(soil, dry * 0.14)

			var band: float = f_strata.at01(px, pz)
			var rc: Color = rock.lerp(rock_hi,
				clampf(alt * 0.6 + band * 0.4, 0.0, 1.0))
			var grain: float = f_grain.at(px, pz) * 0.06
			rc = Color(clampf(rc.r + grain, 0.0, 1.0),
				clampf(rc.g + grain, 0.0, 1.0), clampf(rc.b + grain, 0.0, 1.0))

			var c: Color
			var rocky: float
			match t.surf[i]:
				Terrain.Surf.WATER:
					c = water.lerp(water_deep,
						clampf((t.water_h - t.h[i]) / 2.5, 0.0, 1.0))
					rocky = 0.0
				Terrain.Surf.SAND:
					c = soil.lerp(gc, 0.30)
					rocky = Rng.smoothstep01(0.26, 0.62, t.slope[i])
				Terrain.Surf.PATH:
					c = soil.lerp(g_lo, 0.12 + f_path.at01(px, pz) * 0.22)
					rocky = 0.35
				Terrain.Surf.FLOOR:
					c = soil.lerp(gc, 0.78)
					rocky = 0.35
				Terrain.Surf.ROCK:
					c = rc
					rocky = 1.0
				_:
					var mix: float = Rng.smoothstep01(0.30, 0.62, t.slope[i])
					c = gc.lerp(rc, mix)
					rocky = Rng.smoothstep01(0.26, 0.62, t.slope[i])

			# AO folded in, then sRGB -> linear. Alpha is rockiness, NOT opacity,
			# so it must not go through the colour conversion.
			var k: float = lerpf(0.72, 1.0, t.ao[i])
			var lin: Color = Color(c.r * k, c.g * k, c.b * k).srgb_to_linear()
			t.vcol[i] = Color(lin.r, lin.g, lin.b, rocky)

			# --- normal, from the detailed height -----------------------------
			var xl: int = x - 1 if x > 0 else 0
			var xr: int = x + 1 if x < sz - 1 else sz - 1
			var yd: int = y - 1 if y > 0 else 0
			var yu: int = y + 1 if y < sz - 1 else sz - 1
			var dx: float = (t.h[y * sz + xr] - t.h[y * sz + xl]) * inv_cell2
			var dy: float = (t.h[yu * sz + x] - t.h[yd * sz + x]) * inv_cell2
			t.vnrm[i] = Vector3(-dx, 1.0, -dy).normalized()


# Albedo with ambient occlusion folded in, and NOTHING else. This is what the 3D
# mesher writes into vertex colour.
#
# The first 3D pass baked the key light in here and marked the terrain unshaded.
# That is fast, but an unshaded surface CANNOT RECEIVE A SHADOW — so two
# thousand trees cast nothing onto the ground and the world looked pressed flat.
# Real lighting costs a phone very little on an untextured mesh, and contact
# shadows under trees are most of what makes a place feel three-dimensional.
#
# AO stays baked because it is a property of the terrain's own shape, not of the
# light, and computing it per-frame would be genuinely expensive.
static func albedo_ao(t: Terrain, x: int, y: int) -> Color:
	var i: int = t.idx(x, y)
	var c: Color = albedo(t, x, y)
	var k: float = lerpf(0.72, 1.0, t.ao[i])
	# ALPHA IS NOT OPACITY HERE. The terrain shader reads it as "rockiness", so
	# stone can take grain and specular differently from grass without needing a
	# second UV channel or a splat map.
	return Color(c.r * k, c.g * k, c.b * k, rockiness(t, x, y))


# 0 = soft ground, 1 = bare stone. Slope-driven, with the explicitly rocky
# surface classes pinned to the top of the range.
static func rockiness(t: Terrain, x: int, y: int) -> float:
	var i: int = t.idx(x, y)
	match t.surf[i]:
		Terrain.Surf.ROCK:
			return 1.0
		Terrain.Surf.WATER:
			return 0.0
		Terrain.Surf.PATH, Terrain.Surf.FLOOR:
			return 0.35
		_:
			return Rng.smoothstep01(0.26, 0.62, t.slope[i])


# The full shaded colour of a cell — used by the top-down preview, which has no
# light of its own.
static func shaded(t: Terrain, x: int, y: int) -> Color:
	var i: int = t.idx(x, y)
	var b: Dictionary = Biome.get_biome(t.biome_id)
	var span: float = maxf(t.h_max - t.h_min, 0.0001)
	var alt: float = clampf((t.h[i] - t.h_min) / span, 0.0, 1.0)
	return light(albedo(t, x, y), normal_at(t, x, y), t.ao[i], alt, b)
