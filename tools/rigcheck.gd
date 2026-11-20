extends SceneTree
# Load a sample of heroes through HeroRig itself (not raw GLTFDocument) and
# report what the game would see: is_rigged, missing_states(), and which real
# clip each canonical state resolved to.

const SAMPLE_SIZE := 12

func _init() -> void:
	var all: PackedStringArray = HeroRig.animated_heroes()
	print("HeroRig.animated_heroes() -> %d heroes (from %s)" % [all.size(), HeroRig.search_dirs[0]])
	if all.is_empty():
		quit(1)
		return

	# Spread the sample across the whole sorted list rather than taking the first N.
	var picks := PackedStringArray()
	var step: int = maxi(1, all.size() / SAMPLE_SIZE)
	var i := 0
	while i < all.size() and picks.size() < SAMPLE_SIZE:
		picks.append(all[i])
		i += step

	var n_rigged := 0
	var missing_tally := {}
	for hero in picks:
		var rig := HeroRig.new()
		root.add_child(rig)
		var ok: bool = rig.load_hero(hero)
		if not ok:
			print("%-10s LOAD FAILED" % hero)
			rig.queue_free()
			continue
		if rig.is_rigged:
			n_rigged += 1
		var missing: PackedStringArray = rig.missing_states()
		for m in missing:
			missing_tally[m] = int(missing_tally.get(m, 0)) + 1
		print("%-10s rigged=%s  missing=%s" % [hero, str(rig.is_rigged), str(missing)])

		# Which actual clip name did each canonical state bind to, and how long?
		var ap: AnimationPlayer = rig._anim
		var lines := PackedStringArray()
		for st in HeroRig.STATE_NAMES.keys():
			var canon: String = String(HeroRig.STATE_NAMES[st])
			if rig._clip_for.has(st):
				var clip: String = rig._clip_for[st]
				var len_s: float = ap.get_animation(clip).length if ap else -1.0
				lines.append("%s->%s(%.2fs)" % [canon, clip, len_s])
			else:
				lines.append("%s->UNRESOLVED" % canon)
		print("           ", " ".join(lines))

		# Scale check: measured mesh height before normalisation, and root motion.
		var aabb := AABB()
		var first := true
		for c in rig._model.find_children("*", "MeshInstance3D", true, false):
			var mi := c as MeshInstance3D
			if mi.mesh == null:
				continue
			if first:
				aabb = mi.get_aabb()
				first = false
			else:
				aabb = aabb.merge(mi.get_aabb())
		var root_tracks := 0
		var root_moves := false
		if ap:
			for clip in ap.get_animation_list():
				var a: Animation = ap.get_animation(clip)
				for t in a.get_track_count():
					var p: String = String(a.track_get_path(t))
					if a.track_get_type(t) == Animation.TYPE_POSITION_3D and (p.contains(":Hips") or p.contains(":Root") or p == "." or p.contains("Skeleton3D:Hips")):
						root_tracks += 1
						# does it actually translate in x/z?
						var k0: Vector3 = a.track_get_key_value(t, 0)
						for k in range(1, a.track_get_key_count(t)):
							var kv: Vector3 = a.track_get_key_value(t, k)
							if absf(kv.x - k0.x) > 0.01 or absf(kv.z - k0.z) > 0.01:
								root_moves = true
								break
		print("            mesh_h=%.3f scale=%.3f clips=%d hip_pos_tracks=%d hip_xz_motion=%s" % [
			aabb.size.y, rig._model.scale.y,
			ap.get_animation_list().size() if ap else 0, root_tracks, str(root_moves)])
		rig.queue_free()

	print("")
	print("SUMMARY: %d/%d sampled heroes rigged=true" % [n_rigged, picks.size()])
	print("SUMMARY: missing-state tally across sample: ", missing_tally)
	quit()
