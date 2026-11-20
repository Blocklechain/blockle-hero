extends SceneTree
# Where is the model origin relative to the body, in BOTH sets? HeroRig places
# the model at the HeroRig's own origin, and HeroController pins that origin to
# the terrain surface -- so the mesh's AABB must start at y == 0 (feet at the
# origin) or the hero sinks / floats by exactly that offset.

const ANIM := "/Volumes/ExtremePro/raid/assets/heroes/animated"
const STAT := "/Volumes/ExtremePro/raid/assets/heroes/tex"
const PICKS := ["aldous", "brom", "g001", "g070", "g169", "kaelen", "willow", "g015", "g101"]


func _init() -> void:
	for dir in [ANIM, STAT]:
		print("=== ", dir)
		for h in PICKS:
			var path: String = dir.path_join(h + ".glb")
			if not FileAccess.file_exists(path):
				print("   %-9s (absent)" % h)
				continue
			var doc := GLTFDocument.new()
			var st := GLTFState.new()
			if doc.append_from_file(path, st) != OK:
				print("   %-9s PARSE FAIL" % h)
				continue
			var scene: Node = doc.generate_scene(st)
			var aabb := AABB()
			var first := true
			for c in scene.find_children("*", "MeshInstance3D", true, false):
				var mi := c as MeshInstance3D
				if mi.mesh == null:
					continue
				# Same measurement HeroRig._normalise_scale makes (local mesh AABB).
				var a: AABB = mi.get_aabb()
				if first:
					aabb = a
					first = false
				else:
					aabb = aabb.merge(a)
			var scale: float = 1.85 / aabb.size.y
			print("   %-9s aabb y=[%+.3f .. %+.3f] size=%s -> scale %.4f  => feet land at y=%+.3f m" % [
				h, aabb.position.y, aabb.position.y + aabb.size.y,
				str(aabb.size).pad_decimals(2), scale, aabb.position.y * scale])
			scene.queue_free()
	quit()
