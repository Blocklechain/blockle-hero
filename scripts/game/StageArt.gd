class_name StageArt
extends RefCounted
# ------------------------------------------------------------------------------
# WHICH PICTURE A MAP SHOWS.
#
# The campaign is 100 maps over 16 biomes, so there is no 1:1 map-to-plate
# option worth having: 100 plates would be a hundred near-identical pictures of
# the same six forests, and 16 would make map 95 look exactly as safe as map 5.
# Plates are therefore generated per BIOME x DREAD BAND and a map resolves to
# one — the quantisation the roadmap's dread curve calls for.
#
# BANDS IS DECLARED HERE AND NOWHERE ELSE. tools/gen_concept_art.py parses this
# constant out of this file to decide how many plates to generate and which
# dread clause each one gets, for the same reason it parses the biome moods out
# of Biome.gd: the art cannot drift from the thing it depicts if there is only
# one place the number lives.
#
# FIVE BANDS, because the campaign is ten acts (Campaign.ACT_COUNT) and dread is
# linear, so a band is exactly two acts: the picture changes every twenty maps,
# which is often enough to feel like progress and rare enough that an act keeps
# a recognisable look. Fewer and act 1 shares its sky with act 4; more and the
# plate count rises without the player being able to tell two neighbours apart.
# ------------------------------------------------------------------------------

const BANDS: int = 5

const STAGE_DIR: String = "res://assets/art/stages"
const MENU_DIR: String = "res://assets/art/menu"

## The menu plates. Named here so a screen asks for a plate by name and the
## generator and tools/uitest-style checks can enumerate the same set.
const MENUS: PackedStringArray = [
	"title", "stage_select", "roster", "stash", "defeat",
]


## The plate a map wants, as `<biome>_d<band>`. Pure naming: it does not care
## whether the file was generated yet.
##
## base_id() because a biome id may arrive dread-TAGGED ("greenwood@40", the
## palette shift's encoding). The tag is the continuous curve; the plate wants
## the quantised band, and a key like "greenwood@40_d0" would name a file that
## cannot exist.
static func plate_key(index: int) -> String:
	return "%s_d%d" % [Biome.base_id(Campaign.biome_at(index)),
		Campaign.dread_band(index, BANDS)]


## The plate a map actually gets, or "" when there is no art on disk at all.
##
## FALLS BACK ALONG THE BAND, not along the biome: a Boneyard map shown the
## wrong-dread Boneyard plate still shows the right place, while the
## right-dread Ashwastes plate shows the wrong one. Needed because the art set
## is generated for the biome x band pairs the campaign actually visits — a
## later change to Campaign.biome_at can reach a pair nobody has generated yet,
## and that must dim the mood, not crash a screen or boot a black frame.
static func stage_plate(index: int) -> String:
	var biome: String = Biome.base_id(Campaign.biome_at(index))
	var want: int = Campaign.dread_band(index, BANDS)
	for distance in range(BANDS):
		for band in [want - distance, want + distance]:
			if band < 0 or band >= BANDS:
				continue
			var path: String = "%s/%s_d%d.jpg" % [STAGE_DIR, biome, band]
			if ResourceLoader.exists(path):
				return path
	return ""


static func menu_plate(name: String) -> String:
	var path: String = "%s/%s.jpg" % [MENU_DIR, name]
	return path if ResourceLoader.exists(path) else ""


## Every plate the campaign can ask for, deduplicated — what the generator
## renders and what an audit counts. Ordered by first appearance so the list
## reads as the journey.
static func required_plates() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for i in range(Campaign.map_count()):
		var key: String = plate_key(i)
		if not out.has(key):
			out.append(key)
	return out
