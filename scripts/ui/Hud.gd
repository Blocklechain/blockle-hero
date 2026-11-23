class_name Hud
extends CanvasLayer
# ------------------------------------------------------------------------------
# THE IN-GAME HUD, and the only way to play this game on a phone.
#
# Before this existed the four actions were bound to KEY_1..KEY_4 and touch did
# nothing but walk, so on the device the champion could not attack at all. An
# iOS-only ARPG whose abilities are on a keyboard is not a hard game, it is a
# broken one, and no amount of combat balance underneath is reachable.
#
# WHAT IS ON SCREEN, and why it is where it is:
#
#   bottom RIGHT   four round keys — basic attack plus ability_1..3 — in a thumb
#                  arc around the attack key. Right-handed-thumb reachable in
#                  portrait, and deliberately NOT centred: the left half of the
#                  screen stays clear because that is where tap-to-move happens.
#   top LEFT       the champion plate: name, class, health, active statuses. Left,
#                  because UiShell parks its "Menu" button in the top right and
#                  two panels fighting over that corner is how a player ends up
#                  quitting the region by accident.
#   over an enemy  a compact health bar, shown while it is hurt or being hurt.
#   anywhere       floating damage numbers, crits twice the size and gold.
#
# THE TAP-THROUGH RULE, which is the bug this kind of HUD always ships with:
# a finger that lands on a key must cast and MUST NOT also order a walk. Two
# independent guards, because they fail in different ways:
#
#   1. each key is a Control with mouse_filter STOP that calls accept_event(),
#      so the press never reaches Play.gd's _unhandled_input at all; and
#   2. `blocks_point()` is a geometric test Play.gd asks before it issues any
#      move order, which still holds if the event ever arrives by another route
#      (iOS emulates a mouse from touch, and the emulated event is a second
#      event with its own path through the input stack).
#
# Guard 1 alone is the one everybody writes, and it is the one that stops working
# the day the input path changes under you.
#
# NO NODES, NO SCENES, NO ART: built in code like the rest of the shell (see
# UiShell.gd) and drawn from polygons like UiGlyph, because this project ships no
# 2D textures and no emoji in UI text.
# ------------------------------------------------------------------------------

## Above the 3D world, below UiShell's Overlay (layer 10) so the shell's toast
## and its "Menu" button stay reachable while the HUD owns the screen.
const LAYER: int = 5

# --- the thumb arc ------------------------------------------------------------
# Viewport pixels; the viewport is 1170x2532 (an iPhone at 3x), so these are
# about 100 pt and 79 pt across. Both are far over Apple's 44 pt minimum because
# they are pressed while the other thumb is steering and the hand is moving.
const KEY_R_BASIC: float = 150.0
const KEY_R_ABILITY: float = 118.0
## Centre-to-centre from the attack key out to the three abilities. Wide enough
## that no two keys touch: the three abilities are 45 degrees apart on this arc,
## which puts 275 px between their centres against a 236 px diameter. Tighten it
## and the rims overlap, and a tap in the overlap goes to whichever key happens
## to be drawn last — a cleave where the player asked for a stun.
const ARC_RADIUS: float = 360.0
## Where the three abilities sit on that arc: straight up, up-left, left. The
## order runs away from the attack key, so ability_3 — the self/escape slot — is
## the furthest and least likely to be hit by accident.
const ARC_ANGLES: PackedFloat32Array = [-90.0, -135.0, -180.0]
const PAD_MARGIN: float = 40.0

## ---- THE ROLL KEY -----------------------------------------------------------
##
## Its own key on its own ring, NOT a fifth seat on the ability arc, and the
## geometry is forced by two things it must not touch:
##
##   * THE JOYSTICK ZONE. Joystick.claims() takes any touch in the left
##     Joystick.ZONE_W (42%) of the screen, and Play.gd asks the stick first —
##     so a roll key whose EDGE reaches into that band has a dead side. This is
##     why it cannot go near the thumb that steers, which is otherwise where a
##     movement verb belongs.
##   * THE FOUR ABILITY KEYS. Two circles overlap unless their centres are more
##     than the sum of their radii apart.
##
## -112.5 degrees at 620 px sits above the arc, between ability_1 and
## ability_2's headings and well outboard of both. tools/dodgeuitest.gd checks
## both clearances against the SHIPPING viewport rather than trusting these
## numbers, because every one of them is a guess that a later layout change can
## quietly invalidate.
const DODGE_SLOT: int = 4
const ROLL_ANGLE: float = -112.5
const ROLL_RADIUS: float = 620.0

# --- floating numbers --------------------------------------------------------
const NUM_LIFE: float = 0.95
const NUM_RISE: float = 170.0
## Fanned sideways so two hits in the same instant are two readable numbers
## rather than one bold blur.
const NUM_FAN: float = 62.0

