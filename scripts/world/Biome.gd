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
	# Added later: the original set was heavy on vegetation and light on
	# anything BUILT or anything that reads as a landmark across open ground.
	"cairn", "standing_stone", "arch", "obelisk", "root_arch",
	"fungus_shelf", "ash_cone", "shard_cluster",
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
		"flower": 8, "rock_small": 6, "stump": 3, "log": 3, "mushroom": 2, "root_arch": 10, "cairn": 5},
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
		"boulder": 8, "tree_dead": 5, "bush": 8, "ruin_wall": 3, "standing_stone": 9, "cairn": 6},
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
		"rock_small": 9, "log": 7, "stump": 6, "brazier": 2, "flower": 4, "ash_cone": 8, "cairn": 5},
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
		"boulder": 14, "rock_small": 12, "tree_dead": 8, "crystal": 4, "bone": 2, "standing_stone": 10, "shard_cluster": 8},
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
		"rock_small": 8, "stump": 6, "mushroom": 5, "bone": 3, "fungus_shelf": 11, "root_arch": 8},
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
		"rock_small": 12, "pillar": 8, "totem": 5, "ruin_wall": 4, "standing_stone": 11, "obelisk": 6},
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
		"rock_small": 10, "mushroom": 8, "pillar": 6, "brazier": 4, "flower": 6, "arch": 8, "cairn": 7},
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
		"bush": 10, "log": 8, "stump": 6, "rock_small": 6, "bone": 3, "root_arch": 12, "fungus_shelf": 9},
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
		"rock_small": 10, "bone": 8, "boulder": 6, "skull_pile": 4, "root_arch": 9, "obelisk": 6},
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
		"rock_large": 12, "skull_pile": 6, "ruin_wall": 4, "pillar": 2, "ash_cone": 12, "cairn": 6},
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
		"grass_tuft": 10, "pillar": 8, "ruin_wall": 6, "statue": 2, "cairn": 10, "arch": 7},
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
		"rock_small": 10, "boulder": 8, "bone": 5, "brazier": 3, "fungus_shelf": 9, "shard_cluster": 7},
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
		"boulder": 8, "pillar": 6, "grass_tuft": 6, "shard_cluster": 13, "obelisk": 7},
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
		"stalagmite": 8, "brazier": 6, "pillar": 4, "bone": 4, "ash_cone": 13, "shard_cluster": 7},
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
		"pillar": 10, "rock_small": 8, "totem": 5, "statue": 3, "obelisk": 11, "shard_cluster": 10},
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
		"brazier": 10, "rock_small": 6, "grass_tuft": 5, "totem": 3, "arch": 12, "obelisk": 10},
},
}


