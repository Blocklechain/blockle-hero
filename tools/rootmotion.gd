extends SceneTree
# Does any clip translate the character in the horizontal plane? The contract
# says root motion: none. Measure the Hips bone's global position (in metres,
# after HeroRig's scale normalisation) at the start, middle and end of every clip.

func _init() -> void:
	var heroes := ["aldous", "brom", "g070", "g169"]
	for hero in heroes:
		var rig := HeroRig.new()
		root.add_child(rig)
		if not rig.load_hero(hero):
			print(hero, ": load failed"); continue
		var ap: AnimationPlayer = rig._anim
		var sk: Skeleton3D = rig._model.find_children("*", "Skeleton3D", true, false)[0]
		var hip := -1
		for b in sk.get_bone_count():
			if sk.get_bone_name(b).to_lower().contains("hips"):
				hip = b
				break
		print("== %s  (model scale %.4f, hips bone '%s')" % [hero, rig._model.scale.y, sk.get_bone_name(hip)])
		for clip in ap.get_animation_list():
			var a: Animation = ap.get_animation(clip)
			var pts := []
			for frac in [0.0, 0.25, 0.5, 0.75, 1.0]:
				ap.play(clip)
				ap.seek(a.length * frac, true)
				# force the pose to be applied
				sk.force_update_all_bone_transforms()
				var p: Vector3 = sk.to_global(sk.get_bone_global_pose(hip).origin)
				pts.append(p)
			var minx := INF; var maxx := -INF; var minz := INF; var maxz := -INF
			var miny := INF; var maxy := -INF
			for p in pts:
				minx = minf(minx, p.x); maxx = maxf(maxx, p.x)
				miny = minf(miny, p.y); maxy = maxf(maxy, p.y)
				minz = minf(minz, p.z); maxz = maxf(maxz, p.z)
			print("   %-11s len=%.2fs  hips@t0=(%.3f, %.3f, %.3f)m  travel x=%.3f y=%.3f z=%.3f" % [
				clip, a.length, pts[0].x, pts[0].y, pts[0].z,
				maxx - minx, maxy - miny, maxz - minz])
		rig.queue_free()
	quit()
