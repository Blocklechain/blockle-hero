extends Node3D
# ------------------------------------------------------------------------------
# Can this game be played on a phone?
#
# Everything below was UNREACHABLE on a device before the HUD existed: the four
# actions were bound to KEY_1..KEY_4, there was not one Control node in any of
# the nine scenes, and Play.gd never called setup_combat() — so every button
# played the same attack clip, no cooldown was ever non-zero, and the champion
# had no health to lose. None of that fails a compile and none of it fails the
# combat balance tests, because a game nobody can reach is perfectly
# self-consistent.
#
# So this drives scenes/Play.tscn FOR REAL — one generated region, one rigged
# champion, one enemy — and asserts on what a thumb can actually do:
#
#   1. the pad's geometry AT THE SHIPPING VIEWPORT: four keys over the minimum
#      touch target, none overlapping, none under the shell's "Menu" button
#   2. the champion has a combat body, so the four keys are four DIFFERENT
#      abilities with real Ability.cooldown values behind them
#   3. pressing a key casts, and the key shows the cooldown draining
#   4. a stunned champion's keys read locked, and refuse to fire
#   5. A TAP ON A KEY DOES NOT ALSO WALK THE CHAMPION — pushed through the real
#      input stack, which is the bug this kind of HUD always ships with
#   6. a cast reaches an enemy, and that shows up as a bar over its head and a
#      floating number; a crit is a different number
#   7. the champion's own health bar, status chips and hurt overlay respond
#
# A SCENE rather than a --script harness, because `--script` never opens a
# window: the root viewport comes up 0x0, the stretch transform is degenerate,
# and no pushed input event can be made to land on a Control. Point 5 is the
# whole reason this file exists, so it has to run somewhere input works.
#
#   godot --headless --path . res://tools/HudTest.tscn
# ------------------------------------------------------------------------------

## Frames to wait for a 384 m region to generate on the background thread.
const BUILD_FRAMES: int = 8000
## Frames to wait for one ability animation to finish and resolve.
const CAST_FRAMES: int = 600

## What the HUD's layout is judged against: project.godot's viewport, an iPhone
## at 3x. A headless run gets a square viewport, so asserting on the live nodes
## alone would prove nothing about the phone.
const SHIP_VIEW: Vector2 = Vector2(1170.0, 2532.0)

var fails: int = 0
var _play: Node3D = null
var _hero: HeroController = null
var _hud: Hud = null


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, detail])


func _ready() -> void:
	_the_pad_fits_a_phone()

	var hero: String = _pick_fighter()
	if hero == "":
		check("a rigged Fighter is on the roster", false)
		get_tree().quit(1)
		return
	print("\nchampion '%s' (%s), harness viewport %s" % [hero,
		HeroClass.display_name(HeroClass.for_hero(hero)),
		str(get_viewport().get_visible_rect().size)])

	if not await _boot(hero):
		get_tree().quit(1)
		return

	_the_hud_is_reachable()
	_four_real_actions()
	await _a_key_casts()
	await _a_stun_locks_the_keys()
	await _a_tap_on_a_key_does_not_walk()
	await _an_enemy_reads_as_hurt()
	await _the_champion_reads_as_hurt()

	await _teardown()
	print("\n=== %d failure(s) ===" % fails)
	get_tree().quit(1 if fails > 0 else 0)


## The first rigged Fighter in roster order. A known class rather than whichever
## hero sorts first, so the kit under test is the authored Cleave / Shield Slam /
## Rally and the cooldowns asserted on below are the real published numbers.
func _pick_fighter() -> String:
	for h in HeroRig.animated_heroes():
		if HeroClass.for_hero(h) == HeroClass.Kind.FIGHTER and HeroRig.is_animated(h):
			return h
	return ""


func _boot(hero: String) -> bool:
	var packed: PackedScene = load("res://scenes/Play.tscn") as PackedScene
	if packed == null:
		check("scenes/Play.tscn loads", false)
		return false
	_play = packed.instantiate() as Node3D
	_play.set("hero", hero)
	_play.set("champion_level", 12)
	add_child(_play)

	var waited: int = 0
	while waited < BUILD_FRAMES:
		await get_tree().process_frame
		waited += 1
		_hero = _play.get("_hero") as HeroController
		if _hero != null and _hero.body != null:
			break
	if _hero == null or _hero.body == null:
		check("the region builds and the champion lands in it", false,
			"gave up after %d frames" % waited)
		return false
	_hud = _play.get_node_or_null("Hud") as Hud
	print("  region built in %d frames" % waited)
	return true