# ------------------------------------------------------------------------------
# THE DREAD CURVE — map 1 cheerful, map 100 terrifying
#
# `Campaign.dread(index)` is 0 at map 1 and 1 at map 100. Everything frightening
# descends from that one number, and this is where it turns into pixels.
#
# IT IS A TRANSFORM, NOT A SECOND TABLE. There are sixteen biomes above and there
# will never be a seventeenth "scared voidrift": the shift below reads a biome's
# OWN sun, ambient, fog and ground and grades them, so adding a biome costs one
# entry and inherits the whole curve for free. Thirty-two entries would also mean
# thirty-two chances for the scared variant to disagree with its parent, which is
# the five-files-of-independent-scary failure this task exists to avoid.
#
# HOW IT REACHES THE RENDERER. A biome id may carry its dread with it:
# "voidrift~63" is voidrift at dread 0.63. `get_biome()` resolves the tag, so
# every existing reader — Terrain's parameters, Shade's palette, Mesher's sky fog
# and key light, Props' foliage and bark, Scatter's cover density — picks the
# shift up through the one chokepoint it already went through, with no dread
# argument threaded through twenty call sites and no file free to invent its own
# idea of menacing. `Biome.tag(id, dread)` writes one; `base_id()` reads it back.
#
# `~` and not `@`: these ids become Node names (WorldBuilder names the region
# after its biome) and Godot reserves `@` for auto-generated names.
#
# AND IT STAYS READABLE, which is the hard half. Three rules do most of it, and
# every one of them is CHECKED by tools/dreadtest.gd rather than asserted here:
#   * LOWER KEY MEANS A BIGGER KEY-TO-FILL RATIO, NOT A DIMMER PICTURE. The key
#     holds its luminance and gains energy (KEY_MULT) while the fill falls by
#     half, so a late map is harsher and more three-dimensional, not darker.
#   * NOTHING MAY GO DARKER THAN THE GAME ALREADY GOES. The floors on the ground
#     and on the fill are DERIVED from the sixteen shipped palettes — the
#     darkest ground and the dimmest fill somebody has already judged readable —
#     so the biomes that are nearly black have no darkening left to spend and
#     put their dread into fog, chroma and emptiness instead.
#   * THE ACCENT IS EXEMPT, AND GAINS. As everything else drains, the one bold
#     colour — crystal tip, brazier, lava seam — becomes the most legible thing
#     on the screen rather than another casualty.
# Chroma is also traded for value: ground saturation halves while the luminance
# SPAN between low and high ground nearly doubles, so when colour stops carrying
# the terrain, form takes over.
#
# WHAT DREAD DOES NOT TOUCH: amplitude, freq, ridge, roughness, terrace, warp,
# water_level, prop density or the prop table. Dread is presentation. Terrain
# shape is validated per biome for walkability and lane reachability (kindtest),
# and a dial that can quietly make map 90 unplayable is not worth having —
# besides which, holding the shape fixed means the same seed renders the same
# ground at every dread, so dread 0.0 and dread 1.0 of one map differ ONLY in
# light, colour and air. That is exactly what makes the four comparison renders
# in tools/dreadshots.gd evidence of anything.
# ------------------------------------------------------------------------------

## Separates a biome id from its dread percentage: "molten~75".
const DREAD_SEP: String = "~"

## Everything rotates a little toward one hue as dread rises — a cold, sick
## teal. ONE target, no warm/cold branch: at these rotation amounts a warm biome
## reads as having lost its warmth rather than as having turned green, and a cold
## one goes colder, which is the "colder or sicklier" the brief asks for without
## two rules that can disagree.
const DREAD_HUE: float = 0.47

# Per-channel grade at dread 1.0. `HUE_*` is how far toward DREAD_HUE, `SAT_*` a
# multiplier on saturation, `LUM_*` a multiplier on LUMINANCE. All are read
# through lerp(1.0, X, dread), so dread 0 is the identity.
#
# LUMINANCE, NOT HSV VALUE, AND THAT IS NOT A DETAIL. The first cut scaled HSV
# `v` and was measured non-monotonic: rotating molten's red-orange ambient a
# third of the way toward teal lands it in yellow-green, where the luminance
# coefficients are 0.72 instead of 0.21, so the colour came out BRIGHTER at
# dread 1.0 than at dread 0.6 despite a 0.52 value multiplier. Hue and brightness
# have to be independently steerable or "colder" silently means "lighter", so the
# grade rotates hue, scales saturation, and then RETARGETS the luminance.
#
# READABILITY IS WHY THESE ARE NOT ALL BELOW 1.0. The lit side of the world does
# NOT get darker with dread: the key holds its luminance (LUM_SUN 0.96) and gains
# energy (KEY_MULT), while the FILL drops hard (LUM_AMB, FILL_MULT). "Lower key"
# is a bigger key-to-fill ratio, not a dimmer picture — the frame gets harsher
# and more three-dimensional, and a phone in daylight still has something to
# show.
const HUE_SUN: float = 0.18
const SAT_SUN: float = 0.55
const LUM_SUN: float = 0.96

