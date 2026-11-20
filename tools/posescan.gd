extends Node3D
# ------------------------------------------------------------------------------
# Headless scan of the whole animated roster for two defects that are obvious in
# a screenshot but need numbers to be found across 139 heroes:
#
#   COLLAPSE  the character's vertical extent during an action clip falls far
#             below its idle extent -- i.e. it goes horizontal / lies down
#             mid-ability, which reads as a ragdoll rather than a strike.
#   AIRBORNE  the lowest point of the skeleton rises well above where it sits at
#             idle, i.e. the hero leaves the ground during a clip the controller
#             will never move vertically.
#
# This MUST run inside a processing scene tree and await a real frame per
# sample. AnimationPlayer.seek(t, true) does not pose the skeleton from a bare
# SceneTree script -- the bone transforms stay in rest pose and every hero
# measures identical, which silently turns the whole scan into a no-op.
#
#   godot --headless --path . res://tools/PoseScan.tscn
# ------------------------------------------------------------------------------

const STATES := [
	HeroRig.State.ATTACK, HeroRig.State.ABILITY_1,
	HeroRig.State.ABILITY_2, HeroRig.State.ABILITY_3,
]
const NAMES := ["attack", "ability_1", "ability_2", "ability_3"]
const SAMPLES := 12


# World-space vertical extent of the posed skeleton. MUST go through
# Skeleton3D.to_global(): get_bone_global_pose().origin is in the skeleton's own
# (glTF, ~100x) units, and scaling it by the model node's scale alone still
# leaves it ~7x out -- it produces plausible-looking numbers that are pure
# nonsense. The HeroRig sits at y=0 here, so world y IS height above ground.
func _extent(sk: Skeleton3D, _scale: float) -> Vector2:
	var lo := INF
	var hi := -INF
	for b in range(sk.get_bone_count()):
		var y: float = sk.to_global(sk.get_bone_global_pose(b).origin).y
		lo = minf(lo, y)
		hi = maxf(hi, y)
	return Vector2(lo, hi)


func _ready() -> void:
	var heroes: PackedStringArray = HeroRig.animated_heroes()
	print("scanning ", heroes.size(), " animated heroes")
	var collapse: Array[String] = []
	var airborne: Array[String] = []
	var checked: int = 0
	var sanity_moved: int = 0

	for h in heroes:
		var rig := HeroRig.new()
		add_child(rig)
		if not rig.load_hero(h) or not rig.is_rigged \
				or not rig._clip_for.has(HeroRig.State.IDLE):
			rig.queue_free()
			continue
		var sks: Array = rig._model.find_children("*", "Skeleton3D", true, false)
		if sks.is_empty():
			rig.queue_free()
			continue
		var sk: Skeleton3D = sks[0]
		var sc: float = rig._model.scale.y
		var ap: AnimationPlayer = rig._anim

		ap.play(rig._clip_for[HeroRig.State.IDLE])
		ap.seek(0.0, true)
		await get_tree().process_frame
		var ref: Vector2 = _extent(sk, sc)
		var ref_h: float = ref.y - ref.x
		if ref_h <= 0.01:
			rig.queue_free()
			continue
		checked += 1
		var moved := false

		for i in range(STATES.size()):
			var st: int = STATES[i]
			if not rig._clip_for.has(st):
				continue
			ap.play(rig._clip_for[st])
			var L: float = ap.current_animation_length
			var worst_h: float = INF
			var worst_lo: float = -INF
			var at_h: float = 0.0
			var at_lo: float = 0.0
			for s in range(SAMPLES):
				var t: float = L * float(s) / float(SAMPLES - 1)
				ap.seek(t, true)
				await get_tree().process_frame
				var e: Vector2 = _extent(sk, sc)
				var hh: float = e.y - e.x
				if absf(hh - ref_h) > 0.005:
					moved = true
				if hh < worst_h:
					worst_h = hh
					at_h = t
				if e.x - ref.x > worst_lo:
					worst_lo = e.x - ref.x
					at_lo = t
			var ratio: float = worst_h / ref_h
			if ratio < 0.80:
				collapse.append("%6.1f%%|%-10s %-10s extent %.2f m -> %.2f m at t=%.2fs of %.2fs" % [
					ratio * 100.0, h, NAMES[i], ref_h, worst_h, at_h, L])
			if worst_lo > 0.20:
				airborne.append("%6.2f|%-10s %-10s lowest bone rises %+.2f m above idle at t=%.2fs" % [
					worst_lo, h, NAMES[i], worst_lo, at_lo])
		if moved:
			sanity_moved += 1
		rig.queue_free()

	# Sanity gate: if the skeletons never actually moved, the scan measured
	# nothing and its clean result is meaningless rather than reassuring.
	print("\n=== checked %d heroes; %d had skeletons that actually posed ===" % [
		checked, sanity_moved])
	if sanity_moved < checked / 2:
		print("!! SCAN INVALID - skeletons did not pose; ignore the results below")
	print("\n--- COLLAPSE (goes horizontal / lies down mid-ability): %d ---" % collapse.size())
	collapse.sort()
	for c in collapse:
		print("  ", c)
	print("\n--- AIRBORNE (leaves the ground mid-ability): %d ---" % airborne.size())
	airborne.sort()
	airborne.reverse()
	for a in airborne:
		print("  ", a)
	get_tree().quit()
