extends SceneTree
# Scan EVERY glb in animated/: skeleton+animplayer present, exact clip set, and
# whether any clip carries root motion (a position track on a node outside the
# Skeleton3D, or on the skeleton's root bone).

const ANIM_DIR := "/Volumes/ExtremePro/raid/assets/heroes/animated"

func _init() -> void:
	var names := PackedStringArray()
	var dir := DirAccess.open(ANIM_DIR)
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".glb"):
			names.append(f)
		f = dir.get_next()
	names.sort()

	var clipset_tally := {}
	var shape_tally := {}
	var bad := PackedStringArray()
	var rootmotion := PackedStringArray()
	var h_min := 1e9
	var h_max := -1e9
	var scanned := 0

	for file in names:
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(ANIM_DIR.path_join(file), state) != OK:
			bad.append(file + ":parse")
			continue
		var scene: Node = doc.generate_scene(state)
		if scene == null:
			bad.append(file + ":noscene")
			continue
		var players: Array = scene.find_children("*", "AnimationPlayer", true, false)
		var skels: Array = scene.find_children("*", "Skeleton3D", true, false)
		var meshes: Array = scene.find_children("*", "MeshInstance3D", true, false)
		var bones: int = (skels[0] as Skeleton3D).get_bone_count() if skels.size() > 0 else 0
		var shape := "sk=%d ap=%d mesh=%d bones=%d" % [skels.size(), players.size(), meshes.size(), bones]
		shape_tally[shape] = int(shape_tally.get(shape, 0)) + 1
		if skels.size() != 1 or players.size() != 1:
			bad.append(file + ":" + shape)
		else:
			var ap := players[0] as AnimationPlayer
			var clips: PackedStringArray = ap.get_animation_list()
			clips.sort()
			var key := String(",".join(clips))
			clipset_tally[key] = int(clipset_tally.get(key, 0)) + 1
			# Root motion: any 3D position track whose target path is not inside
			# the Skeleton3D (skeleton bone tracks use ":BoneName" subpaths).
			for cn in clips:
				var a: Animation = ap.get_animation(cn)
				for ti in a.get_track_count():
					if a.track_get_type(ti) != Animation.TYPE_POSITION_3D:
						continue
					var p: String = String(a.track_get_path(ti))
					if not p.contains(":"):
						rootmotion.append("%s/%s: %s" % [file, cn, p])
		# Height from mesh AABB, as HeroRig's normaliser sees it.
		var aabb := AABB()
		var first := true
		for c in meshes:
			var mi := c as MeshInstance3D
			if mi.mesh == null:
				continue
			var a2: AABB = mi.get_aabb()
			if first:
				aabb = a2
				first = false
			else:
				aabb = aabb.merge(a2)
		if aabb.size.y > 0.001:
			h_min = minf(h_min, aabb.size.y)
			h_max = maxf(h_max, aabb.size.y)
		scanned += 1
		scene.queue_free()

	print("scanned=%d of %d files" % [scanned, names.size()])
	print("node-shape tally: ", shape_tally)
	print("clip-set tally:")
	for k in clipset_tally.keys():
		print("   %dx  [%s]" % [clipset_tally[k], k])
	print("bad files: ", bad)
	print("root-motion position tracks outside skeleton: %d  %s" % [
		rootmotion.size(), ", ".join(rootmotion).substr(0, 400)])
	print("mesh AABB height range: %.3f .. %.3f m" % [h_min, h_max])
	quit()
