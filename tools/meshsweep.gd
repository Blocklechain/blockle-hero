extends SceneTree
# Coarse-grained work (one whole mesh per task, local buffers) may thread even
# though the fine-grained per-cell passes did not. Measure, do not assume.

func _init() -> void:
	var plan := Layout.generate(7000, Vector2(192, 192), Layout.Sym.ASYMMETRIC, 11)
	var ter := Terrain.generate(7000, "greenwood", 384, 0.5, plan)

	for mode in [false, true, false, true]:
		Mesher._parallel = mode
		var t0: int = Time.get_ticks_usec()
		var chunks: Array = Mesher.build_chunks(ter, 1)
		var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
		var verts: int = 0
		for m in chunks:
			verts += (m as ArrayMesh).surface_get_array_len(0)
		print("build_chunks  parallel=%-5s  %8.1f ms   %d chunks, %d verts" % [
			str(mode), ms, chunks.size(), verts])
	quit()
