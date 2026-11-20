extends SceneTree
# Item 4: prove the DELIVERED clip names resolve through HeroRig's matcher, and
# say WHICH path matched (exact canonical vs ALIASES substring). Also check the
# skeleton root bone for forward drift in the loco clips (root motion smuggled
# through bone 0 would still fight the controller).

var DELIVERED := PackedStringArray([
	"ability_1", "ability_2", "ability_3", "attack", "death",
	"idle-loop", "run-loop", "walk-loop",
])
const ANIM_DIR := "/Volumes/ExtremePro/raid/assets/heroes/animated"

func _init() -> void:
	var rig := HeroRig.new()
	print("delivered clips: ", DELIVERED, "\n")
	for st in HeroRig.STATE_NAMES.keys():
		var canon: String = String(HeroRig.STATE_NAMES[st])
		var hit: String = rig._find_clip(DELIVERED, st)
		# Which path? exact canonical compare is case-lowered equality.
		var how := "NO MATCH"
		if hit != "":
			how = "exact-canonical" if hit.to_lower() == canon else "ALIASES-substring"
		var which_alias := ""
		if how == "ALIASES-substring":
			for w in HeroRig.ALIASES[st]:
				if hit.to_lower().contains(String(w)):
					which_alias = " via alias '%s'" % String(w)
					break
		print("  %-10s -> %-12s [%s%s]" % [canon, hit if hit != "" else "-", how, which_alias])
	rig.free()

	# Root-bone drift in walk-loop / run-loop / attack on one hero.
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_file(ANIM_DIR.path_join("aldous.glb"), state)
	var scene: Node = doc.generate_scene(state)
	var ap := scene.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	var sk := scene.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var root_bone := sk.get_bone_name(0)
	print("\nroot bone name: '%s' (bone 0)" % root_bone)
	for cn in ["walk-loop", "run-loop", "attack", "death"]:
		var a: Animation = ap.get_animation(cn)
		var found := false
		for ti in a.get_track_count():
			if a.track_get_type(ti) != Animation.TYPE_POSITION_3D:
				continue
			var p: String = String(a.track_get_path(ti))
			if not p.ends_with(":" + root_bone):
				continue
			found = true
			var first: Vector3 = a.position_track_interpolate(ti, 0.0)
			var last: Vector3 = a.position_track_interpolate(ti, a.length)
			var lo := first
			var hi := first
			for k in range(21):
				var v: Vector3 = a.position_track_interpolate(ti, a.length * float(k) / 20.0)
				lo = Vector3(minf(lo.x, v.x), minf(lo.y, v.y), minf(lo.z, v.z))
				hi = Vector3(maxf(hi.x, v.x), maxf(hi.y, v.y), maxf(hi.z, v.z))
			print("  %-10s root-bone pos track: start=%s end=%s net=%.4f  travel_bbox=%s" % [
				cn, str(first.snappedf(0.001)), str(last.snappedf(0.001)),
				(last - first).length(), str((hi - lo).snappedf(0.001))])
		if not found:
			print("  %-10s no position track on root bone" % cn)
	print("\ntotal position tracks in walk-loop: ", _count_pos(ap.get_animation("walk-loop")))
	quit()

func _count_pos(a: Animation) -> int:
	var n := 0
	for ti in a.get_track_count():
		if a.track_get_type(ti) == Animation.TYPE_POSITION_3D:
			n += 1
	return n
