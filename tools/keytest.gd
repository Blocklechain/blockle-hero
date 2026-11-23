extends SceneTree
# ------------------------------------------------------------------------------
# A REAL TOUCH ON A REAL ABILITY KEY, IN THE REAL SCENE, ACTUALLY ATTACKS.
#
# THE SEAM NOTHING COVERED. tools/hudtest.gd emits AbilityKey.fired directly;
# tools/dodgeuitest.gd delivers a real touch but to the roll key, in a HUD with
# no Play and no joystick. So the path a player's thumb actually travels —
#
#   touch -> Viewport GUI pick -> AbilityKey._gui_input -> fired
#         -> Hud._on_key_fired -> Hud.action -> Play._on_hud_action
#         -> Play._use -> Play._aim_point -> HeroController.use_ability
#
# — was asserted at neither end. A bug anywhere along it reads to a player as
# "the game ignores my taps", which is the single worst thing a phone ARPG can
# do, and the one thing no existing harness would have noticed.
#
# EVERY STAGE IS CHECKED SEPARATELY, because "the tap did nothing" has at least
# six distinct causes and they need telling apart: the key never got the event,
# the key got it and did not emit, the HUD swallowed it, Play never forwarded
# it, use_ability refused, or it fired and the damage went nowhere.
#
# THE CHAMPION IS MADE INVULNERABLE FOR THE DURATION, and that is not laziness.
# Three attempts at this test in a live region failed for reasons that had
# nothing to do with input: twice the slots were still on cooldown from an
# earlier section, and once the champion was quietly killed by the ten enemies
# it was standing among while the test waited out a cooldown — reporting
# "ability_used=NO" for slots 2 and 3 when the real cause was `dead=true`. A
# test whose subject can die mid-assertion measures the encounter, not the
# input.
# ------------------------------------------------------------------------------

## Populated, so the aim path has real enemies to resolve against — _aim_point
## picks the nearest target in range, and an empty region would never exercise
## it.
const REGION: int = 37

var fails: int = 0
var _ran: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, detail])
	if not ok:
		fails += 1


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	# THE SHIPPING VIEWPORT, 2532x1170 LANDSCAPE (project.godot). Without this
	# the root window is square and the HUD lays its keys out against a screen
	# that does not exist — the first draft of this harness pressed y=2308 on a
	# 1170-tall screen and learned nothing.
	var design := Vector2i(2532, 1170)
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_size = design
	get_root().size = design
	await process_frame

	var account: Roster = Roster.create(HeroRig.animated_heroes())
	var who: String = String(account.owned.keys()[0])
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

	var f: int = 0
	while f < 2400 and play.get("_hero") == null:
		await process_frame
		f += 1
	var me: HeroController = play.get("_hero")
	check("the region came up with a champion", me != null, who)
	if me == null:
		_done()
		return

	# Let the opening flyover hand the region over, the way a player waits.
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 6000 and bool(play.get("_flying")):
		await process_frame
	check("the flyover handed over", not bool(play.get("_flying")))

	var hud = play.get("_hud")
	check("the HUD is there with its four keys",
		hud != null and (hud.get("_keys") as Array).size() == 4)
	if hud == null:
		_done()
		return

	# UNKILLABLE *AND* UNSTUNNABLE, so a dropped tap cannot be confused with a
	# champion the region took away.
	#
	# `invulnerable` only stops DAMAGE — it is checked in strike() and
	# take_hit(). A stun arrives by a different road: Combat.cast applies the
	# rider through Combatant.apply(), which never consults it. So an
	# invulnerable champion standing in a pack of ten still gets stunned, and
	# use_ability refuses while stunned. That is what turned this very test red
	# in CI on slot 3 while it passed here (build 49): the readiness check saw
	# `stunned=false`, and a stun landed in the frames between that and the
	# touch.
	#
	# Fourth time the live region has interfered with a test of mine this
	# session. The subject of an INPUT test must be immovable by anything the
	# encounter does.
	me.body.invulnerable = true
	_quiesce(me)

	var keyed: Array = []
	var acted: Array = []
	var used: Array = []
	for k in (hud.get("_keys") as Array):
		k.fired.connect(func(s: int) -> void: keyed.append(s))
	hud.action.connect(func(s: int) -> void: acted.append(s))
	me.ability_used.connect(func(s: int) -> void: used.append(s))

	for k in (hud.get("_keys") as Array):
		await _press(me, hud, k, keyed, acted, used)
		_ran += 1

	check("every slot was exercised", _ran == 4, "%d of 4" % _ran)
	me.body.invulnerable = false
	play.queue_free()
	await process_frame
	_done()