## How long an enemy's bar stays up after the last hit. Long enough to read the
## result of a cleave, short enough that a wandering survivor is not labelled
## for the rest of the region.
const ENEMY_BAR_HOLD: float = 2.6
## And how long a dead one's empty bar lingers, so a kill is confirmed rather
## than the bar simply vanishing at the same moment the body does.
const ENEMY_BAR_DEATH: float = 1.0
const ENEMY_BAR_SIZE: Vector2 = Vector2(190.0, 16.0)
## Metres above the enemy's origin. Heroes normalise to 1.85 m (HeroRig), so this
## sits the bar just clear of the tallest head.
const ENEMY_BAR_LIFT: float = 2.15

## How long a one-off line of text stays up before it fades itself out.
const MESSAGE_LIFE: float = 6.0

const STATUS_COLOUR: Dictionary = {
	StatusEffect.Kind.STUN: HeroTheme.DANGER,
	StatusEffect.Kind.SLOW: HeroTheme.GEM,
	StatusEffect.Kind.HASTE: HeroTheme.ACCENT,
	StatusEffect.Kind.SHIELD: HeroTheme.GOLD,
	StatusEffect.Kind.BURN: Color("ff8f6b"),
	StatusEffect.Kind.WEAKEN: HeroTheme.CRYSTAL,
}

## Fired when a key is pressed. Play.gd owns what an action MEANS — the HUD only
## reports that a thumb landed on slot n.
signal action(slot: int)

## A thumb landed on the roll key. Separate from action() because a roll is not
## an ability: it has no slot in the kit, no Ability record and its own cooldown.
signal dodge_pressed

var _champion: HeroController = null
var _camera: Camera3D = null

var _root: Control
var _world_bars: Control
var _numbers: Control
var _vignette: Vignette
var _plate: PanelContainer
var _name: Label
var _class: Label
var _hp_bar: ProgressBar
var _hp_text: Label
var _status_row: HBoxContainer
var _chips: Dictionary = {}                 # StatusEffect.Kind -> Label
var _chip_panels: Dictionary = {}           # StatusEffect.Kind -> PanelContainer
var _message: Label
var _message_left: float = 0.0
var _locked_banner: Label

var _keys: Array[AbilityKey] = []
var _floats: Array[FloatingNumber] = []
var _tracked: Array[EnemyTrack] = []
var _fan: int = 0


# ------------------------------------------------------------------------------
# Build
# ------------------------------------------------------------------------------

func _ready() -> void:
	layer = LAYER

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# The backdrop is NOT interactive. Only the keys take touches; everything
	# else — plate, numbers, bars — is a picture, and a picture that swallows a
	# tap is a champion that will not walk.
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_world_bars = _passive_layer()
	_numbers = _passive_layer()

	_vignette = Vignette.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_vignette)

	_build_plate()
	_build_message()
	_build_pad()


func _passive_layer() -> Control:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(c)
	return c


# iOS has a notch and a home indicator and the whole UI is one stretched
# viewport, so the safe area has to be converted out of window pixels before it
# means anything. UiShell does the same sum for the menus; the HUD repeats it
# rather than borrowing it because Play.tscn is launched standalone by several
# tools/ harnesses, where there is no shell to ask.
## The device's insets, from the ONE place that computes them.
##
## This used to be a private copy of UiShell's arithmetic, with the same two
## bugs: it measured only the top and bottom, and it scaled them by the
## HORIZONTAL ratio. In landscape — the only way this game is played — the
## camera cut-out is on a SIDE, so the health plate and the ability keys were
## being placed under it.
##
## A second copy of a calculation is a second place for it to be wrong, and
## this one was wrong in exactly the way the first one was.
func _insets() -> Dictionary:
	return UiShell.safe_margins(DisplayServer.window_get_size(),
		DisplayServer.get_display_safe_area(), _view())


func _view() -> Vector2:
	return get_viewport().get_visible_rect().size


func _build_plate() -> void:
	var inset: Dictionary = _insets()
	_plate = HeroTheme.panel(Color(HeroTheme.BG_LIFT.r, HeroTheme.BG_LIFT.g,
		HeroTheme.BG_LIFT.b, 0.82), HeroTheme.LINE)
	_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Clear of the cut-out on the left edge, not a flat pad.
	_plate.position = Vector2(float(inset["left"]) + HeroTheme.GAP,
		float(inset["top"]) + HeroTheme.GAP)
	# A FIXED WIDTH, NOT A SHARE OF THE SCREEN.
	#
	# This was `_view().x - PAD - 340`, which was reasonable in portrait: 796 of
	# 1170 px, about two thirds. In landscape the same expression is 2158 of
	# 2532 — a health plate stretched across 85% of the glass, over the fight it
	# is reporting on. The plate holds a name, a class and a bar; it needs the
	# width of its text, not the width of the device.
	#
	# Width is a MINIMUM rather than a size: a PanelContainer under a plain
	# Control sizes itself to its contents, so anything assigned to `size` is
	# overwritten on the next layout pass and the plate collapses to the width
	# of the longest champion name.
	_plate.custom_minimum_size = Vector2(
		minf(HeroTheme.COL_W, _view().x - HeroTheme.PAD - 340.0), 0.0)
	_plate.visible = false
	_root.add_child(_plate)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	_plate.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	col.add_child(head)

	_name = HeroTheme.clipped("", HeroTheme.F_BODY, HeroTheme.TEXT)
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_name)

	_class = HeroTheme.label("", HeroTheme.F_SMALL, HeroTheme.DIM,
		HORIZONTAL_ALIGNMENT_RIGHT)
	head.add_child(_class)

	_hp_bar = HeroTheme.bar(1.0, HeroTheme.DANGER, 30)
	_hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_hp_bar)

	_hp_text = HeroTheme.label("", HeroTheme.F_SMALL, HeroTheme.DIM)
	col.add_child(_hp_text)

	_status_row = HBoxContainer.new()
	_status_row.add_theme_constant_override("separation", 10)
	col.add_child(_status_row)
	for kind in STATUS_COLOUR.keys():
		var colour: Color = STATUS_COLOUR[kind]
		var chip: PanelContainer = HeroTheme.chip("", colour)
		chip.visible = false
		_status_row.add_child(chip)
		_chip_panels[kind] = chip
		_chips[kind] = chip.get_child(0) as Label


