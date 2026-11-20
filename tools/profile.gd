extends SceneTree
# Where does region generation actually spend its time? Threading the wrong
# pass is wasted work, so measure before designing.

func _init() -> void:
	var CELLS := 384
	var CELL := 0.5
	var t0: int = Time.get_ticks_usec()

	var plan := Layout.generate(7000, Vector2(CELLS * CELL, CELLS * CELL),
		Layout.Sym.ASYMMETRIC, 11)
	var t_layout: int = Time.get_ticks_usec() - t0

	# Time the terrain passes individually by rebuilding the object by hand.
	var t := Terrain.new()
	t.seed = Rng.seed_of(7000, "terrain")
	t.biome_id = "greenwood"
	t.size = CELLS
	t.cell = CELL
	t.layout = plan
	# Match what Terrain.generate() does. It builds serially — see the measured
	# justification in Terrain.generate() and docs/THREADING.md.
	t._bands_n = 1
	var n: int = CELLS * CELLS
	for arr in [t.h, t.h_macro, t.ao, t.slope, t.carve]:
		arr.resize(n)
	t.surf.resize(n)
	t.walk.resize(n)

	var marks: Array = []
	var last: int = Time.get_ticks_usec()
	for step in [["_build_fields", "_build_fields"], ["_macro", "_macro"], ["_normalise_slope", "_normalise_slope"],
			["_set_water_level", "_set_water_level"], ["_rim", "_rim"],
			["_carve_layout", "_carve_layout"], ["_path_field", "_path_field"], ["_basins", "_basins"],
			["_terrace", "_terrace"], ["_micro", "_micro"], ["_derive", "_derive"]]:
		t.call(step[1])
		var now: int = Time.get_ticks_usec()
		marks.append([step[0], now - last])
		last = now

	# Shade.bake() is a static on Shade, not a Terrain method, so it cannot ride
	# the step loop above — but it is part of the pipeline and must be measured.
	var t_bake0: int = Time.get_ticks_usec()
	Shade.bake(t)
	marks.append(["Shade.bake", Time.get_ticks_usec() - t_bake0])

	var t1: int = Time.get_ticks_usec()
	var scat := Scatter.generate(t, plan, 7000)
	var t_scatter: int = Time.get_ticks_usec() - t1

	t1 = Time.get_ticks_usec()
	var chunks: Array = Mesher.build_chunks(t, 1)
	var t_mesh: int = Time.get_ticks_usec() - t1

	t1 = Time.get_ticks_usec()
	var built: int = 0
	for key in scat.buckets().keys():
		var parts: PackedStringArray = String(key).split("#")
		Props.build(parts[0], "greenwood", int(parts[1]))
		built += 1
	for key in scat.cover_buckets().keys():
		var parts2: PackedStringArray = String(key).split("#")
		Props.build(parts2[0], "greenwood", int(parts2[1]))
		built += 1
	var t_props: int = Time.get_ticks_usec() - t1

	var total: int = Time.get_ticks_usec() - t0
	print("\n=== region generation profile (384^2 = %d cells, greenwood) ===" % n)
	print("%-22s %8.1f ms  %5.1f%%" % ["Layout.generate", t_layout / 1000.0,
		100.0 * float(t_layout) / float(total)])
	for m in marks:
		var label: String = String(m[0])
		if not label.begins_with("Shade"):
			label = "Terrain." + label
		print("%-22s %8.1f ms  %5.1f%%" % [label,
			float(m[1]) / 1000.0, 100.0 * float(m[1]) / float(total)])
	print("%-22s %8.1f ms  %5.1f%%" % ["Scatter (props+cover)", t_scatter / 1000.0,
		100.0 * float(t_scatter) / float(total)])
	print("%-22s %8.1f ms  %5.1f%%" % ["Mesher.build_chunks", t_mesh / 1000.0,
		100.0 * float(t_mesh) / float(total)])
	print("%-22s %8.1f ms  %5.1f%%" % ["Props.build x%d" % built, t_props / 1000.0,
		100.0 * float(t_props) / float(total)])
	print("%-22s %8.1f ms" % ["TOTAL", total / 1000.0])

	# How much of the cost is my hand-written GDScript noise?
	t1 = Time.get_ticks_usec()
	var acc: float = 0.0
	for i in range(200000):
		acc += Rng.fbm(123, float(i) * 0.01, float(i) * 0.013, 4)
	var t_gd: int = Time.get_ticks_usec() - t1

	var fnl := FastNoiseLite.new()
	fnl.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fnl.fractal_octaves = 4
	t1 = Time.get_ticks_usec()
	for i in range(200000):
		acc += fnl.get_noise_2d(float(i) * 0.01, float(i) * 0.013)
	var t_fnl: int = Time.get_ticks_usec() - t1

	print("\n=== noise: 200k 4-octave samples ===")
	print("Rng.fbm (GDScript)     %8.1f ms" % (t_gd / 1000.0))
	print("FastNoiseLite (C++)    %8.1f ms   -> %.1fx faster" % [
		t_fnl / 1000.0, float(t_gd) / maxf(float(t_fnl), 1.0)])
	quit()
