extends SceneTree
# ------------------------------------------------------------------------------
# THE TWO NEW MODES MUST ACTUALLY RUN.
#
# This repo's recurring failure is a system that is built, unit-tested, and
# then wired to nothing — the lane generator, the encounter builder,
# record_map_cleared(), gain_xp(), all complete and all uncalled. A game mode
# is the easiest thing in the world to add that way: the rules file reads
# beautifully and the Play button still launches a campaign map.
#
# So the second half of this boots the REAL Play scene, kills the real wave,
# and checks the real next wave arrives. It is forbidden from calling
# _next_wave() itself — doing so would test that the function exists, which
# nobody doubted.
# ------------------------------------------------------------------------------

const PlayS := preload("res://scripts/game/Play.gd")
const GameMode := preload("res://scripts/game/GameMode.gd")
const PLAY_SCENE := "res://scenes/Play.tscn"
const CELLS: int = 96

var _fails: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-52s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _init() -> void:
	_rules()
	_run_modes()


# ---- the pure rules ----------------------------------------------------------

func _rules() -> void:
	print("\n=== the rules ===")

	check("there are three modes and the campaign is one",
		GameMode.all().size() == 3
			and GameMode.all().has(GameMode.Id.CAMPAIGN))

	check("only the descent is endless",
		GameMode.is_endless(GameMode.Id.DESCENT)
			and not GameMode.is_endless(GameMode.Id.GAUNTLET)
			and not GameMode.is_endless(GameMode.Id.CAMPAIGN))

	# An endless mode has no final wave, or it would end.
	var endless_final: bool = false
	for w in [0, 5, 50, 500]:
		if GameMode.is_final_wave(GameMode.Id.DESCENT, w):
			endless_final = true
	check("a descent never reaches a final wave", not endless_final)

	check("a gauntlet ends on its last crown",
		GameMode.is_final_wave(GameMode.Id.GAUNTLET,
			GameMode.GAUNTLET_BOSSES - 1)
			and not GameMode.is_final_wave(GameMode.Id.GAUNTLET, 0))

	# ---- difficulty must climb, and keep climbing --------------------------
	var last: int = -1
	var monotonic: bool = true
	for w in range(GameMode.DESCENT_RAMP + 1):
		var idx: int = GameMode.scaling_index(GameMode.Id.DESCENT, w)
		if idx < last:
			monotonic = false
		last = idx
	check("a descent's difficulty never goes backwards", monotonic,
		"reaches campaign index %d by wave %d"
			% [last, GameMode.DESCENT_RAMP])

	# THE PLATEAU, which is the failure mode of every endless mode: the
	# campaign curve runs out and the game stops getting harder.
	var deep: float = GameMode.overdrive(GameMode.Id.DESCENT,
		GameMode.DESCENT_RAMP + 40)
	check("...and keeps climbing after the campaign curve runs out",
		deep > 2.0, "x%.1f forty waves past the ramp" % deep)
	check("...but is exactly campaign-hard before then",
		is_equal_approx(GameMode.overdrive(GameMode.Id.DESCENT, 0), 1.0)
			and is_equal_approx(
				GameMode.overdrive(GameMode.Id.DESCENT,
					GameMode.DESCENT_RAMP), 1.0))
	check("other modes never get an overdrive multiplier",
		is_equal_approx(GameMode.overdrive(GameMode.Id.GAUNTLET, 99), 1.0)
			and is_equal_approx(
				GameMode.overdrive(GameMode.Id.CAMPAIGN, 99), 1.0))

	# ---- a gauntlet draws from the whole campaign --------------------------
	var first: int = GameMode.scaling_index(GameMode.Id.GAUNTLET, 0)
	var final_i: int = GameMode.scaling_index(GameMode.Id.GAUNTLET,
		GameMode.GAUNTLET_BOSSES - 1)
	check("a gauntlet walks the whole campaign, not just the shallows",
		first == 0 and final_i == Campaign.map_count() - 1,
		"index %d -> %d" % [first, final_i])

	check("a gauntlet is bosses only; the others are not",
		GameMode.boss_only(GameMode.Id.GAUNTLET, 3)
			and not GameMode.boss_only(GameMode.Id.DESCENT, 3)
			and not GameMode.boss_only(GameMode.Id.CAMPAIGN, 0))

	check("both new modes are fought in one arena, not a lane",
		int(GameMode.shape_of(GameMode.Id.DESCENT).get("kind", -1))
			== Terrain.Kind.ARENA
			and int(GameMode.shape_of(GameMode.Id.GAUNTLET).get("kind", -1))
			== Terrain.Kind.ARENA)

	check("each mode has its own record slot, and the campaign has none",
		GameMode.record_key(GameMode.Id.DESCENT)
			!= GameMode.record_key(GameMode.Id.GAUNTLET)
			and GameMode.record_key(GameMode.Id.CAMPAIGN).is_empty())

	# ---- the record survives a save/load -----------------------------------
	# A high score that evaporates on restart is the whole reward of these
	# modes evaporating. Roster is a RefCounted, so set_meta() would NOT have
	# been written to the save — this checks the real round trip.
	var r := Roster.new()
	var key: String = GameMode.record_key(GameMode.Id.DESCENT)
	check("a deeper run beats the record", r.note_mode_run(key, 12))
	check("...and a shallower one does not", not r.note_mode_run(key, 7))
	var back := Roster.from_dict(r.to_dict(), HeroRig.animated_heroes())
	check("...and it survives being saved and loaded",
		back.best_in_mode(key) == 12, "best %d" % back.best_in_mode(key))