func _build_message() -> void:
	_message = HeroTheme.prose("", HeroTheme.F_SMALL, HeroTheme.DIM)
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.set_anchors_preset(Control.PRESET_TOP_WIDE)
	var mi: Dictionary = _insets()
	_message.offset_left = float(mi["left"]) + HeroTheme.GAP
	_message.offset_right = -(float(mi["right"]) + HeroTheme.GAP)
	_message.offset_top = float(mi["top"]) + 340.0
	_message.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_message)


## Where the four keys go, as pure geometry: slot, centre and radius, for a given
## viewport and bottom safe-area inset.
##
## SEPARATED FROM THE BUILD so it can be checked against the SHIPPING viewport
## (1170x2532; see project.godot) rather than against whatever the harness
## happens to be running at — a headless run gets a square viewport, so a layout
## asserted only on live nodes proves nothing about the phone. tools/hudtest.gd
## evaluates this for the real screen.
static func key_layout(view: Vector2, bottom_inset: float,
		right_inset: float = 0.0) -> Array[Dictionary]:
	# RIGHT INSET TOO. The ability keys sit in the bottom-right corner, which
	# in landscape is where the home indicator runs and, on half the
	# orientations, where the cut-out is — the basic attack was partly under
	# it and the arc above it was clipped by the rounded corner.
	var basic := Vector2(
		view.x - right_inset - PAD_MARGIN - KEY_R_BASIC,
		view.y - bottom_inset - PAD_MARGIN - KEY_R_BASIC)
	var out: Array[Dictionary] = [
		{"slot": 0, "centre": basic, "radius": KEY_R_BASIC},
	]
	for i in range(3):
		var a: float = deg_to_rad(ARC_ANGLES[i])
		out.append({
			"slot": i + 1,
			"centre": basic + Vector2(cos(a), sin(a)) * ARC_RADIUS,
			"radius": KEY_R_ABILITY,
		})
	return out


## Where the roll key goes. Deliberately NOT part of key_layout(): that function
## answers "where are the four ability keys", which several harnesses asserted
## before the roll existed, and the roll is not one of them.
static func dodge_key_layout(view: Vector2, bottom_inset: float,
		right_inset: float = 0.0) -> Dictionary:
	var basic := Vector2(
		view.x - right_inset - PAD_MARGIN - KEY_R_BASIC,
		view.y - bottom_inset - PAD_MARGIN - KEY_R_BASIC)
	var a: float = deg_to_rad(ROLL_ANGLE)
	return {
		"slot": DODGE_SLOT,
		"centre": basic + Vector2(cos(a), sin(a)) * ROLL_RADIUS,
		"radius": KEY_R_ABILITY,
	}


func _build_pad() -> void:
	var inset: Dictionary = _insets()
	var view: Vector2 = _view()

	_keys.clear()
	for spec in key_layout(view, float(inset["bottom"]),
			float(inset["right"])):
		_keys.append(_make_key(int(spec["slot"]), spec["centre"],
			float(spec["radius"])))

	var roll: Dictionary = dodge_key_layout(view, float(inset["bottom"]),
		float(inset["right"]))
	_dodge_key = _make_key(int(roll["slot"]), roll["centre"],
		float(roll["radius"]))

	# Above the arc rather than over it: a stun lasts seconds and the player is
	# looking at their thumb, not at the top of the screen.
	_locked_banner = HeroTheme.label("", HeroTheme.F_BODY, HeroTheme.DANGER,
		HORIZONTAL_ALIGNMENT_RIGHT)
	_locked_banner.position = Vector2(
		view.x - float(inset["right"]) - 700.0 - PAD_MARGIN,
		_keys[0].position.y + KEY_R_BASIC - ARC_RADIUS - KEY_R_ABILITY - 76.0)
	_locked_banner.size = Vector2(700.0, 60.0)
	_locked_banner.visible = false
	_root.add_child(_locked_banner)


## The roll key, held apart from _keys so every loop over the four ability keys
## keeps meaning exactly what it did.
var _dodge_key: AbilityKey = null


