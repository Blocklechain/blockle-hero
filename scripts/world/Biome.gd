class_name Biome
extends RefCounted
# ------------------------------------------------------------------------------
# THE ART DIRECTION. Every colour in Blockle Hero is declared here and nowhere
# else, and every terrain parameter with it.
#
# This is deliberate. On Blockle Idle twelve subsystems each improvised their own
# palette and the result was a collage rather than a world; the rebuild that
# finally looked right had one palette, one grid, one renderer. Same rule here:
# if a module needs a colour it asks the biome for it.
#
# The sixteen biomes are the ones already established by raid's arena backdrops
# (assets/env/arena_*.png), so the generated terrain inherits a vocabulary the
# hero art was authored against instead of inventing a competing one.
# ------------------------------------------------------------------------------

const IDS: PackedStringArray = [
	"greenwood", "tidebreak", "emberfall", "frostcrag",
	"mistmoor", "stormreach", "duskvale", "gloomroot",
	"thornspire", "ashwastes", "boneyard", "hollows",
	"shimmer", "molten", "voidrift", "throne",
]


# Prop vocabulary. Deliberately generic names: the generator places a "tree_dead"
# and the art layer decides what a dead tree looks like in frostcrag versus in
# molten, so swapping meshes never means regenerating a world.
const PROPS: PackedStringArray = [
	"tree_conifer", "tree_broad", "tree_dead", "stump", "log",
	"bush", "thorn", "reed", "flower", "grass_tuft", "mushroom",
	"rock_small", "rock_large", "boulder", "stalagmite", "crystal",
	"ice_shard", "lava_rock", "bone", "skull_pile",
	"pillar", "ruin_wall", "statue", "brazier", "totem", "banner",
]


# ------------------------------------------------------------------------------
# Field reference, so the tables below read as data rather than as magic:
#
#   PALETTE   ground_lo/ground_hi  ground colour at low / high altitude
#             rock, rock_hi        exposed stone on slopes, lit faces
#             soil                 what shows where ground is worn through
#             accent               THE one bold colour. Spent on very little.
#             water, water_deep
#             sun, ambient         directional key + sky fill
#             fog, fog_density     aerial perspective; density is per-metre
#             sky_top, sky_horizon
#
#   TERRAIN   amplitude   metres of vertical relief
#             freq        base feature frequency (lower = broader landforms)
#             ridge       0..1 blend of ridged (rock creases) over fbm (dunes)
#             roughness   high-octave gain; detail versus smoothness
#             terrace     0 = natural slope, >0 = plateau steps
#             water_level normalised height, or -1 for a dry biome
#             warp        domain-warp strength; the erosion-look dial
#
#   SCATTER   props       {prop: weight}; density is props per 100 m^2
# ------------------------------------------------------------------------------

