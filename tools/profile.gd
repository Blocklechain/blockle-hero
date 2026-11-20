extends SceneTree
# Where does region generation actually spend its time? Threading the wrong
# pass is wasted work, so measure before designing.
#
# BOTH LAYOUT KINDS are profiled, in the same process, at the same size and
# biome. A lane is a 380 m route carved through the region while an arena is a
# dozen discs joined by corridors, and the carve pass is output-sensitive — so
# "does a lane cost more to generate than an arena" is a question with a number,
# not an opinion. The two tables are printed side by side at the end.
#
#   godot --headless --path . --script tools/profile.gd

const CELLS := 384
const CELL := 0.5
const STEPS: Array[String] = ["_build_fields", "_macro", "_normalise_slope",
	"_set_water_level", "_rim", "_carve_layout", "_path_field", "_basins",
	"_terrace", "_micro", "_derive"]


func _init() -> void:
	var arena: Dictionary = _profile(Terrain.Kind.ARENA)
	var lane: Dictionary = _profile(Terrain.Kind.LANE)

	_report("ARENA — Layout.gd", arena)
	_report("LANE — Lane.gd", lane)

	print("\n=== lane vs arena, per pass (negative = the lane is cheaper) ===")
	var rows: Array = arena["rows"]
	for i in range(rows.size()):
		var a: float = float((arena["rows"][i] as Array)[1])
		var b: float = float((lane["rows"][i] as Array)[1])
		print("%-22s %8.1f ms -> %8.1f ms  %+7.1f ms  %+6.1f%%" % [
			String((rows[i] as Array)[0]), a / 1000.0, b / 1000.0,
			(b - a) / 1000.0, 100.0 * (b - a) / maxf(a, 1.0)])
	print("%-22s %8.1f ms -> %8.1f ms  %+7.1f ms  %+6.1f%%" % ["TOTAL",
		float(arena["total"]) / 1000.0, float(lane["total"]) / 1000.0,
		float(lane["total"] - arena["total"]) / 1000.0,
		100.0 * float(lane["total"] - arena["total"]) / maxf(float(arena["total"]), 1.0)])

	_noise_baseline()
	quit()


# One region, timed pass by pass. The terrain object is assembled by hand so the
# steps can be called individually; Terrain.generate() runs exactly this list.
func _profile(kind: int) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	var plan: Layout = Terrain.plan_for(kind, 7000,
		Vector2(CELLS * CELL, CELLS * CELL), Layout.Sym.ASYMMETRIC, 11)
	var t_layout: int = Time.get_ticks_usec() - t0

	var t := Terrain.new()
	t.seed = Rng.seed_of(7000, "terrain")
	t.biome_id = "greenwood"
	t.size = CELLS
	t.cell = CELL
	t.layout = plan
	t.layout_kind = Terrain.kind_of(plan)
	# Match what Terrain.generate() does. It builds serially — see the measured
	# justification in Terrain.generate() and docs/THREADING.md.
	t._bands_n = 1
	var n: int = CELLS * CELLS
	for arr in [t.h, t.h_macro, t.ao, t.slope, t.carve]:
		arr.resize(n)
	t.surf.resize(n)
	t.walk.resize(n)

	var rows: Array = [["Layout.generate", t_layout]]
	var last: int = Time.get_ticks_usec()
	for step in STEPS:
		t.call(step)
		var now: int = Time.get_ticks_usec()
		rows.append(["Terrain." + step, now - last])
		last = now

	# Shade.bake() is a static on Shade, not a Terrain method, so it cannot ride
	# the step loop above — but it is part of the pipeline and must be measured.
	var t_bake0: int = Time.get_ticks_usec()
	Shade.bake(t)
	rows.append(["Shade.bake", Time.get_ticks_usec() - t_bake0])

	var t1: int = Time.get_ticks_usec()
	var scat := Scatter.generate(t, plan, 7000)
	rows.append(["Scatter (props+cover)", Time.get_ticks_usec() - t1])

	t1 = Time.get_ticks_usec()
	var chunks: Array = Mesher.build_chunks(t, 1)
	rows.append(["Mesher.build_chunks", Time.get_ticks_usec() - t1])

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
	rows.append(["Props.build x%d" % built, Time.get_ticks_usec() - t1])

	return {
		"rows": rows,
		"total": Time.get_ticks_usec() - t0,
		"plan": plan,
		"chunks": chunks.size(),
		"props": scat.items.size(),
		"cover": scat.cover.size(),
	}


func _report(title: String, r: Dictionary) -> void:
	var plan: Layout = r["plan"]
	var shape: String = "%d nodes, %d edges" % [plan.nodes.size(),
		plan.edges.size()]
	if plan is Lane:
		shape += ", %.0f m of lane" % (plan as Lane).spine_length
	print("\n=== %s (384^2 = %d cells, greenwood; %s) ===" % [title,
		CELLS * CELLS, shape])
	var total: float = maxf(float(r["total"]), 1.0)
	for row in r["rows"]:
		print("%-22s %8.1f ms  %5.1f%%" % [String((row as Array)[0]),
			float((row as Array)[1]) / 1000.0,
			100.0 * float((row as Array)[1]) / total])
	print("%-22s %8.1f ms   (%d chunks, %d props, %d cover)" % ["TOTAL",
		total / 1000.0, int(r["chunks"]), int(r["props"]), int(r["cover"])])


# How much of the cost is my hand-written GDScript noise?
func _noise_baseline() -> void:
	var t1: int = Time.get_ticks_usec()
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
