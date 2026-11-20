extends SceneTree
# Full sweep of EVERY hero in the animated dir through the real HeroRig, so the
# "every hero is rigged with missing=[hit]" claim is tested on all of them, not
# a sample. Also measures per-clip motion magnitude to prove the clips are not
# static poses, and compares walk vs run pose-for-pose (the handoff says walk
# must read as laboured next to run, so an identical time-scaled clip is a
# content bug, not a win).

func _init() -> void:
	var all: PackedStringArray = HeroRig.animated_heroes()
	print("sweeping %d heroes" % all.size())
	var rigged := 0
	var missing_tally := {}
	var missing_sets := {}
	var clipset_tally := {}
	var bad := PackedStringArray()
	var deep_done := false

	for hero in all:
		var rig := HeroRig.new()
		root.add_child(rig)
		if not rig.load_hero(hero):
			bad.append(hero + ":LOAD_FAIL")
			rig.queue_free()
			continue
		if rig.is_rigged:
			rigged += 1
		else:
			bad.append(hero + ":NOT_RIGGED")
		var ms: PackedStringArray = rig.missing_states()
		var key: String = str(ms)
		missing_sets[key] = int(missing_sets.get(key, 0)) + 1
		for m in ms:
			missing_tally[m] = int(missing_tally.get(m, 0)) + 1
		if rig._anim:
			var cl: PackedStringArray = rig._anim.get_animation_list()
			var ck: String = str(cl)
			clipset_tally[ck] = int(clipset_tally.get(ck, 0)) + 1
			# Are the clips real motion? Measure rotation spread per clip.
			if not deep_done:
				deep_done = true
				_deep(rig, hero)
		rig.queue_free()

	print("")
	print("rigged=%d / %d" % [rigged, all.size()])
	print("missing-state tally: ", missing_tally)
	print("distinct missing sets: ", missing_sets)
	print("distinct clip sets: ", clipset_tally)
	print("anomalies: ", bad if bad.size() > 0 else "none")
	quit()


func _deep(rig: HeroRig, hero: String) -> void:
	var ap: AnimationPlayer = rig._anim
	print("\n--- motion detail for %s ---" % hero)
	var sampled := {}
	for clip in ap.get_animation_list():
		var a: Animation = ap.get_animation(clip)
		var rot_tracks := 0
		var moving_tracks := 0
		var total_keys := 0
		var max_delta := 0.0
		for t in a.get_track_count():
			total_keys += a.track_get_key_count(t)
			if a.track_get_type(t) != Animation.TYPE_ROTATION_3D:
				continue
			rot_tracks += 1
			var n: int = a.track_get_key_count(t)
			if n < 2:
				continue
			var q0: Quaternion = a.track_get_key_value(t, 0)
			var d := 0.0
			for k in range(1, n):
				var qk: Quaternion = a.track_get_key_value(t, k)
				d = maxf(d, rad_to_deg(q0.angle_to(qk)))
			if d > 1.0:
				moving_tracks += 1
			max_delta = maxf(max_delta, d)
		print("  %-11s len=%.2fs loop=%s tracks=%d keys=%d rot_tracks=%d moving=%d max_rot=%.1fdeg" % [
			clip, a.length, str(a.loop_mode != Animation.LOOP_NONE),
			a.get_track_count(), total_keys, rot_tracks, moving_tracks, max_delta])
		sampled[clip] = a

	# walk vs run: are they the same motion, just time-scaled?
	if sampled.has("walk-loop") and sampled.has("run-loop"):
		var w: Animation = sampled["walk-loop"]
		var r: Animation = sampled["run-loop"]
		print("  walk/run length ratio = %.3f" % (w.length / r.length))
		# Sample both at the same normalised phase and compare pose.
		var worst := 0.0
		var avg := 0.0
		var cnt := 0
		for t in w.get_track_count():
			if w.track_get_type(t) != Animation.TYPE_ROTATION_3D:
				continue
			var path: String = String(w.track_get_path(t))
			var rt: int = r.find_track(NodePath(path), Animation.TYPE_ROTATION_3D)
			if rt < 0:
				continue
			for i in 9:
				var ph: float = float(i) / 8.0
				var qw: Quaternion = w.rotation_track_interpolate(t, ph * w.length)
				var qr: Quaternion = r.rotation_track_interpolate(rt, ph * r.length)
				var dd: float = rad_to_deg(qw.angle_to(qr))
				worst = maxf(worst, dd)
				avg += dd
				cnt += 1
		if cnt > 0:
			print("  walk-vs-run same-phase pose diff: avg=%.2fdeg worst=%.2fdeg over %d samples" % [
				avg / float(cnt), worst, cnt])
			print("  => %s" % ("DISTINCT motions" if worst > 5.0 else "SAME motion, only time-scaled"))
