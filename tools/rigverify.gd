extends SceneTree
# Load a spread of animated heroes through the REAL HeroRig and report what the
# game itself sees: is_rigged + missing_states(). No assumptions, no shortcuts —
# same code path Play.tscn uses.

const HEROES := [
	"aldous", "g015", "g037", "g050", "g065", "g083",
	"g101", "g127", "g149", "g164", "kaelen", "willow",
]

func _init() -> void:
	print("search_dirs = ", HeroRig.search_dirs)
	print("animated_heroes() -> %d entries" % HeroRig.animated_heroes().size())
	print("")
	var ok := 0
	var all_missing := {}
	for h in HEROES:
		var rig := HeroRig.new()
		root.add_child(rig)
		var loaded: bool = rig.load_hero(h)
		var resolved := ""
		for d in HeroRig.search_dirs:
			if FileAccess.file_exists(d.path_join(h + ".glb")):
				resolved = d
				break
		if not loaded:
			print("%-10s LOAD FAILED" % h)
			rig.queue_free()
			continue
		var missing: PackedStringArray = rig.missing_states()
		print("%-10s rigged=%s  missing=%s  from=%s" % [
			h, str(rig.is_rigged), str(missing), resolved.get_file()])
		# What each canonical state actually resolved to.
		var mapping := []
		for st in HeroRig.STATE_NAMES.keys():
			var nm: String = String(HeroRig.STATE_NAMES[st])
			mapping.append("%s->%s" % [nm, rig._clip_for.get(st, "MISSING")])
		print("           ", ", ".join(mapping))
		print("           model scale=%.3f  clips=%s" % [
			rig._model.scale.y,
			str(rig._anim.get_animation_list()) if rig._anim else "none"])
		if rig.is_rigged:
			ok += 1
		all_missing[h] = str(missing)
		rig.queue_free()
	print("")
	print("rigged %d/%d" % [ok, HEROES.size()])
	var distinct := {}
	for k in all_missing:
		distinct[all_missing[k]] = distinct.get(all_missing[k], 0) + 1
	print("distinct missing sets: ", distinct)
	quit()
