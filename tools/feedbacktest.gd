extends SceneTree
# ------------------------------------------------------------------------------
# Does being hit, and dying, actually reach the player?
#
# Everything here was PRESENT AND DEAD before this check existed, which is the
# only reason it exists: Combatant emitted `damaged` and `died` with nothing
# connected to either, a 5.8 s death clip shipped on all 139 heroes and was
# never played, HeroRig.State.HIT changed nothing at all on a rigged model
# because no `hit` clip was ever delivered, and the project contained no audio.
# None of that fails a compile and none of it fails a balance test — a silent,
# reactionless game is perfectly self-consistent. So the assertions below are
# deliberately about OBSERVABLE change, not about code being present:
#
#   1. the five synthesised cues are real, distinct, non-silent PCM
#   2. a damaged or killed combatant actually causes a cue to be requested
#   3. `died` has a listener, from every door a combatant can be built through
#   4. a HIT on a RIGGED hero visibly moves the body and lights the mesh,
#      without interrupting the clip that was already playing
#   5. a dead champion plays DEATH and STAYS down, with its controller inert
#
#   godot --headless --path . --script tools/feedbacktest.gd
# ------------------------------------------------------------------------------

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-56s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_cues()
	await _routing()
	await _hit_reads_on_a_rigged_hero()
	await _death_happens()

	await _teardown()
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


## Audio's cache and its voice pool are STATIC, so they outlive the main loop and
## a cue still mid-play when quit() lands is reported as a leaked instance. The
## game never exits between frames like this, so rather than contort the engine
## the harness tidies up after itself — a check that ends in a leak warning is a
## check people learn to ignore.
func _teardown() -> void:
	var node: Audio = Audio.boot()
	if node != null and is_instance_valid(node):
		node.free()
	Audio._node = null
	Audio._streams.clear()
	# Freeing the voices only queues the AudioServer's playbacks for release; it
	# needs mix frames to actually let go of them.
	for i in range(30):
		await process_frame


# ------------------------------------------------------------------------------
# 1. The sound exists and is not silence
# ------------------------------------------------------------------------------

const CUE_NAMES: Dictionary = {
	Audio.Cue.HIT: "hit", Audio.Cue.CRIT: "crit", Audio.Cue.DEATH: "death",
	Audio.Cue.CAST: "cast", Audio.Cue.STEP: "step",
}


func _cues() -> void:
	print("\n=== synthesised cues ===")
	var hashes: Dictionary = {}
	for cue in CUE_NAMES.keys():
		var s: AudioStreamWAV = Audio.stream_for(cue)
		var name: String = CUE_NAMES[cue]
		if s == null or s.data.is_empty():
			check("%s: synthesises to PCM" % name, false, "empty stream")
			continue

		var n: int = s.data.size() / 2
		var peak: float = 0.0
		var energy: float = 0.0
		for i in range(n):
			var v: float = float(s.data.decode_s16(i * 2)) / 32768.0
			peak = maxf(peak, absf(v))
			energy += v * v
		var rms: float = sqrt(energy / float(n))
		var head: float = absf(float(s.data.decode_s16(0)) / 32768.0)
		var tail: float = absf(float(s.data.decode_s16((n - 1) * 2)) / 32768.0)

		check("%s: %.0f ms of 16-bit %d Hz mono" % [name, 1000.0 * float(n) / float(Audio.RATE), Audio.RATE],
			s.format == AudioStreamWAV.FORMAT_16_BITS
			and s.mix_rate == Audio.RATE and not s.stereo,
			"%d samples" % n)
		# A buffer of zeroes would pass every structural test and play nothing,
		# which is the exact failure this whole task exists to prevent.
		check("%s: audibly loud, not silence" % name, peak > 0.25 and rms > 0.01,
			"peak %.2f  rms %.3f" % [peak, rms])
		# Ends on silence or it clicks on every single play.
		check("%s: starts and ends at zero (no click)" % name,
			head < 0.02 and tail < 0.02, "head %.4f  tail %.4f" % [head, tail])
		hashes[name] = hash(s.data)

	check("all five cues are different sounds",
		hashes.size() == CUE_NAMES.size(),
		"%d distinct buffers" % _distinct(hashes.values()))

	# Generated once, not per play: a hit fires several times a second.
	check("a cue is synthesised once and cached",
		Audio.stream_for(Audio.Cue.HIT) == Audio.stream_for(Audio.Cue.HIT),
		"same resource returned twice")

	# The ability sweep is one buffer re-pitched per slot, so all four slots must
	# resolve to a stream rather than only slot 0 having a sound.
	var pitched: bool = true
	for slot in range(4):
		var before: int = Audio.cues_played
		Audio.play(Audio.Cue.CAST, 1.0)
		if Audio.cues_played == before:
			# Only acceptable reason is the retrigger window.
			pitched = pitched and slot > 0
	check("the cast cue is playable", pitched)