func _make_key(slot: int, centre: Vector2, r: float) -> AbilityKey:
	var k := AbilityKey.new()
	k.setup(slot, r)
	k.position = centre - Vector2(r, r)
	k.visible = false
	k.fired.connect(_on_key_fired)
	_root.add_child(k)
	return k


# ------------------------------------------------------------------------------
# Binding
# ------------------------------------------------------------------------------

## Hand the HUD the champion it is reporting on, and the camera its world-space
## overlays project through. Safe to call once the controller has a combat body;
## the keys stay hidden until then, because four buttons that do nothing are
## worse than none.
func bind_champion(champion: HeroController, camera: Camera3D) -> void:
	_champion = champion
	_camera = camera
	if champion == null:
		return

	# The champion's own body may not exist yet (setup_combat is separate), so
	# these two forwarding signals on the controller are used rather than
	# connecting to `body` — see the note in HeroController.gd.
	if not champion.took_damage.is_connected(_on_champion_damaged):
		champion.took_damage.connect(_on_champion_damaged)
	if not champion.champion_died.is_connected(_on_champion_died):
		champion.champion_died.connect(_on_champion_died)

	_name.text = ChampionName.of(champion.rig.hero_name) if champion.rig != null \
		else ""
	var cls: int = HeroClass.for_hero(champion.rig.hero_name) \
		if champion.rig != null else HeroClass.Kind.FIGHTER
	_class.text = HeroClass.display_name(cls)
	_plate.visible = true

	for k in _keys:
		var ab: Ability = champion.ability_in_slot(k.slot)
		k.title = ab.title if ab != null else ""
		k.glyph_kind = _glyph_for(k.slot, cls)
		k.visible = true
		k.refresh_look()

	if _dodge_key != null:
		# Not from the kit: every champion rolls, so the title is fixed.
		_dodge_key.title = "Roll"
		_dodge_key.glyph_kind = UiGlyph.Kind.ARROW
		_dodge_key.visible = true
		_dodge_key.refresh_look()


## Slot 0 shows the class's weapon; the three abilities show their ROLE, which is
## the same in every kit (damage, control, self — see Ability.gd). A player who
## learns one champion can then read any of the 139 at a glance.
func _glyph_for(slot: int, cls: int) -> int:
	match slot:
		1: return UiGlyph.Kind.SPARK
		2: return UiGlyph.Kind.SIGIL
		3: return UiGlyph.Kind.CHECK
		_: return UiGlyph.for_class(cls)


## Put an enemy on the HUD: a compact bar over its head and floating numbers off
## its body.
##
## REGISTERED, NOT HOOKED. Audio can attach itself to Combatant.on_spawn because
## a sound needs nothing but the combatant; a bar needs to know WHERE the thing
## is, and a Combatant is pure data with no position (deliberately — see
## Combatant.gd). So whatever spawns an enemy hands over the body and the node it
## is drawn at, and the HUD follows that node until it is freed.
func track_enemy(body: Combatant, node: Node3D) -> void:
	if body == null or node == null:
		return
	for t in _tracked:
		if t.body == body:
			return
	var track := EnemyTrack.new()
	track.body = body
	track.node = node
	track.bar = HeroTheme.bar(1.0, HeroTheme.DANGER, int(ENEMY_BAR_SIZE.y))
	track.bar.size = ENEMY_BAR_SIZE
	track.bar.custom_minimum_size = ENEMY_BAR_SIZE
	track.bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.bar.visible = false
	_world_bars.add_child(track.bar)
	_tracked.append(track)

	# KEPT so they can be disconnected again. A Combatant is RefCounted and a
	# signal connection holds its callable, so a lambda that captures the track —
	# which holds the body — is a reference cycle: drop the track and the enemy,
	# its stats and its effects are never collected. One corpse is nothing; a
	# region of them is a leak that grows with play time.
	track.on_damaged = func(amount: float, crit: bool, _source: String) -> void:
		_on_enemy_damaged(track, amount, crit)
	track.on_died = func() -> void:
		track.hold = ENEMY_BAR_DEATH
		track.dying = true
	body.damaged.connect(track.on_damaged)
	body.died.connect(track.on_died)


## Stop watching an enemy, so a caller can drop what it spawned.
func forget_enemy(body: Combatant) -> void:
	for i in range(_tracked.size() - 1, -1, -1):
		if _tracked[i].body == body:
			_drop_track(i)


func _drop_track(i: int) -> void:
	var t: EnemyTrack = _tracked[i]
	_unhook(t)
	t.bar.queue_free()
	_tracked.remove_at(i)


## Let go of an enemy completely. Both steps are load-bearing: the disconnect
## breaks the body -> callable -> track -> body cycle, and CLEARING THE
## CALLABLES breaks a second one entirely inside the track, because a lambda
## stored on the object it captures holds that object alive by itself. Miss
## either and every enemy the player kills stays in memory for the session,
## with its stats and its effects.
func _unhook(t: EnemyTrack) -> void:
	if t.body != null:
		if t.on_damaged.is_valid() and t.body.damaged.is_connected(t.on_damaged):
			t.body.damaged.disconnect(t.on_damaged)
		if t.on_died.is_valid() and t.body.died.is_connected(t.on_died):
			t.body.died.disconnect(t.on_died)
	t.on_damaged = Callable()
	t.on_died = Callable()


