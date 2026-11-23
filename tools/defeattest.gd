extends SceneTree
# ------------------------------------------------------------------------------
# DYING HAS TO END THE RUN.
#
# It did not. The only listener for HeroController.champion_died anywhere in the
# project was Hud._on_champion_died, which flashes the vignette, locks the
# ability keys and writes "Your champion has fallen" — and then the game sat
# there indefinitely with a corpse on the floor and no way out but the side
# menu. Nothing called _finish_run(). A loss the game does not acknowledge is
# not a loss, and it is the kind of hole that survives a full green test suite
# because no test ever killed the player.
#
# So this file kills the player, in the real scene, and asks what happened.
#
# THE TWO HALVES OF THE DESIGN, both asserted, because getting either wrong is
# worse than having no defeat screen at all:
#
#   * THE MAP MUST NOT COUNT AS CLEARED. record_map_cleared() is reached only
#     from _clear_region(), so defeat must not route through it — otherwise
#     dying to the boss unlocks the next region and the gate means nothing.
#   * WHAT WAS EARNED MUST SURVIVE. Gold, experience and drops bank per kill
#     rather than at the end, so they are already in the save by the time the
#     champion dies. Clawing them back would need a special un-banking path
#     whose only purpose is to punish the same death twice.
# ------------------------------------------------------------------------------

## Populated enough to kill something before dying, so the "what was earned
## survives" half has something to measure.
const REGION: int = 37

var fails: int = 0
var _ran: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	print("  %s %-56s %s" % ["PASS" if ok else "FAIL", label, detail])
	if not ok:
		fails += 1


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	await _the_flag()
	_ran += 1
	await _dying_ends_the_run()
	_ran += 1
	await _the_screen_says_so()
	_ran += 1

	print("")
	check("every section ran to completion", _ran == 3, "%d of 3" % _ran)
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


## The once-per-account latch, and the thing that makes it once per ACCOUNT
## rather than once per launch: it has to survive a save.
func _the_flag() -> void:
	print("\n=== a story beat heard once stays heard ===")
	var r: Roster = Roster.create(HeroRig.animated_heroes())
	check("a fresh account has heard nothing", not r.story_heard("first_death"))
	check("marking it returns true the first time", r.mark_story("first_death"))
	check("...and false the second", not r.mark_story("first_death"))
	check("...and it reads as heard", r.story_heard("first_death"))

	# THE ASSERTION THE OLD IMPLEMENTATION FAILED. The latch used to live in
	# object meta, which Roster.to_dict() does not serialise, so quitting and
	# returning re-armed it — and the one line written to land once landed
	# every single launch.
	var back: Roster = Roster.from_dict(r.to_dict(), HeroRig.animated_heroes())
	check("IT SURVIVES A SAVE AND LOAD", back.story_heard("first_death"))

	# And an older save, written before the field existed, must load rather
	# than fault — nothing heard yet is the correct answer for it.
	var old: Dictionary = r.to_dict()
	old.erase("story_seen")
	var legacy: Roster = Roster.from_dict(old, HeroRig.animated_heroes())
	check("a save written before this field still loads",
		legacy != null and not legacy.story_heard("first_death"))


func _play(account: Roster, who: String) -> Node:
	var play: Node = load("res://scenes/Play.tscn").instantiate()
	play.set("world_seed", Campaign.region_seed(4242, REGION))
	play.set("biome", Biome.tag(Campaign.biome_at(REGION),
		Campaign.dread(REGION)))
	play.set("hero", who)
	play.set("region_index", REGION)
	play.set("campaign_seed", 4242)
	play.set("tier", Campaign.Tier.NORMAL)
	play.set("region_cells", 96)
	play.roster = account
	get_root().add_child(play)
	var frames: int = 0
	while frames < 2400 and play.get("_hero") == null:
		await process_frame
		frames += 1
	return play