const HUE_AMB: float = 0.40
const SAT_AMB: float = 0.92
## The fill at dread 1.0 — and it is DELIBERATELY the same constant as the
## lighting ratio's FILL_MULT below, because the two renderers get their fill
## from different places and must still arrive at the same answer. The preview
## reads this ambient COLOUR; the game lights from the sky and reads an ENERGY.
## One number, two mechanisms, no drift.
const LUM_AMB: float = FILL_MULT
## THE FILL HAS A FLOOR, and like the ground's it is the art direction's own
## darkest: dread may take a biome's fill down to the dimmest fill the game
## already ships and no further. Below that an enemy standing in shadow is a
## silhouette with no readable armour, which is a lost fight rather than a scary
## one — and the biomes that would go there are precisely the ones that are
## already frightening, so nothing is gained by it.
##
## FILL_KEYS is what "the fill" means to the 3D renderer, which is not the
## `ambient` colour at all: Mesher builds a ProceduralSky whose upper half is
## sky_top/sky_horizon and whose lower half is the FOG colour, and lights the
## shadowed side of the world from that sky. So all three are floored together,
## as one composite, or the floor holds in the preview and fails on screen.
const FILL_KEYS: PackedStringArray = ["sky_top", "sky_horizon", "fog"]

const HUE_FOG: float = 0.26
const SAT_FOG: float = 0.68
const LUM_FOG: float = 0.60

## Fog thickens, but with a HARD CEILING in per-metre density. The ARPG camera
## sits 25 m out (tools/shots.gd), and 0.034/m quartered by Mesher is an 8%
## wash at that distance — thick enough to swallow the far end of a lane, far
## too thin to hide the enemy you are fighting. Without the ceiling, hollows
## (0.030 base) x 2.3 would fog the player's own feet.
const FOG_GAIN: float = 1.30
const FOG_CEIL: float = 0.034

## THE SKY IS THE FILL. Mesher lights ambient from the sky at full contribution,
## and MEASURED — by rendering the same frame with the ambient energy multiplied
## by five and getting the same image to within 1% — `ambient_light_energy` does
## nothing at all in that configuration. So in the game, the only thing that
## darkens the shadowed side of the world is these two numbers.
##
## They are therefore CONSTRAINED, not chosen: their mean is FILL_MULT, so the
## in-game fill falls by exactly what the fill is supposed to fall by and the
## preview (which reads the ambient colour instead) agrees with it.
## tools/dreadtest.gd asserts the constraint, because getting it wrong is
## invisible in the palette table and obvious on screen.
const HUE_SKY: float = 0.28
const SAT_SKY_TOP: float = 0.80
const LUM_SKY_TOP: float = 0.42
## The horizon darkens LESS than the zenith, which keeps it the brighter of the
## two at every dread. Hills and props silhouette against the bright band; a
## uniformly black sky would lose the skyline entirely.
const SAT_SKY_HZ: float = 0.60
const LUM_SKY_HZ: float = 0.62

## The ground is graded as a PAIR, around its mean and its span, rather than as
## two independent colours — the mean goes down and the span goes UP, so the
## terrain darkens while its altitude ramp gets harder to miss. That is the
## readability trade in one line: chroma falls by half (SAT_GROUND) and the
## luminance range it is spent on nearly doubles (SPAN_GROUND), so when colour
## stops telling the player where the hill is, value takes over.
##
## It has to be mean-and-span and not lo-darker/hi-lighter because the ramp is
## not always uphill: tidebreak runs from bright sand LOW to dark grass HIGH, and
## darkening "lo" there collapsed its span from 0.197 to 0.025 — the one biome
## where the dread shift was flattening the terrain instead of carving it.
const HUE_GROUND: float = 0.10
const SAT_GROUND: float = 0.52
const LUM_GROUND: float = 0.72
const SPAN_GROUND: float = 1.85
const SAT_SOIL: float = 0.58
const LUM_SOIL: float = 0.76
const SAT_ROCK: float = 0.55
const LUM_ROCK: float = 0.70
const SPAN_ROCK: float = 1.60