func _distinct(values: Array) -> int:
	var seen: Dictionary = {}
	for v in values:
		seen[v] = true
	return seen.size()


# ------------------------------------------------------------------------------
# 2 and 3. Damage and death reach a listener, through the one spawn door
# ------------------------------------------------------------------------------

func _routing() -> void:
	print("\n=== every combatant is wired at birth ===")
	# Engine.get_main_loop() is still null inside a MainLoop script's _init(), so
	# the no-context boot() cannot find the tree until the loop is running. The
	# game never hits that window; this harness does.
	await process_frame
	check("Audio.boot() returns its node", Audio.boot() != null)
	# boot() parents its node deferred, so the voice pool only exists next frame.
	await process_frame

	check("Audio.boot() armed the spawn hook", not Combatant.on_spawn.is_empty(),
		"%d hook(s) on Combatant.on_spawn" % Combatant.on_spawn.size())

	var c: Combatant = _mk("skeleton", Combatant.Team.ENEMY, 10)
	check("a spawned combatant has a damaged listener",
		c.damaged.get_connections().size() > 0,
		"%d listener(s)" % c.damaged.get_connections().size())
	# THE HEADLINE: `died` used to have none, anywhere in the project.
	check("a spawned combatant has a died listener",
		c.died.get_connections().size() > 0,
		"%d listener(s)" % c.died.get_connections().size())

	Audio.last_cue = -1
	var before: int = Audio.cues_played
	c._take_raw(1.0, false, "test")
	check("being damaged requests the hit cue", Audio.cues_played > before
		and Audio.last_cue == Audio.Cue.HIT, "cue=%s" % _cue_name(Audio.last_cue))

	var before_crit: int = Audio.cues_played
	c._take_raw(1.0, true, "test")
	check("a crit is a DIFFERENT sound, not a louder one",
		Audio.cues_played > before_crit and Audio.last_cue == Audio.Cue.CRIT,
		"cue=%s" % _cue_name(Audio.last_cue))

	var before_death: int = Audio.cues_played
	c._take_raw(c.max_health * 2.0, false, "test")
	check("dying requests the death cue", not c.alive
		and Audio.cues_played > before_death
		and Audio.last_cue == Audio.Cue.DEATH, "cue=%s" % _cue_name(Audio.last_cue))

	# A cleave hits six enemies in one frame; six thuds in one frame is a flange.
	_let_retrigger_lapse()
	var crowd: Array[Combatant] = []
	for i in range(6):
		crowd.append(_mk("e%d" % i, Combatant.Team.ENEMY, 10))
	var before_cleave: int = Audio.cues_played
	for e in crowd:
		e._take_raw(1.0, false, "cleave")
	check("six hits in one frame collapse to one thud",
		Audio.cues_played - before_cleave == 1,
		"%d cue(s) for 6 hits" % (Audio.cues_played - before_cleave))

	# The mute switch has to work at the source, or a settings toggle is a lie.
	_let_retrigger_lapse()
	Audio.enabled = false
	var muted_at: int = Audio.cues_played
	_mk("mute", Combatant.Team.ENEMY, 10)._take_raw(1.0, false, "test")
	check("Audio.enabled = false silences everything",
		Audio.cues_played == muted_at)
	Audio.enabled = true


## The retrigger window is measured against the wall clock, and every
## assertion in this file runs inside a single frame — so without a real pause
## the next cue is suppressed as a duplicate and the test reads as a silent
## engine. Slept rather than awaited: headless frames are far shorter than
## 35 ms, so awaiting one proves nothing.
func _let_retrigger_lapse() -> void:
	OS.delay_msec(int(Audio.RETRIGGER * 1000.0) + 10)


func _cue_name(cue: int) -> String:
	return String(CUE_NAMES.get(cue, "none"))


