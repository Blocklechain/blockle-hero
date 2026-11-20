extends SceneTree
# Proves the SHIPPED load path works — the one an iPhone will actually use.
#
# The old failure was silent: heroes loaded fine on this machine because
# HeroRig fell back to absolute /Volumes paths, and failed on device because
# those paths do not exist there. So this check does not merely assert "the
# hero loaded"; it asserts the hero loaded from res:// WITHOUT the disk
# fallback, by blanking the fallback dirs first.


func _init() -> void:
	# Remove the dev fallback entirely. Anything that loads now must have come
	# out of the PCK, which is the only thing a device has.
	HeroRig.search_dirs = PackedStringArray()

	var roster: PackedStringArray = HeroRig.animated_heroes()
	print("roster from manifest: %d heroes" % roster.size())
	if roster.size() != 139:
		print("FAIL: expected 139, got %d" % roster.size())
		quit(1)
		return

	# Spread the sample across the alphabet rather than taking the first N.
	var picks: Array[String] = []
	for i in range(0, roster.size(), maxi(1, roster.size() / 12)):
		picks.append(roster[i])

	var ok: int = 0
	var failures: Array[String] = []
	for hero in picks:
		var rig := HeroRig.new()
		get_root().add_child(rig)
		var loaded: bool = rig.load_hero(hero)
		if not loaded:
			failures.append("%s: load_hero returned false" % hero)
		elif not rig.is_rigged:
			failures.append("%s: loaded but is_rigged=false" % hero)
		else:
			var missing: PackedStringArray = rig.missing_states()
			var m: String = ", ".join(missing)
			if m != "hit":
				failures.append("%s: missing=[%s], expected [hit]" % [hero, m])
			else:
				ok += 1
				print("  %-14s rigged, bundled, missing=[hit]" % hero)
		rig.queue_free()

	print("\nbundled-load: %d/%d ok" % [ok, picks.size()])
	if not failures.is_empty():
		for f in failures:
			print("FAIL  " + f)
		quit(1)
		return

	# Every roster name must be bundled, or a crystal could hand out a hero
	# that cannot be displayed on a device.
	var unbundled: Array[String] = []
	for hero in roster:
		if not ResourceLoader.exists(HeroRig.BUNDLED_DIR.path_join(hero + ".glb")):
			unbundled.append(hero)
	if not unbundled.is_empty():
		print("FAIL: %d roster heroes are not bundled: %s" % [
			unbundled.size(), ", ".join(unbundled.slice(0, 8))])
		quit(1)
		return
	print("all %d roster heroes are present in %s" % [roster.size(), HeroRig.BUNDLED_DIR])

	if not _boot_scene_ships():
		quit(1)
		return
	quit(0)


## The boot scene must survive the export filter.
##
## Checked here because this is the "will it work on the phone" harness, and
## because the failure is completely silent: Godot drops anything matching
## exclude_filter without comment, including res://scenes/Main.tscn if someone
## lists it alongside the debug scenes — which happened. Nothing in the project
## then fails, no check goes red, the .pck is still 580 MiB of heroes, and the
## app boots to a black screen on the device. One line of guard is cheaper than
## one TestFlight round trip.
func _boot_scene_ships() -> bool:
	var main: String = String(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main == "":
		print("FAIL: project.godot has no application/run/main_scene")
		return false
	if not ResourceLoader.exists(main):
		print("FAIL: main_scene '%s' does not exist" % main)
		return false

	var cfg := ConfigFile.new()
	if cfg.load("res://export_presets.cfg") != OK:
		print("FAIL: cannot read res://export_presets.cfg")
		return false
	var rel: String = main.trim_prefix("res://")
	for section in cfg.get_sections():
		if not cfg.has_section_key(section, "exclude_filter"):
			continue
		for pattern in String(cfg.get_value(section, "exclude_filter", "")).split(","):
			var p: String = pattern.strip_edges()
			if p != "" and rel.match(p):
				print("FAIL: export preset '%s' excludes the boot scene (%s matches '%s')"
					% [cfg.get_value(section, "name", section), rel, p])
				return false
	print("boot scene %s exists and is not excluded from the export" % main)
	return true
