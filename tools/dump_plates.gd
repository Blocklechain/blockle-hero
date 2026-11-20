extends SceneTree
# What stage art the campaign needs, straight from the campaign.
#
# tools/gen_concept_art.py runs this and generates exactly the plates it names.
# It exists so the generator never re-derives Campaign.biome_at, the dread curve
# or the band count in Python: the plate list, the dread each plate covers and
# the biome mood that becomes the prompt all come out of the GDScript that the
# game itself reads. Replicating biome_at in the generator would mean the art
# silently stops matching the maps the first time the act windows move.
#
# Also an audit: run it by hand to see which plates are missing from disk and
# how many of the hundred maps each one is carrying.
#
#   Godot --headless --path . --script tools/dump_plates.gd


func _init() -> void:
	var plates: Dictionary = {}
	var order: Array[String] = []
	for i in range(Campaign.map_count()):
		var key: String = StageArt.plate_key(i)
		var d: float = Campaign.dread(i)
		if not plates.has(key):
			order.append(key)
			var biome: String = Campaign.biome_at(i)
			plates[key] = {
				"key": key,
				"biome": biome,
				"band": Campaign.dread_band(i, StageArt.BANDS),
				"name": Biome.display_name(biome),
				"mood": String(Biome.field(biome, "mood", "")),
				"dread_lo": d,
				"dread_hi": d,
				"maps": 0,
				"first_map": i + 1,
				"first_title": Campaign.region_title(i),
			}
		var e: Dictionary = plates[key]
		e["dread_lo"] = minf(float(e["dread_lo"]), d)
		e["dread_hi"] = maxf(float(e["dread_hi"]), d)
		e["maps"] = int(e["maps"]) + 1

	var out: Array = []
	var missing: int = 0
	print("=== stage plates: %d for %d maps, %d bands ===" % [
		order.size(), Campaign.map_count(), StageArt.BANDS])
	for key in order:
		var e: Dictionary = plates[key]
		var path: String = "%s/%s.jpg" % [StageArt.STAGE_DIR, key]
		var have: bool = ResourceLoader.exists(path)
		if not have:
			missing += 1
		e["exists"] = have
		out.append(e)
		print("  %-16s band %d  dread %.2f-%.2f  %2d maps  from %-38s %s" % [
			key, int(e["band"]), float(e["dread_lo"]), float(e["dread_hi"]),
			int(e["maps"]), e["first_title"], "" if have else "MISSING"])

	# Every map must land on a file, which is not the same as every plate
	# existing: StageArt.stage_plate falls back along the band.
	var unart: int = 0
	for i in range(Campaign.map_count()):
		if StageArt.stage_plate(i) == "":
			unart += 1
	print("plates missing: %d   maps with no art at all: %d" % [missing, unart])

	for name in StageArt.MENUS:
		if StageArt.menu_plate(name) == "":
			print("  menu plate MISSING: %s" % name)
			out.append({"key": name, "menu": true, "exists": false})
		else:
			out.append({"key": name, "menu": true, "exists": true})

	# The machine-readable half. One line, marked, so the generator can find it
	# past Godot's own startup chatter.
	print("PLATES_JSON " + JSON.stringify(out))
	quit(0)
