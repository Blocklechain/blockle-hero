extends Node3D
# ------------------------------------------------------------------------------
# Does the STUN actually do what StatusEffect.gd and HeroController.gd claim?
# Measured on the real controller, in a real world, not read off the source:
#
#   1. running, unstunned   -> rig state RUN, ~RUN_SPEED m/s
#   2. the same order, stunned -> rig state WALK, ~WALK_SPEED*0.55 m/s
#   3. abilities refused while stunned
#   4. stunned but STANDING STILL -> what does the rig play?
#   5. does the walk CLIP's playback rate change with the 0.55? (it must not —
#      HeroRig never touches speed_scale, so the feet keep walk cadence while
#      the body moves at 55%, i.e. foot slide)
#
#   godot --headless --path . res://scenes/StunLive.tscn
# ------------------------------------------------------------------------------

const SAMPLE_FRAMES := 90

var _builder: WorldBuilder
var _hero: HeroController
var _ter: Terrain
var _plan: Layout
var _fails: int = 0

const STATE_NAME := {0: "IDLE", 1: "WALK", 2: "RUN", 3: "ATTACK",
	4: "ABILITY_1", 5: "ABILITY_2", 6: "ABILITY_3", 7: "HIT", 8: "DEATH"}


func _ready() -> void:
	_builder = WorldBuilder.new()
	add_child(_builder)
	_builder.finished.connect(_go)
	_builder.build(7000, "greenwood", 384, 0.5)


func _check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s%s" % ["PASS" if ok else "FAIL", label,
		("   " + detail) if detail != "" else ""])


