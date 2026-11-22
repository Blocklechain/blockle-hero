extends SceneTree
# ------------------------------------------------------------------------------
# EVERY MAP MUST BE FINISHABLE.
#
# A region is cleared by killing its boss, and region N+1 is sealed until N is
# cleared. So a boss the player cannot reach does not spoil one map — it ends
# the campaign at that map, permanently, on that save.
#
# That shipped. Five of the hundred campaign maps placed the boss in a pocket
# the player could not walk to: walkable ground, a real enemy, no route. The
# cause was that placement asked the wrong question —
#
#     Pathing.is_walkable(p)      "is this cell open"
#
# is not
#
#     "can the player get to this cell"
#
# and a procedural map has pockets. There was no error, no log line and no
# visible difference from a boss that had simply wandered off; the map just
# never ended. Which five maps depends on the campaign seed, so one player's
# broken map is another player's fine one, and a bug report naming map 14 is
# not reproducible from a fresh save.
#
# ------------------------------------------------------------------------------
# WHY THIS SWEEPS EVERYTHING RATHER THAN SAMPLING.
#
# A one-in-twenty failure spread over a hundred maps is invisible to a spot
# check: play five maps and the odds are you see nothing. The only honest
# test is all hundred — and across more than one campaign seed, because the
# seed is what decides which maps land badly.
#
# It is the slowest harness in the project (it generates real terrain for
# every map) and it is worth it: this is the one class of bug that makes the
# game unfinishable rather than merely worse.
# ------------------------------------------------------------------------------

const MapShapeS := preload("res://scripts/game/MapShape.gd")

## The seed every new account is actually given (Roster.create's default).
## One campaign, swept completely, is what CI runs: a hundred real terrain
## builds is about three minutes, and the failure it catches makes a save
## unfinishable, so it earns its place in every build.
const DEFAULT_SEED: int = 20261119

## WHICH MAPS FAIL IS A PROPERTY OF THE SEED, so one seed proves one campaign
## rather than the generator. Extra seeds are opt-in because each one is
## another hundred terrain builds:
##
##   REACH_SEEDS=4242,7,99 godot --headless --path . --script tools/reachtest.gd
##
## Worth running after any change to Layout, Lane, Terrain, MapShape or
## Encounter placement — those are the five files that decide whether a boss
## ends up somewhere a player can walk.
func _seeds() -> PackedInt32Array:
	var out := PackedInt32Array([DEFAULT_SEED])
	var extra: String = OS.get_environment("REACH_SEEDS")
	for part in extra.split(",", false):
		var t: String = String(part).strip_edges()
		if t.is_valid_int() and int(t) != DEFAULT_SEED:
			out.append(int(t))
	return out

var _fails: int = 0


func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _init() -> void:
	var playable: PackedStringArray = HeroRig.animated_heroes()
	if playable.is_empty():
		check("there are champions to build encounters from", false)
		print("\n=== %d failure(s) ===" % _fails)
		quit(1)
		return

	var total: int = 0
	var no_boss: Array = []
	var unreachable: Array = []
	var no_entry: Array = []
	# Smallest region a player was ever given, so a map that generates almost
	# nothing walkable is caught as well.
	var tiniest: int = 1 << 30
	var tiniest_at: String = ""

	var seeds: PackedInt32Array = _seeds()
	for campaign_seed in seeds:
		for i in range(Campaign.map_count()):
			var shape: Dictionary = MapShapeS.at(i)
			var cells: int = int(shape.get("cells", 384))
			var kind: int = int(shape.get("kind", Terrain.Kind.LANE))
			var form: String = String(shape.get("id", "?"))
			var seed: int = Campaign.region_seed(campaign_seed, i)
			var plan: Layout = Terrain.plan_for(kind, seed,
				Vector2(cells, cells) * 0.5, Layout.Sym.ASYMMETRIC,
				int(shape.get("nodes", 11)))
			var ter: Terrain = Terrain.generate(seed, Campaign.biome_at(i),
				cells, 0.5, plan)
			var path := Pathing.new(ter)
			total += 1

			# WHERE THE PLAYER ACTUALLY STARTS. Play reads the ENTRY node and
			# places the champion there, so that is the origin every
			# reachability claim has to be measured from.
			var entry_node: Dictionary = plan.node_of_kind(Layout.ENTRY)
			if entry_node.is_empty():
				no_entry.append("%s map %d (%s)" % [campaign_seed, i + 1, form])
				continue
			var entry: Vector2 = entry_node.get("pos", Vector2.ZERO)

			var region: PackedByteArray = path.region_from(entry)
			var open_cells: int = Pathing.region_size(region)
			if open_cells < tiniest:
				tiniest = open_cells
				tiniest_at = "map %d (%s)" % [i + 1, form]

			var spawns: Array = Encounter.build(i, Campaign.Tier.NORMAL,
				campaign_seed, playable, "", path, entry, plan)
			var boss: Encounter.Spawn = null
			for sp in spawns:
				var s := sp as Encounter.Spawn
				if s != null and s.is_boss:
					boss = s
					break
			if boss == null:
				no_boss.append("seed %d map %d (%s)"
					% [campaign_seed, i + 1, form])
				continue
			# THE WHOLE POINT. Not is_walkable — reachable, from where the
			# player stands, through the same flood fill the placer uses.
			if not path.in_region(region, boss.at):
				unreachable.append("seed %d map %-3d %-11s %-5s %.0f m"
					% [campaign_seed, i + 1, form,
						"ARENA" if kind == Terrain.Kind.ARENA else "LANE",
						entry.distance_to(boss.at)])

	print("")
	check("every map was generated and populated", total > 0,
		"%d map builds across %d campaign seed(s)" % [total, seeds.size()])
	check("every map has an entry for the player to stand on",
		no_entry.is_empty(), "%d missing: %s" % [no_entry.size(), no_entry])
	check("every map places a boss", no_boss.is_empty(),
		"%d without one: %s" % [no_boss.size(), str(no_boss)])
	# THE ASSERTION THIS FILE EXISTS FOR.
	check("every boss can be WALKED TO from where the player starts",
		unreachable.is_empty(), "%d unreachable" % unreachable.size())
	for u in unreachable:
		print("        %s" % u)

	# A map whose walkable region is a handful of cells is technically
	# finishable and is not a map. Reported with its own number so a
	# generation change that starts strangling regions is visible before it
	# starts sealing them.
	check("no map generates a near-empty walkable region",
		tiniest > 2000, "smallest reachable region %d cells, at %s"
			% [tiniest, tiniest_at])

	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)