func _notification(what: int) -> void:
	# Leaving the region frees the HUD while enemies are still being tracked, and
	# the engine freeing an Array does not break the cycles above.
	if what == NOTIFICATION_PREDELETE:
		for t in _tracked:
			_unhook(t)
		_tracked.clear()


# ------------------------------------------------------------------------------
# The tap-through guard
# ------------------------------------------------------------------------------

## Is this screen point owned by a control? Play.gd asks before it turns a touch
## into a walk order.
##
## Tested against the keys' CIRCLES, not their bounding squares, so the gaps
## between the keys still walk the champion — the pad is three quarters empty
## space and treating it as a solid block would steal a sixth of the screen.
func blocks_point(p: Vector2) -> bool:
	for k in _keys:
		if k.visible and k.covers_global(p):
			return true
	# The roll key too, or a press on it ALSO issues a walk order to the ground
	# underneath — the champion rolls and then strolls back to where the thumb
	# landed, which is the opposite of escaping.
	if _dodge_key != null and _dodge_key.visible \
			and _dodge_key.covers_global(p):
		return true
	return false


func _on_key_fired(slot: int) -> void:
	if slot == DODGE_SLOT:
		dodge_pressed.emit()
		return
	action.emit(slot)


# ------------------------------------------------------------------------------
# Per-frame
# ------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_advance_message(delta)
	_advance_floats(delta)
	_advance_enemies(delta)
	if _champion == null:
		return
	_advance_keys()
	_advance_health()
	_advance_statuses()


func _advance_keys() -> void:
	# The stun is the game's core control effect and it was completely invisible:
	# the champion simply stopped responding. Lock the keys so the player can SEE
	# that they have been taken off their abilities rather than concluding the
	# touch handler is broken.
	var stunned: bool = _champion.is_stunned()
	var dead: bool = _champion.is_dead()
	for k in _keys:
		var ab: Ability = _champion.ability_in_slot(k.slot)
		k.set_state(_champion.cooldown_left(k.slot),
			_champion.cooldown_fraction(k.slot),
			stunned or dead,
			ab)
	if _dodge_key != null:
		# A stun takes the roll away too. It is an escape, not an exemption —
		# and a key that looked live while dodge() refused would read as the
		# button being broken.
		_dodge_key.set_state(_champion.dodge_cooldown_left(),
			_champion.dodge_cooldown_fraction(),
			stunned or dead,
			null)
	_locked_banner.visible = stunned and not dead
	if _locked_banner.visible:
		var e: StatusEffect = _champion.body.effect_of(StatusEffect.Kind.STUN) \
			if _champion.body != null else null
		_locked_banner.text = "Stunned — abilities locked  %.1fs" % \
			maxf(e.remaining if e != null else 0.0, 0.0)


func _advance_health() -> void:
	var body: Combatant = _champion.body
	if body == null:
		return
	_hp_bar.value = body.health_fraction()
	_hp_text.text = "%d / %d" % [int(ceil(body.health)), int(round(body.max_health))]
	# A shield is health the player HAS, so it belongs on the health line rather
	# than only in the status row — otherwise a warded mage reads as being on the
	# brink while sitting behind 30% of their health in absorb.
	var shield: StatusEffect = body.effect_of(StatusEffect.Kind.SHIELD)
	if shield != null:
		_hp_text.text += "   +%d shielded" % int(ceil(shield.magnitude))


func _advance_statuses() -> void:
	var body: Combatant = _champion.body
	for kind in _chip_panels.keys():
		var panel: PanelContainer = _chip_panels[kind]
		var e: StatusEffect = body.effect_of(kind) if body != null else null
		panel.visible = e != null
		if e == null:
			continue
		var label: Label = _chips[kind]
		# Magnitude is only meaningful for the two that absorb or burn; for the
		# rest the countdown is the whole story.
		if kind == StatusEffect.Kind.SHIELD:
			label.text = "%s %d" % [e.name_of(), int(ceil(e.magnitude))]
		else:
			label.text = "%s %.1fs" % [e.name_of(), maxf(e.remaining, 0.0)]


func _advance_enemies(delta: float) -> void:
	for i in range(_tracked.size() - 1, -1, -1):
		var t: EnemyTrack = _tracked[i]
		# The spawner is free to despawn a corpse whenever it likes, so a tracked
		# node going away is normal, not an error.
		if not is_instance_valid(t.node):
			_drop_track(i)
			continue
		t.hold = maxf(t.hold - delta, 0.0)
		if t.dying and t.hold <= 0.0:
			_drop_track(i)
			continue

		var hurt: bool = t.body != null and t.body.health_fraction() < 0.999
		var show: bool = t.hold > 0.0 or (hurt and t.body.alive)
		var at: Vector2 = _project(t.node.global_position
			+ Vector3(0.0, ENEMY_BAR_LIFT, 0.0))
		if not show or at == Vector2.INF:
			t.bar.visible = false
			continue
		t.bar.visible = true
		t.bar.value = t.body.health_fraction()
		t.bar.position = at - ENEMY_BAR_SIZE * 0.5
		# A wounded survivor keeps its bar at full opacity — it is standing
		# evidence of an unfinished fight. Everything else fades out over the
		# last half second rather than blinking off.
		var standing: bool = hurt and t.body.alive
		t.bar.modulate.a = 1.0 if standing else clampf(t.hold / 0.5, 0.0, 1.0)


