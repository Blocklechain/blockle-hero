extends SceneTree
# Why did get_bone_global_pose() report zero travel? Print raw numbers, and
# cross-check against a hand-chained parent walk so the metres are trustworthy.

func _chain_global(sk: Skeleton3D, b: int) -> Transform3D:
	var t := Transform3D()
	var i := b
	var guard := 0
	while i >= 0 and guard < 128:
		t = sk.get_bone_pose(i) * t
		i = sk.get_bone_parent(i)
		guard += 1
	return t


func _init() -> void:
	var rig := HeroRig.new()
	root.add_child(rig)
	rig.load_hero("aldous")
	var ap: AnimationPlayer = rig._anim
	var sk: Skeleton3D = rig._model.find_children("*", "Skeleton3D", true, false)[0]
	print("skeleton has force_update_all_bone_transforms? ",
		sk.has_method("force_update_all_bone_transforms"))

	var foot := -1
	var hip := -1
	for b in sk.get_bone_count():
		var n := sk.get_bone_name(b).to_lower()
		if foot < 0 and n.contains("leftfoot"):
			foot = b
		if hip < 0 and n.contains("hips"):
			hip = b
	print("bones: hips=%d(%s) leftfoot=%d(%s)" % [
		hip, sk.get_bone_name(hip), foot, sk.get_bone_name(foot)])

	# Which tracks does the walk clip actually have for hips?
	for clip in ["walk-loop", "run-loop"]:
		var a: Animation = ap.get_animation(clip)
		var kinds := {}
		var hip_tracks := []
		for t in a.get_track_count():
			var ty: int = a.track_get_type(t)
			kinds[ty] = int(kinds.get(ty, 0)) + 1
			if String(a.track_get_path(t)).to_lower().contains("hips"):
				hip_tracks.append("%s type=%d keys=%d" % [
					a.track_get_path(t), ty, a.track_get_key_count(t)])
		print("%s: track types %s (3=pos 4=rot 5=scale)  hips tracks: %s" % [
			clip, str(kinds), str(hip_tracks)])

	for clip in ["walk-loop", "run-loop"]:
		var a: Animation = ap.get_animation(clip)
		print("--- ", clip)
		for i in 8:
			var t: float = a.length * (float(i) / 8.0)
			ap.play(clip)
			ap.seek(t, true)
			sk.force_update_all_bone_transforms()
			var gp_api: Vector3 = sk.get_bone_global_pose(foot).origin
			var gp_chain: Vector3 = _chain_global(sk, foot).origin
			var hip_chain: Vector3 = _chain_global(sk, hip).origin
			var thigh_rot: Quaternion = sk.get_bone_pose_rotation(foot)
			print("  t=%.3f api_foot=(%.3f,%.3f,%.3f) chain_foot=(%.3f,%.3f,%.3f) chain_hip=(%.3f,%.3f,%.3f) footrot=%s" % [
				t, gp_api.x, gp_api.y, gp_api.z,
				gp_chain.x, gp_chain.y, gp_chain.z,
				hip_chain.x, hip_chain.y, hip_chain.z, str(thigh_rot)])
	quit()
