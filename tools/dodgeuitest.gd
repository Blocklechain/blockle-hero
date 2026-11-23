extends SceneTree
# ------------------------------------------------------------------------------
# THE ROLL KEY IS ACTUALLY REACHABLE, AND ACTUALLY ROLLS.
#
# tools/dodgetest.gd proves HeroController.dodge() works. That is not the same
# claim as "the player can roll", and this project has shipped the gap five
# times: record_map_cleared, quests, partners, training and the IAP store were
# each built, tested, and connected to nothing. A dodge() with no button is the
# sixth of those.
#
# So this file asserts the two things a unit test cannot see:
#
#   1. THE KEY IS WHERE A THUMB CAN REACH IT. Joystick.claims() swallows any
#      touch in the left 42% of the screen and Play.gd asks the stick FIRST, so
#      a roll key whose edge crosses that line has a dead side that silently
#      walks the champion instead of rolling. Two overlapping circles have the
#      same problem: the tap goes to whichever was drawn last.
#   2. PRESSING IT MOVES THE CHAMPION. Not "emits a signal" — the displacement,
#      measured, with the press delivered as a real touch through the real
#      input stack.
#
# Checked against the SHIPPING viewport (1170x2532), because a headless run gets
# a square window and a layout asserted only against that proves nothing about
# the phone — the same reason Hud.key_layout is a static function.
# ------------------------------------------------------------------------------

const HC := preload("res://scripts/game/HeroController.gd")

## project.godot's viewport. Hard-coded on purpose: if someone changes the window
## size the geometry below has to be re-derived, and silently following the new
## value would hide that.
const SHIP_VIEW := Vector2(1170.0, 2532.0)
const SHIP_INSET: float = 40.0

var _fails: int = 0
var _ran: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-56s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _init() -> void:
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_size = Vector2i(SHIP_VIEW)
	get_root().size = Vector2i(SHIP_VIEW)
	await process_frame

	_geometry(); _ran += 1
	await _it_exists_on_screen(); _ran += 1
	await _pressing_it_rolls(); _ran += 1
	print("")
	check("every section ran to completion", _ran == 3, "%d of 3" % _ran)
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


func _geometry() -> void:
	print("\n=== the roll key clears the stick and the ability keys ===")
	var roll: Dictionary = Hud.dodge_key_layout(SHIP_VIEW, SHIP_INSET)
	var c: Vector2 = roll["centre"]
	var r: float = float(roll["radius"])

	check("the roll key has its own slot", int(roll["slot"]) == Hud.DODGE_SLOT,
		"slot %d" % int(roll["slot"]))

	# 1. THE STICK. Its claim is a band, not a circle, so the key's LEFT EDGE is
	# what matters — a centre that clears it is not enough.
	var stick_edge: float = SHIP_VIEW.x * Joystick.ZONE_W
	check("its left edge clears the joystick's summoning zone",
		c.x - r > stick_edge,
		"edge %.0f px vs zone %.0f px" % [c.x - r, stick_edge])

	# 2. THE FOUR ABILITY KEYS.
	var worst: float = 1e9
	var worst_slot: int = -1
	for spec in Hud.key_layout(SHIP_VIEW, SHIP_INSET):
		var gap: float = c.distance_to(spec["centre"]) - r - float(spec["radius"])
		if gap < worst:
			worst = gap
			worst_slot = int(spec["slot"])
	check("it does not overlap any ability key", worst > 0.0,
		"closest is slot %d with %.0f px to spare" % [worst_slot, worst])

	# 3. ON THE SCREEN AT ALL. A key placed off the top or past an edge is
	# unreachable in a way that looks fine in every log.
	check("the whole key is on screen",
		c.x - r >= 0.0 and c.y - r >= 0.0
			and c.x + r <= SHIP_VIEW.x and c.y + r <= SHIP_VIEW.y,
		"centre (%.0f, %.0f) r %.0f" % [c.x, c.y, r])

	# 4. REACHABLE BY A THUMB. The far corner of a 2532 px screen is on-screen
	# and still unusable one-handed; the keys exist in the bottom third for that
	# reason, and the roll is pressed mid-fight like the rest.
	check("...and in the bottom half, where the thumb already is",
		c.y > SHIP_VIEW.y * 0.5,
		"%.0f px down a %.0f px screen" % [c.y, SHIP_VIEW.y])