func _advance_floats(delta: float) -> void:
	for i in range(_floats.size() - 1, -1, -1):
		var f: FloatingNumber = _floats[i]
		f.t += delta
		var k: float = f.t / NUM_LIFE
		if k >= 1.0:
			f.label.queue_free()
			_floats.remove_at(i)
			continue
		# Rises fast and then coasts, which is what makes it feel struck off the
		# body rather than lerped upward.
		var rise: float = NUM_RISE * (1.0 - pow(1.0 - k, 2.2))
		f.label.position = f.from + Vector2(f.drift * k, -rise)
		f.label.modulate.a = clampf((1.0 - k) * 2.2, 0.0, 1.0)


func _advance_message(delta: float) -> void:
	if _message_left <= 0.0:
		return
	_message_left -= delta
	if _message_left <= 0.0:
		_message.text = ""


# ------------------------------------------------------------------------------
# Events
# ------------------------------------------------------------------------------

func _on_champion_damaged(amount: float, crit: bool, _source: String) -> void:
	if _champion != null:
		_number_at(_champion.global_position + Vector3(0.0, 1.9, 0.0),
			amount, crit, true)
	# The edges of the screen, not a full-screen wash: the player is looking at
	# their champion and a tint over the whole viewport hides it at exactly the
	# moment they need to see it.
	_vignette.flash(minf(0.35 + amount * 0.02, 1.0))


func _on_champion_died() -> void:
	_vignette.flash(1.0)
	_locked_banner.visible = false
	for k in _keys:
		k.set_state(0.0, 0.0, true, null)
	set_message("Your champion has fallen.")


func _on_enemy_damaged(track: EnemyTrack, amount: float, crit: bool) -> void:
	track.hold = ENEMY_BAR_HOLD
	if is_instance_valid(track.node):
		_number_at(track.node.global_position + Vector3(0.0, 1.6, 0.0),
			amount, crit, false)


# ------------------------------------------------------------------------------
# Floating numbers
# ------------------------------------------------------------------------------

## A damage number over a world point.
##
## CRITS ARE A DIFFERENT SHAPE, not a bigger number: gold, half again the size,
## and prefixed. Colour alone does not survive a burning biome at arm's length,
## and "did that crit" is the one question combat feedback exists to answer.
func _number_at(world: Vector3, amount: float, crit: bool, on_me: bool) -> void:
	if amount < 0.5:
		return                            # a rounded-to-zero hit is just noise
	var at: Vector2 = _project(world)
	if at == Vector2.INF:
		return

	var size: int = 66 if crit else 44
	var colour: Color = HeroTheme.GOLD if crit else HeroTheme.TEXT
	if on_me:
		# Damage TAKEN is always red, crit or not. The player needs to tell their
		# own blood from the enemy's in one glance.
		colour = HeroTheme.DANGER
	var text: String = ("%d!" % int(round(amount))) if crit \
		else str(int(round(amount)))

	var l: Label = HeroTheme.label(text, size, colour,
		HORIZONTAL_ALIGNMENT_CENTER)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 3)
	l.add_theme_constant_override("shadow_offset_y", 4)
	l.size = Vector2(260.0, float(size) * 1.4)
	_numbers.add_child(l)

	var f := FloatingNumber.new()
	f.label = l
	f.from = at - Vector2(130.0, 0.0)
	_fan += 1
	f.drift = (float(_fan % 3) - 1.0) * NUM_FAN
	l.position = f.from
	_floats.append(f)


## World point to screen point, or Vector2.INF if it is not in front of the
## camera. Behind-camera positions project to a mirrored point on screen, which
## puts an enemy's health bar on the wrong side of the player.
func _project(world: Vector3) -> Vector2:
	if _camera == null or not _camera.is_inside_tree():
		return Vector2.INF
	if _camera.is_position_behind(world):
		return Vector2.INF
	return _camera.unproject_position(world)


# ------------------------------------------------------------------------------
# Messages
# ------------------------------------------------------------------------------

## One line of text under the plate. Used for load progress and for the one-time
## control hint; it fades itself out, because a hint that never leaves becomes
## part of the furniture.
func set_message(text: String, sticky: bool = false) -> void:
	_message.text = text
	_message_left = 0.0 if (text == "" or sticky) else MESSAGE_LIFE


# ------------------------------------------------------------------------------
# Inner classes
# ------------------------------------------------------------------------------