# ------------------------------------------------------------------------------
# 1. The pad, measured against the screen it ships on
# ------------------------------------------------------------------------------

func _the_pad_fits_a_phone() -> void:
	print("=== the thumb pad fits a phone (%dx%d) ===" % [SHIP_VIEW.x, SHIP_VIEW.y])
	var pad: Array[Dictionary] = Hud.key_layout(SHIP_VIEW, 40.0)
	check("four keys: attack plus ability_1..3", pad.size() == 4)

	var smallest: float = INF
	var inside: bool = true
	var reachable: bool = true
	var clear_of_menu: bool = true
	# The shell parks its "Menu" button 300 px off the right edge, 80 px down
	# (UiShell._launch). Anything of ours inside that rect is a quit under a thumb.
	var menu := Rect2(SHIP_VIEW.x - 300.0, 80.0, 260.0, float(HeroTheme.TAP))
	for spec in pad:
		var c: Vector2 = spec["centre"]
		var r: float = spec["radius"]
		smallest = minf(smallest, r * 2.0)
		inside = inside and c.x - r >= 0.0 and c.y - r >= 0.0 \
			and c.x + r <= SHIP_VIEW.x and c.y + r <= SHIP_VIEW.y
		# Right-hand half, bottom half: one-handed portrait, with the left of the
		# screen left clear for tap-to-move.
		reachable = reachable and c.x > SHIP_VIEW.x * 0.5 and c.y > SHIP_VIEW.y * 0.5
		clear_of_menu = clear_of_menu and not menu.intersects(
			Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0))
	check("every key clears the 44 pt minimum touch target",
		smallest >= float(HeroTheme.TAP), "smallest %.0f px across" % smallest)
	check("every key is on screen", inside)
	check("the pad is bottom-right, so the left half stays walkable", reachable)
	check("nothing overlaps the shell's Menu button", clear_of_menu)

	# Overlapping rims would send a tap to whichever key was drawn last.
	var tightest: float = INF
	for i in range(pad.size()):
		for j in range(i + 1, pad.size()):
			var gap: float = Vector2(pad[i]["centre"]).distance_to(pad[j]["centre"]) \
				- float(pad[i]["radius"]) - float(pad[j]["radius"])
			tightest = minf(tightest, gap)
	check("no two keys overlap", tightest > 0.0,
		"%.0f px between the closest rims" % tightest)


# ------------------------------------------------------------------------------
# ...and the live HUD is wired into the scene
# ------------------------------------------------------------------------------

func _the_hud_is_reachable() -> void:
	print("\n=== the HUD is in the scene ===")
	check("scenes/Play.tscn declares a Hud", _hud != null)
	if _hud == null:
		return
	check("it draws above the world, below the shell's overlay",
		_hud.layer > 0 and _hud.layer < 10, "layer %d" % _hud.layer)
	check("the keys were built", _hud._keys.size() == 4)

	# A key is a circle, so the dead space inside the arc has to fall through to
	# the world — the pad is mostly empty space and treating it as a solid block
	# would steal a sixth of the screen from tap-to-move.
	var basic: Hud.AbilityKey = _hud._keys[0]
	var centre: Vector2 = basic.position + basic.size * 0.5
	check("the HUD claims the point under a key",
		_hud.blocks_point(centre))
	check("the gaps between keys are not swallowed",
		not _hud.blocks_point(centre + Vector2(0.0, -Hud.ARC_RADIUS * 0.5)))


# ------------------------------------------------------------------------------
# 2. Four DIFFERENT actions, with real cooldowns
# ------------------------------------------------------------------------------

func _four_real_actions() -> void:
	print("\n=== the four actions are four different things ===")
	check("the champion has a combat body", _hero.body != null,
		"%s, %.0f hp" % [_hero.body.display_name, _hero.body.max_health])
	check("basic attack exists", _hero.basic != null)
	check("exactly three abilities", _hero.abilities.size() == 3)

	var titles: Array[String] = []
	var states: Array[int] = []
	var cooldowns: Array[float] = []
	for slot in range(4):
		var ab: Ability = _hero.ability_in_slot(slot)
		titles.append(ab.title if ab != null else "")
		states.append(ab.anim_state() if ab != null else -1)
		cooldowns.append(ab.cooldown if ab != null else -1.0)
	check("four distinct actions", _distinct(titles), ", ".join(titles))
	check("each drives its own rig clip", states == [HeroRig.State.ATTACK,
		HeroRig.State.ABILITY_1, HeroRig.State.ABILITY_2, HeroRig.State.ABILITY_3],
		str(states))
	check("every key carries a real cooldown",
		cooldowns.all(func(c: float) -> bool: return c > 0.0),
		"%.2f / %.0f / %.0f / %.0f s" % [cooldowns[0], cooldowns[1],
			cooldowns[2], cooldowns[3]])

	var labelled: bool = true
	for k in _hud._keys:
		labelled = labelled and k.title == titles[k.slot]
	check("each key is labelled with the ability it casts", labelled)


