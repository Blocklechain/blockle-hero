extends SceneTree
# ------------------------------------------------------------------------------
# MORE ART, AND ART THAT KNOWS WHAT MAP IT IS ON.
#
# Two failures this guards, both of which look fine in code review:
#
#   A PROP THAT BUILDS NOTHING. Props.build() returns an ArrayMesh from a
#   match statement. A kind that is listed in the biome tables but has no
#   branch falls through and returns an EMPTY mesh — the generator places it,
#   the scatter counts it, the pathing blocks on it, and the player sees a
#   hole in the ground. Nothing errors. So every kind the tables can emit is
#   built here and checked for actual triangles.
#
#   DRESSING THAT DOES NOTHING. Dress re-weights a biome's prop table by the
#   map's form. A bias dictionary with a typo'd key, or a form id that never
#   reaches Scatter, produces exactly the behaviour it had before — seven
#   floor plans wearing identical furniture — and no test of the rules alone
#   would notice.
# ------------------------------------------------------------------------------

const MapShapeS := preload("res://scripts/game/MapShape.gd")
const Dress := preload("res://scripts/world/Dress.gd")

var _fails: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-56s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


const WorldBuilderS := preload("res://scripts/world/WorldBuilder.gd")

func _init() -> void:
	_props()
	_dressing()
	_wired()


## THE WIRING GUARD. Everything above is pure: Dress could be perfect and
## still never be called, which is this repo's signature failure. So build
## two real worlds, same seed and same biome, differing only in form, and
## check the ground actually comes out different.
func _wired() -> void:
	print("\n=== the dressing reaches the generator ===")
	var warren: int = await _count("warren", 16)
	var hollow: int = await _count("hollow", 7)
	check("a warren plants more than a hollow at the same seed",
		warren > hollow, "%d props vs %d" % [warren, hollow])
	# Not merely different — meaningfully so, or the form is a rounding error.
	check("...and by enough to see", warren > int(float(hollow) * 1.4),
		"ratio %.2f" % (float(warren) / maxf(float(hollow), 1.0)))
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


func _count(form_id: String, nodes: int) -> int:
	var b := WorldBuilderS.new()
	root.add_child(b)
	var done := [false]
	var got := [null]
	b.finished.connect(func(r, _t, _p):
		got[0] = r
		done[0] = true)
	# Same seed, same biome, same size: form is the ONLY difference.
	if not b.build(777, "greenwood", 192, 0.5, Layout.Sym.ASYMMETRIC,
			nodes, Terrain.Kind.ARENA, form_id):
		print("    build() refused for ", form_id)
		b.queue_free()
		return -1
	var f := 0
	while not done[0] and f < 4000:
		await process_frame
		f += 1
	if not done[0]:
		print("    never finished after %d frames (%s)" % [f, form_id])
	elif got[0] == null:
		print("    finished but root was null (%s)" % form_id)
	var n: int = _multimesh_total(got[0]) if got[0] != null else -1
	b.queue_free()
	return n


## Props are drawn as MultiMeshes, one per kind/variant bucket, so the count
## is the sum of their instance counts rather than a child count.
func _multimesh_total(n: Node) -> int:
	var total: int = 0
	if n is MultiMeshInstance3D:
		var mm: MultiMesh = (n as MultiMeshInstance3D).multimesh
		if mm != null:
			total += mm.instance_count
	for c in n.get_children():
		total += _multimesh_total(c)
	return total


# ---- every prop the tables can emit actually exists --------------------------