# ---- reachable from the menus ------------------------------------------------

func _reachable() -> void:
	print("\n=== reachable from the campaign screen ===")
	# THE WIRING GUARD. A mode Play supports but no screen offers is the
	# repo's signature failure, and the rules above would all still pass.
	var screen := CampaignScreen.new()
	screen.roster = Roster.new()
	screen.hero = HeroRig.animated_heroes()[0]
	root.add_child(screen)
	# UiScreen builds `content` in _ready(), which needs a frame to run —
	# calling build() before it exists fails inside split_fixed() and leaves
	# an empty screen that looks exactly like "the buttons are missing".
	await process_frame
	screen.build()
	await process_frame

	var payloads: Array = []
	screen.navigate.connect(func(route, arg):
		if route == UiRoute.LAUNCH:
			payloads.append(arg))

	var buttons: Array = []
	_buttons_in(screen, buttons)
	var hit: Dictionary = {}
	for b in buttons:
		var t: String = String((b as Button).text)
		for id in GameMode.all():
			if id != GameMode.Id.CAMPAIGN and t.begins_with(GameMode.name_of(id)):
				hit[id] = b
	check("both new modes have a button on the campaign screen",
		hit.size() == 2, "found %s" % str(hit.keys()))

	for id in hit.keys():
		(hit[id] as Button).emit_signal("pressed")
	var modes_asked: Array = []
	for pl in payloads:
		modes_asked.append(int((pl as Dictionary).get("mode", -1)))
	check("...and pressing them asks to launch THAT mode",
		modes_asked.has(GameMode.Id.DESCENT)
			and modes_asked.has(GameMode.Id.GAUNTLET),
		"asked for %s" % str(modes_asked))

	screen.queue_free()


func _buttons_in(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is Button:
			out.append(c)
		_buttons_in(c, out)


# ---- the modes as actually played --------------------------------------------

func _run_modes() -> void:
	await _reachable()
	await _play_mode(GameMode.Id.DESCENT, "Descent")
	await _play_mode(GameMode.Id.GAUNTLET, "Gauntlet")
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


func _play_mode(mode: int, label: String) -> void:
	print("\n=== %s, as actually played ===" % label)
	var packed: PackedScene = load(PLAY_SCENE) as PackedScene
	if packed == null:
		check("the play scene loads", false)
		return
	var play: Node = packed.instantiate()
	play.set("mode", mode)
	play.set("tier", Campaign.Tier.NORMAL)
	play.set("region_index", 0)
	play.set("campaign_seed", 4242)
	play.set("world_seed", 4242)
	play.set("region_cells", CELLS)
	play.set("hero", HeroRig.animated_heroes()[0])
	root.add_child(play)

	# Wave one.
	var foes: Array = []
	for i in range(3000):
		await process_frame
		foes = _living(play)
		if foes.size() > 0:
			break
	check("wave 1 arrives", foes.size() > 0, "%d enemies" % foes.size())
	if foes.is_empty():
		play.queue_free()
		return

	if mode == GameMode.Id.GAUNTLET:
		var bosses: int = 0
		for f in foes:
			if (f as Node3D).scale.y >= Encounter.BOSS_SIZE - 0.001:
				bosses += 1
		check("...and a gauntlet wave is nothing but boss",
			bosses == foes.size(), "%d of %d are bosses"
				% [bosses, foes.size()])

	# KILL IT AND SEE WHAT COMES. Through the real damage path, so the real
	# clear logic runs — not by calling _next_wave().
	var before_wave: int = int(play.get("_wave"))
	for f in foes:
		var hc := f as HeroController
		if hc != null and hc.body != null:
			hc.body.take_hit(hc.body.max_health * 10.0, "test")

	var next: Array = []
	for i in range(3000):
		await process_frame
		if int(play.get("_wave")) > before_wave:
			next = _living(play)
			if next.size() > 0:
				break
	check("...and clearing it sends the NEXT wave, in the same arena",
		int(play.get("_wave")) == before_wave + 1 and next.size() > 0,
		"wave %d with %d enemies" % [int(play.get("_wave")), next.size()])

	play.queue_free()
	await process_frame


func _living(play: Node) -> Array:
	var out: Array = []
	for c in play.get_children():
		var hc := c as HeroController
		if hc == null or hc.body == null or hc.is_dead():
			continue
		# The champion is a HeroController too; the enemies are the ones with
		# an entry in the enemy list.
		if hc == play.get("_hero"):
			continue
		out.append(hc)
	return out
