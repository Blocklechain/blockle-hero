extends SceneTree
# ------------------------------------------------------------------------------
# A HUNDRED MAPS SHOULD NOT BE ONE MAP.
#
# Before MapShape every campaign region was built as `Kind.LANE, 384 cells,
# 11 nodes`, because Play.gd passed those literals and nothing varied them.
# Sixteen biomes repainted one floor plan. This asserts the shapes are
# actually distributed, actually different, and actually affordable — a
# "variety" pass that quietly emits the same form for ninety of a hundred
# maps, or that doubles generation time on a phone, is worse than none.
# ------------------------------------------------------------------------------

const MapShapeS := preload("res://scripts/game/MapShape.gd")

var _fails: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _init() -> void:
	var n: int = Campaign.map_count()

	# ---- every map has a usable shape ---------------------------------------
	var bad: int = 0
	for i in range(n):
		var cells: int = MapShapeS.cells_at(i)
		var nodes: int = MapShapeS.nodes_at(i)
		var kind: int = MapShapeS.kind_at(i)
		if cells < MapShapeS.CELLS_MIN or cells > MapShapeS.CELLS_MAX:
			bad += 1
		if nodes < MapShapeS.NODES_MIN or nodes > MapShapeS.NODES_MAX:
			bad += 1
		if kind != Terrain.Kind.LANE and kind != Terrain.Kind.ARENA:
			bad += 1
		if String(MapShapeS.name_at(i)).is_empty():
			bad += 1
	check("every map's shape is within the buildable bounds", bad == 0,
		"%d out of range" % bad)

	# ---- the forms are actually used ----------------------------------------
	var seen: Dictionary = {}
	for i in range(n):
		var id: String = String(MapShapeS.at(i).get("id", "?"))
		seen[id] = int(seen.get(id, 0)) + 1
	var want: int = MapShapeS.forms().size() + 1  # + the finale
	check("every form appears somewhere in the campaign",
		seen.size() == want, "%d of %d forms used" % [seen.size(), want])

	# No form may dominate. A "variety" pass that emits one shape for most of
	# the campaign has not added variety, it has added a config file.
	var worst: int = 0
	for k in seen.keys():
		worst = maxi(worst, int(seen[k]))
	check("no single form is more than a third of the campaign",
		worst <= n / 3, "commonest form used %d/%d times" % [worst, n])

	# ---- consecutive maps differ --------------------------------------------
	# The player experiences the campaign in order, so adjacency is what
	# actually reads as repetition.
	var repeats: int = 0
	for i in range(1, n):
		if String(MapShapeS.at(i).get("id", "")) \
				== String(MapShapeS.at(i - 1).get("id", "")):
			repeats += 1
	check("no two maps in a row have the same form", repeats == 0,
		"%d back-to-back repeats" % repeats)

	# ---- acts do not all open the same way ----------------------------------
	var openers: Dictionary = {}
	for a in range(Campaign.act_count()):
		var id: String = String(
			MapShapeS.at(a * Campaign.maps_per_act()).get("id", ""))
		openers[id] = true
	check("acts do not all open on the same form", openers.size() >= 3,
		"%d distinct openers over %d acts"
			% [openers.size(), Campaign.act_count()])

	# ---- acts end on the finale ---------------------------------------------
	var finales: int = 0
	for a in range(Campaign.act_count()):
		var last: int = a * Campaign.maps_per_act() + Campaign.maps_per_act() - 1
		if String(MapShapeS.at(last).get("id", "")) == "colosseum":
			finales += 1
	check("every act ends on the colosseum",
		finales == Campaign.act_count(),
		"%d of %d" % [finales, Campaign.act_count()])

	# ---- both forms are represented -----------------------------------------
	var lanes: int = 0
	var arenas: int = 0
	for i in range(n):
		if MapShapeS.kind_at(i) == Terrain.Kind.LANE:
			lanes += 1
		else:
			arenas += 1
	check("the campaign uses both lanes and arenas",
		lanes > 0 and arenas > 0, "%d lane / %d arena" % [lanes, arenas])

	# ---- it is deterministic ------------------------------------------------
	# Map 37 must be the same shape on every device and every run, the way the
	# biome and the dread curve already are. Otherwise "that awful narrow one"
	# is not a thing two players can talk about.
	var stable: bool = true
	for i in range(n):
		if String(MapShapeS.at(i).get("id", "")) \
				!= String(MapShapeS.at(i).get("id", "")):
			stable = false
	var sample_a: String = String(MapShapeS.at(37).get("id", ""))
	var sample_b: String = String(MapShapeS.at(37).get("id", ""))
	check("a map's shape is the same every time it is asked for",
		stable and sample_a == sample_b, "map 37 is '%s'" % sample_a)

	# ---- cost stays bounded -------------------------------------------------
	# Cells are quadratic. The ceiling is what keeps a "big" map a change of
	# pace rather than a loading screen on a phone.
	var biggest: int = 0
	for i in range(n):
		biggest = maxi(biggest, MapShapeS.cells_at(i))
	var ratio: float = float(biggest * biggest) / float(384 * 384)
	check("the largest map is not a loading screen", ratio <= 1.5,
		"%d cells = %.2fx the old 384 in area" % [biggest, ratio])

	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)