func _props() -> void:
	print("\n=== the prop vocabulary ===")

	# Gather every kind any biome can actually place, which is the set that
	# matters — an unused entry in PROPS is harmless, a used one with no
	# mesh is a hole in the world.
	var used: Dictionary = {}
	for id in Biome.IDS:
		var table: Array = Biome.prop_table(id)
		for n in table[0]:
			used[String(n)] = true
	# Ground cover is a separate table on the biome and its kinds go through
	# the same Props.build(), so a broken one is the same hole in the world.
	for id in Biome.IDS:
		var cover: Dictionary = Biome.field(id, "cover", {}) as Dictionary
		for n in cover.keys():
			used[String(n)] = true

	var empty: Array = []
	for kind in used.keys():
		var mesh: ArrayMesh = Props.build(String(kind), "greenwood", 0)
		if mesh == null or mesh.get_surface_count() == 0:
			empty.append(kind)
			continue
		var arr: Array = mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if verts.size() < 3:
			empty.append(kind)
	check("every prop a biome can place builds real geometry",
		empty.is_empty(), "%d placed kinds, broken: %s"
			% [used.size(), str(empty)])

	# The eight added kinds, specifically — named so a failure says which
	# feature regressed rather than just "a prop".
	var added: PackedStringArray = ["cairn", "standing_stone", "arch",
		"obelisk", "root_arch", "fungus_shelf", "ash_cone", "shard_cluster"]
	var missing: Array = []
	var not_placed: Array = []
	for k in added:
		var m: ArrayMesh = Props.build(k, "greenwood", 0)
		if m == null or m.get_surface_count() == 0:
			missing.append(k)
		if not used.has(k):
			not_placed.append(k)
	check("the eight new props all build", missing.is_empty(),
		str(missing))
	# A new prop no biome lists is a prop nobody will ever see.
	check("...and every one of them is reachable from some biome",
		not_placed.is_empty(), "never placed: %s" % str(not_placed))

	# Variants must differ, or "variant" is decoration on the signature.
	var a: ArrayMesh = Props.build("cairn", "greenwood", 0)
	var b: ArrayMesh = Props.build("cairn", "greenwood", 3)
	var va: PackedVector3Array = a.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var vb: PackedVector3Array = b.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check("two variants of a prop are not the same mesh",
		va != vb, "%d vs %d verts" % [va.size(), vb.size()])

	# Every biome must still reference only kinds that exist.
	var unknown: Array = []
	for id in Biome.IDS:
		for n in Biome.prop_table(id)[0]:
			if not Biome.PROPS.has(String(n)):
				unknown.append("%s/%s" % [id, n])
	check("no biome references a prop outside the vocabulary",
		unknown.is_empty(), str(unknown))


# ---- the form changes what is standing there ---------------------------------

func _dressing() -> void:
	print("\n=== form dressing ===")

	var base: Array = Biome.prop_table("greenwood")

	# A form with no opinion must change nothing at all.
	var plain: Array = Dress.apply(base, "")
	check("an unknown form leaves the biome's own table alone",
		plain[1] == base[1])

	# Density must actually differ between the extremes, and in the right
	# direction: a warren is cluttered, a hollow is bare.
	var warren: float = Dress.density_scale("warren")
	var hollow: float = Dress.density_scale("hollow")
	check("a warren is denser than a hollow", warren > hollow * 2.0,
		"x%.2f vs x%.2f" % [warren, hollow])

	# And neither extreme may be absurd — these multiply a tuned figure, and
	# four times the props is a phone dropping frames.
	var worst: float = 0.0
	for f in MapShapeS.forms():
		worst = maxf(worst, Dress.density_scale(String(f.get("id", ""))))
	worst = maxf(worst, Dress.density_scale("colosseum"))
	check("no form more than doubles the prop budget", worst <= 2.0,
		"heaviest x%.2f" % worst)

	# THE MIX, not just the amount. A warren must prefer things you cannot
	# see past; a hollow must prefer things you can.
	var w: Array = Dress.apply(base, "warren")
	var h: Array = Dress.apply(base, "hollow")
	var w_struct: float = _share(w, Dress.STRUCTURE)
	var h_struct: float = _share(h, Dress.STRUCTURE)
	check("a warren is mostly things you cannot see past",
		w_struct > h_struct * 1.5,
		"%.0f%% vs %.0f%% structure" % [w_struct * 100.0, h_struct * 100.0])

	var col: Array = Dress.apply(base, "colosseum")
	check("a colosseum prefers things that were BUILT",
		_share(col, Dress.MADE) > _share(base, Dress.MADE) * 1.5,
		"%.0f%% vs %.0f%% made"
			% [_share(col, Dress.MADE) * 100.0,
				_share(base, Dress.MADE) * 100.0])

	# NOTHING IS ERASED. A form that zeroes a prop deletes part of a biome's
	# identity — a hollow in frostcrag must still have ice in it.
	for form in ["warren", "hollow", "causeway", "colosseum", "gauntlet"]:
		for id in Biome.IDS:
			var t: Array = Dress.apply(Biome.prop_table(id), form)
			for ww in t[1]:
				if float(ww) <= 0.0:
					check("%s/%s keeps every prop" % [form, id], false)
					return
	check("no form eliminates any of a biome's props entirely", true,
		"checked %d biomes x 5 forms" % Biome.IDS.size())


## What share of the total weight belongs to a family.
func _share(table: Array, family: PackedStringArray) -> float:
	var total: float = 0.0
	var hit: float = 0.0
	for i in range(table[0].size()):
		var wv: float = float(table[1][i])
		total += wv
		if family.has(String(table[0][i])):
			hit += wv
	return hit / maxf(total, 0.001)