## Boot the real HUD against a real champion.
func _live() -> Dictionary:
	var hud := Hud.new()
	root.add_child(hud)
	await process_frame

	var seed: int = 31337
	var plan: Layout = Terrain.plan_for(Terrain.Kind.ARENA, seed,
		Vector2(96, 96) * 0.5, Layout.Sym.ASYMMETRIC, 7)
	var ter: Terrain = Terrain.generate(seed, "greenwood", 96, 0.5, plan)
	var path := Pathing.new(ter)
	var at: Vector2 = path.nearest_walkable_centre(
		plan.node_of_kind(Layout.ENTRY).get("pos", Vector2.ZERO))

	var who: String = HeroRig.animated_heroes()[0]
	var hero: HeroController = HC.new()
	root.add_child(hero)
	if not hero.setup(ter, who, at):
		return {}
	hero.setup_combat(Combat.champion_body(null, who, 10,
		Rng.seed_of(seed, who), who), HeroClass.for_hero(who), who)
	hud.bind_champion(hero, null)
	await process_frame
	return {"hud": hud, "hero": hero}


func _it_exists_on_screen() -> void:
	print("\n=== the key is built, visible and live ===")
	var l: Dictionary = await _live()
	if l.is_empty():
		check("the HUD bound to a champion", false)
		return
	var hud: Hud = l["hud"]
	var key = hud.get("_dodge_key")

	check("the roll key was built", key != null)
	if key == null:
		hud.queue_free()
		(l["hero"] as Node).queue_free()
		return
	check("...and is visible once a champion is bound", bool(key.visible))
	check("...and is labelled for the player", String(key.title) != "",
		"\"%s\"" % String(key.title))

	# The tap-through guard. A press on the roll key must not ALSO be read as a
	# walk order, or the champion rolls and then strolls back.
	var centre: Vector2 = key.position + Vector2(key.radius, key.radius)
	check("the HUD claims the point under it, so it cannot also walk",
		hud.blocks_point(centre))

	# And the four ability keys are untouched by its arrival.
	check("the four ability keys are still four",
		(hud.get("_keys") as Array).size() == 4,
		"%d keys" % (hud.get("_keys") as Array).size())

	hud.queue_free()
	(l["hero"] as Node).queue_free()


func _pressing_it_rolls() -> void:
	print("\n=== pressing it moves the champion ===")
	var l: Dictionary = await _live()
	if l.is_empty():
		check("the HUD bound to a champion", false)
		return
	var hud: Hud = l["hud"]
	var hero: HeroController = l["hero"]

	# Play.gd is what connects the key to the champion in the game. Reproduced
	# here rather than booting the whole region: the claim under test is that
	# the SIGNAL carries a press to a roll, and Play's handler is one line.
	hud.dodge_pressed.connect(func() -> void: hero.dodge(Vector2.ZERO))

	var key = hud.get("_dodge_key")
	if key == null:
		check("there is a key to press", false)
		hud.queue_free(); hero.queue_free()
		return

	var before: Vector2 = hero.ground_position()

	# A REAL TOUCH, through the real input stack, at the key's real centre —
	# not key.fired.emit(). A key that is built, visible and wired can still be
	# covered by something, or have mouse_filter wrong, and only a delivered
	# event finds that.
	var centre: Vector2 = key.position + Vector2(key.radius, key.radius)
	await _touch(centre, true)
	await _touch(centre, false)

	# Until the roll ENDS, for the same reason dodgetest does: a fixed frame
	# count is a different amount of simulated time on every machine, and a
	# roll measured mid-flight reads as a roll that barely moved.
	var spin: int = 0
	while bool(hero.get("_dodging")) and spin < 600:
		await process_frame
		spin += 1
	var moved: float = before.distance_to(hero.ground_position())
	check("A TOUCH ON THE KEY ROLLED THE CHAMPION",
		moved > HC.DODGE_DISTANCE * 0.5, "%.2f m" % moved)

	hud.queue_free()
	hero.queue_free()


## Half a gesture, pushed through Input the way a finger does.
##
## THE POSITION IS CONVERTED OUT OF CANVAS SPACE FIRST. A touch arrives in window
## coordinates and the viewport's canvas_items stretch transform maps it onto the
## 1170-wide canvas the HUD was laid out in. Feeding canvas coordinates straight
## in lands the tap thousands of pixels off screen — which is exactly what the
## first version of this file did, and it reported the roll key dead when the
## key was fine.
func _touch(at: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 0
	e.position = get_root().get_final_transform() * at
	e.pressed = pressed
	Input.parse_input_event(e)
	# Parsed events are delivered at the top of the next frame, and the
	# viewport's GUI pass runs before _unhandled_input.
	await process_frame
	await process_frame