const SAT_WATER: float = 0.82
const LUM_WATER: float = 0.80
const LUM_WATER_DEEP: float = 0.70

## THE ACCENT IS EXEMPT, and gains. It is the one bold colour in the palette and
## it is what crystal tips, braziers and lava seams emit; leaving it saturated
## while everything around it drains means the most legible thing on a dread-1.0
## screen is the thing the player needs to see.
const SAT_ACCENT: float = 1.10
const LUM_ACCENT: float = 1.06

## Ground cover thins out — the world loses its living detail rather than just
## its colour. Cover casts no shadow and blocks nothing, so this cannot affect
## walkability.
const COVER_DRAIN: float = 0.45

# ---- lighting ratio, read by Shade.light() and by Mesher's environment -------
#
# These live here rather than in the two renderers for the same reason the
# palette does: the preview and the game must agree, and "how much lower is the
# key at dread 1" is one answer, not two.

## Ambient/fill energy multiplier at dread 1.0. See LUM_AMB — this is the same
## drop, expressed for the renderer that lights from the sky.
const FILL_MULT: float = 0.52
## Key light energy multiplier at dread 1.0. ABOVE ONE on purpose, and this
## particular number is not a feel: it is what holds the lit side of open,
## up-facing ground at the SAME luminance at dread 1.0 as at dread 0.0 while the
## fill falls to 0.52. Solved against Shade.light()'s own terms — the fill loses
## about a quarter of the light and 1.34 is what the key has to gain to put it
## back — and
## tools/dreadtest.gd then checks the outcome rather than the arithmetic. Lower
## it and late maps get dim as well as harsh, which is the failure the brief
## names: atmospheric is not the same as dark.
const KEY_MULT: float = 1.34
## Half-lambert exponent on the key (Shade default 1.4). Higher = the terminator
## tightens and shading gets harsher.
const KEY_GAMMA_LO: float = 1.4
const KEY_GAMMA_HI: float = 1.62
# THE BAKED AERIAL-HAZE CEILING (Shade's 0.42) IS DELIBERATELY ABSENT FROM THIS
# LIST. It was tried at 0.50: thicker air, but haze pulls lit ground and
# shadowed ground toward the SAME fog colour, so it compresses contrast — and in
# the foggiest biome, which is already at the fog ceiling, it compressed faster
# than the key gain widened. The Hollows came out measurably FLATTER at dread
# 1.0 than at dread 0.0 (lit:shadow 2.43 -> 2.37), which is the opposite of this
# curve's whole claim. Fog density still rises; the cap stays a guard.

## How dark baked ambient occlusion is allowed to go (Shade default 0.72).
const AO_FLOOR_LO: float = 0.72
const AO_FLOOR_HI: float = 0.62
## Global saturation grade multiplier for the 3D environment.
const SAT_GRADE: float = 0.86

## Fraction of dread-0 open-ground light that survives at dread 1.0. KEY_MULT
## above is solved to hold that at 1.0 for a typical biome, but it cannot hold
## for all sixteen at once: voidrift takes more of its light from the fill than
## greenwood does, so it loses a fifth where greenwood loses none. MEASURED worst
## case, used to lift the ground's darkness floor by exactly what the light
## stopped delivering — the floor belongs on what reaches the eye, so when the
## fill falls the floor has to rise to meet it.
const LIGHT_LOSS: float = 0.80

## Resolved biome dictionaries, keyed by tagged id. Rebuilding one costs ~30
## colour conversions and `get_biome()` is called per cell by the top-down
## preview, so it is cached — behind a mutex because WorldBuilder generates a
## region on a worker thread while the main thread is still drawing the UI from
## the same table.
static var _shift_cache: Dictionary = {}
static var _shift_lock: Mutex = Mutex.new()


## Tag a biome id with a dread value. Quantised to whole percent — Campaign's
## hundred maps step by 1.01%, so a percent is exactly the resolution the curve
## has, and it keeps the cache to one entry per map instead of one per float.
static func tag(id: String, dread: float) -> String:
	var base: String = base_id(id)
	var pct: int = clampi(int(round(clampf(dread, 0.0, 1.0) * 100.0)), 0, 100)
	if pct <= 0:
		return base
	return base + DREAD_SEP + str(pct)