func _distinct(items: Array[String]) -> bool:
	var seen: Dictionary = {}
	for i in items:
		if seen.has(i):
			return false
		seen[i] = true
	return true


# ------------------------------------------------------------------------------
# 3. Pressing a key casts, and the key shows it cooling
# ------------------------------------------------------------------------------

func _a_key_casts() -> void:
	print("\n=== a key press casts, and the cooldown is visible ===")
	var key: Hud.AbilityKey = _hud._keys[1]
	var ab: Ability = _hero.ability_in_slot(1)
	var seen: Array[int] = []
	_hero.ability_used.connect(func(slot: int) -> void: seen.append(slot))

	# Through the key's own signal, so the whole chain is exercised:
	# key -> Hud.action -> Play._use -> HeroController.use_ability.
	key.fired.emit(1)
	await get_tree().process_frame
	check("the press reaches the controller", seen == [1], str(seen))
	check("the champion is committed to the cast", _hero.is_busy())
	# Within a frame of the published figure — a tick of _physics_process has
	# already come off it, which is the point: the HUD reads the live countdown
	# and does not keep a number of its own.
	check("the cooldown started at the ability's own value",
		_hero.cooldown_left(1) > ab.cooldown - 0.2
			and _hero.cooldown_left(1) <= ab.cooldown,
		"%.2f of %.1f s" % [_hero.cooldown_left(1), ab.cooldown])

	await get_tree().physics_frame
	await get_tree().process_frame
	check("the key draws a sweep", key._cd_frac > 0.0 and key._cd_frac <= 1.0,
		"%.0f%% remaining" % (key._cd_frac * 100.0))
	check("the key counts the wait down", key._timer.visible,
		"reads '%s'" % key._timer.text)
	check("a key on cooldown refuses a second press",
		not _hero.use_ability(1))

	# Let the swing land so the champion is free again.
	var guard: int = 0
	while _hero.is_busy() and guard < CAST_FRAMES:
		await get_tree().process_frame
		guard += 1
	check("the cast completes and the champion is free", not _hero.is_busy(),
		"%d frames" % guard)


# ------------------------------------------------------------------------------
# 4. The stun, which is the game's core control effect and was invisible
# ------------------------------------------------------------------------------

func _a_stun_locks_the_keys() -> void:
	print("\n=== a stunned champion reads as locked out ===")
	_hero.body.apply(StatusEffect.make(StatusEffect.Kind.STUN, 3.0, 0.0, "test"))
	await get_tree().process_frame
	check("the champion is stunned", _hero.is_stunned())

	var locked: bool = true
	for k in _hud._keys:
		locked = locked and k._locked
	check("all four keys read locked", locked)
	check("the lock-out is spelled out", _hud._locked_banner.visible,
		"'%s'" % _hud._locked_banner.text)
	check("a status chip is up for the stun",
		(_hud._chip_panels[StatusEffect.Kind.STUN] as PanelContainer).visible,
		"'%s'" % (_hud._chips[StatusEffect.Kind.STUN] as Label).text)
	check("pressing a key does nothing while stunned",
		not _hero.use_ability(2))

	# Ticked off through the controller, which is what the game does.
	var guard: int = 0
	while _hero.is_stunned() and guard < 600:
		await get_tree().physics_frame
		guard += 1
	await get_tree().process_frame
	var freed: bool = true
	for k in _hud._keys:
		freed = freed and not k._locked
	check("the keys come back when the stun ends", freed and not _hero.is_stunned())


# ------------------------------------------------------------------------------
# 5. THE TAP-THROUGH BUG
# ------------------------------------------------------------------------------

