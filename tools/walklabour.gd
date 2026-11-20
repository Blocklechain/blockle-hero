extends SceneTree
# ANIMATION-HANDOFF.md asks for one specific QUALITY, not just a difference:
# "walk should read clearly as *laboured* next to run ... if walk reads as a
# confident stroll, the stun will not land visually."
#
# "Different" is already proven (tools/walkrun.gd). This asks the narrower
# question: is the walk a LABOURED walk, or just a slower, smaller run?
# Markers of laboured that are measurable on a skeleton:
#   - forward hunch: mean spine/head pitch vs the run
#   - head drop: mean head height vs the run
#   - a limp: left/right asymmetry in the leg swing WITHIN the walk
#   - drag: how close the feet stay to the ground

const HERO := "aldous"
const N := 32


func _chain(sk: Skeleton3D, b: int) -> Transform3D:
	var t := Transform3D()
	var i: int = b
	var g: int = 0
	while i >= 0 and g < 128:
		t = sk.get_bone_pose(i) * t
		i = sk.get_bone_parent(i)
		g += 1
	return t


func _bone(sk: Skeleton3D, needle: String) -> int:
	for b in sk.get_bone_count():
		if sk.get_bone_name(b).to_lower().contains(needle):
			return b
	return -1


func _init() -> void:
	var rig := HeroRig.new()
	root.add_child(rig)
	rig.load_hero(HERO)
	var ap: AnimationPlayer = rig._anim
	var sk: Skeleton3D = rig._model.find_children("*", "Skeleton3D", true, false)[0]

	var to_world := Transform3D()
	var n: Node3D = sk
	while n != null and n != rig:
		to_world = n.transform * to_world
		n = n.get_parent() as Node3D

	var spine: int = _bone(sk, "spine2")
	if spine < 0:
		spine = _bone(sk, "spine")
	var head: int = _bone(sk, "head")
	var hips: int = _bone(sk, "hips")
	var lleg: int = _bone(sk, "leftupleg")
	var rleg: int = _bone(sk, "rightupleg")
	var lfoot: int = _bone(sk, "leftfoot")
	var rfoot: int = _bone(sk, "rightfoot")
	print("hero %s  spine=%s head=%s lUpLeg=%s rUpLeg=%s" % [HERO,
		sk.get_bone_name(spine), sk.get_bone_name(head),
		sk.get_bone_name(lleg), sk.get_bone_name(rleg)])

	var out := {}
	for st in [HeroRig.State.WALK, HeroRig.State.RUN]:
		var clip: String = rig._clip_for[st]
		var a: Animation = ap.get_animation(clip)
		var head_y := 0.0
		var hip_y := 0.0
		var lean_sum := 0.0
		var lo_lfoot := INF
		var lo_rfoot := INF
		var hi_lfoot := -INF
		var hi_rfoot := -INF
		var l_swing_lo := INF; var l_swing_hi := -INF
		var r_swing_lo := INF; var r_swing_hi := -INF
		for i in N:
			ap.play(clip)
			ap.seek(a.length * (float(i) / float(N)), true)
			var hp: Vector3 = to_world * _chain(sk, head).origin
			var hipp: Vector3 = to_world * _chain(sk, hips).origin
			head_y += hp.y
			hip_y += hipp.y
			# Forward hunch: angle of the hips->head axis away from vertical,
			# signed by whether the head is ahead of (+Z) or behind the hips.
			var axis: Vector3 = (hp - hipp)
			lean_sum += rad_to_deg(atan2(axis.z, axis.y))
			var lf: Vector3 = to_world * _chain(sk, lfoot).origin
			var rf: Vector3 = to_world * _chain(sk, rfoot).origin
			lo_lfoot = minf(lo_lfoot, lf.y); hi_lfoot = maxf(hi_lfoot, lf.y)
			lo_rfoot = minf(lo_rfoot, rf.y); hi_rfoot = maxf(hi_rfoot, rf.y)
			l_swing_lo = minf(l_swing_lo, lf.z); l_swing_hi = maxf(l_swing_hi, lf.z)
			r_swing_lo = minf(r_swing_lo, rf.z); r_swing_hi = maxf(r_swing_hi, rf.z)
		out[st] = {
			"head_y": head_y / float(N),
			"hip_y": hip_y / float(N),
			"lean": lean_sum / float(N),
			"lfoot_lift": hi_lfoot - lo_lfoot,
			"rfoot_lift": hi_rfoot - lo_rfoot,
			"lstride": l_swing_hi - l_swing_lo,
			"rstride": r_swing_hi - r_swing_lo,
		}

	var w: Dictionary = out[HeroRig.State.WALK]
	var r: Dictionary = out[HeroRig.State.RUN]
	print("")
	print("                        WALK        RUN      delta")
	print("mean head height     %7.3f m   %7.3f m   %+.3f m" % [
		w["head_y"], r["head_y"], w["head_y"] - r["head_y"]])
	print("mean hip height      %7.3f m   %7.3f m   %+.3f m" % [
		w["hip_y"], r["hip_y"], w["hip_y"] - r["hip_y"]])
	print("mean forward lean    %7.1f deg %7.1f deg %+.1f deg  (+ = leaning forward)" % [
		w["lean"], r["lean"], w["lean"] - r["lean"]])
	print("foot lift L / R      %5.1f/%4.1f cm %5.1f/%4.1f cm" % [
		w["lfoot_lift"] * 100.0, w["rfoot_lift"] * 100.0,
		r["lfoot_lift"] * 100.0, r["rfoot_lift"] * 100.0])
	print("stride L / R         %5.1f/%4.1f cm %5.1f/%4.1f cm" % [
		w["lstride"] * 100.0, w["rstride"] * 100.0,
		r["lstride"] * 100.0, r["rstride"] * 100.0])

	var limp: float = absf(w["lstride"] - w["rstride"]) / maxf(
		maxf(w["lstride"], w["rstride"]), 0.0001)
	var run_limp: float = absf(r["lstride"] - r["rstride"]) / maxf(
		maxf(r["lstride"], r["rstride"]), 0.0001)
	print("")
	print("LIMP (L/R stride asymmetry): walk %.1f%%, run %.1f%%" % [
		limp * 100.0, run_limp * 100.0])
	print("VERDICT inputs:")
	print("  hunched more than the run?  %s (%+.1f deg)" % [
		str(w["lean"] > r["lean"] + 2.0), w["lean"] - r["lean"]])
	print("  head carried lower?         %s (%+.1f cm)" % [
		str(w["head_y"] < r["head_y"] - 0.01), (w["head_y"] - r["head_y"]) * 100.0])
	print("  asymmetric / limping?       %s" % str(limp > 0.15))
	quit()