## The biome id without its dread tag.
static func base_id(id: String) -> String:
	var at: int = id.find(DREAD_SEP)
	return id if at < 0 else id.substr(0, at)


## The dread a tagged id carries, 0 if untagged.
static func dread_in(id: String) -> float:
	var at: int = id.find(DREAD_SEP)
	if at < 0:
		return 0.0
	return clampf(float(id.substr(at + 1).to_int()) / 100.0, 0.0, 1.0)


static func exists(id: String) -> bool:
	return TABLE.has(base_id(id))


# `mood` is NOT dread-graded here. The stage plates need a dread clause in their
# prompt and they get one from StageArt.BANDS + DREAD_LADDER in
# tools/gen_concept_art.py, which is one ladder in one file; a second clause
# bolted onto `mood` would be a second author of the same idea, and the prompt
# would then carry two descriptions of how frightening the place is.


# ---- access ------------------------------------------------------------------

static func get_biome(id: String) -> Dictionary:
	var at: int = id.find(DREAD_SEP)
	if at < 0:
		return TABLE.get(id, TABLE["greenwood"])

	var base: String = id.substr(0, at)
	if not TABLE.has(base):
		base = "greenwood"
	var dread: float = clampf(float(id.substr(at + 1).to_int()) / 100.0, 0.0, 1.0)
	# A zero tag must be BIT-IDENTICAL to no tag, not merely close: map 1 has to
	# look exactly like the world looked before the curve existed, or every
	# before/after comparison is reading float noise through an HSV round-trip.
	if dread <= 0.0005:
		return TABLE[base]

	_shift_lock.lock()
	var hit: Variant = _shift_cache.get(id)
	_shift_lock.unlock()
	if hit != null:
		return hit

	var out: Dictionary = _shift(TABLE[base], dread)
	_shift_lock.lock()
	_shift_cache[id] = out
	_shift_lock.unlock()
	return out