const TABLE: Dictionary = {

"greenwood": {
	"name": "Greenwood", "mood": "temperate forest, late afternoon",
	"ground_lo": Color("6d9f4b"), "ground_hi": Color("a2c86a"),
	"rock": Color("6c6a60"), "rock_hi": Color("8d8a7c"), "soil": Color("5a4632"),
	"accent": Color("d9c44e"),
	"water": Color("2f6b7a"), "water_deep": Color("1b3f4e"),
	"sun": Color("ffe9b8"), "ambient": Color("8fa6c4"),
	"fog": Color("b9ccae"), "fog_density": 0.004,
	"sky_top": Color("4e7fb5"), "sky_horizon": Color("cfe0d8"),
	"amplitude": 11.0, "freq": 0.022, "ridge": 0.18, "roughness": 0.50,
	"terrace": 0.0, "water_level": 0.24, "warp": 1.6,
	"density": 7.0,
	"cover_density": 78,
	"cover": {"grass_tuft": 50, "fern": 20, "flower": 13, "pebble": 9, "twig": 5, "mushroom": 3},
	"props": {"tree_broad": 30, "tree_conifer": 14, "bush": 16, "grass_tuft": 20,
		"flower": 8, "rock_small": 6, "stump": 3, "log": 3, "mushroom": 2},
},

"tidebreak": {
	"name": "Tidebreak", "mood": "sea cliffs, salt wind",
	"ground_lo": Color("c8b996"), "ground_hi": Color("74906a"),
	"rock": Color("6a6e72"), "rock_hi": Color("8d9196"), "soil": Color("7a6a50"),
	"accent": Color("6fd0d8"),
	"water": Color("2d7a94"), "water_deep": Color("12405c"),
	"sun": Color("ffeccf"), "ambient": Color("9ab8d0"),
	"fog": Color("bcd0d4"), "fog_density": 0.006,
	"sky_top": Color("5a90c0"), "sky_horizon": Color("e2ecea"),
	"amplitude": 17.0, "freq": 0.018, "ridge": 0.42, "roughness": 0.52,
	"terrace": 0.22, "water_level": 0.40, "warp": 1.3,
	"density": 4.0,
	"cover_density": 34,
	"cover": {"grass_tuft": 38, "pebble": 34, "reed": 14, "twig": 9, "flower": 5},
	"props": {"grass_tuft": 26, "rock_large": 16, "rock_small": 14, "reed": 10,
		"boulder": 8, "tree_dead": 5, "bush": 8, "ruin_wall": 3},
},

"emberfall": {
	"name": "Emberfall", "mood": "autumn woods under falling ash",
	"ground_lo": Color("8e5a32"), "ground_hi": Color("c8854a"),
	"rock": Color("5c4a44"), "rock_hi": Color("7d6960"), "soil": Color("4e3524"),
	"accent": Color("e8803a"),
	"water": Color("4a3a30"), "water_deep": Color("2a1e18"),
	"sun": Color("ffcf9a"), "ambient": Color("a8764e"),
	"fog": Color("d9a876"), "fog_density": 0.009,
	"sky_top": Color("8a5a40"), "sky_horizon": Color("e8b480"),
	"amplitude": 13.0, "freq": 0.024, "ridge": 0.26, "roughness": 0.55,
	"terrace": 0.0, "water_level": 0.20, "warp": 1.7,
	"density": 6.5,
	"cover_density": 58,
	"cover": {"grass_tuft": 26, "twig": 28, "fern": 16, "pebble": 16, "flower": 8, "mushroom": 6},
	"props": {"tree_broad": 26, "tree_dead": 18, "grass_tuft": 14, "bush": 10,
		"rock_small": 9, "log": 7, "stump": 6, "brazier": 2, "flower": 4},
},

"frostcrag": {
	"name": "Frostcrag", "mood": "high snow peaks, thin air",
	"ground_lo": Color("cdd9e6"), "ground_hi": Color("f4f8fc"),
	"rock": Color("5b6673"), "rock_hi": Color("7f8b99"), "soil": Color("4a5260"),
	"accent": Color("7fd4e8"),
	"water": Color("4a7f9b"), "water_deep": Color("24495e"),
	"sun": Color("dceaff"), "ambient": Color("8ba4c8"),
	"fog": Color("cdd9e6"), "fog_density": 0.010,
	"sky_top": Color("3f6a9e"), "sky_horizon": Color("dce8f4"),
	"amplitude": 30.0, "freq": 0.014, "ridge": 0.78, "roughness": 0.56,
	"terrace": 0.0, "water_level": 0.12, "warp": 1.1,
	"density": 2.2,
	"cover_density": 20,
	"cover": {"pebble": 54, "grass_tuft": 20, "twig": 16, "ice_shard": 10},
	"props": {"ice_shard": 24, "rock_large": 20, "tree_conifer": 16,
		"boulder": 14, "rock_small": 12, "tree_dead": 8, "crystal": 4, "bone": 2},
},

"mistmoor": {
	"name": "Mistmoor", "mood": "drowned moorland, visibility nil",
	"ground_lo": Color("4a5448"), "ground_hi": Color("68705c"),
	"rock": Color("5c6061"), "rock_hi": Color("7b7f80"), "soil": Color("3e4238"),
	"accent": Color("b9c4a8"),
	"water": Color("44565c"), "water_deep": Color("22333a"),
	"sun": Color("cfd8d0"), "ambient": Color("90a09c"),
	"fog": Color("aab4ac"), "fog_density": 0.026,
	"sky_top": Color("7e8c8a"), "sky_horizon": Color("c0c8c0"),
	"amplitude": 7.0, "freq": 0.020, "ridge": 0.10, "roughness": 0.44,
	"terrace": 0.0, "water_level": 0.42, "warp": 2.1,
	"density": 5.0,
	"cover_density": 62,
	"cover": {"grass_tuft": 42, "reed": 24, "fern": 12, "mushroom": 10, "pebble": 8, "twig": 4},
	"props": {"reed": 30, "grass_tuft": 22, "tree_dead": 16, "bush": 10,
		"rock_small": 8, "stump": 6, "mushroom": 5, "bone": 3},
},

"stormreach": {
	"name": "Stormreach", "mood": "storm-lashed highland, lightning",
	"ground_lo": Color("44504f"), "ground_hi": Color("5e6c66"),
	"rock": Color("4a5254"), "rock_hi": Color("6e7679"), "soil": Color("373f40"),
	"accent": Color("8fd0ff"),
	"water": Color("35474f"), "water_deep": Color("1c2a31"),
	"sun": Color("b8c8d4"), "ambient": Color("6e8090"),
	"fog": Color("6a767c"), "fog_density": 0.015,
	"sky_top": Color("2e3c48"), "sky_horizon": Color("76858e"),
	"amplitude": 23.0, "freq": 0.016, "ridge": 0.62, "roughness": 0.60,
	"terrace": 0.18, "water_level": 0.18, "warp": 1.5,
	"density": 3.0,
	"cover_density": 30,
	"cover": {"grass_tuft": 36, "pebble": 38, "twig": 16, "fern": 10},
	"props": {"rock_large": 22, "boulder": 18, "grass_tuft": 16, "tree_dead": 12,
		"rock_small": 12, "pillar": 8, "totem": 5, "ruin_wall": 4},
},

"duskvale": {
	"name": "Duskvale", "mood": "perpetual twilight, violet haze",
	"ground_lo": Color("4a4466"), "ground_hi": Color("6b6290"),
	"rock": Color("46415a"), "rock_hi": Color("635d7e"), "soil": Color("2e2a40"),
	"accent": Color("b79be8"),
	"water": Color("2e3a5c"), "water_deep": Color("181e36"),
	"sun": Color("c8b4ff"), "ambient": Color("6a5f94"),
	"fog": Color("4e4766"), "fog_density": 0.013,
	"sky_top": Color("231f38"), "sky_horizon": Color("6e5f8e"),
	"amplitude": 14.0, "freq": 0.021, "ridge": 0.30, "roughness": 0.50,
	"terrace": 0.0, "water_level": 0.26, "warp": 1.8,
	"density": 5.5,
	"cover_density": 42,
	"cover": {"grass_tuft": 30, "flower": 20, "mushroom": 16, "fern": 14, "pebble": 14, "twig": 6},
	"props": {"tree_dead": 22, "crystal": 14, "bush": 14, "grass_tuft": 16,
		"rock_small": 10, "mushroom": 8, "pillar": 6, "brazier": 4, "flower": 6},
},

"gloomroot": {
	"name": "Gloomroot", "mood": "black swamp forest, bioluminescent",
	"ground_lo": Color("3f5339"), "ground_hi": Color("5c7650"),
	"rock": Color("3a3f36"), "rock_hi": Color("545a4e"), "soil": Color("242e24"),
	"accent": Color("7ad48a"),
	"water": Color("2a3a2e"), "water_deep": Color("14201a"),
	"sun": Color("9fc49a"), "ambient": Color("4e6450"),
	"fog": Color("35422f"), "fog_density": 0.020,
	"sky_top": Color("1a2419"), "sky_horizon": Color("46583e"),
	"amplitude": 9.0, "freq": 0.023, "ridge": 0.16, "roughness": 0.52,
	"terrace": 0.0, "water_level": 0.38, "warp": 2.2,
	"density": 8.0,
	"cover_density": 80,
	"cover": {"fern": 34, "mushroom": 26, "grass_tuft": 18, "twig": 12, "pebble": 10},
	"props": {"tree_broad": 24, "tree_dead": 18, "mushroom": 18, "reed": 14,
		"bush": 10, "log": 8, "stump": 6, "rock_small": 6, "bone": 3},
},

"thornspire": {
	"name": "Thornspire", "mood": "bramble badlands, dried blood",
	"ground_lo": Color("5a3a44"), "ground_hi": Color("7a5055"),
	"rock": Color("4e3840"), "rock_hi": Color("6c5058"), "soil": Color("3e2a32"),
	"accent": Color("d4506a"),
	"water": Color("3a2a34"), "water_deep": Color("1e1620"),
	"sun": Color("e8b0a8"), "ambient": Color("8a6068"),
	"fog": Color("6e4a52"), "fog_density": 0.011,
	"sky_top": Color("3e2630"), "sky_horizon": Color("8e6060"),
	"amplitude": 19.0, "freq": 0.019, "ridge": 0.55, "roughness": 0.62,
	"terrace": 0.0, "water_level": 0.14, "warp": 1.9,
	"density": 6.0,
	"cover_density": 34,
	"cover": {"twig": 30, "pebble": 28, "grass_tuft": 18, "thorn": 14, "bone": 10},
	"props": {"thorn": 32, "tree_dead": 18, "rock_large": 12, "bush": 10,
		"rock_small": 10, "bone": 8, "boulder": 6, "skull_pile": 4},
},

"ashwastes": {
	"name": "Ashwastes", "mood": "grey dead desert, nothing grows",
	"ground_lo": Color("6b6560"), "ground_hi": Color("8a8279"),
	"rock": Color("4f4a46"), "rock_hi": Color("6e6963"), "soil": Color("57524d"),
	"accent": Color("c4b8a4"),
	"water": Color("5a564e"), "water_deep": Color("3a372f"),
	"sun": Color("d8cfc0"), "ambient": Color("8e8878"),
	"fog": Color("a89f94"), "fog_density": 0.016,
	"sky_top": Color("6e6a62"), "sky_horizon": Color("bcb2a4"),
	"amplitude": 12.0, "freq": 0.013, "ridge": 0.34, "roughness": 0.42,
	"terrace": 0.30, "water_level": -1.0, "warp": 2.4,
	"density": 1.8,
	"cover_density": 16,
	"cover": {"pebble": 58, "twig": 26, "bone": 10, "grass_tuft": 6},
	"props": {"rock_small": 26, "boulder": 20, "tree_dead": 16, "bone": 14,
		"rock_large": 12, "skull_pile": 6, "ruin_wall": 4, "pillar": 2},
},

"boneyard": {
	"name": "Boneyard", "mood": "a field of the dead, sickly light",
	"ground_lo": Color("8c8473"), "ground_hi": Color("b3a992"),
	"rock": Color("6e6757"), "rock_hi": Color("8d8673"), "soil": Color("5e5848"),
	"accent": Color("c3d46b"),
	"water": Color("4d5a3a"), "water_deep": Color("2a3220"),
	"sun": Color("e4e0c8"), "ambient": Color("9a9c78"),
	"fog": Color("9c9a80"), "fog_density": 0.014,
	"sky_top": Color("6a6e4e"), "sky_horizon": Color("c4c09c"),
	"amplitude": 8.0, "freq": 0.017, "ridge": 0.20, "roughness": 0.46,
	"terrace": 0.0, "water_level": 0.16, "warp": 1.6,
	"density": 4.5,
	"cover_density": 32,
	"cover": {"pebble": 30, "bone": 24, "grass_tuft": 26, "twig": 14, "mushroom": 6},
	"props": {"bone": 30, "skull_pile": 18, "tree_dead": 14, "rock_small": 12,
		"grass_tuft": 10, "pillar": 8, "ruin_wall": 6, "statue": 2},
},

"hollows": {
	"name": "The Hollows", "mood": "cavern under the world",
	"ground_lo": Color("4c433c"), "ground_hi": Color("685c52"),
	"rock": Color("2c2724"), "rock_hi": Color("4a433e"), "soil": Color("2e2824"),
	"accent": Color("6fd3c4"),
	"water": Color("1f3a3c"), "water_deep": Color("0e2022"),
	"sun": Color("8fa8b0"), "ambient": Color("3e4a50"),
	"fog": Color("262120"), "fog_density": 0.030,
	"sky_top": Color("14100e"), "sky_horizon": Color("2e2724"),
	"amplitude": 16.0, "freq": 0.026, "ridge": 0.70, "roughness": 0.64,
	"terrace": 0.0, "water_level": 0.22, "warp": 1.4,
	"density": 5.0,
	"cover_density": 34,
	"cover": {"pebble": 44, "mushroom": 28, "crystal": 12, "twig": 10, "bone": 6},
	"props": {"stalagmite": 30, "rock_large": 18, "crystal": 14, "mushroom": 12,
		"rock_small": 10, "boulder": 8, "bone": 5, "brazier": 3},
},

"shimmer": {
	"name": "Shimmer", "mood": "crystal shelf, impossible light",
	"ground_lo": Color("4a5a7a"), "ground_hi": Color("6e84a8"),
	"rock": Color("56608a"), "rock_hi": Color("7986ae"), "soil": Color("3c496a"),
	"accent": Color("8ff0ff"),
	"water": Color("3a6a8a"), "water_deep": Color("1c3a56"),
	"sun": Color("e0f4ff"), "ambient": Color("8ca8d4"),
	"fog": Color("9ec0dc"), "fog_density": 0.012,
	"sky_top": Color("3a5a94"), "sky_horizon": Color("c0dcf0"),
	"amplitude": 18.0, "freq": 0.020, "ridge": 0.58, "roughness": 0.50,
	"terrace": 0.40, "water_level": 0.28, "warp": 1.2,
	"density": 4.0,
	"cover_density": 28,
	"cover": {"pebble": 40, "crystal": 20, "grass_tuft": 22, "ice_shard": 12, "twig": 6},
	"props": {"crystal": 34, "ice_shard": 20, "rock_large": 14, "rock_small": 12,
		"boulder": 8, "pillar": 6, "grass_tuft": 6},
},

"molten": {
	"name": "Molten", "mood": "black rock, running fire",
	"ground_lo": Color("3a2b26"), "ground_hi": Color("553d33"),
	"rock": Color("2e2320"), "rock_hi": Color("584038"), "soil": Color("3a2a22"),
	"accent": Color("ff6b24"),
	"water": Color("ff7a2a"), "water_deep": Color("c43a08"),
	"sun": Color("ffb070"), "ambient": Color("96482c"),
	"fog": Color("6b2a18"), "fog_density": 0.018,
	"sky_top": Color("2a1210"), "sky_horizon": Color("a84418"),
	"amplitude": 21.0, "freq": 0.018, "ridge": 0.66, "roughness": 0.60,
	# Lava up to 0.46: at 0.30 the lake sat below every arena floor (which is
	# clamped above the water line), so the defining feature of the biome was
	# never once on screen.
	"terrace": 0.24, "water_level": 0.46, "warp": 1.6,
	"density": 3.5,
	"cover_density": 22,
	"cover": {"pebble": 52, "lava_rock": 20, "twig": 10, "bone": 10, "crystal": 8},
	"props": {"lava_rock": 32, "rock_large": 20, "boulder": 14, "rock_small": 12,
		"stalagmite": 8, "brazier": 6, "pillar": 4, "bone": 4},
},

"voidrift": {
	"name": "Voidrift", "mood": "a tear in the world",
	"ground_lo": Color("2e2642"), "ground_hi": Color("473a63"),
	"rock": Color("191426"), "rock_hi": Color("342c4a"), "soil": Color("1a1526"),
	"accent": Color("e054ff"),
	"water": Color("4a1a6a"), "water_deep": Color("240a38"),
	"sun": Color("c47aff"), "ambient": Color("4e3a74"),
	"fog": Color("2a1e3c"), "fog_density": 0.022,
	"sky_top": Color("0e0a16"), "sky_horizon": Color("3e2a5c"),
	"amplitude": 25.0, "freq": 0.022, "ridge": 0.74, "roughness": 0.68,
	"terrace": 0.0, "water_level": 0.20, "warp": 2.6,
	"density": 3.0,
	"cover_density": 26,
	"cover": {"pebble": 42, "crystal": 22, "twig": 14, "bone": 12, "mushroom": 10},
	"props": {"crystal": 26, "rock_large": 20, "stalagmite": 16, "boulder": 12,
		"pillar": 10, "rock_small": 8, "totem": 5, "statue": 3},
},

"throne": {
	"name": "The Throne", "mood": "the citadel at the end, gold and marble",
	"ground_lo": Color("6a5f52"), "ground_hi": Color("93866f"),
	"rock": Color("7d7465"), "rock_hi": Color("a09884"), "soil": Color("574e42"),
	"accent": Color("e8c45a"),
	"water": Color("3a4a6a"), "water_deep": Color("1e2a42"),
	"sun": Color("fff0c8"), "ambient": Color("9a8e78"),
	"fog": Color("a89878"), "fog_density": 0.008,
	"sky_top": Color("4a4260"), "sky_horizon": Color("d8c49c"),
	"amplitude": 10.0, "freq": 0.015, "ridge": 0.22, "roughness": 0.40,
	"terrace": 0.55, "water_level": 0.18, "warp": 0.7,
	"density": 3.2,
	"cover_density": 30,
	"cover": {"pebble": 38, "grass_tuft": 28, "twig": 14, "flower": 12, "bone": 8},
	"props": {"pillar": 30, "ruin_wall": 20, "statue": 14, "banner": 12,
		"brazier": 10, "rock_small": 6, "grass_tuft": 5, "totem": 3},
},
}


