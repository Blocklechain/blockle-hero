extends SceneTree
# What is actually inside a hero glb right now? Skeleton? Animations? The
# controller has to drive whatever the animation pass produces, so find out what
# the contract has to cope with rather than assuming.

const HERO_DIR := "/Volumes/ExtremePro/raid/assets/heroes/animated"

func _init() -> void:
	var dir := HERO_DIR
	for file in ["aldous.glb", "brom.glb", "g001.glb"]:
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(dir.path_join(file), state) != OK:
			print(file, ": load failed")
			continue
		var scene: Node = doc.generate_scene(state)
		var players: Array = scene.find_children("*", "AnimationPlayer", true, false)
		var skels: Array = scene.find_children("*", "Skeleton3D", true, false)
		var meshes: Array = scene.find_children("*", "MeshInstance3D", true, false)
		print("%-12s  meshes=%d  skeletons=%d  animplayers=%d" % [
			file, meshes.size(), skels.size(), players.size()])
		for sk in skels:
			print("    skeleton '%s': %d bones" % [sk.name, (sk as Skeleton3D).get_bone_count()])
		for ap in players:
			print("    animations: ", (ap as AnimationPlayer).get_animation_list())
		for m in meshes:
			var mi := m as MeshInstance3D
			print("    mesh '%s': surfaces=%d  skin=%s" % [mi.name,
				mi.mesh.get_surface_count() if mi.mesh else 0,
				"yes" if mi.skin != null else "no"])
	quit()