## The dread shift itself: one biome's values, graded. Pure — same input, same
## output, no state — which is what lets it be cached and read from a thread.
static func _shift(base: Dictionary, d: float) -> Dictionary:
	# Shallow copy. Only top-level keys are reassigned, so the prop and cover
	# weight tables stay shared with the parent biome rather than being
	# duplicated a hundred times; nothing in the engine writes to them.
	var b: Dictionary = base.duplicate()

	b["dread"] = d
	b["sun"] = _grade(base["sun"], d, HUE_SUN, SAT_SUN, LUM_SUN)
	# The fill drops furthest of anything here, and is then held at the dimmest
	# ambient the game already ships — by way of minf against the biome's own
	# starting luminance, so a biome that was ALREADY at or under that floor
	# (hollows, voidrift) is held where it is rather than being brightened by
	# its own dread. This is the preview's fill; FILL_KEYS is the game's.
	b["ambient"] = _floor_lum(
		_grade(base["ambient"], d, HUE_AMB, SAT_AMB, LUM_AMB),
		minf(_lum(base["ambient"]), _darkest("ambient")))

	b["fog_density"] = minf(float(base["fog_density"]) * lerpf(1.0, FOG_GAIN, d),
		maxf(float(base["fog_density"]), FOG_CEIL))

	# fog is graded with the sky because it IS part of the sky here — see
	# FILL_KEYS. _hold_fill then floors the three of them as one.
	b["fog"] = _grade(base["fog"], d, HUE_FOG, SAT_FOG, LUM_FOG)
	b["sky_top"] = _grade(base["sky_top"], d, HUE_SKY, SAT_SKY_TOP, LUM_SKY_TOP)
	b["sky_horizon"] = _grade(base["sky_horizon"], d, HUE_SKY, SAT_SKY_HZ,
		LUM_SKY_HZ)
	_hold_fill(b, base)

	# THE FLOOR IS THE ART DIRECTION'S OWN DARKEST GROUND, not a number invented
	# here: dread may darken a biome down to voidrift and no further, because
	# voidrift at dread 0 is the darkest ground this game has ever shipped and
	# someone judged it readable. Derived, so a new biome moves the floor by
	# being authored rather than by anyone remembering to update a constant.
	# The consequence is deliberate and visible in the renders: the biomes that
	# are already nearly black have no darkening left, so their dread is spent
	# on fog, sky, fill and chroma instead.
	var ground: Array = _pair(base["ground_lo"], base["ground_hi"], d,
		HUE_GROUND, SAT_GROUND, LUM_GROUND, SPAN_GROUND,
		_darkest_pair("ground_lo", "ground_hi") / lerpf(1.0, LIGHT_LOSS, d))
	b["ground_lo"] = ground[0]
	b["ground_hi"] = ground[1]
	var stone: Array = _pair(base["rock"], base["rock_hi"], d, HUE_GROUND,
		SAT_ROCK, LUM_ROCK, SPAN_ROCK,
		_darkest_pair("rock", "rock_hi") / lerpf(1.0, LIGHT_LOSS, d))
	b["rock"] = stone[0]
	b["rock_hi"] = stone[1]
	b["soil"] = _grade(base["soil"], d, HUE_GROUND, SAT_SOIL, LUM_SOIL)

	b["water"] = _grade(base["water"], d, HUE_FOG, SAT_WATER, LUM_WATER)
	b["water_deep"] = _grade(base["water_deep"], d, HUE_FOG, SAT_WATER,
		LUM_WATER_DEEP)

	b["accent"] = _grade(base["accent"], d, 0.0, SAT_ACCENT, LUM_ACCENT)

	b["cover_density"] = int(round(float(base["cover_density"])
		* lerpf(1.0, 1.0 - COVER_DRAIN, d)))

	# Lighting ratio, for whoever is doing the lighting.
	#
	# `key_mult` is applied — by Shade.light() and by Mesher's DirectionalLight,
	# since the sun COLOUR holds its luminance and energy is the only place the
	# key can gain. `fill_mult` is NOT applied by anybody: both renderers get
	# their fill from a colour that has already been graded down (the ambient
	# here, the sky there), so this is the number they are tied TO, reported for
	# the tools that print the curve. Multiplying by it as well was the
	# double-darkening bug; see Shade.light().
	b["key_mult"] = lerpf(1.0, KEY_MULT, d)
	b["fill_mult"] = lerpf(1.0, FILL_MULT, d)
	b["key_gamma"] = lerpf(KEY_GAMMA_LO, KEY_GAMMA_HI, d)
	b["ao_floor"] = lerpf(AO_FLOOR_LO, AO_FLOOR_HI, d)
	b["sat_grade"] = lerpf(1.0, SAT_GRADE, d)
	return b


# Rotate a colour toward DREAD_HUE, drain its saturation, and land it on a
# luminance. HSV for hue and chroma because a lerp toward grey loses the hue, and
# the hue is the whole difference between "colder", "sicklier" and merely
# "darker"; luminance separately and last, for the reason in the LUM_* note.
static func _grade(c: Color, d: float, hue_amt: float, sat_mult: float,
		lum_mult: float) -> Color:
	return _grade_to(c, d, hue_amt, sat_mult,
		_lum(c) * lerpf(1.0, lum_mult, d))


