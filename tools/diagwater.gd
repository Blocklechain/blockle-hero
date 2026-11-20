extends SceneTree
func _init() -> void:
	# MUST use the same seeds the shot harness uses (7000 + index*1361) or this
	# measures a different world than the one in the screenshot.
	var shots := [["greenwood", 0], ["tidebreak", 1], ["emberfall", 2],
		["frostcrag", 3], ["mistmoor", 4], ["duskvale", 6]]
	for sh in shots:
		var bid: String = sh[0]
		var ws: int = 7000 + int(sh[1]) * 1361
		var plan := Layout.generate(ws, Vector2(192, 192), Layout.Sym.ASYMMETRIC, 11)
		var ter := Terrain.generate(ws, bid, 384, 0.5, plan)
		var deepest: float = 0.0
		var submerged: int = 0
		for i in range(ter.h.size()):
			var d: float = ter.water_h - ter.h[i]
			if d > 0.0:
				submerged += 1
				deepest = maxf(deepest, d)
		var m: ArrayMesh = Mesher.build_water(ter)
		var verts: int = 0
		var maxc: float = 0.0
		if m != null:
			var arr: Array = m.surface_get_arrays(0)
			var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
			verts = cols.size()
			for c in cols:
				maxc = maxf(maxc, c.r)
		# Median depth matters more than the max: one deep cell in a wide shallow
		# pan still renders as an all-foam sheet.
		var ds := PackedFloat32Array()
		for i in range(ter.h.size()):
			var dd: float = ter.water_h - ter.h[i]
			if dd > 0.0:
				ds.append(dd)
		ds.sort()
		var med: float = 0.0 if ds.is_empty() else ds[ds.size() / 2]
		print("%-10s seed=%5d  submerged=%6d  median=%5.2f m  deepest=%5.2f m  maxCOLOR.r=%.3f" % [
			bid, ws, submerged, med, deepest, maxc])
	quit()