func _press(me: HeroController, hud, k, keyed: Array, acted: Array,
		used: Array) -> void:
	print("\n=== slot %d: %s ===" % [k.slot,
		me.ability_in_slot(k.slot).title
			if me.ability_in_slot(k.slot) != null else "<none>"])

	# A FAIR PRESS. Wait out the previous cast and this slot's own cooldown,
	# because use_ability refuses both and neither is an input bug.
	# 30 s of headroom, not 20. Rally's cooldown measured 14.5 s and the
	# previous cast's recovery sits on top of it; a runner that is slower than
	# this laptop should not be able to turn a cooldown into a failure.
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 30000 \
			and (me.is_busy() or me.cooldown_left(k.slot) > 0.0):
		await physics_frame
	check("the slot is ready to press", not me.is_busy()
		and me.cooldown_left(k.slot) <= 0.0,
		"busy=%s cd=%.2f" % [me.is_busy(), me.cooldown_left(k.slot)])
	check("...and the champion is alive and able to act",
		not me.is_dead() and not me.is_stunned(),
		"dead=%s stunned=%s" % [me.is_dead(), me.is_stunned()])

	# STANDING STILL, which is the case the player reported — and re-quietened
	# immediately before the press, because the wait above can be fifteen
	# seconds of a pack swinging at the champion.
	me.drive(Vector2.ZERO)
	_quiesce(me)
	await physics_frame
	_quiesce(me)

	var centre: Vector2 = k.position + Vector2(k.radius, k.radius)
	check("the key is visible and owns its own centre",
		bool(k.visible) and k.get_global_rect().has_point(centre),
		str(k.get_global_rect()))

	var nk: int = keyed.size()
	var na: int = acted.size()
	var nu: int = used.size()
	await _touch(centre, true)
	await _touch(centre, false)

	# EACH STAGE NAMED, so a regression says WHERE it broke rather than that
	# the tap did nothing.
	check("the touch reached the key (fired)", keyed.size() > nk)
	check("...the HUD reported the action", acted.size() > na)
	check("...and the champion used the ability", used.size() > nu,
		"slot %d" % k.slot)


## Take the encounter out of the question: clear any control effect on the
## champion and hold stun immunity open for longer than this harness runs.
##
## Uses the real Combatant.stun_immunity rather than a test-only hook, so what
## is being leaned on is a mechanism the game itself has.
func _quiesce(me: HeroController) -> void:
	if me.body == null:
		return
	me.body.stun_immunity = 600.0
	var keep: Array[StatusEffect] = []
	for e in me.body.effects:
		if e.kind != StatusEffect.Kind.STUN \
				and e.kind != StatusEffect.Kind.SLOW:
			keep.append(e)
	me.body.effects = keep


## Half a gesture, through Input, the way a thumb does.
##
## Converted out of canvas space first: a touch arrives in WINDOW coordinates
## and the canvas_items stretch transform maps it onto the 2532-wide canvas the
## HUD laid itself out in. Feeding canvas coordinates straight in lands the tap
## off screen and every assertion then fails for the wrong reason.
func _touch(at: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 0
	e.position = get_root().get_final_transform() * at
	e.pressed = pressed
	Input.parse_input_event(e)
	await process_frame
	await process_frame


func _done() -> void:
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