# A two-colour ramp — ground_lo/ground_hi, rock/rock_hi — graded around its mean
# and its span so the pair darkens while the distance between them grows. Which
# end is the bright one is READ, not assumed; see the SPAN_GROUND note.
static func _pair(c_lo: Color, c_hi: Color, d: float, hue_amt: float,
		sat_mult: float, lum_mult: float, span_mult: float,
		mean_floor: float = 0.0) -> Array:
	var l_lo: float = _lum(c_lo)
	var l_hi: float = _lum(c_hi)
	var base_mean: float = (l_lo + l_hi) * 0.5
	# The floor can land ABOVE this biome's own mean, and that is intended for
	# exactly one case: the darkest biome in the game, whose albedo has to be
	# lifted by the light the dread shift stopped delivering (see LIGHT_LOSS) so
	# that what reaches the screen holds the floor. The lift is at most 1/0.84,
	# it only ever applies where the biome is already at the bottom of the
	# range, and the thing it holds constant is the RENDER, not the swatch.
	var mean: float = maxf(base_mean * lerpf(1.0, lum_mult, d), mean_floor)
	var half: float = absf(l_hi - l_lo) * 0.5 * lerpf(1.0, span_mult, d)
	var dir: float = 1.0 if l_hi >= l_lo else -1.0
	return [
		_grade_to(c_lo, d, hue_amt, sat_mult, maxf(mean - dir * half, 0.012)),
		_grade_to(c_hi, d, hue_amt, sat_mult, maxf(mean + dir * half, 0.012)),
	]


static func _grade_to(c: Color, d: float, hue_amt: float, sat_mult: float,
		target_lum: float) -> Color:
	var h: float = c.h
	if hue_amt > 0.0001 and c.s > 0.001:
		# Shortest way round the wheel, or a rotation from red toward teal
		# travels through half the spectrum and arrives via green.
		var dh: float = DREAD_HUE - h
		if dh > 0.5:
			dh -= 1.0
		elif dh < -0.5:
			dh += 1.0
		h = fposmod(h + dh * hue_amt * d, 1.0)
	var out: Color = Color.from_hsv(h,
		clampf(c.s * lerpf(1.0, sat_mult, d), 0.0, 1.0), c.v, c.a)
	return _set_lum(out, target_lum)


# Scale a colour to a luminance. Uniform across the channels, so the hue and the
# saturation the grade just chose survive it.
static func _set_lum(c: Color, target: float) -> Color:
	var l: float = _lum(c)
	if l <= 0.0001:
		return Color(target, target, target, c.a).clamp()
	var k: float = target / l
	# Brightening stops at the first channel that would clip. A clipped channel
	# is a hue and saturation change by the back door, and the one colour this
	# matters for is the accent — the thing dread is supposed to leave boldest.
	if k > 1.0:
		var mx: float = maxf(maxf(c.r, c.g), c.b)
		if mx > 0.0001:
			k = minf(k, 1.0 / mx)
	return Color(c.r * k, c.g * k, c.b * k, c.a).clamp()


# Hold a colour at or above a luminance.
static func _floor_lum(c: Color, floor_lum: float) -> Color:
	return c if _lum(c) >= floor_lum else _set_lum(c, floor_lum)


# The mean luminance of the darkest shipped pair of a two-colour ramp, over
# every biome. Pure and uncached: it runs 16 luminance reads, once per
# (biome, dread) pair, inside a result that is itself cached.
# Hold the composite fill — sky_top, sky_horizon and fog together — at or above
# the dimmest the shipped palettes already produce, scaling all three by the
# same factor so the dread grade's hues and their relative order survive.
#
# WHY A COMPOSITE AND NOT THREE FLOORS: the three are averaged into one ambient
# term by the renderer, so flooring them individually would let two of them sink
# while the third held the arithmetic up. Measured on voidrift, whose zenith is
# already the darkest in the game: individual floors still took its shadowed
# ground to a quarter of its shipped brightness on screen, and the strip in
# tools/out/dread3d_voidrift.png showed the champion disappearing into it.
static func _hold_fill(b: Dictionary, base: Dictionary) -> void:
	var now: float = 0.0
	var was: float = 0.0
	for k in FILL_KEYS:
		now += _lum(b[k])
		was += _lum(base[k])
	now /= float(FILL_KEYS.size())
	was /= float(FILL_KEYS.size())

	var limit: float = 1.0
	for id in IDS:
		var e: Dictionary = TABLE[id]
		var sum: float = 0.0
		for k in FILL_KEYS:
			sum += _lum(e[k])
		limit = minf(limit, sum / float(FILL_KEYS.size()))

	var want: float = minf(was, limit)
	if now >= want or now <= 0.0001:
		return
	var k2: float = want / now
	for k in FILL_KEYS:
		b[k] = _set_lum(b[k], _lum(b[k]) * k2)