func _dying_ends_the_run() -> void:
	print("\n=== killing the champion ends the run ===")
	var account: Roster = Roster.create(HeroRig.animated_heroes())
	var who: String = String(account.owned.keys()[0])
	var play: Node = await _play(account, who)
	var me: HeroController = play.get("_hero")
	check("the region came up", me != null)
	if me == null:
		return

	var gold_before: int = account.wallet.balance(Wallet.Kind.GOLD)
	var cleared_before: bool = account.is_map_cleared(Campaign.Tier.NORMAL,
		REGION)
	check("the map is not cleared before any of this", not cleared_before)

	# Catch the summary the run ends with.
	var seen: Array = []
	play.region_cleared.connect(func(s: Dictionary) -> void: seen.append(s))

	# KILLED THROUGH THE BODY, the way anything in the game kills it, so the
	# whole chain runs: Combatant.died -> HeroController._on_body_died ->
	# champion_died -> Play._on_champion_died.
	me.body.take_hit(me.body.max_health * 10.0, "test")
	await process_frame
	check("the champion is down", me.is_dead() and not me.body.alive)

	# DEFEAT_HOLD is deliberately a couple of seconds — the death clip and the
	# line want that time — so this waits it out rather than asserting
	# instantly and calling a timer that has not fired a bug.
	# MEASURED ON THE CLOCK, NOT IN FRAMES. A headless run renders frames as
	# fast as it can, so counting `1.0 / 60.0` per frame reached "6 seconds"
	# long before the 2.8 s hold had actually elapsed — the first version of
	# this test reported the run never ending when it simply had not ended yet.
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 9000 and seen.is_empty():
		await process_frame
	var took: float = float(Time.get_ticks_msec() - t0) / 1000.0
	check("THE RUN ENDED", not seen.is_empty(),
		"summary after %.1fs of real time" % took)
	if seen.is_empty():
		play.queue_free()
		return

	var s: Dictionary = seen[0]
	check("...reported as a defeat", bool(s.get("defeat", false)))
	check("...with nowhere to advance to", int(s.get("next", 0)) < 0,
		"next=%d" % int(s.get("next", 0)))
	check("...and not as a region cleared",
		not bool(s.get("cleared_this_run", true)))

	# THE GATE HELD. This is the half that matters: if defeat marked the map
	# cleared, dying to a boss would unlock the next region.
	check("THE MAP IS STILL NOT CLEARED",
		not account.is_map_cleared(Campaign.Tier.NORMAL, REGION))
	check("...so the next region stays sealed",
		not account.is_map_unlocked(Campaign.Tier.NORMAL, REGION + 1))

	# AND WHAT WAS EARNED SURVIVED.
	check("gold earned before dying was kept",
		account.wallet.balance(Wallet.Kind.GOLD) >= gold_before,
		"%d -> %d" % [gold_before,
			account.wallet.balance(Wallet.Kind.GOLD)])

	# A second death must not queue a second summary.
	me.body.take_hit(me.body.max_health * 10.0, "test again")
	for i in range(30):
		await process_frame
	check("a second death does not end the run twice", seen.size() == 1,
		"%d summaries" % seen.size())

	play.queue_free()
	await process_frame


func _the_screen_says_so() -> void:
	print("\n=== and the screen does not claim a win ===")
	# The clear screen is reused for both outcomes, so the one thing it must get
	# right is the headline. Telling a player "REGION CLEARED" over a run they
	# died in is a lie the stats underneath immediately contradict.
	var won: Dictionary = {"region": 3, "tier": Campaign.Tier.NORMAL,
		"kills": 4, "cleared": 4, "total": 100, "next": 4}
	var lost: Dictionary = won.duplicate()
	lost["defeat"] = true
	lost["next"] = -1

	for spec in [{"s": won, "want": "REGION CLEARED", "name": "a clear"},
			{"s": lost, "want": "YOUR CHAMPION FELL", "name": "a defeat"}]:
		var scr: ClearScreen = ClearScreen.new()
		root.add_child(scr)
		# show_summary() is the only door the game uses; ClearScreen is a plain
		# Control and has no roster or hero of its own.
		scr.show_summary(spec["s"])
		await process_frame
		await process_frame
		var found: bool = false
		for node in scr.find_children("*", "Label", true, false):
			if String((node as Label).text) == String(spec["want"]):
				found = true
				break
		check("%s is headlined \"%s\"" % [spec["name"], spec["want"]], found)
		scr.queue_free()
		await process_frame
