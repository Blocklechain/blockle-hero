extends SceneTree
# Why is greenwood ground tan? Print what the shader is actually being fed,
# rather than guessing at it from a screenshot.

func _init() -> void:
	var plan := Layout.generate(7000, Vector2(192, 192), Layout.Sym.ASYMMETRIC, 11)
	var ter := Terrain.generate(7000, "greenwood", 384, 0.5, plan)
	var entry: Dictionary = plan.node_of_kind(Layout.ENTRY)
	var focus: Vector2 = ter.nearest_walkable(entry.get("pos", Vector2.ZERO))

	var names := ["GROUND", "ROCK", "SAND", "PATH", "WATER", "FLOOR"]
	var hist := [0, 0, 0, 0, 0, 0]
	for v in ter.surf:
		hist[v] += 1
	print("surface histogram over whole region:")
	for i in range(6):
		print("  %-7s %6d  (%4.1f%%)" % [names[i], hist[i],
			100.0 * float(hist[i]) / float(ter.surf.size())])

	# What the camera is actually looking at: a 25 m box around the focus.
	var half: float = 384.0 * 0.5 * 0.5
	var cx: int = int((focus.x + half) / 0.5)
	var cy: int = int((focus.y + half) / 0.5)
	var local := [0, 0, 0, 0, 0, 0]
	for dy in range(-25, 26):
		for dx in range(-25, 26):
			if ter.in_bounds(cx + dx, cy + dy):
				local[ter.surf[ter.idx(cx + dx, cy + dy)]] += 1
	print("\nin view at the entry arena:")
	for i in range(6):
		if local[i] > 0:
			print("  %-7s %5d" % [names[i], local[i]])

	print("\nbiome palette:")
	var b: Dictionary = Biome.get_biome("greenwood")
	for k in ["ground_lo", "ground_hi", "soil", "sun", "ambient"]:
		print("  %-10s %s" % [k, (b[k] as Color).to_html(false)])

	print("\nalbedo actually produced at 5 cells near the camera:")
	for n in range(5):
		var x: int = cx + n * 4 - 8
		var y: int = cy + n * 3 - 6
		if not ter.in_bounds(x, y):
			continue
		print("  surf=%-7s carve=%.2f slope=%.2f  albedo=%s" % [
			names[ter.surf[ter.idx(x, y)]], ter.carve[ter.idx(x, y)],
			ter.slope[ter.idx(x, y)], Shade.albedo(ter, x, y).to_html(false)])
	quit()
