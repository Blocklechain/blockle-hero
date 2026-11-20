extends SceneTree

const CELL: float = 0.5
const REGION: Vector2 = Vector2(192.0, 192.0)


func _init() -> void:
	for sd in [206894, 32676]:
		var l := Lane.make(sd, REGION)
		var n: int = int(REGION.x / CELL)
		var half: float = REGION.x * 0.5
		var bits := PackedByteArray()
		bits.resize(n * n)
		for nd in l.nodes:
			var p: Vector2 = nd["pos"]
			var r: float = float(nd["radius"])
			for y in range(n):
				for x in range(n):
					var q := Vector2(float(x) * CELL - half, float(y) * CELL - half)
					if q.distance_to(p) <= r:
						bits[y * n + x] = 1
		for e in l.edges:
			var pts: PackedVector2Array = e["pts"]
			var w: float = float(e["width"]) * 0.5
			for s in range(pts.size() - 1):
				for y in range(n):
					for x in range(n):
						var q2 := Vector2(float(x) * CELL - half, float(y) * CELL - half)
						if Layout._seg_dist(q2, pts[s], pts[s + 1]) <= w:
							bits[y * n + x] = 1

		var grid := AStarGrid2D.new()
		grid.region = Rect2i(0, 0, n, n)
		grid.cell_size = Vector2(CELL, CELL)
		grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
		grid.update()
		for y in range(n):
			for x in range(n):
				if bits[y * n + x] != 1:
					grid.set_point_solid(Vector2i(x, y), true)

		var e0: Vector2 = l.node_of_kind(Layout.ENTRY)["pos"]
		var b0: Vector2 = l.node_of_kind(Layout.BOSS)["pos"]
		var ca := Vector2i(int((e0.x + half) / CELL), int((e0.y + half) / CELL))
		var cb := Vector2i(int((b0.x + half) / CELL), int((b0.y + half) / CELL))
		var ids: Array[Vector2i] = grid.get_id_path(ca, cb)
		var walked: float = 0.0
		for i in range(ids.size() - 1):
			walked += Vector2(ids[i]).distance_to(Vector2(ids[i + 1])) * CELL

		# where does the route leave the spine?
		var worst: float = 0.0
		var worst_p := Vector2.ZERO
		for c in ids:
			var p2 := Vector2(float(c.x) * CELL - half, float(c.y) * CELL - half)
			var d: float = 1e9
			for q3 in l.spine:
				d = minf(d, p2.distance_to(q3))
			if d > worst:
				worst = d
				worst_p = p2
		print("seed %d len %.1f walked %.1f ratio %.2f  worst off-spine %.1f m at %s" % [
			sd, l.spine_length, walked, walked / l.spine_length, worst, str(worst_p)])
		for nd2 in l.nodes:
			var p3: Vector2 = nd2["pos"]
			if p3.distance_to(worst_p) < 40.0:
				print("   near: id %2d %-8s r %5.1f at %s  d %.1f" % [int(nd2["id"]),
					String(nd2["kind"]), float(nd2["radius"]), str(p3),
					p3.distance_to(worst_p)])

		var img := Image.create(n, n, false, Image.FORMAT_RGB8)
		for y in range(n):
			for x in range(n):
				img.set_pixel(x, y, Color(0.08, 0.09, 0.1) if bits[y * n + x] != 1
					else Color(0.55, 0.52, 0.45))
		for c2 in ids:
			img.set_pixel(c2.x, c2.y, Color(1.0, 0.3, 0.2))
		img.save_png("res://tools/out/lane_%d.png" % sd)
	quit(0)
