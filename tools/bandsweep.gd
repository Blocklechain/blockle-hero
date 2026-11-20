extends SceneTree
# Does banding actually help? Run the same passes at 1, 2, 4 and 8 bands inside
# one process so the comparison is apples to apples.

func _build(bands: int) -> Array:
	var CELLS := 384
	var CELL := 0.5
	var plan := Layout.generate(7000, Vector2(CELLS * CELL, CELLS * CELL),
		Layout.Sym.ASYMMETRIC, 11)
	var t := Terrain.new()
	t.seed = Rng.seed_of(7000, "terrain")
	t.biome_id = "greenwood"
	t.size = CELLS
	t.cell = CELL
	t.layout = plan
	t._bands_n = bands
	var n: int = CELLS * CELLS
	for arr in [t.h, t.h_macro, t.ao, t.slope, t.carve]:
		arr.resize(n)
	t.surf.resize(n)
	t.walk.resize(n)
	t._build_fields()

	var out: Array = []
	var last: int = Time.get_ticks_usec()
	for step in ["_macro", "_normalise_slope", "_set_water_level", "_rim",
			"_carve_layout", "_basins", "_terrace", "_micro", "_derive"]:
		t.call(step)
		var now: int = Time.get_ticks_usec()
		out.append(float(now - last) / 1000.0)
		last = now
	return [out, t]


func _init() -> void:
	var names := ["_macro", "_norm", "_water", "_rim", "_carve", "_basins",
		"_terrace", "_micro", "_derive"]
	var results: Dictionary = {}
	var checks: Dictionary = {}
	for bands in [1, 2, 4, 8]:
		var r: Array = _build(bands)
		results[bands] = r[0]
		# Correctness: the whole point is that banding changes nothing. Hash the
		# finished heightfield so a silent divergence cannot hide behind a
		# pretty speedup table.
		var t: Terrain = r[1]
		var acc: float = 0.0
		for i in range(0, t.h.size(), 97):
			acc += t.h[i] * float(i % 13 + 1)
		checks[bands] = acc

	print("\n=== pass time by band count (ms) ===")
	print("%-12s %9s %9s %9s %9s" % ["pass", "1 band", "2", "4", "8"])
	var totals := {1: 0.0, 2: 0.0, 4: 0.0, 8: 0.0}
	for i in range(names.size()):
		var row := "%-12s" % names[i]
		for bands in [1, 2, 4, 8]:
			var v: float = results[bands][i]
			totals[bands] += v
			row += " %9.1f" % v
		print(row)
	var trow := "%-12s" % "TOTAL"
	for bands in [1, 2, 4, 8]:
		trow += " %9.1f" % totals[bands]
	print(trow)
	print("\nspeedup vs 1 band:  2x=%.2f  4x=%.2f  8x=%.2f" % [
		totals[1] / totals[2], totals[1] / totals[4], totals[1] / totals[8]])

	print("\n=== correctness: heightfield checksum must be identical ===")
	for bands in [1, 2, 4, 8]:
		print("  %d band(s): %.6f%s" % [bands, checks[bands],
			"" if is_equal_approx(checks[bands], checks[1]) else "   <-- DIVERGED"])
	quit()
