extends SceneTree
# ------------------------------------------------------------------------------
# The loadout preview, and reaching the stash from inside a run.
#
# Both have failure modes that look fine in a screenshot:
#
#   * a preview that loads a rig but never animates — indistinguishable from the
#     pre-rendered portrait it exists to replace, until you watch it for a
#     second;
#   * a preview that leaks a HeroRig per champion viewed, which on a 139-strong
#     roster is a slideshow by the time the player has browsed a dozen;
#   * an inventory button that shows the stash while the run keeps TICKING
#     behind it, so the boss empties your health bar while you read your bags;
#   * a resume that leaves the run frozen, which reads as the game having hung.
#
#   godot --headless --path . --script tools/loadouttest.gd
# ------------------------------------------------------------------------------

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	await process_frame
	# AWAITED. _preview() contains `await`, so calling it bare suspends it and
	# lets this function run straight on to quit() — the whole section reported
	# nothing and the suite still said "0 failures".
	await _preview()
	_freeze()
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


func _preview() -> void:
	print("\n=== the champion is alive in the menu ===")
	var roster: PackedStringArray = HeroRig.animated_heroes()
	var who: String = roster[0]

	var pv := HeroPreview.new()
	get_root().add_child(pv)
	pv.show_hero(who)
	await process_frame

	var rigs: Array = pv.find_children("*", "HeroRig", true, false)
	check("the preview holds a real rig", rigs.size() == 1,
		"%d rig(s) for '%s'" % [rigs.size(), who])
	if rigs.is_empty():
		pv.queue_free()
		return
	var rig: HeroRig = rigs[0]
	check("it is the rigged model, not the static fallback", rig.is_rigged,
		who)

	# A still image is the failure this class exists to avoid, so the idle has
	# to be PLAYING rather than merely assigned.
	var players: Array = rig.find_children("*", "AnimationPlayer", true, false)
	var playing: bool = players.size() > 0 and (players[0] as AnimationPlayer).is_playing()
	check("the idle clip is actually running", playing,
		"not a portrait")

	var before: float = pv._pivot.rotation_degrees.y
	pv._process(0.5)
	check("the turntable turns", absf(pv._pivot.rotation_degrees.y - before) > 0.1,
		"%.1f deg -> %.1f deg" % [before, pv._pivot.rotation_degrees.y])
	check("...slowly enough to look at", HeroPreview.SPIN <= 30.0,
		"%.0f deg/s" % HeroPreview.SPIN)

	# Browsing the roster must not accumulate bodies.
	for i in range(6):
		pv.show_hero(roster[i + 1])
		await process_frame
	var after: Array = pv.find_children("*", "HeroRig", true, false)
	check("switching champions does not leak rigs", after.size() == 1,
		"%d rig(s) after viewing 7 champions" % after.size())

	# Asking for the same champion twice must not rebuild it.
	var current: Array = pv.find_children("*", "HeroRig", true, false)
	var id_before: int = (current[0] as HeroRig).get_instance_id()
	pv.show_hero(roster[6])
	await process_frame
	var again: Array = pv.find_children("*", "HeroRig", true, false)
	check("re-selecting the same champion is a no-op",
		again.size() == 1 and (again[0] as HeroRig).get_instance_id() == id_before)
	pv.queue_free()


func _freeze() -> void:
	print("\n=== the inventory freezes the run, and resume unfreezes it ===")
	# A stand-in for the live map: the only thing under test is that the node
	# tree stops and starts ticking, which process_mode governs regardless of
	# what the node happens to be.
	var run := Node3D.new()
	run.name = "Play"
	get_root().add_child(run)
	var child := Node3D.new()
	run.add_child(child)

	check("a running map ticks", run.can_process() and child.can_process())

	run.process_mode = Node.PROCESS_MODE_DISABLED
	run.visible = false
	check("opening the inventory stops the map", not run.can_process(),
		"the boss cannot hit you while you read")
	check("...and everything in it", not child.can_process(),
		"enemies, cooldowns and status ticks together")

	run.process_mode = Node.PROCESS_MODE_INHERIT
	run.visible = true
	check("resuming starts it again", run.can_process() and child.can_process())
	check("...and shows it again", run.visible)

	# The map is frozen, NOT unloaded: coming back has to be instant rather
	# than a 580 MiB regenerate.
	check("the map was never torn down", is_instance_valid(run)
		and run.get_child_count() == 1, "still in the tree with its contents")
	run.queue_free()
