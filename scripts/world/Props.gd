class_name Props
extends RefCounted
# ------------------------------------------------------------------------------
# Procedural prop meshes — every tree, rock, crystal and ruin in the game, built
# from code at load time.
#
# Why generated rather than modelled: there is no art budget for 26 prop types
# across 16 biomes (416 assets), and more importantly a generated prop takes its
# colours from the SAME biome table the terrain does, so a frostcrag pine cannot
# drift away from frostcrag ground. Hand-made props would need re-tinting per
# biome by hand and would eventually disagree.
#
# Every prop is low-poly with flat vertex colour and an unshaded material, which
# matches the terrain exactly and costs a phone almost nothing. Props are drawn
# with MultiMesh, so a thousand trees is one draw call.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Mesh builder — accumulates triangles with per-vertex colour.
# ------------------------------------------------------------------------------

class Build:
	# Emission for subsequent triangles, 0 = inert. A STATE rather than a
	# per-colour alpha: Color defaults to alpha 1.0, so reading emission off the
	# colour made every leaf, rock and trunk emit at full strength and the whole
	# forest blew out to neon.
	var emit: float = 0.0

	var v := PackedVector3Array()
	var c := PackedColorArray()
	var n := PackedVector3Array()
	var i := PackedInt32Array()

	func tri(a: Vector3, b: Vector3, d: Vector3, col: Color) -> void:
		var base: int = v.size()
		var nrm: Vector3 = (b - a).cross(d - a).normalized()
		# Alpha carries EMISSION for the prop shader, so it must not be dragged
		# through the sRGB conversion with the colour channels.
		var lin: Color = col.srgb_to_linear()
		var out := Color(lin.r, lin.g, lin.b, emit)
		for p in [a, b, d]:
			v.append(p)
			c.append(out)
			n.append(nrm)
		i.append_array([base, base + 1, base + 2])

	func quad(a: Vector3, b: Vector3, d: Vector3, e: Vector3, col: Color) -> void:
		tri(a, b, d, col)
		tri(a, d, e, col)

	# A tapered drum: trunks, stalagmites, pillars and crystal shafts are all
	# this with different parameters.
	func drum(bottom: Vector3, top: Vector3, r0: float, r1: float, sides: int,
			col: Color, twist: float = 0.0) -> void:
		for s in range(sides):
			var a0: float = float(s) / float(sides) * TAU
			var a1: float = float(s + 1) / float(sides) * TAU
			var p0 := bottom + Vector3(cos(a0) * r0, 0, sin(a0) * r0)
			var p1 := bottom + Vector3(cos(a1) * r0, 0, sin(a1) * r0)
			var q0 := top + Vector3(cos(a0 + twist) * r1, 0, sin(a0 + twist) * r1)
			var q1 := top + Vector3(cos(a1 + twist) * r1, 0, sin(a1 + twist) * r1)
			# Alternate faces a touch darker so a flat-shaded cylinder still
			# reads as round rather than as a flat blob.
			var f: Color = col if s % 2 == 0 else col.darkened(0.07)
			quad(p0, p1, q1, q0, f)
		if r1 > 0.001:
			for s in range(sides):
				var a0: float = float(s) / float(sides) * TAU
				var a1: float = float(s + 1) / float(sides) * TAU
				tri(top,
					top + Vector3(cos(a0 + twist) * r1, 0, sin(a0 + twist) * r1),
					top + Vector3(cos(a1 + twist) * r1, 0, sin(a1 + twist) * r1),
					col.lightened(0.06))

	func cone(base_at: Vector3, h: float, r: float, sides: int, col: Color) -> void:
		var tip := base_at + Vector3(0, h, 0)
		for s in range(sides):
			var a0: float = float(s) / float(sides) * TAU
			var a1: float = float(s + 1) / float(sides) * TAU
			var p0 := base_at + Vector3(cos(a0) * r, 0, sin(a0) * r)
			var p1 := base_at + Vector3(cos(a1) * r, 0, sin(a1) * r)
			# Faces turned toward the key light are brighter. Baking the light
			# direction into the mesh keeps the prop consistent with the
			# terrain, which is lit the same way.
			var face_dir: Vector3 = Vector3(cos((a0 + a1) * 0.5), 0.45,
				sin((a0 + a1) * 0.5)).normalized()
			var k: float = clampf(face_dir.dot(Shade.SUN_DIR.normalized()) * 0.5 + 0.5,
				0.0, 1.0)
			tri(p0, p1, tip, col.lerp(col.lightened(0.26), k))

	# An irregular lump: rocks, boulders, rubble, skull piles.
	func lump(centre: Vector3, r: float, sd: int, col: Color,
			squash: float = 0.75, jag: float = 0.30) -> void:
		# 7x12 rather than 4x6. Quadruples the facet count, which is what lets a
		# rock read as a weathered boulder instead of a cut gem — and at a few
		# hundred triangles per prop, drawn through MultiMesh, it is affordable.
		var rows: int = 7
		var cols: int = 12
		var grid: Array = []
		for ry in range(rows + 1):
			var ring: Array = []
			var phi: float = float(ry) / float(rows) * PI
			for cx in range(cols):
				var th: float = float(cx) / float(cols) * TAU
				var rr: float = r * (1.0 - jag + Rng.unit3(sd, ry, cx, 0) * jag * 2.0)
				ring.append(centre + Vector3(
					sin(phi) * cos(th) * rr,
					cos(phi) * rr * squash,
					sin(phi) * sin(th) * rr))
			grid.append(ring)
		for ry in range(rows):
			for cx in range(cols):
				var nx: int = (cx + 1) % cols
				var a: Vector3 = grid[ry][cx]
				var b: Vector3 = grid[ry][nx]
				var d: Vector3 = grid[ry + 1][nx]
				var e: Vector3 = grid[ry + 1][cx]
				var up: float = 1.0 - float(ry) / float(rows)
				quad(a, b, d, e, col.lerp(col.lightened(0.22), up * 0.7))

	# Darken the lowest part of a prop before committing. Real objects gather
	# occlusion where they meet the ground; without it every tree and rock looks
	# pasted onto the terrain rather than growing out of it. This is the cheapest
	# "contact shadow" there is — no extra geometry, no extra draw, and it works
	# under any light because it is baked into the albedo.
	func ground_contact(fade_height: float = 0.55, strength: float = 0.45) -> void:
		for k in range(v.size()):
			var y: float = v[k].y
			if y >= fade_height:
				continue
			var t: float = clampf(y / maxf(fade_height, 0.0001), 0.0, 1.0)
			var f: float = lerpf(1.0 - strength, 1.0, t * t)
			var col: Color = c[k]
			c[k] = Color(col.r * f, col.g * f, col.b * f, col.a)

	func commit() -> ArrayMesh:
		if v.is_empty():
			return null
		var arr: Array = []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_COLOR] = c
		arr[Mesh.ARRAY_INDEX] = i
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		return m


