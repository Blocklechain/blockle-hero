class_name Dress
extends RefCounted
# ------------------------------------------------------------------------------
# HOW A MAP'S FORM CHANGES WHAT IS STANDING ON IT.
#
# MapShape gave the campaign seven floor plans. They measure differently — a
# warren is 304 cells with 16 nodes, a hollow is 352 with 7 — but until now
# they DRESSED identically, because Scatter only ever asked the biome what to
# plant. So a warren and a hollow in the same biome were the same field of
# trees at the same density, and the only way to tell them apart was to walk
# them.
#
# That is the difference between a level and a floor plan. A warren should be
# cluttered with things you cannot see past; a hollow should be bare enough
# that the thing chasing you is visible from across it. Those are the same
# biome's props at different densities and different mixes, which costs
# nothing to generate and changes how the map plays:
#
#   warren      dense, and biased to STRUCTURE — the corners become real
#               cover instead of decoration, and a ranged champion cannot
#               hold a sightline.
#   hollow      sparse, and biased to GROUND — open fighting, long lines,
#               the map where kiting finally works.
#   causeway    thin, with landmarks, so a long march has something to
#               measure progress against.
#   colosseum   built: pillars, statues, braziers. It should look made.
#
# SOFT RE-WEIGHTING, NOT A SECOND TABLE. Every biome keeps its own prop list
# and its own identity — frostcrag dressed as a warren is still frostcrag,
# with ice shards and conifers rather than someone else's pillars. A form
# multiplies the weights the biome already chose. A form that listed its own
# props would quietly erase sixteen biomes' worth of work.
# ------------------------------------------------------------------------------

## Props that BLOCK or interrupt a sightline. The ones a warren wants more of.
const STRUCTURE: PackedStringArray = [
	"tree_conifer", "tree_broad", "tree_dead", "rock_large", "boulder",
	"stalagmite", "pillar", "ruin_wall", "statue", "totem", "arch",
	"standing_stone", "obelisk", "crystal", "ice_shard", "shard_cluster",
	"ash_cone", "root_arch",
]

## Props you can see and walk over. The ones a hollow wants instead.
const GROUND: PackedStringArray = [
	"grass_tuft", "flower", "mushroom", "reed", "bush", "thorn", "fern",
	"pebble", "rock_small", "bone", "log", "stump", "fungus_shelf",
]

## Props that read as BUILT. A colosseum should look like somewhere people
## made, not somewhere people happen to fight.
const MADE: PackedStringArray = [
	"pillar", "ruin_wall", "statue", "brazier", "totem", "banner", "arch",
	"obelisk", "cairn", "standing_stone",
]

## Props that read as a LANDMARK at distance — the tall, lonely things that
## give an open or a long map something to navigate by.
const LANDMARK: PackedStringArray = [
	"obelisk", "standing_stone", "statue", "totem", "cairn", "arch",
	"tree_dead",
]


## How much of the biome's own density a form wants.
##
## Bounded well away from zero and from anything that would choke the
## generator: these multiply a per-100m^2 figure that is already tuned, and a
## map with four times the props is a map that drops frames on a phone.
static func density_scale(form_id: String) -> float:
	match form_id:
		"warren": return 1.65
		"gauntlet": return 1.30
		"crossroads": return 1.05
		"spine": return 1.0
		"causeway": return 0.70
		"hollow": return 0.55
		"colosseum": return 0.80
		_: return 1.0


## Which prop families a form favours, and by how much.
##
## A multiplier of 1.0 means "leave the biome's own weight alone", which is
## the default for everything a form has no opinion about.
static func bias(form_id: String) -> Dictionary:
	match form_id:
		"warren":
			return {"structure": 2.0, "ground": 0.55}
		"hollow":
			return {"structure": 0.35, "ground": 1.8, "landmark": 1.6}
		"causeway":
			return {"structure": 0.7, "ground": 1.2, "landmark": 2.2}
		"gauntlet":
			return {"structure": 1.5, "ground": 0.8}
		"colosseum":
			return {"made": 3.0, "structure": 1.2, "ground": 0.7}
		"crossroads":
			return {"made": 1.4, "structure": 1.1}
		_:
			return {}


## Re-weight a biome's prop table for a form.
##
## Takes and returns the [names, weights] pair Biome.prop_table() produces, so
## a caller can drop this in without knowing what a bias is. A form with no
## opinion returns the table untouched — identity, not a rebuilt copy with
## rounding drift.
static func apply(table: Array, form_id: String) -> Array:
	if table.size() < 2:
		return table
	var b: Dictionary = bias(form_id)
	if b.is_empty():
		return table

	var names: Array = table[0]
	var weights: Array = table[1]
	var out: Array = []
	for i in range(names.size()):
		var kind: String = String(names[i])
		var w: float = float(weights[i])
		# Families overlap on purpose — a pillar is both STRUCTURE and MADE,
		# and a colosseum should want it for both reasons. Multiplying rather
		# than picking the first match is what lets that compound.
		if STRUCTURE.has(kind):
			w *= float(b.get("structure", 1.0))
		if GROUND.has(kind):
			w *= float(b.get("ground", 1.0))
		if MADE.has(kind):
			w *= float(b.get("made", 1.0))
		if LANDMARK.has(kind):
			w *= float(b.get("landmark", 1.0))
		# NEVER ZERO. A form that eliminates a prop entirely erases part of
		# the biome's identity, which is exactly what this module promised
		# not to do — a hollow in frostcrag must still have ice in it.
		out.append(maxf(w, 0.4))
	return [names, out]