func _a_tap_on_a_key_does_not_walk() -> void:
	print("\n=== a tap on a key must never also move the champion ===")
	var key: Hud.AbilityKey = _hud._keys[0]
	var on_key: Vector2 = key.position + key.size * 0.5

	# Open ground: project the champion's own surroundings back to the screen, so
	# the point is guaranteed to be over terrain the camera can see. Metres, kept
	# small — the camera is 25 m out through a 38 degree lens, so three metres is
	# already most of a thousand pixels, and a point off the edge of the window is
	# a point no pushed touch event can land on.
	var cam: ArpgCamera = _play.get("_cam") as ArpgCamera
	var screen := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	var open: Vector2 = Vector2.INF
	for offset in [Vector3(3, 0, 3), Vector3(-3, 0, -3), Vector3(3, 0, -3),
			Vector3(-3, 0, 3), Vector3(2, 0, 0), Vector3(0, 0, 2)]:
		var p: Vector2 = cam.unproject_position(_hero.position + offset)
		if _hud.blocks_point(p) or not screen.has_point(p):
			continue
		_hero.stop()
		_play.call("_order_move", p)
		if _hero.is_moving():
			open = p
			break
	check("a tap on open ground walks the champion", open != Vector2.INF,
		"at %s" % str(open))

	_hero.stop()
	_play.call("_order_move", on_key)
	check("a move order aimed at a key is refused outright",
		not _hero.is_moving())

	# And now through the real input stack, which is the only version of this
	# check that would have caught the bug: the key consumes its own press, so
	# Play.gd's _unhandled_input never sees it.
	#
	# Asserted BETWEEN the press and the release, because the release clears the
	# hold either way — a gesture examined only after it ended cannot tell a
	# guarded press from an unguarded one.
	_hero.stop()
	await _touch(on_key, true)
	check("the tap fired the basic attack",
		_hero.is_busy() or _hero.cooldown_left(0) > 0.0,
		"busy=%s cd=%.2f" % [str(_hero.is_busy()), _hero.cooldown_left(0)])
	check("...and issued no walk order at all",
		_hero.path_points().is_empty(),
		"%d waypoints" % _hero.path_points().size())
	check("...and the champion is not being steered",
		not bool(_play.get("_holding")))
	await _touch(on_key, false)

	# The swing has to finish first: a champion committed to an animation refuses
	# movement orders by design (HeroController.move_to), so testing the tap
	# before the recovery ends would assert the wrong rule.
	var swing: int = 0
	while _hero.is_busy() and swing < CAST_FRAMES:
		await get_tree().process_frame
		swing += 1

	# The other half of the rule: a tap on open ground must STILL walk when the
	# HUD is up, or the guard has simply eaten the game's only movement control.
	_hero.stop()
	await _touch(open, true)
	check("a real tap on open ground still walks", _hero.is_moving(),
		"%d waypoints" % _hero.path_points().size())
	await _touch(open, false)
	check("lifting the finger stops the steering",
		not bool(_play.get("_holding")))

	_hero.stop()
	var guard: int = 0
	while _hero.is_busy() and guard < CAST_FRAMES:
		await get_tree().process_frame
		guard += 1