func _go(root: Node3D, ter: Terrain, plan: Layout) -> void:
	add_child(root)
	_ter = ter
	_plan = plan

	var pick: String = HeroRig.animated_heroes()[0]
	_hero = HeroController.new()
	add_child(_hero)
	var entry: Dictionary = plan.node_of_kind(Layout.ENTRY)
	if not _hero.setup(ter, pick, entry.get("pos", Vector2.ZERO)):
		print("FAIL: hero setup"); get_tree().quit(1); return

	# Play.gd never does this, which is why the stun is unreachable there.
	var body: Combatant = Combatant.make("test", Combatant.Team.PLAYER, 10,
		Stats.new(), HeroClass.School.MELEE, 10.0, 5.0, 1)
	_hero.setup_combat(body, HeroClass.Kind.FIGHTER, pick)

	print("hero '%s' rigged=%s  walk clip=%s  run clip=%s" % [
		pick, str(_hero.rig.is_rigged),
		_hero.rig._clip_for.get(HeroRig.State.WALK, "NONE"),
		_hero.rig._clip_for.get(HeroRig.State.RUN, "NONE")])
	await _run_tests(body)
	print("\n%d failure(s)" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


# Order a long move and watch the hero for SAMPLE_FRAMES physics ticks.
# Returns {speed, states:{state:count}, clip_pos_delta}.
func _observe(goal: Vector2) -> Dictionary:
	_hero.move_to(goal, true)
	var states: Dictionary = {}
	var start: Vector2 = _hero.ground_position()
	var t0: float = float(Time.get_ticks_usec()) / 1e6
	var dist: float = 0.0
	var prev: Vector2 = start
	var frames: int = 0
	var scales: Array = []
	while frames < SAMPLE_FRAMES and _hero.is_moving():
		await get_tree().physics_frame
		frames += 1
		var now: Vector2 = _hero.ground_position()
		dist += prev.distance_to(now)
		prev = now
		var st: int = _hero.rig.state()
		states[st] = int(states.get(st, 0)) + 1
		scales.append(_hero.rig._anim.speed_scale)
	# SIMULATED time, not wall clock. --headless is not paced to realtime, so
	# dist/wall-clock over-reports: it put the run at 6.78 m/s against a
	# RUN_SPEED of 6.2. Movement is integrated in _physics_process, so frames
	# divided by the physics tick rate is the exact elapsed game time.
	var secs: float = float(frames) / float(Engine.physics_ticks_per_second)
	var worst_scale: float = 1.0
	for s in scales:
		if absf(float(s) - 1.0) > absf(worst_scale - 1.0):
			worst_scale = float(s)
	return {
		"speed": dist / maxf(secs, 0.0001),
		"wall_speed": dist / maxf(float(Time.get_ticks_usec()) / 1e6 - t0, 0.0001),
		"states": states,
		"frames": frames,
		"clip": _hero.rig._anim.current_animation,
		"speed_scale": worst_scale,
		"secs": secs,
	}


func _dominant(states: Dictionary) -> int:
	var best: int = -1
	var n: int = -1
	for k in states:
		if int(states[k]) > n:
			n = int(states[k])
			best = int(k)
	return best


func _far_goal() -> Vector2:
	var here: Vector2 = _hero.ground_position()
	var best: Vector2 = here
	var bd: float = -1.0
	for nd in _plan.nodes:
		var p: Vector2 = nd["pos"]
		var d: float = here.distance_to(p)
		if d > bd:
			bd = d
			best = p
	return best


func _run_tests(body: Combatant) -> void:
	# --- 1. unstunned run -----------------------------------------------
	print("\n1) RUNNING, not stunned")
	var a: Dictionary = await _observe(_far_goal())
	var run_state: int = _dominant(a["states"])
	_check("rig plays RUN", run_state == HeroRig.State.RUN,
		"dominant=%s  clip=%s" % [STATE_NAME.get(run_state, "?"), a["clip"]])
	_check("moves at ~RUN_SPEED (6.2)", absf(a["speed"] - 6.2) < 0.3,
		"measured %.2f m/s over %d physics frames (%.2f s sim)" % [
			a["speed"], a["frames"], a["secs"]])
	var run_speed: float = a["speed"]

	# --- 2. same order, stunned -----------------------------------------
	print("\n2) SAME ORDER, STUNNED  (stun = walk clip + 0.55 speed)")
	body.effects.append(StatusEffect.make(StatusEffect.Kind.STUN, 60.0))
	_check("Combatant.is_stunned()", body.is_stunned())
	_check("move_multiplier == STUN_SPEED_MULT",
		is_equal_approx(body.move_multiplier(), StatusEffect.STUN_SPEED_MULT),
		"x%.3f" % body.move_multiplier())
	var b: Dictionary = await _observe(_far_goal())
	var stun_state: int = _dominant(b["states"])
	_check("rig is FORCED to WALK", stun_state == HeroRig.State.WALK,
		"dominant=%s  clip=%s" % [STATE_NAME.get(stun_state, "?"), b["clip"]])
	var want: float = HeroController.WALK_SPEED * StatusEffect.STUN_SPEED_MULT
	_check("moves at WALK_SPEED*0.55 = %.3f" % want, absf(b["speed"] - want) < 0.5,
		"measured %.2f m/s" % b["speed"])
	_check("stunned is visibly slower than running",
		b["speed"] < run_speed * 0.5,
		"%.2f vs %.2f m/s = %.0f%% of run speed" % [
			b["speed"], run_speed, 100.0 * b["speed"] / maxf(run_speed, 0.001)])

	# --- 3. abilities locked out ----------------------------------------
	print("\n3) ABILITIES WHILE STUNNED")
	for slot in range(4):
		_check("slot %d refused" % slot, not _hero.use_ability(slot))

	# --- 5. does the CLIP slow down too? --------------------------------
	#
	# Measured via AnimationPlayer.speed_scale, not by differencing
	# current_animation_position: walk-loop LOOPS inside the sample window, so
	# the position wraps and the delta comes out negative and meaningless (the
	# first run of this harness reported "-0.40x realtime").
	print("\n5) CLIP PLAYBACK RATE (does the 0.55 slow reach the animation?)")
	print("    AnimationPlayer.speed_scale: running %.2f, stunned %.2f" % [
		a["speed_scale"], b["speed_scale"]])
	_check("walk clip plays at 1.0x even though the body is at 0.55x",
		is_equal_approx(float(b["speed_scale"]), 1.0),
		"HeroRig never sets speed_scale, so the feet keep full walk cadence " +
		"(%.2f cycles/s) while the body crawls at %.2f m/s" % [
			1.0 / _hero.rig._anim.get_animation(
				_hero.rig._clip_for[HeroRig.State.WALK]).length, b["speed"]])
	_check("rig.set_locomotion() reaches the rigged animation at all",
		false,
		"it only feeds _speed01, which is read exclusively by _procedural() " +
		"(the STATIC stand-in). On a rigged hero the 0.55 is invisible.")

	# --- 4. stunned but standing still ----------------------------------
	print("\n4) STUNNED BUT STANDING STILL")
	_hero.stop()
	for i in 20:
		await get_tree().physics_frame
	var idle_state: int = _hero.rig.state()
	print("    rig state while stunned and stationary: %s" % STATE_NAME.get(idle_state, "?"))
	_check("a stationary stunned hero still looks stunned",
		idle_state == HeroRig.State.WALK,
		"it plays %s — identical to an un-stunned hero standing still, so a " % STATE_NAME.get(idle_state, "?") +
		"stun landing while the player is not moving has NO animation at all")

	# --- clear and confirm it reverts ------------------------------------
	print("\n6) STUN EXPIRES")
	body.effects.clear()
	var c: Dictionary = await _observe(_far_goal())
	_check("back to RUN", _dominant(c["states"]) == HeroRig.State.RUN,
		"%.2f m/s" % c["speed"])