# ---- access ------------------------------------------------------------------

static func get_biome(id: String) -> Dictionary:
	return TABLE.get(id, TABLE["greenwood"])


static func field(id: String, key: String, fallback: Variant = null) -> Variant:
	var b: Dictionary = get_biome(id)
	return b.get(key, fallback)


static func display_name(id: String) -> String:
	return String(field(id, "name", id.capitalize()))


# The ground colour at a normalised altitude, which is the single most important
# read in the whole renderer: it is what stops terrain looking like one flat
# sheet of green.
static func ground_at(id: String, altitude01: float) -> Color:
	var b: Dictionary = get_biome(id)
	return (b["ground_lo"] as Color).lerp(b["ground_hi"] as Color,
		clampf(altitude01, 0.0, 1.0))


static func rock_at(id: String, lit01: float) -> Color:
	var b: Dictionary = get_biome(id)
	return (b["rock"] as Color).lerp(b["rock_hi"] as Color,
		clampf(lit01, 0.0, 1.0))


static func has_water(id: String) -> bool:
	return float(field(id, "water_level", -1.0)) >= 0.0


# Weighted prop tables are stored as a {prop: weight} dictionary for readability;
# the scatter pass wants two parallel arrays.
static func prop_table(id: String) -> Array:
	var props: Dictionary = field(id, "props", {}) as Dictionary
	var names: Array = []
	var weights: Array = []
	for k in props.keys():
		names.append(k)
		weights.append(float(props[k]))
	return [names, weights]


# Campaign ordering. The act structure is the biome list in TABLE order, which is
# arranged as a difficulty ramp: pastoral -> harsh -> hostile -> unreal -> the
# citadel. Act boundaries fall every four biomes.
static func act_of(id: String) -> int:
	var i: int = IDS.find(id)
	if i < 0:
		return 0
	return i / 4


static func campaign_order() -> PackedStringArray:
	return IDS