## One action key: a round button that draws its own cooldown.
##
## A Control rather than a Button because a Button is a rectangle with a label
## and this needs a circular hit area (see `_has_point`) and a radial sweep. It
## fires on PRESS, not on release: in an action game the gap between landing a
## thumb and lifting it is a gap the player reads as lag.
class AbilityKey extends Control:
	signal fired(slot: int)

	## Forgiveness around the drawn edge, in pixels. A thumb is wider than the
	## point iOS reports and a near miss on a cooldown key is maddening.
	const SLOP: float = 10.0

	var slot: int = 0
	var radius: float = 118.0
	var title: String = "":
		set(v):
			title = v
			if _title != null:
				_title.text = v
	var glyph_kind: int = UiGlyph.Kind.BLADE:
		set(v):
			glyph_kind = v
			if _glyph != null:
				_glyph.kind = v

	var _cd_left: float = 0.0
	var _cd_frac: float = 0.0
	var _locked: bool = false
	var _down: bool = false

	var _glyph: UiGlyph
	var _title: Label
	var _timer: Label


	func setup(slot_v: int, r: float) -> void:
		slot = slot_v
		radius = r
		size = Vector2(r, r) * 2.0
		custom_minimum_size = size
		mouse_filter = Control.MOUSE_FILTER_STOP
		# A focus ring means nothing without a keyboard and leaves a stuck
		# highlight on the last thing a finger touched.
		focus_mode = Control.FOCUS_NONE

		var mark: float = r * 0.52
		_glyph = UiGlyph.make(glyph_kind, mark, HeroTheme.TEXT)
		_glyph.size = Vector2(mark, mark)
		_glyph.position = Vector2(r - mark * 0.5, r * 0.70 - mark * 0.5)
		add_child(_glyph)

		_title = HeroTheme.label(title, _font(0.22, 26, 40), HeroTheme.TEXT,
			HORIZONTAL_ALIGNMENT_CENTER)
		_title.size = Vector2(size.x, r * 0.4)
		_title.position = Vector2(0.0, r * 1.18)
		_title.clip_text = true
		add_child(_title)

		_timer = HeroTheme.label("", _font(0.44, 44, 70), HeroTheme.GOLD,
			HORIZONTAL_ALIGNMENT_CENTER)
		_timer.size = Vector2(size.x, r * 0.6)
		_timer.position = Vector2(0.0, r * 0.52)
		_timer.visible = false
		add_child(_timer)


	func _font(k: float, lo: int, hi: int) -> int:
		return clampi(int(radius * k), lo, hi)


	## Circular, so the dead space between the keys falls through to the world.
	func _has_point(point: Vector2) -> bool:
		return point.distance_to(Vector2(radius, radius)) <= radius + SLOP


	## Is a point in VIEWPORT space on this key? The same circle as `_has_point`,
	## which is what keeps Play.gd's guard and the engine's hit-testing from ever
	## disagreeing about where the button is.
	func covers_global(p: Vector2) -> bool:
		return _has_point(p - global_position)


	func set_state(cd_left: float, cd_frac: float, locked: bool,
			ability: Ability) -> void:
		var redraw: bool = locked != _locked \
			or absf(cd_frac - _cd_frac) > 0.004 \
			or (cd_frac > 0.0) != (_cd_frac > 0.0)
		_cd_left = cd_left
		_cd_frac = cd_frac
		_locked = locked
		if ability != null and _title != null and _title.text != ability.title:
			_title.text = ability.title
		_timer.visible = cd_left > 0.05 and not locked
		if _timer.visible:
			# One decimal under a second, whole seconds above: "7.3" on a 16 s
			# cooldown is precision the player cannot use.
			_timer.text = ("%.1f" % cd_left) if cd_left < 1.0 else "%d" % int(ceil(cd_left))
		_glyph.visible = not _timer.visible
		if redraw:
			queue_redraw()


	func refresh_look() -> void:
		if _glyph != null:
			_glyph.kind = glyph_kind
		if _title != null:
			_title.text = title
		queue_redraw()


	func _gui_input(event: InputEvent) -> void:
		var press: bool = false
		var release: bool = false
		if event is InputEventScreenTouch:
			press = (event as InputEventScreenTouch).pressed
			release = not press
		elif event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index != MOUSE_BUTTON_LEFT:
				return
			# iOS emulates a mouse from every touch, so one thumb arrives twice:
			# as a touch and as a synthesised click. Taking both fires the slot
			# twice per tap. The emulated copy is the one to drop — a real mouse
			# is a real device and has to keep working for desktop testing.
			if mb.device == InputEvent.DEVICE_ID_EMULATION:
				return
			press = mb.pressed
			release = not press
		else:
			return

		# Consumed either way. A release that is left unhandled reaches Play.gd,
		# which reads it as "the finger that was steering has lifted" — and
		# lifting a finger that never touched the ground used to cancel a walk
		# order the player had not finished giving.
		accept_event()
		if press:
			_down = true
			queue_redraw()
			fired.emit(slot)
		elif release:
			_down = false
			queue_redraw()


	func _draw() -> void:
		var c := Vector2(radius, radius)
		var fill: Color = HeroTheme.PANEL_HI
		var edge: Color = HeroTheme.LINE
		var alpha: float = 0.88

		if _locked:
			# Reads as taken away, not as merely unavailable: the whole key goes
			# cold and the rim turns to the damage colour.
			fill = HeroTheme.PANEL.lerp(HeroTheme.DANGER, 0.18)
			edge = HeroTheme.DANGER
			alpha = 0.72
		elif _cd_frac > 0.0:
			fill = HeroTheme.PANEL
		elif _down:
			fill = HeroTheme.ACCENT_SHADE.lerp(Color.WHITE, 0.2)
			edge = HeroTheme.ACCENT
		else:
			fill = HeroTheme.ACCENT_SHADE.lerp(HeroTheme.PANEL_HI, 0.45)
			edge = HeroTheme.ACCENT_DEEP

		draw_circle(c, radius, Color(fill.r, fill.g, fill.b, alpha))

		# The sweep. The DARK part is what is left to wait, so the key visibly
		# fills back up — an emptying wedge reads as the ability draining away.
		if _cd_frac > 0.0:
			_wedge(c, radius - 4.0, _cd_frac, Color(0.02, 0.02, 0.05, 0.74))
			draw_arc(c, radius - 7.0, -PI * 0.5,
				-PI * 0.5 + TAU * (1.0 - _cd_frac), 48,
				HeroTheme.ACCENT_DEEP, 8.0, true)

		draw_arc(c, radius - 3.0, 0.0, TAU, 72, edge, 5.0, true)
		if _locked:
			# A second, inset rim: one ring could be a colour the player has not
			# learned yet, two is unmistakably a state.
			draw_arc(c, radius - 22.0, 0.0, TAU, 72,
				Color(HeroTheme.DANGER.r, HeroTheme.DANGER.g,
					HeroTheme.DANGER.b, 0.55), 3.0, true)


	## A pie slice from twelve o'clock, clockwise. Built as a fan rather than a
	## thick arc because an arc cannot cover the centre of the key.
	func _wedge(c: Vector2, r: float, frac: float, colour: Color) -> void:
		var steps: int = maxi(3, int(ceil(clampf(frac, 0.0, 1.0) * 56.0)))
		var pts := PackedVector2Array()
		pts.append(c)
		for i in range(steps + 1):
			var a: float = -PI * 0.5 + TAU * frac * (float(i) / float(steps))
			pts.append(c + Vector2(cos(a), sin(a)) * r)
		draw_colored_polygon(pts, colour)