# ------------------------------------------------------------------------------
# The prop library
# ------------------------------------------------------------------------------

static func material() -> ShaderMaterial:
	# Shares the terrain's noise so ground and props agree about surface scale.
	var m := ShaderMaterial.new()
	m.shader = load("res://scripts/world/prop.gdshader")
	m.set_shader_parameter("grain", Mesher._noise_tex(1101, 0.021, 4, 512, false))
	m.set_shader_parameter("relief", Mesher._noise_tex(3307, 0.016, 4, 512, true, 2.4))
	return m


# Build one prop. `variant` lets a biome carry several shapes of the same kind so
# a forest is not one tree stamped three hundred times.
static func build(kind: String, biome_id: String, variant: int) -> ArrayMesh:
	var b: Dictionary = Biome.get_biome(biome_id)
	var sd: int = Rng.seed_of(Rng.seed_of(12345, kind), str(variant))
	var bd := Build.new()

	# Shared palette reads. Foliage descends from the biome's high ground colour
	# and bark from its soil, so a tree always belongs to its biome.
	# Foliage is darker and more saturated than the ground. Canopy lighter than
	# grass reads as fog, not as a tree — the first prop pass made that mistake
	# and the whole forest went flat.
	var leaf: Color = (b["ground_lo"] as Color).lerp(b["accent"] as Color,
		0.06 + Rng.unit1(sd, 3) * 0.14).darkened(0.16)
	var bark: Color = (b["soil"] as Color).darkened(0.12)
	var stone: Color = b["rock"]
	var accent: Color = b["accent"]

	match kind:
		"tree_conifer":
			var h: float = 3.6 + Rng.unit1(sd, 1) * 2.6
			bd.drum(Vector3.ZERO, Vector3(0, h * 0.32, 0), 0.19, 0.12, 9, bark)
			# Three stacked skirts, each smaller and lighter than the one below.
			for t in range(3):
				var at: float = h * (0.22 + float(t) * 0.22)
				var rr: float = (0.20 - float(t) * 0.042) * h
				var hh: float = h * (0.40 - float(t) * 0.06)
				bd.cone(Vector3(0, at, 0), hh, rr, 11,
					leaf.lightened(float(t) * 0.09))

		"tree_broad":
			var h2: float = 3.2 + Rng.unit1(sd, 2) * 2.4
			bd.drum(Vector3.ZERO, Vector3(0, h2 * 0.45, 0), 0.24, 0.16, 9, bark)
			# A canopy of overlapping lumps rather than one sphere — reads as
			# foliage clusters instead of a lollipop.
			# Six clusters at mixed radii and heights rather than four equal ones.
			# An even ring of same-size lumps reads as a single bush; uneven
			# clusters give the ragged edge that says "tree" at a glance.
			var lobes: int = 5 + int(Rng.unit1(sd, 21) * 3.0)
			for c in range(lobes):
				var a: float = float(c) / float(lobes) * TAU + Rng.unit1(sd, c) * 1.4
				var out_r: float = h2 * (0.10 + Rng.unit1(sd, c + 17) * 0.13)
				var rad: float = h2 * (0.12 + Rng.unit1(sd, c + 7) * 0.10)
				bd.lump(Vector3(cos(a) * out_r,
					h2 * (0.58 + Rng.unit1(sd, c + 3) * 0.30),
					sin(a) * out_r), rad, sd + c,
					leaf.lightened(Rng.unit1(sd, c + 11) * 0.18), 0.86, 0.30)
			# A crown lump to close the top, or the silhouette reads as a ring.
			bd.lump(Vector3(0, h2 * 0.92, 0), h2 * 0.15, sd + 31,
				leaf.lightened(0.14), 0.78, 0.24)

		"tree_dead":
			var h3: float = 3.4 + Rng.unit1(sd, 4) * 2.8
			bd.drum(Vector3.ZERO, Vector3(0, h3, 0), 0.22, 0.05, 9, bark, 0.3)
			for br in range(3):
				var a2: float = float(br) / 3.0 * TAU + Rng.unit1(sd, br) * 1.5
				var at2: float = h3 * (0.5 + Rng.unit1(sd, br + 5) * 0.35)
				var len2: float = h3 * (0.22 + Rng.unit1(sd, br + 9) * 0.2)
				bd.drum(Vector3(0, at2, 0),
					Vector3(cos(a2) * len2, at2 + len2 * 0.7, sin(a2) * len2),
					0.08, 0.02, 4, bark)

		"stump":
			bd.drum(Vector3.ZERO, Vector3(0, 0.5 + Rng.unit1(sd, 1) * 0.4,
				0), 0.34, 0.30, 10, bark)

		"log":
			var ln: float = 1.6 + Rng.unit1(sd, 1) * 1.6
			bd.drum(Vector3(-ln * 0.5, 0.22, 0), Vector3(ln * 0.5, 0.22, 0),
				0.22, 0.19, 10, bark)

		"bush":
			var n2: int = 2 + int(Rng.unit1(sd, 1) * 2.0)
			for c2 in range(n2):
				var a3: float = float(c2) / float(n2) * TAU
				bd.lump(Vector3(cos(a3) * 0.3, 0.32 + Rng.unit1(sd, c2) * 0.2,
					sin(a3) * 0.3), 0.42 + Rng.unit1(sd, c2 + 4) * 0.26,
					sd + c2, leaf.darkened(0.08), 0.78, 0.32)

		"thorn":
			for sp in range(6):
				var a4: float = float(sp) / 6.0 * TAU
				var lean := Vector3(cos(a4) * 0.5, 1.0 + Rng.unit1(sd, sp) * 0.7,
					sin(a4) * 0.5)
				bd.drum(Vector3(cos(a4) * 0.14, 0, sin(a4) * 0.14), lean,
					0.07, 0.01, 4, accent.darkened(0.40))

		"reed":
			for r2 in range(7):
				var off := Vector3(Rng.range2(sd, r2, 1, -0.3, 0.3), 0.0,
					Rng.range2(sd, r2, 2, -0.3, 0.3))
				var hh2: float = 0.8 + Rng.unit2(sd, r2, 3) * 0.9
				bd.drum(off, off + Vector3(Rng.range2(sd, r2, 4, -0.2, 0.2), hh2,
					Rng.range2(sd, r2, 5, -0.2, 0.2)), 0.035, 0.008, 3,
					leaf.darkened(0.12))

		"grass_tuft":
			# Nine blades rather than five, and taller. At five the tufts read as
			# stray weeds on bare dirt instead of as ground that has grass on it.
			var blades: int = 7 + int(Rng.unit1(sd, 11) * 3.0)
			for g in range(blades):
				var off2 := Vector3(Rng.range2(sd, g, 1, -0.20, 0.20), 0.0,
					Rng.range2(sd, g, 2, -0.20, 0.20))
				var bh: float = 0.42 + Rng.unit2(sd, g, 4) * 0.38
				bd.drum(off2, off2 + Vector3(Rng.range2(sd, g, 3, -0.20, 0.20),
					bh, Rng.range2(sd, g, 5, -0.20, 0.20)), 0.035, 0.004, 3,
					leaf.lightened(Rng.unit2(sd, g, 6) * 0.18))

		"flower":
			bd.drum(Vector3.ZERO, Vector3(0, 0.26, 0), 0.025, 0.018, 5,
				leaf.darkened(0.1))
			bd.lump(Vector3(0, 0.3, 0), 0.09, sd, accent, 0.7, 0.2)

		"mushroom":
			var mh: float = 0.22 + Rng.unit1(sd, 1) * 0.3
			bd.drum(Vector3.ZERO, Vector3(0, mh, 0), 0.055, 0.045, 5,
				Color(0.86, 0.84, 0.76))
			bd.lump(Vector3(0, mh, 0), 0.17 + Rng.unit1(sd, 2) * 0.1, sd,
				accent, 0.52, 0.14)

		"rock_small":
			bd.lump(Vector3(0, 0.16, 0), 0.30 + Rng.unit1(sd, 1) * 0.22, sd,
				stone, 0.72, 0.34)

		"rock_large":
			bd.lump(Vector3(0, 0.5, 0), 0.95 + Rng.unit1(sd, 1) * 0.7, sd,
				stone, 0.78, 0.30)

		"boulder":
			bd.lump(Vector3(0, 0.8, 0), 1.5 + Rng.unit1(sd, 1) * 1.1, sd,
				stone.darkened(0.06), 0.84, 0.26)

		"lava_rock":
			bd.lump(Vector3(0, 0.35, 0), 0.7 + Rng.unit1(sd, 1) * 0.6, sd,
				stone.darkened(0.2), 0.7, 0.38)
			# A glowing seam in the crust — this is why emission is packed into
			# vertex alpha: one mesh, one draw call, two materials' worth of look.
			# A glowing seam in the crust — this is why emission is a builder
			# state: one mesh, one draw call, two materials' worth of look.
			bd.emit = 0.8
			bd.lump(Vector3(0, 0.12, 0), 0.34, sd + 3, accent, 0.4, 0.2)
			bd.emit = 0.0

		"stalagmite":
			var sh: float = 1.4 + Rng.unit1(sd, 1) * 2.4
			bd.cone(Vector3.ZERO, sh, 0.30 + Rng.unit1(sd, 2) * 0.22, 10, stone)

		"crystal", "ice_shard":
			var ch: float = 1.0 + Rng.unit1(sd, 1) * 2.2
			var col: Color = accent if kind == "crystal" else accent.lightened(0.3)
			# Crystals glow; ice only catches the light.
			bd.emit = 0.42 if kind == "crystal" else 0.06
			# A main shaft plus two smaller ones, all leaning slightly apart.
			bd.drum(Vector3.ZERO, Vector3(0, ch, 0), 0.26, 0.05, 7, col, 0.4)
			for k2 in range(2):
				var a5: float = float(k2) * PI + Rng.unit1(sd, k2) * 2.0
				var o := Vector3(cos(a5) * 0.28, 0, sin(a5) * 0.28)
				bd.drum(o, o + Vector3(cos(a5) * 0.35, ch * 0.55, sin(a5) * 0.35),
					0.14, 0.03, 7, col.lightened(0.12), 0.3)

		"bone":
			bd.drum(Vector3(-0.5, 0.1, 0), Vector3(0.5, 0.1, 0), 0.07, 0.07, 5,
				Color(0.84, 0.82, 0.72))
			for e2 in [-0.55, 0.55]:
				bd.lump(Vector3(e2, 0.1, 0), 0.13, sd, Color(0.88, 0.86, 0.76),
					0.9, 0.18)

		"skull_pile":
			for s2 in range(5):
				bd.lump(Vector3(Rng.range2(sd, s2, 1, -0.4, 0.4),
					0.16 + Rng.unit2(sd, s2, 2) * 0.35,
					Rng.range2(sd, s2, 3, -0.4, 0.4)),
					0.20 + Rng.unit2(sd, s2, 4) * 0.08, sd + s2,
					Color(0.82, 0.80, 0.70), 0.88, 0.2)

		"pillar":
			var ph: float = 3.0 + Rng.unit1(sd, 1) * 3.0
			# Broken at a random height — intact columns everywhere look staged.
			bd.drum(Vector3(0, 0, 0), Vector3(0, 0.22, 0), 0.52, 0.46, 12,
				stone.lightened(0.05))
			bd.drum(Vector3(0, 0.22, 0), Vector3(0, ph, 0), 0.38, 0.34, 12, stone)

		"ruin_wall":
			var wl2: float = 2.2 + Rng.unit1(sd, 1) * 2.6
			var wh: float = 1.2 + Rng.unit1(sd, 2) * 1.8
			# Courses of stone with a ragged top edge.
			var courses: int = maxi(int(wh / 0.42), 2)
			for c3 in range(courses):
				var frac: float = float(c3) / float(courses)
				var run: float = wl2 * (1.0 - frac * Rng.unit1(sd, c3) * 0.55)
				var y0: float = frac * wh
				bd.drum(Vector3(-run * 0.5, y0, 0), Vector3(run * 0.5, y0, 0),
					0.22, 0.22, 4,
					stone.lightened(0.04 * float(c3 % 3)))

		"statue":
			bd.drum(Vector3.ZERO, Vector3(0, 0.4, 0), 0.6, 0.55, 10,
				stone.darkened(0.08))
			bd.drum(Vector3(0, 0.4, 0), Vector3(0, 1.9, 0), 0.32, 0.26, 10, stone)
			bd.lump(Vector3(0, 2.1, 0), 0.3, sd, stone.lightened(0.08), 0.95, 0.16)

		"brazier":
			bd.drum(Vector3.ZERO, Vector3(0, 0.9, 0), 0.14, 0.1, 5,
				stone.darkened(0.2))
			bd.drum(Vector3(0, 0.9, 0), Vector3(0, 1.25, 0), 0.22, 0.34, 7,
				stone.darkened(0.1))
			bd.emit = 1.0
			bd.lump(Vector3(0, 1.35, 0), 0.26, sd, accent, 0.8, 0.3)
			bd.emit = 0.0

		"totem":
			var th2: float = 2.0 + Rng.unit1(sd, 1) * 1.6
			bd.drum(Vector3.ZERO, Vector3(0, th2, 0), 0.26, 0.22, 5, bark)
			for r3 in range(3):
				var y2: float = th2 * (0.25 + float(r3) * 0.25)
				bd.drum(Vector3(0, y2, 0), Vector3(0, y2 + 0.14, 0), 0.34, 0.34,
					5, accent.darkened(0.25 + float(r3) * 0.08))

		"banner":
			bd.drum(Vector3.ZERO, Vector3(0, 3.0, 0), 0.07, 0.06, 4,
				stone.darkened(0.25))
			# The cloth: a simple hanging quad, double-sided via CULL_DISABLED.
			bd.quad(Vector3(0.04, 2.9, 0), Vector3(0.04, 2.9, 1.1),
				Vector3(0.04, 1.4, 1.0), Vector3(0.04, 1.3, 0), accent)

		# ---- added vocabulary ------------------------------------------
		# Eight more shapes, built from the same drum/cone/lump helpers as
		# everything above. The point is not novelty for its own sake: the
		# old set was heavy on vegetation and light on anything BUILT or
		# anything that reads as a landmark, so every biome's silhouette came
		# from trees and rocks and the ruined ones had almost nothing of
		# their own.

		"cairn":
			# A stack of shrinking stones. Reads as deliberate — someone
			# was here — which is what a wilderness biome has none of.
			var cn: int = 3 + int(Rng.unit1(sd, 1) * 3.0)
			var cy: float = 0.0
			for ci in range(cn):
				var cr: float = 0.42 * (1.0 - float(ci) / float(cn + 1))
				var ch: float = 0.20 + Rng.unit1(sd, ci + 2) * 0.14
				bd.lump(Vector3(0, cy + ch * 0.5, 0), cr, sd + ci,
					stone.lightened(0.03 * float(ci % 3)), 0.6, 0.22)
				cy += ch

		"standing_stone":
			# A single leaning monolith. The lean is what stops a field of
			# them looking like fence posts.
			var sh: float = 2.4 + Rng.unit1(sd, 1) * 2.2
			var tilt: float = (Rng.unit1(sd, 2) - 0.5) * 0.5
			bd.drum(Vector3.ZERO, Vector3(tilt, sh, tilt * 0.6),
				0.46, 0.30, 5, stone)
			bd.lump(Vector3(tilt, sh, tilt * 0.6), 0.26, sd,
				stone.lightened(0.05), 0.5, 0.3)

		"arch":
			# Two posts and a lintel: the smallest thing that reads as
			# architecture rather than geology.
			var aw: float = 1.3 + Rng.unit1(sd, 1) * 0.9
			var ah: float = 2.2 + Rng.unit1(sd, 2) * 1.4
			for side in [-1.0, 1.0]:
				bd.drum(Vector3(aw * side, 0, 0), Vector3(aw * side, ah, 0),
					0.30, 0.26, 8, stone)
			bd.drum(Vector3(-aw - 0.2, ah, 0), Vector3(aw + 0.2, ah, 0),
				0.26, 0.26, 6, stone.lightened(0.04))

		"obelisk":
			# Tall, four-sided, sharply tapered — a landmark visible across
			# an open map, which a hollow badly needs.
			var oh: float = 3.4 + Rng.unit1(sd, 1) * 2.6
			bd.drum(Vector3.ZERO, Vector3(0, 0.3, 0), 0.6, 0.52, 4,
				stone.darkened(0.1))
			bd.drum(Vector3(0, 0.3, 0), Vector3(0, oh, 0), 0.44, 0.16, 4,
				stone)
			bd.cone(Vector3(0, oh, 0), 0.5, 0.16, 4, accent.darkened(0.2))

		"root_arch":
			# A root humped out of the ground and back in. Low, wide, and
			# the only prop that is an obstacle without being a wall.
			var rl: float = 1.4 + Rng.unit1(sd, 1) * 1.2
			var rh: float = 0.5 + Rng.unit1(sd, 2) * 0.6
			bd.drum(Vector3(-rl, 0, 0), Vector3(-rl * 0.35, rh, 0),
				0.17, 0.21, 6, bark)
			bd.drum(Vector3(-rl * 0.35, rh, 0), Vector3(rl * 0.35, rh, 0),
				0.21, 0.21, 6, bark.lightened(0.04))
			bd.drum(Vector3(rl * 0.35, rh, 0), Vector3(rl, 0, 0),
				0.21, 0.17, 6, bark)

		"fungus_shelf":
			# A stump wearing brackets. Gives damp biomes something that is
			# neither grass nor rock.
			bd.drum(Vector3.ZERO, Vector3(0, 0.7, 0), 0.34, 0.30, 9,
				bark.darkened(0.1))
			var fn: int = 3 + int(Rng.unit1(sd, 1) * 3.0)
			for fi in range(fn):
				var ang: float = TAU * float(fi) / float(fn)
				var fy: float = 0.2 + Rng.unit1(sd, fi + 2) * 0.45
				var off := Vector3(cos(ang) * 0.3, fy, sin(ang) * 0.3)
				bd.drum(off, off + Vector3(cos(ang) * 0.3, 0.04,
					sin(ang) * 0.3), 0.05, 0.26, 7,
					leaf.lightened(0.22))

		"ash_cone":
			# A low vent with a dark throat. Volcanic biomes had lava rock
			# and nothing with a shape.
			var ar: float = 0.9 + Rng.unit1(sd, 1) * 0.8
			bd.cone(Vector3.ZERO, ar * 0.8, ar, 10, stone.darkened(0.14))
			bd.emit = 0.5
			bd.cone(Vector3(0, ar * 0.42, 0), ar * 0.26, ar * 0.3, 8,
				accent)
			bd.emit = 0.0

		"shard_cluster":
			# Several thin spikes from one base. Shares crystal's language
			# without sharing its silhouette.
			var kn: int = 3 + int(Rng.unit1(sd, 1) * 4.0)
			bd.emit = 0.22
			for ki in range(kn):
				var ka: float = TAU * float(ki) / float(kn)
				var kr: float = 0.18 + Rng.unit1(sd, ki + 2) * 0.3
				var kh: float = 0.7 + Rng.unit1(sd, ki + 9) * 1.5
				bd.cone(Vector3(cos(ka) * kr, 0, sin(ka) * kr), kh,
					0.10 + Rng.unit1(sd, ki + 5) * 0.08, 5,
					accent.lightened(0.1 * float(ki % 3)))
			bd.emit = 0.0

		"fern":
			# A low rosette of fronds. Cheap, but it breaks up flat ground far
			# better than more grass does because the silhouette differs.
			var fronds: int = 5 + int(Rng.unit1(sd, 1) * 3.0)
			for f in range(fronds):
				var fa: float = float(f) / float(fronds) * TAU + Rng.unit1(sd, f) * 0.6
				var fl: float = 0.34 + Rng.unit1(sd, f + 5) * 0.26
				var tipv := Vector3(cos(fa) * fl, 0.16 + fl * 0.5, sin(fa) * fl)
				bd.drum(Vector3(cos(fa) * 0.04, 0.0, sin(fa) * 0.04), tipv,
					0.055, 0.01, 3, leaf.darkened(Rng.unit1(sd, f + 9) * 0.16))

		"pebble":
			var pn: int = 2 + int(Rng.unit1(sd, 1) * 3.0)
			for pb in range(pn):
				bd.lump(Vector3(Rng.range2(sd, pb, 1, -0.22, 0.22),
					0.045 + Rng.unit2(sd, pb, 2) * 0.05,
					Rng.range2(sd, pb, 3, -0.22, 0.22)),
					0.07 + Rng.unit2(sd, pb, 4) * 0.07, sd + pb,
					stone.lightened(Rng.unit2(sd, pb, 5) * 0.16), 0.66, 0.34)

		"twig":
			var tl: float = 0.3 + Rng.unit1(sd, 1) * 0.4
			var ta: float = Rng.unit1(sd, 2) * TAU
			bd.drum(Vector3(-cos(ta) * tl * 0.5, 0.045, -sin(ta) * tl * 0.5),
				Vector3(cos(ta) * tl * 0.5, 0.05, sin(ta) * tl * 0.5),
				0.035, 0.022, 4, bark)

		_:
			bd.lump(Vector3(0, 0.2, 0), 0.3, sd, stone, 0.8, 0.3)

	# Ground contact, scaled to the kind: a boulder needs a deeper skirt than a
	# mushroom, and flat ground litter needs none at all.
	match kind:
		"grass_tuft", "flower", "twig", "pebble", "bone", "log", "reed":
			pass
		"boulder", "rock_large", "statue", "pillar", "ruin_wall", "tree_broad", \
		"tree_conifer", "tree_dead", "stalagmite":
			bd.ground_contact(0.85, 0.46)
		_:
			bd.ground_contact(0.40, 0.38)
	return bd.commit()


# How many shape variants to generate for a kind. Things the player sees in
# quantity get more; one-offs get fewer.
static func variants_for(kind: String) -> int:
	match kind:
		"grass_tuft", "pebble", "fern", "twig":
			# Ground cover is seen in the thousands, so it needs the most shapes.
			return 7
		"tree_conifer", "tree_broad", "tree_dead", "rock_small", \
		"bush", "crystal", "rock_large":
			return 5
		"statue", "banner", "brazier", "totem":
			return 2
		_:
			return 3