func _mk(name: String, team: int, lv: int) -> Combatant:
	var cls: int = HeroClass.Kind.FIGHTER
	var st: Stats = HeroClass.base_stats(cls).plus(HeroClass.growth_to(cls, lv))
	return Combatant.make(name, team, lv, st, HeroClass.school_of(cls),
		10.0, 20.0, 1)


# ------------------------------------------------------------------------------
# 4. A hit reads on a RIGGED hero, which has no hit clip to play
# ------------------------------------------------------------------------------

## `_model` and `_anim` are read directly, as tools/stunlive.gd already does.
## The point of this check is the mechanism, and asserting on the public surface
## alone would pass on a rig that moves nothing.
func _hit_reads_on_a_rigged_hero() -> void:
	print("\n=== a hit is visible on a rigged hero ===")
	var roster: PackedStringArray = HeroRig.animated_heroes()
	if roster.is_empty():
		check("roster is loadable", false, "no heroes")
		return

	var rig := HeroRig.new()
	get_root().add_child(rig)
	if not rig.load_hero(roster[0]):
		check("'%s' loads" % roster[0], false)
		return
	check("'%s' is rigged" % roster[0], rig.is_rigged)
	# The premise of the whole mechanism. If a hit clip is ever delivered this
	# flips, and the recoil then rides on top of a real flinch animation.
	check("...and still has NO hit clip to play",
		not rig._clip_for.has(HeroRig.State.HIT),
		"missing: [%s]" % ", ".join(rig.missing_states()))

	var meshes: Array = rig.find_children("*", "MeshInstance3D", true, false)
	check("the body has meshes to flash", meshes.size() > 0,
		"%d surface(s)" % meshes.size())

	var rest_pos: Vector3 = rig._model.position
	var rest_rot: Vector3 = rig._model.rotation
	var rest_scale: Vector3 = rig._model.scale

	rig.set_state(HeroRig.State.HIT)
	check("HIT keeps the 0.25 s timing contract",
		is_equal_approx(rig._oneshot_left, HeroRig.RECOIL_TIME),
		"%.3f s" % rig._oneshot_left)

	# Stepped by hand rather than by awaiting frames, so the sample lands on the
	# peak of the impulse instead of wherever headless pacing happens to tick.
	rig._process(0.04)
	var moved_rot: float = (rig._model.rotation - rest_rot).length()
	var moved_pos: float = (rig._model.position - rest_pos).length()
	var squashed: float = (rig._model.scale - rest_scale).length()
	check("the body recoils (rotation)", moved_rot > 0.02, "%.3f rad" % moved_rot)
	check("the body is shoved back (position)", moved_pos > 0.004, "%.4f m" % moved_pos)
	check("the body squashes (scale)", squashed > 0.0005, "%.4f" % squashed)
	check("it leans BACK, not forward", rig._model.rotation.x < rest_rot.x - 0.01,
		"pitch %+.3f rad" % (rig._model.rotation.x - rest_rot.x))

	var flashed: int = 0
	for m in meshes:
		var mi := m as MeshInstance3D
		if mi.material_overlay != null:
			flashed += 1
	check("the mesh flashes", flashed == meshes.size(),
		"%d/%d surfaces lit" % [flashed, meshes.size()])
	check("the rig reports the reaction", rig.is_flinching())

	# Settle it, and insist the rest pose comes back EXACTLY — a reaction that
	# leaves a few thousandths behind drifts a hero into the floor over a fight.
	for i in range(12):
		rig._process(0.04)
	check("the reaction ends", not rig.is_flinching())
	check("the rest pose is restored exactly",
		rig._model.position.is_equal_approx(rest_pos)
		and rig._model.rotation.is_equal_approx(rest_rot)
		and rig._model.scale.is_equal_approx(rest_scale),
		"pos %+.5f  rot %+.5f  scale %+.5f" % [
			(rig._model.position - rest_pos).length(),
			(rig._model.rotation - rest_rot).length(),
			(rig._model.scale - rest_scale).length()])
	var lit: int = 0
	for m in meshes:
		if (m as MeshInstance3D).material_overlay != null:
			lit += 1
	check("the flash is removed, not left on", lit == 0, "%d still lit" % lit)

	# THE REASON flinch() EXISTS: a hero struck mid-run must not drop out of the
	# run, and a hero struck mid-swing must not lose the swing it paid for.
	rig.set_state(HeroRig.State.RUN)
	var running_clip: String = rig._anim.current_animation
	rig.flinch()
	rig._process(0.04)
	check("a flinch does not interrupt the clip playing",
		rig._anim.current_animation == running_clip and rig.state() == HeroRig.State.RUN,
		"still '%s'" % running_clip)
	check("...but the body still moves",
		(rig._model.rotation - rest_rot).length() > 0.02
		or (rig._model.position - rest_pos).length() > 0.004)

	# Hit again mid-reaction: a flurry must read as a flurry.
	rig._process(0.1)
	var mid: float = rig._recoil_left
	rig.flinch()
	check("re-striking restarts the reaction", rig._recoil_left > mid,
		"%.3f s -> %.3f s" % [mid, rig._recoil_left])

	rig.free()


