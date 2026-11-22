extends SceneTree
# ------------------------------------------------------------------------------
# EVERY SCRIPT MUST LOAD.
#
# This exists because the same failure happened four times in one sitting.
#
# Godot resolves `class_name` through a global cache that is rebuilt by the
# EDITOR. A script added from outside the editor — by a script, by a merge,
# by anyone who has not opened the project since — is not in it. Every
# consumer that refers to the new class by its bare name then fails to PARSE,
# and the failure surfaces wherever that consumer happens to be loaded:
#
#   * MapShape broke every headless harness that touches Play.tscn.
#   * GameMode broke the same, plus the menu shell.
#   * TrainingScreen broke UiShell, which is every UI test.
#   * Dress was the worst: Scatter compiles on the WORLD BUILD THREAD, so
#     the symptom was not an error anyone reads — it was maps that silently
#     never finished generating.
#
# The fix each time is a preload by path. The problem is that NOTHING CHECKS,
# so the next one is found by whichever unrelated test happens to run first,
# or by a player.
#
# This loads every .gd in the project. A parse error in any of them, for any
# reason, fails here — which is both cheaper and far more legible than
# finding out from a world that never builds.
# ------------------------------------------------------------------------------

const ROOTS: PackedStringArray = ["res://scripts", "res://tools"]

var _checked: int = 0
var _bad: Array = []


func _init() -> void:
	for r in ROOTS:
		_walk(r)

	print("\n=== %d scripts loaded ===" % _checked)
	if not _bad.is_empty():
		for b in _bad:
			push_error("classcheck: %s" % b)
		print("=== %d failure(s) ===" % _bad.size())
		quit(1)
		return
	print("classcheck OK")
	quit(0)


func _walk(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full: String = path.path_join(name)
		if dir.current_is_dir():
			_walk(full)
		elif name.ends_with(".gd"):
			_check(full)
		name = dir.get_next()
	dir.list_dir_end()


func _check(path: String) -> void:
	# Reloading the script that is CURRENTLY RUNNING is not a valid thing to
	# do and reports err 22. Skipping it costs nothing: if this file did not
	# parse, none of this would be executing.
	if path.ends_with("classcheck.gd"):
		return
	_checked += 1
	# RE-PARSE FROM SOURCE, rather than load().
	#
	# The first version of this used load() and was worthless: it reported
	# OK on a file Godot had just printed "Failed to load script ... Parse
	# error" for, and it did not notice a deliberately removed preload. The
	# resource cache hands back something non-null and the check passes.
	#
	# Building a fresh GDScript from the file's text and calling reload()
	# actually runs the parser, which is the thing being tested.
	# CACHE_MODE_REPLACE forces a real re-parse. Plain load() returns a
	# cached resource and reported OK on a file Godot had just refused to
	# parse; building a GDScript from source text instead went the other
	# way and failed every script whose `extends` is a class_name, because
	# a hand-built script has no resource_path to resolve against. Going
	# through ResourceLoader keeps the real path and skips the cache.
	var res: Resource = ResourceLoader.load(path, "GDScript",
		ResourceLoader.CACHE_MODE_REPLACE)
	if res == null or not (res is GDScript):
		_bad.append("%s did not load at all" % path)
		return
	# load() alone is not enough: Godot hands back a GDScript object even
	# for a file it has just printed "Parse error" for. reload() on the
	# loaded resource — which still has its real resource_path, so relative
	# preloads and `extends` resolve — returns the error code that load()
	# swallowed.
	var err: int = (res as GDScript).reload()
	if err != OK:
		_bad.append("%s failed to parse (err %d) — a bare class_name that "
			% [path, err] + "is not in the global cache is the usual cause; "
			+ "preload it by path instead")