## One damage number in flight.
class FloatingNumber extends RefCounted:
	var label: Label
	var from: Vector2 = Vector2.ZERO
	var drift: float = 0.0
	var t: float = 0.0


## One enemy the HUD is drawing a bar for.
class EnemyTrack extends RefCounted:
	var body: Combatant
	var node: Node3D
	var bar: ProgressBar
	## Seconds the bar stays up regardless of health, refreshed on every hit.
	var hold: float = 0.0
	var dying: bool = false
	## The two listeners on `body`, held so they can be disconnected. See
	## track_enemy() for why that matters.
	var on_damaged: Callable
	var on_died: Callable


## The hurt overlay: four bands of red bled in from the edges.
##
## Edges rather than a full-screen tint, and polygons rather than a texture —
## `draw_polygon` interpolates per-vertex colour, so a gradient costs nothing and
## the project stays free of 2D art.
class Vignette extends Control:
	const BAND: float = 0.22              # fraction of the screen each band covers
	const DECAY: float = 2.6              # per second

	var _k: float = 0.0


	func flash(strength: float) -> void:
		_k = maxf(_k, clampf(strength, 0.0, 1.0))
		queue_redraw()


	func _process(delta: float) -> void:
		if _k <= 0.0:
			return
		_k = maxf(_k - DECAY * delta, 0.0)
		queue_redraw()


	func _draw() -> void:
		if _k <= 0.001:
			return
		var w: float = size.x
		var h: float = size.y
		var dv: float = h * BAND
		var dh: float = w * BAND
		var hot := Color(HeroTheme.DANGER.r, HeroTheme.DANGER.g,
			HeroTheme.DANGER.b, 0.46 * _k)
		var cold := Color(hot.r, hot.g, hot.b, 0.0)
		_band(Vector2(0, 0), Vector2(w, 0), Vector2(w, dv), Vector2(0, dv), hot, cold)
		_band(Vector2(0, h), Vector2(w, h), Vector2(w, h - dv), Vector2(0, h - dv),
			hot, cold)
		_band(Vector2(0, 0), Vector2(0, h), Vector2(dh, h), Vector2(dh, 0), hot, cold)
		_band(Vector2(w, 0), Vector2(w, h), Vector2(w - dh, h), Vector2(w - dh, 0),
			hot, cold)


	# Two vertices on the screen edge at `hot`, two inboard at `cold`.
	func _band(e0: Vector2, e1: Vector2, i1: Vector2, i0: Vector2,
			hot: Color, cold: Color) -> void:
		draw_polygon(PackedVector2Array([e0, e1, i1, i0]),
			PackedColorArray([hot, hot, cold, cold]))
