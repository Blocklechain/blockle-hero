extends SceneTree
# ------------------------------------------------------------------------------
# THE STUN-READABILITY HARNESS.
#
# `walk` doubles as the stun animation (docs/ANIMATION-HANDOFF.md). If walk does
# not read as obviously different from run, a stun is invisible and the control
# mechanic fails. So measure it, do not assume it:
#
#   1. clip length / loop mode / track count for walk vs run
#   2. are the clips literally the same keyframe data? (byte-ish comparison)
#   3. per-bone angular difference between walk and run AT MATCHING PHASE
#   4. per-clip range of motion per bone (how big is the stride in each)
#   5. hip bob + foot lift + limb swing in metres, through HeroRig's own scale
#   6. foot-slide check: authored cadence vs the speed the controller moves at
# ------------------------------------------------------------------------------

const HEROES := ["aldous", "brom", "g015", "g083", "kaelen", "willow"]
const SAMPLES := 24

# Controller / status constants, restated so the harness fails loudly if they move.
const WALK_SPEED := 3.4
const RUN_SPEED := 6.2


func _quat_angle(a: Quaternion, b: Quaternion) -> float:
	var d: float = absf(a.dot(b))
	return rad_to_deg(2.0 * acos(clampf(d, -1.0, 1.0)))


# Sample every bone's LOCAL rotation at `n` evenly spaced phases of `clip`.
func _sample(ap: AnimationPlayer, sk: Skeleton3D, clip: String, n: int) -> Array:
	var a: Animation = ap.get_animation(clip)
	var frames: Array = []
	for i in n:
		var t: float = a.length * (float(i) / float(n))
		ap.play(clip)
		ap.seek(t, true)
		sk.force_update_all_bone_transforms()
		var pose: Array = []
		for b in sk.get_bone_count():
			pose.append(sk.get_bone_pose_rotation(b))
		frames.append(pose)
	return frames


# Chain a bone up through its parents by hand.
#
# WHY NOT get_bone_global_pose(): in a --headless SceneTree the skeleton's
# global pose cache is never recomputed (force_update_all_bone_transforms() does
# not help), so it returns the SAME stale value at every phase — measured in
# tools/walkrun_dbg.gd. get_bone_pose() is the live animated value, so chain it.
func _chain(sk: Skeleton3D, b: int) -> Transform3D:
	var t := Transform3D()
	var i: int = b
	var guard: int = 0
	while i >= 0 and guard < 128:
		t = sk.get_bone_pose(i) * t
		i = sk.get_bone_parent(i)
		guard += 1
	return t


# Position of every bone at `n` phases, in WORLD METRES as the player sees it:
# bone chain, then the Skeleton3D's own node transform (the glTF Armature
# carries a 0.01 unit scale), then HeroRig's height normalisation.
func _sample_global(ap: AnimationPlayer, sk: Skeleton3D, clip: String, n: int,
		to_world: Transform3D) -> Array:
	var a: Animation = ap.get_animation(clip)
	var frames: Array = []
	for i in n:
		var t: float = a.length * (float(i) / float(n))
		ap.play(clip)
		ap.seek(t, true)
		var pose: Array = []
		for b in sk.get_bone_count():
			pose.append(to_world * _chain(sk, b).origin)
		frames.append(pose)
	return frames


# Max angle any bone travels through over a whole cycle -> stride size.
func _rom(frames: Array, b: int) -> float:
	var worst: float = 0.0
	for i in frames.size():
		for j in range(i + 1, frames.size()):
			worst = maxf(worst, _quat_angle(frames[i][b], frames[j][b]))
	return worst


func _tracks_identical(a: Animation, b: Animation) -> bool:
	if a.get_track_count() != b.get_track_count():
		return false
	if not is_equal_approx(a.length, b.length):
		return false
	for t in a.get_track_count():
		if String(a.track_get_path(t)) != String(b.track_get_path(t)):
			return false
		if a.track_get_key_count(t) != b.track_get_key_count(t):
			return false
		for k in a.track_get_key_count(t):
			var va = a.track_get_key_value(t, k)
			var vb = b.track_get_key_value(t, k)
			if typeof(va) != typeof(vb):
				return false
			if va is Quaternion:
				if _quat_angle(va, vb) > 0.01:
					return false
			elif va is Vector3:
				if (va as Vector3).distance_to(vb) > 0.0001:
					return false
			elif va != vb:
				return false
	return true