## Half a gesture, pushed through Input the way a finger does.
##
## The position is converted out of canvas space first: a touch arrives in
## window coordinates and the viewport's stretch transform (canvas_items, see
## project.godot) maps it onto the 1170-wide canvas the HUD was laid out in.
## Feeding canvas coordinates straight in lands the tap thousands of pixels off
## screen, and every assertion then passes for the wrong reason.
func _touch(at: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 0
	e.position = get_viewport().get_final_transform() * at
	e.pressed = pressed
	Input.parse_input_event(e)
	# Parsed events are delivered at the top of the next frame, and the
	# viewport's GUI pass runs before _unhandled_input.
	await get_tree().process_frame
	await get_tree().process_frame


# ------------------------------------------------------------------------------
# 6. An enemy reads as hurt
# ------------------------------------------------------------------------------

func _an_enemy_reads_as_hurt() -> void:
	print("\n=== hitting something shows up on it ===")
	# A dummy with no agility, so it cannot dodge the one swing this test gets.
	var node := Node3D.new()
	_play.add_child(node)
	var here: Vector2 = _hero.ground_position()
	var facing: float = _hero.rotation.y
	var ahead: Vector2 = here + Vector2(sin(facing), cos(facing)) * 1.6
	node.global_position = Vector3(ahead.x, _hero.position.y, ahead.y)

	var body: Combatant = Combatant.make("Target", Combatant.Team.ENEMY, 12,
		Stats.make(10.0, 0.0, 0.0, 10.0), HeroClass.School.MELEE, 0.0, 0.0, 99)
	_play.call("add_enemy", body, node)
	await get_tree().process_frame
	check("the HUD is tracking it", _hud._tracked.size() == 1)
	check("an untouched enemy carries no bar",
		not (_hud._tracked[0].bar as ProgressBar).visible)

	var full: float = body.health
	var floats_before: int = _hud._floats.size()
	# The tap in the previous check put the basic attack on its 0.65 s cooldown.
	var cooling: int = 0
	while _hero.cooldown_left(0) > 0.0 and cooling < CAST_FRAMES:
		await get_tree().physics_frame
		cooling += 1
	_hud._keys[0].fired.emit(0)
	var guard: int = 0
	while _hero.is_busy() and guard < CAST_FRAMES:
		await get_tree().process_frame
		guard += 1
	await get_tree().process_frame

	check("the swing reached it", body.health < full,
		"%.0f -> %.0f of %.0f" % [full, body.health, body.max_health])
	check("a bar appeared over its head",
		(_hud._tracked[0].bar as ProgressBar).visible
			and (_hud._tracked[0].bar as ProgressBar).value < 1.0,
		"%.0f%%" % ((_hud._tracked[0].bar as ProgressBar).value * 100.0))
	check("the bar is positioned over the enemy, on screen",
		Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size).has_point(
			(_hud._tracked[0].bar as ProgressBar).position))
	check("a damage number floated off it",
		_hud._floats.size() > floats_before,
		"%d in flight" % _hud._floats.size())

	# Crits have to be a different SHAPE, not just a different colour: bigger
	# and marked, because colour alone does not survive a burning biome at arm's
	# length. Driven directly, since a crit cannot be waited for.
	_hud.call("_number_at", node.global_position, 120.0, true, false)
	_hud.call("_number_at", node.global_position, 120.0, false, false)
	var crit: Label = (_hud._floats[_hud._floats.size() - 2] as Hud.FloatingNumber).label
	var plain: Label = (_hud._floats[_hud._floats.size() - 1] as Hud.FloatingNumber).label
	check("a crit is drawn bigger than a normal hit",
		crit.get_theme_font_size("font_size") > plain.get_theme_font_size("font_size"),
		"%d vs %d px" % [crit.get_theme_font_size("font_size"),
			plain.get_theme_font_size("font_size")])
	check("a crit is marked, not merely coloured", crit.text.ends_with("!"),
		"'%s' vs '%s'" % [crit.text, plain.text])

	# And death clears up after itself rather than leaving a bar in the air.
	body._take_raw(body.max_health * 2.0, false, "test")
	check("the kill registered", not body.alive)
	var waited: float = 0.0
	while _hud._tracked.size() > 0 and waited < 4.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	check("the bar is cleared once the enemy is dead",
		_hud._tracked.is_empty(), "after %.1fs" % waited)


# ------------------------------------------------------------------------------
# 7. The champion's own state
# ------------------------------------------------------------------------------

func _the_champion_reads_as_hurt() -> void:
	print("\n=== the player's own bar and overlay ===")
	check("the plate is up", _hud._plate.visible)
	check("the health bar starts full",
		is_equal_approx(_hud._hp_bar.value, 1.0))

	var floats_before: int = _hud._floats.size()
	_hero.body._take_raw(_hero.body.max_health * 0.4, false, "test")
	await get_tree().process_frame
	check("the bar drops with the champion's health",
		absf(_hud._hp_bar.value - _hero.body.health_fraction()) < 0.01,
		"%.0f%%  '%s'" % [_hud._hp_bar.value * 100.0, _hud._hp_text.text])
	check("the numbers read out in hit points",
		_hud._hp_text.text.contains("/"))
	check("damage taken floats off the champion too",
		_hud._floats.size() > floats_before)
	check("the screen edges flash on being hit", _hud._vignette._k > 0.0,
		"%.2f" % _hud._vignette._k)

	# A shield is health the player HAS; it has to show on the health line or a
	# warded champion reads as being on the brink.
	_hero.body.apply(StatusEffect.make(StatusEffect.Kind.SHIELD, 8.0, 40.0, "test"))
	await get_tree().process_frame
	check("a shield is reported on the health line",
		_hud._hp_text.text.contains("shielded"), "'%s'" % _hud._hp_text.text)
	check("and as a status chip",
		(_hud._chip_panels[StatusEffect.Kind.SHIELD] as PanelContainer).visible)


# ------------------------------------------------------------------------------

## Audio's voice pool and stream cache are STATIC, so a cue still ringing when
## quit() lands is reported as a leaked instance. Tidied the same way
## tools/feedbacktest.gd does it — a check that ends in a leak warning is a check
## people learn to ignore.
func _teardown() -> void:
	if _play != null:
		remove_child(_play)
		_play.free()
		_play = null
	var node: Audio = Audio.boot(self)
	if node != null and is_instance_valid(node):
		node.free()
	Audio._node = null
	Audio._streams.clear()
	for i in range(30):
		await get_tree().process_frame
