extends SceneTree
# Roster-wide version of tools/walkrun.gd. The six-hero sample all reported the
# SAME clip lengths and the SAME degrees of range-of-motion, which smells like
# one shared clip library stamped onto every rig — if so, whatever is true of
# walk-vs-run is true for all 139 at once, and if not, the sample proves nothing
# about the rest. Check every hero rather than guess which it is.

func _quat_angle(a: Quaternion, b: Quaternion) -> float:
	return rad_to_deg(2.0 * acos(clampf(absf(a.dot(b)), -1.0, 1.0)))


func _init() -> void:
	var heroes: PackedStringArray = HeroRig.animated_heroes()
	print("sweeping %d animated heroes" % heroes.size())

	var shapes: Dictionary = {}        # "walk_len|run_len" -> count
	var leg_rom: Dictionary = {}       # "walk_deg/run_deg" -> count
	var problems: Array = []
	var identical: int = 0
	var n_ok: int = 0

	for h in heroes:
		var rig := HeroRig.new()
		root.add_child(rig)
		if not rig.load_hero(h) or not rig.is_rigged:
			problems.append("%s: load/rig failed" % h)
			rig.queue_free()
			continue
		var ap: AnimationPlayer = rig._anim
		if not rig._clip_for.has(HeroRig.State.WALK) or not rig._clip_for.has(HeroRig.State.RUN):
			problems.append("%s: walk or run UNRESOLVED -> stun cannot read" % h)
			rig.queue_free()
			continue

		var wa: Animation = ap.get_animation(rig._clip_for[HeroRig.State.WALK])
		var ra: Animation = ap.get_animation(rig._clip_for[HeroRig.State.RUN])
		var key: String = "walk %.3fs / run %.3fs (ratio %.2f)" % [
			wa.length, ra.length, wa.length / maxf(ra.length, 0.0001)]
		shapes[key] = int(shapes.get(key, 0)) + 1

		# Cheap gait amplitude: max swing of the upper-leg bones over 12 phases.
		var sk: Skeleton3D = rig._model.find_children("*", "Skeleton3D", true, false)[0]
		var legs: Array = []
		for b in sk.get_bone_count():
			var nm: String = sk.get_bone_name(b).to_lower()
			if nm.contains("upleg") or nm.contains("thigh"):
				legs.append(b)
		var rom := {"walk": 0.0, "run": 0.0}
		for pair in [["walk", wa], ["run", ra]]:
			var label: String = pair[0]
			var clip: Animation = pair[1]
			var frames: Array = []
			for i in 12:
				ap.play(clip.resource_name if clip.resource_name != "" else
					rig._clip_for[HeroRig.State.WALK if label == "walk" else HeroRig.State.RUN])
				ap.seek(clip.length * (float(i) / 12.0), true)
				var pose := []
				for b in legs:
					pose.append(sk.get_bone_pose_rotation(b))
				frames.append(pose)
			var worst: float = 0.0
			for i in frames.size():
				for j in range(i + 1, frames.size()):
					for k in frames[i].size():
						worst = maxf(worst, _quat_angle(frames[i][k], frames[j][k]))
			rom[label] = worst
		var rk: String = "legs walk %.0f deg / run %.0f deg (run is %.2fx)" % [
			rom["walk"], rom["run"], rom["run"] / maxf(rom["walk"], 0.01)]
		leg_rom[rk] = int(leg_rom.get(rk, 0)) + 1

		if is_equal_approx(wa.length, ra.length):
			identical += 1
			problems.append("%s: walk and run are the SAME LENGTH" % h)
		if rom["run"] <= rom["walk"] * 1.05:
			problems.append("%s: run stride is not bigger than walk (%.0f vs %.0f deg)" % [
				h, rom["run"], rom["walk"]])
		n_ok += 1
		rig.queue_free()

	print("\nrigged + walk/run resolved: %d / %d" % [n_ok, heroes.size()])
	print("\ndistinct clip-length shapes across the roster:")
	for k in shapes:
		print("  %4d heroes   %s" % [shapes[k], k])
	print("\ndistinct leg range-of-motion shapes:")
	for k in leg_rom:
		print("  %4d heroes   %s" % [leg_rom[k], k])
	print("\nproblems: %d" % problems.size())
	for p in problems:
		print("  ", p)
	quit()