func _find_bones(sk: Skeleton3D, needles: Array) -> Array:
	var out: Array = []
	for b in sk.get_bone_count():
		var n: String = sk.get_bone_name(b).to_lower()
		for needle in needles:
			if n.contains(String(needle)):
				out.append(b)
				break
	return out


func _init() -> void:
	print("=== WALK vs RUN readability, %d heroes, %d phase samples/clip" % [
		HEROES.size(), SAMPLES])
	print("stun math: WALK_SPEED %.2f * STUN_SPEED_MULT %.2f = %.3f m/s  (run = %.2f m/s)" % [
		WALK_SPEED, StatusEffect.STUN_SPEED_MULT,
		WALK_SPEED * StatusEffect.STUN_SPEED_MULT, RUN_SPEED])
	print("")

	for hero in HEROES:
		var rig := HeroRig.new()
		root.add_child(rig)
		if not rig.load_hero(hero):
			print(hero, ": LOAD FAILED")
			continue
		if not rig.is_rigged:
			print(hero, ": not rigged, skipping")
			rig.queue_free()
			continue

		var ap: AnimationPlayer = rig._anim
		var skels: Array = rig._model.find_children("*", "Skeleton3D", true, false)
		if skels.is_empty():
			print(hero, ": AnimationPlayer but NO Skeleton3D")
			rig.queue_free()
			continue
		var sk: Skeleton3D = skels[0]
		var scl: float = rig._model.scale.y

		var walk_clip: String = rig._clip_for.get(HeroRig.State.WALK, "")
		var run_clip: String = rig._clip_for.get(HeroRig.State.RUN, "")
		var idle_clip: String = rig._clip_for.get(HeroRig.State.IDLE, "")
		if walk_clip == "" or run_clip == "":
			print("%s: walk='%s' run='%s' -> MISSING, stun cannot read" % [
				hero, walk_clip, run_clip])
			rig.queue_free()
			continue

		var wa: Animation = ap.get_animation(walk_clip)
		var ra: Animation = ap.get_animation(run_clip)

		print("== %s   bones=%d  scale=%.3f" % [hero, sk.get_bone_count(), scl])
		print("   walk '%s': len=%.3fs loop=%d tracks=%d" % [
			walk_clip, wa.length, wa.loop_mode, wa.get_track_count()])
		print("   run  '%s': len=%.3fs loop=%d tracks=%d" % [
			run_clip, ra.length, ra.loop_mode, ra.get_track_count()])
		print("   SAME KEYFRAME DATA? %s" % str(_tracks_identical(wa, ra)))

		var wf: Array = _sample(ap, sk, walk_clip, SAMPLES)
		var rf: Array = _sample(ap, sk, run_clip, SAMPLES)

		# (3) phase-matched walk-vs-run divergence, per bone.
		var per_bone_mean: Array = []
		var per_bone_max: Array = []
		for b in sk.get_bone_count():
			var acc: float = 0.0
			var mx: float = 0.0
			for i in SAMPLES:
				var d: float = _quat_angle(wf[i][b], rf[i][b])
				acc += d
				mx = maxf(mx, d)
			per_bone_mean.append(acc / float(SAMPLES))
			per_bone_max.append(mx)
		var overall_mean: float = 0.0
		for v in per_bone_mean:
			overall_mean += v
		overall_mean /= float(sk.get_bone_count())

		# Rank the bones that differ most.
		var order: Array = []
		for b in sk.get_bone_count():
			order.append(b)
		order.sort_custom(func(x, y): return per_bone_mean[x] > per_bone_mean[y])
		var top: Array = []
		for i in mini(6, order.size()):
			var b: int = order[i]
			top.append("%s %.1f/%.1f" % [sk.get_bone_name(b), per_bone_mean[b], per_bone_max[b]])
		print("   PHASE-MATCHED DIFF: mean over all bones = %.2f deg" % overall_mean)
		print("   biggest divergers (mean/max deg): ", ", ".join(top))

		# (4) range of motion per clip on the bones that matter for gait.
		var legs: Array = _find_bones(sk, ["upleg", "thigh", "leg", "foot", "knee"])
		var arms: Array = _find_bones(sk, ["arm", "shoulder", "hand", "elbow"])
		var spine: Array = _find_bones(sk, ["spine", "hips", "pelvis", "chest"])
		for pair in [["legs", legs], ["arms", arms], ["spine", spine]]:
			var label: String = pair[0]
			var bones: Array = pair[1]
			if bones.is_empty():
				print("   ROM %-6s : (no bones matched)" % label)
				continue
			var w_rom: float = 0.0
			var r_rom: float = 0.0
			for b in bones:
				w_rom = maxf(w_rom, _rom(wf, b))
				r_rom = maxf(r_rom, _rom(rf, b))
			print("   ROM %-6s : walk %.1f deg   run %.1f deg   run/walk = %.2fx" % [
				label, w_rom, r_rom, (r_rom / w_rom) if w_rom > 0.01 else INF])

		# (5) hip bob + foot lift in centimetres of WORLD space, as the player sees
		# it. Report all three axes rather than assuming which one is "up" — the
		# glTF armature is rotated, so the vertical axis is not necessarily +Y.
		# NOT sk.global_transform: nothing here is inside the tree, so Godot
		# returns identity and the numbers come out in raw bone units. Chain the
		# node-local transforms from the Skeleton3D up to the HeroRig instead,
		# which picks up both the glTF armature's 0.01 unit scale and HeroRig's
		# own height normalisation.
		var to_world := Transform3D()
		var n: Node3D = sk
		var g2: int = 0
		while n != null and n != rig and g2 < 64:
			to_world = n.transform * to_world
			n = n.get_parent() as Node3D
			g2 += 1
		var wg: Array = _sample_global(ap, sk, walk_clip, SAMPLES, to_world)
		var rg: Array = _sample_global(ap, sk, run_clip, SAMPLES, to_world)
		var feet: Array = _find_bones(sk, ["foot", "toe"])
		var hips: Array = _find_bones(sk, ["hips", "pelvis"])
		var hands: Array = _find_bones(sk, ["hand"])
		for pair2 in [["hips", hips], ["feet", feet], ["hands", hands]]:
			var label2: String = pair2[0]
			var bones2: Array = pair2[1]
			if bones2.is_empty():
				continue
			var wr := Vector3.ZERO
			var rr := Vector3.ZERO
			for b in bones2:
				var wlo := Vector3.INF; var whi := -Vector3.INF
				var rlo := Vector3.INF; var rhi := -Vector3.INF
				for i in SAMPLES:
					wlo = wlo.min(wg[i][b]); whi = whi.max(wg[i][b])
					rlo = rlo.min(rg[i][b]); rhi = rhi.max(rg[i][b])
				wr = wr.max(whi - wlo)
				rr = rr.max(rhi - rlo)
			print("   %-5s travel cm (x,y,z): walk (%.1f, %.1f, %.1f)  run (%.1f, %.1f, %.1f)  run/walk %.2fx" % [
				label2, wr.x * 100.0, wr.y * 100.0, wr.z * 100.0,
				rr.x * 100.0, rr.y * 100.0, rr.z * 100.0,
				(rr.length() / wr.length()) if wr.length() > 0.0001 else INF])

		# Sanity: is walk at least different from idle too?
		if idle_clip != "":
			var idf: Array = _sample(ap, sk, idle_clip, SAMPLES)
			var wi: float = 0.0
			for b in sk.get_bone_count():
				var acc2: float = 0.0
				for i in SAMPLES:
					acc2 += _quat_angle(wf[i][b], idf[i][b])
				wi += acc2 / float(SAMPLES)
			print("   walk vs idle mean diff = %.2f deg (control)" % (wi / float(sk.get_bone_count())))

		# (6) foot slide: cadence is FIXED (HeroRig never sets playback speed for
		# rigged models), so compare authored stride rate to actual ground speed.
		print("   cadence: walk %.2f cycles/s, run %.2f cycles/s -> run is %.2fx faster feet" % [
			1.0 / wa.length, 1.0 / ra.length, wa.length / ra.length])
		print("")
		rig.queue_free()

	# Does the rig ever change playback speed for a rigged model?
	var src: String = FileAccess.get_file_as_string("res://scripts/game/HeroRig.gd")
	print("HeroRig sets AnimationPlayer speed_scale anywhere? %s" % str(
		src.contains("speed_scale")))
	print("HeroRig uses _speed01 outside _procedural? occurrences=%d" % src.count("_speed01"))
	quit()