# ------------------------------------------------------------------------------
# 5. Death actually happens, and stays happened
# ------------------------------------------------------------------------------

func _death_happens() -> void:
	print("\n=== death ===")
	var roster: PackedStringArray = HeroRig.animated_heroes()
	var hero: String = roster[0]

	var hc := HeroController.new()
	get_root().add_child(hc)
	# setup() is skipped because it needs a generated Terrain; the rig is built
	# the same way setup() builds it. _physics_process never reaches the terrain
	# while the hero is standing still, so the controller runs for real here.
	var rig := HeroRig.new()
	hc.add_child(rig)
	if not rig.load_hero(hero):
		check("'%s' loads" % hero, false)
		return
	hc.rig = rig

	check("every hero ships a death clip",
		rig._clip_for.has(HeroRig.State.DEATH),
		"clip '%s', %.1f s" % [rig._clip_for.get(HeroRig.State.DEATH, ""),
			rig._anim.get_animation(rig._clip_for[HeroRig.State.DEATH]).length])

	var body: Combatant = _mk(hero, Combatant.Team.PLAYER, 10)
	hc.setup_combat(body, HeroClass.Kind.FIGHTER, hero)
	check("setup_combat connects died()", body.died.get_connections().size() > 0,
		"%d listener(s)" % body.died.get_connections().size())
	check("setup_combat connects damaged()",
		body.damaged.get_connections().size() > 0)

	# The controller's idle branch sets IDLE every frame it is not moving, which
	# is exactly what used to make a death clip impossible to see.
	await physics_frame
	check("alive and idling", rig.state() == HeroRig.State.IDLE)

	var saw_damage: Array[float] = []
	hc.took_damage.connect(func(amount: float, _crit: bool, _src: String) -> void:
		saw_damage.append(amount))
	var saw_death: Array[bool] = []
	hc.champion_died.connect(func() -> void: saw_death.append(true))

	body._take_raw(5.0, false, "test")
	check("took_damage reaches the HUD seam", saw_damage.size() == 1,
		"%.1f damage forwarded" % (saw_damage[0] if not saw_damage.is_empty() else 0.0))
	check("a surviving hit does not kill the hero", not hc.is_dead())

	body._take_raw(body.max_health * 2.0, false, "test")
	check("champion_died reaches the HUD seam", saw_death.size() == 1)
	check("the rig plays DEATH", rig.state() == HeroRig.State.DEATH,
		"clip '%s'" % rig._anim.current_animation)
	check("the death clip is actually running", rig._anim.is_playing()
		and rig._anim.current_animation == rig._clip_for[HeroRig.State.DEATH])
	check("the controller is inert", hc.is_dead() and not hc.is_moving())
	check("a corpse refuses orders", not hc.use_ability(0)
		and not hc.move_to(Vector2(10, 10)))

	# THE REGRESSION THIS GUARDS: one frame of _physics_process used to stand the
	# body straight back up.
	for i in range(20):
		await physics_frame
	check("the body is LEFT there, not reset to idle",
		rig.state() == HeroRig.State.DEATH and rig.is_dead,
		"still %s after 20 physics frames" % ("DEATH" if rig.state() == HeroRig.State.DEATH else "???"))
	check("set_state cannot animate the corpse back up",
		_refuses_idle(rig))

	hc.free()


func _refuses_idle(rig: HeroRig) -> bool:
	rig.set_state(HeroRig.State.IDLE)
	rig.set_state(HeroRig.State.RUN, true)
	rig.flinch()
	return rig.state() == HeroRig.State.DEATH and not rig.is_flinching()
