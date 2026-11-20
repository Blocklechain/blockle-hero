extends Node3D
# Does the background build actually keep the frame alive?
#
# Claiming "non-blocking" without measuring frame times is exactly the kind of
# assertion this project has been burned by. So: generate a region twice — once
# on the main thread, once on the builder — and record the worst frame in each.

var _builder: WorldBuilder
var _frames: Array[float] = []
var _last_us: int = 0
var _phase := "idle"
var _t0: int = 0


func _ready() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	# AFTER add_child. look_at() works on the global transform and errors out
	# ("Node not inside tree") if the node has not been parented — the same trap
	# that silently left the sun pointing nowhere during the lighting pass.
	cam.look_at_from_position(Vector3(0, 40, 60), Vector3.ZERO, Vector3.UP)

	_builder = WorldBuilder.new()
	add_child(_builder)
	_builder.progress.connect(func(s: String, f: float):
		print("    [%3d%%] %s" % [int(f * 100.0), s]))
	_builder.finished.connect(_on_finished)

	_last_us = Time.get_ticks_usec()
	await get_tree().process_frame
	await get_tree().process_frame

	# --- baseline: build on the main thread -------------------------------
	print("\n=== A. generating ON the main thread ===")
	_frames.clear()
	_phase = "blocking"
	await get_tree().process_frame
	_t0 = Time.get_ticks_usec()
	var plan := Layout.generate(4242, Vector2(192, 192), Layout.Sym.ASYMMETRIC, 11)
	var ter := Terrain.generate(4242, "greenwood", 384, 0.5, plan)
	var scat := Scatter.generate(ter, plan, 4242)
	Mesher.build_chunks(ter, 1)
	var ms_block: float = float(Time.get_ticks_usec() - _t0) / 1000.0
	for i in range(30):
		await get_tree().process_frame
	print("  generation took %.0f ms" % ms_block)
	print("  worst frame while blocking: %.1f ms" % _worst())

	# --- the real thing: build on the worker ------------------------------
	print("\n=== B. generating on the BACKGROUND thread ===")
	_frames.clear()
	_phase = "threaded"
	_t0 = Time.get_ticks_usec()
	_builder.build(4242, "greenwood", 384, 0.5)


func _on_finished(root: Node3D, ter: Terrain, plan: Layout) -> void:
	var ms: float = float(Time.get_ticks_usec() - _t0) / 1000.0
	add_child(root)
	print("  generation took %.0f ms" % ms)
	print("  worst frame while threaded: %.1f ms" % _worst())
	print("  frames rendered during build: %d" % _frames.size())
	print("  region parented: %d children, walkable %.0f%%" % [
		root.get_child_count(), ter.walkable_fraction() * 100.0])
	get_tree().quit()


func _process(_d: float) -> void:
	var now: int = Time.get_ticks_usec()
	var dt: float = float(now - _last_us) / 1000.0
	_last_us = now
	if _phase != "idle":
		_frames.append(dt)


func _worst() -> float:
	var w: float = 0.0
	for f in _frames:
		w = maxf(w, f)
	return w