# The darkest shipped value of one palette key, over every biome.
static func _darkest(key: String) -> float:
	var m: float = 1.0
	for id in IDS:
		m = minf(m, _lum((TABLE[id] as Dictionary)[key]))
	return m


static func _darkest_pair(key_lo: String, key_hi: String) -> float:
	var m: float = 1.0
	for id in IDS:
		var e: Dictionary = TABLE[id]
		m = minf(m, (_lum(e[key_lo]) + _lum(e[key_hi])) * 0.5)
	return m


static func _lum(c: Color) -> float:
	return c.get_luminance()


static func field(id: String, key: String, fallback: Variant = null) -> Variant:
	var b: Dictionary = get_biome(id)
	return b.get(key, fallback)


## The biome's own name, never the tagged id — the player is told they are in
## Voidrift, not in "voidrift~63".
static func display_name(id: String) -> String:
	return String(field(id, "name", base_id(id).capitalize()))


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
	var i: int = IDS.find(base_id(id))
	if i < 0:
		return 0
	return i / 4


## THE ORDER OF `IDS` IS THE PROGRESSION, and that is the whole of biome
## selection: index 0 is the most temperate place in the game and index 15 is the
## citadel at the end of it. Campaign.biome_at() samples this list with a window
## that walks from its head to its tail across the ten acts, so early maps draw
## temperate ids and late maps hostile ones — it is a ramp, not a 16-entry cycle.
## Adding a biome re-spaces the campaign by inserting it where it belongs on the
## ramp; it needs no new per-biome field and no scared variant.
static func campaign_order() -> PackedStringArray:
	return IDS


## Where a biome sits on the progression, 0..1. The inverse of for_dread().
static func dread_of(id: String) -> float:
	var i: int = IDS.find(base_id(id))
	if i < 0:
		return 0.0
	return float(i) / float(maxi(IDS.size() - 1, 1))


## The biome at a point on the progression. Campaign.biome_at() is the authority
## for an actual map (it also spaces acts and overlaps their windows); this is
## for everything that has a dread but no map index — concept-art plates, the
## preview tools, tests.
static func for_dread(d: float) -> String:
	var n: int = IDS.size()
	if n <= 0:
		return ""
	return IDS[clampi(int(round(clampf(d, 0.0, 1.0) * float(n - 1))), 0, n - 1)]


## How frightening a biome is ON ITS OWN, measured from its palette rather than
## declared in a seventeenth column: dark sky, dim sun, thick fog and drained
## ground all read as menace, and a biome's existing numbers already say all
## four. Used to CHECK that the hand-ordered list above really is a ramp
## (tools/dreadtest.gd) instead of taking the ordering on trust — and it costs an
## author nothing when a biome is added.
static func hostility(id: String) -> float:
	var b: Dictionary = get_biome(id)
	var sky: float = (b["sky_top"] as Color).get_luminance()
	var sun: float = (b["sun"] as Color).get_luminance()
	var amb: float = (b["ambient"] as Color).get_luminance()
	var fog: float = clampf(float(b["fog_density"]) / 0.030, 0.0, 1.0)
	var chroma: float = ((b["ground_lo"] as Color).s
		+ (b["ground_hi"] as Color).s) * 0.5
	# Darkness carries most of it; fog and the drained ground are the rest.
	return clampf(
		(1.0 - sky) * 0.34 + (1.0 - sun) * 0.18 + (1.0 - amb) * 0.20
		+ fog * 0.18 + (1.0 - chroma) * 0.10, 0.0, 1.0)
