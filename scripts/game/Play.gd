extends Node3D
# ------------------------------------------------------------------------------
# The playable slice: generate a region on the background thread, drop a hero in
# it, and let the player fight in it.
#
# INPUT IS TOUCH-FIRST, because this ships on iOS only:
#   tap / click        walk there
#   hold / drag        keep walking toward the finger
#   on-screen keys     basic attack and the three abilities (scripts/ui/Hud.gd)
#   1-4                the same four actions, for desktop testing only
#
# The keyboard bindings are kept deliberately: every tools/ harness and every
# editor run is driven from them, and they cost nothing on a device that has no
# keyboard. They are a developer convenience, NOT the shipping control scheme —
# that is the HUD, and until it existed the game could not be played at all.
#
# A TAP ON A CONTROL MUST NEVER ALSO MOVE THE CHAMPION, which is the classic bug
# in a touch game that mixes a world-space tap target with on-screen buttons.
# Two guards, see `_unhandled_input` and Hud.blocks_point().
#
# THE LOOT LOOP CLOSES HERE: an enemy's death rolls a drop (Loot.gd), the orb
# lands where it fell, walking over it banks it in the account's stash and
# wallet, and the champion's own combat body is built FROM that stash — so the
# next region is fought with what the last one paid out.
# ------------------------------------------------------------------------------

@export var world_seed: int = 7000
@export var biome: String = "greenwood"
@export var hero: String = ""

## The champion's level. The shell knows the real figure from the save (see
## Roster/HeroProgress) and may set it before this node enters the tree; on its
## own — tools/, the editor — the slice plays a fresh level 1 champion rather
## than reading the player's save file behind their back.
##
## Ignored when a roster IS supplied: the save is then the authority on what
## level the champion is, and two sources for one number is one too many.
@export var champion_level: int = 1

## The difficulty tier being played. Drives enemy scaling and, through Loot,
## what a kill is allowed to drop — see Campaign.gd.
@export var tier: int = Campaign.Tier.NORMAL

## Region size in walk cells, at 0.5 m each. 384 is the shipping figure (192 m
## of ground, about four seconds of generation); it is an export only so a
## headless harness can ask for a small region and still exercise the real
## scene rather than a stub of it.
@export var region_cells: int = 384

## THE PLAYER'S ACCOUNT, assigned by whoever launched this scene (UiShell.gd)
## before it enters the tree.
##
## Play.gd never calls Roster.load_or_create() itself. Persistence is one file
## by design (Roster.gd) and a second reader becomes a second writer the moment
## loot is picked up, at which point the stash the menus are showing and the
## stash the region is filling are different objects and one of them is about to
## be overwritten. See `_resolve_roster`.
var roster: Roster = null

var _builder: WorldBuilder
var _cam: ArpgCamera
var _hero: HeroController
var _hud: Hud
## Everything lying on the ground, and the only path from a kill into the stash.
var _loot: Loot.Ground
## The account this region is being played on — `roster`, or the scratch one
## `_resolve_roster` falls back to. Never null once _ready has run.
var _account: Roster
## Set when loot has been banked but not yet written to disk. See `_bank_now`.
var _unsaved: bool = false
var _holding: bool = false
var _hold_at: Vector2 = Vector2.ZERO
## The touch that is currently steering. Releases are matched against it, so a
## second finger landing on an ability key cannot cancel the walk the first one
## is still giving.
var _hold_index: int = -1

## Everything hostile in the region, and the node each one is drawn at.
##
## THE ENCOUNTER SEAM. Nothing spawns enemies yet; when something does, it calls
## add_enemy() and gets target acquisition, cast resolution, health bars,
## damage numbers AND loot without touching this file again. Parallel arrays
## because Combat.Context wants them that way.
var _enemies: Array[Combatant] = []
var _enemy_nodes: Array[Node3D] = []
## A stable id per enemy, parallel to the two arrays above. A death is reported
## by id rather than by index because those arrays are compacted as corpses are
## pruned, so an index captured at spawn would name a different enemy by the
## time it died — or nothing at all.
var _enemy_ids: PackedInt32Array = PackedInt32Array()
var _next_enemy_id: int = 1


func _ready() -> void:
	_cam = ArpgCamera.new()
	add_child(_cam)

	# Declared in scenes/Play.tscn so the HUD exists from the first frame — load
	# progress is reported through it — but built in code if this script is run
	# from a scene of someone else's making.
	_hud = get_node_or_null("Hud") as Hud
	if _hud == null:
		_hud = Hud.new()
		_hud.name = "Hud"
		add_child(_hud)
	_hud.action.connect(_on_hud_action)

	_account = _resolve_roster()
	_build_loot_ground()

	_builder = WorldBuilder.new()
	add_child(_builder)
	_builder.progress.connect(func(s: String, f: float):
		_hud.set_message("%s  %d%%" % [s, int(f * 100.0)], true))
	_builder.finished.connect(_on_world_ready)
	_builder.build(world_seed, biome, maxi(region_cells, 32), 0.5)


## The account loot is banked into.
##
## Assigned by the launcher if it has one; failing that, asked of the node that
## launched this scene, which keeps UiShell's "ONE ROSTER" rule true without
## this file knowing what a UiShell is. Failing even that, a scratch account
## that is NEVER saved — a region played from tools/ or from the editor still
## drops, still shows orbs and still fills a stash, and cannot touch the
## player's file while doing it.
func _resolve_roster() -> Roster:
	if roster != null:
		return roster
	var launcher: Node = get_parent()
	if launcher != null:
		var theirs = launcher.get("roster")
		if theirs is Roster:
			roster = theirs
			return roster
	return Roster.new()


func _build_loot_ground() -> void:
	_loot = Loot.Ground.new()
	_loot.name = "Loot"
	# Keyed off the WORLD seed, not the account's, so one region's drops are
	# reproducible from the region alone — the same property the terrain has.
	_loot.region_seed = Rng.seed_of(world_seed, "loot")
	_loot.tier = tier
	_loot.champion_level = champion_level
	_loot.stash = _account.stash
	_loot.wallet = _account.wallet
	_loot.collected.connect(_on_loot_collected)
	_loot.refused.connect(func(text: String) -> void: _hud.set_message(text))
	add_child(_loot)


func _on_world_ready(root: Node3D, ter: Terrain, plan: Layout) -> void:
	add_child(root)

	var we := WorldEnvironment.new()
	we.environment = Mesher.build_environment(biome)
	add_child(we)
	add_child(Mesher.build_sun(biome))

	var heroes: PackedStringArray = HeroRig.animated_heroes()
	var pick: String = hero if hero != "" else (heroes[0] if heroes.size() > 0 else "")
	if pick == "":
		_hud.set_message("No hero models found", true)
		return

	var entry: Dictionary = plan.node_of_kind(Layout.ENTRY)
	var at: Vector2 = entry.get("pos", Vector2.ZERO)

	_hero = HeroController.new()
	add_child(_hero)
	if not _hero.setup(ter, pick, at):
		_hud.set_message("Failed to load hero '%s'" % pick, true)
		return

	_give_combat_body(pick)

	_cam.terrain = ter
	_cam.target = _hero
	_cam.snap_to_target()
	# The champion is what picks loot up, so the ground cannot collect anything
	# until this point — orbs dropped before it simply wait, which is correct.
	_loot.follow = _hero
	_hud.bind_champion(_hero, _cam)
	_hud.set_message("Tap to move. The keys on the right are your four actions.")

	var rigged: String = "rigged" if _hero.rig.is_rigged else "STATIC (procedural stand-in)"
	print("hero '%s': %s" % [pick, rigged])
	if _hero.rig.is_rigged:
		print("  missing clips: ", _hero.rig.missing_states())


## Give the champion a body and its kit.
##
## WITHOUT THIS the controller has no `basic` and no `abilities`, which means
## every one of the four actions falls through to the attack clip, every cooldown
## reads as zero, and the champion has no health to lose — so the HUD would be
## four identical buttons over an empty bar. It is also what makes a stun mean
## anything: `is_stunned()` is false forever on a controller with no body.
##
## THE GEAR IS IN HERE. The body is assembled by Combat.champion_body from the
## account's stash, so the sword the player equipped on the stash screen is the
## sword that swings — this used to pass 0 weapon and 0 armour, which made every
## drop in the game a number that moved the character sheet and nothing else.
func _give_combat_body(name: String) -> void:
	var cls: int = HeroClass.for_hero(name)
	var body: Combatant = Combat.champion_body(_account, name, champion_level,
		Rng.seed_of(world_seed, name), ChampionName.of(name))
	# The save is the authority on level when there is one, and item level is
	# capped against the champion's (Loot.item_level).
	_loot.champion_level = body.level
	_hero.setup_combat(body, cls, name)
	_hero.cast_landed.connect(_on_cast_landed)


# ------------------------------------------------------------------------------
# Enemies
# ------------------------------------------------------------------------------

## Register something hostile: its combat body and the node it is drawn at.
##
## THE FOURTH LISTENER ON `died`, and the one that pays out. The other three are
## each attached from the only place that can know what they need: Audio hooks
## Combatant.on_spawn, because a death cue needs nothing but the combatant;
## HeroController connects its own champion's body, because a corpse has to stop
## taking orders; and Hud.track_enemy is handed the node at registration,
## because a health bar needs to know where the thing is. A DROP needs the same
## thing a health bar does — a position — so it is wired from the same place,
## which is here, the one door every enemy in the region comes through.
func add_enemy(body: Combatant, node: Node3D) -> void:
	if body == null or node == null:
		return
	var id: int = _next_enemy_id
	_next_enemy_id += 1
	_enemies.append(body)
	_enemy_nodes.append(node)
	_enemy_ids.append(id)
	# A bound method rather than a lambda: a lambda that captured the body would
	# be held BY the body's own signal, which is the reference cycle Hud.gd had
	# to unpick by hand. `self` is a Node and outlives every enemy in it.
	body.died.connect(_on_enemy_died.bind(id))
	_hud.track_enemy(body, node)


## Roll and drop what an enemy was carrying, where it fell.
##
## Reading the position at the moment of death is the whole reason this is wired
## here: a corpse may be despawned at any time (HeroController.CORPSE_LINGER is
## a suggestion, not a rule), and loot that spawned at the origin because the
## node had already gone is a bug the player sees as "my kill dropped nothing".
func _on_enemy_died(id: int) -> void:
	var i: int = _enemy_index(id)
	if i < 0:
		return
	var node: Node3D = _enemy_nodes[i]
	if node == null or not is_instance_valid(node):
		return
	_loot.on_kill(_enemies[i], node.global_position)


func _enemy_index(id: int) -> int:
	for i in range(_enemy_ids.size()):
		if _enemy_ids[i] == id:
			return i
	return -1


## Loot has landed in the account. Reported on the HUD line, because an invisible
## reward is not a reward, and the cast cue pitched up stands in for a chime —
## this project synthesises its five cues (Audio.gd) and does not ship a sixth.
func _on_loot_collected(text: String, drop: Loot.Drop) -> void:
	if text != "":
		_hud.set_message(text)
	Audio.play(Audio.Cue.CAST, 1.7)
	_unsaved = true
	# A rare-or-better piece is written out immediately. Everything else waits
	# for the way out of the region (`_exit_tree`), because stringifying a
	# 300-item stash on every common drop is a hitch in the middle of a fight —
	# but losing a legendary to a force-quit is the thing a player never forgives.
	if drop.has_item() and drop.item.rarity >= Item.Rarity.RARE:
		_flush_account()


## Write the account out, if this region has anything to write and a real
## account to write it to. Roster.save() is the single file and the single door
## to it (Roster.gd); what this adds is a reason to walk through it, which the
## menus cannot supply because loot is earned while they are not on screen.
func _flush_account() -> void:
	if not _unsaved or _account == null or _account != roster:
		return
	_unsaved = false
	_account.save()


func _exit_tree() -> void:
	_flush_account()


## Live enemies and their ground positions, as Combat wants them. Dead and freed
## entries are dropped here rather than on a timer, so one pass does both.
func _enemy_context() -> Dictionary:
	var bodies: Array[Combatant] = []
	var points := PackedVector2Array()
	for i in range(_enemies.size() - 1, -1, -1):
		var node: Node3D = _enemy_nodes[i]
		if node == null or not is_instance_valid(node):
			_enemies.remove_at(i)
			_enemy_nodes.remove_at(i)
			_enemy_ids.remove_at(i)
			continue
		if not _enemies[i].alive:
			continue
		bodies.append(_enemies[i])
		points.append(Vector2(node.global_position.x, node.global_position.z))
	return {"bodies": bodies, "points": points}


## Resolve a cast at the moment it LANDS, which is the end of the animation —
## see HeroController.cast_landed. Pressing the key only starts the swing.
func _on_cast_landed(ability: Ability) -> void:
	if _hero == null or _hero.body == null:
		return
	var env: Dictionary = _enemy_context()
	var ctx := Combat.Context.new()
	ctx.caster = _hero.body
	ctx.origin = _hero.ground_position()
	ctx.facing = _hero.rotation.y
	ctx.targets = env["bodies"]
	ctx.positions = env["points"]
	Combat.cast(ability, ctx)


## The nearest living enemy's ground position, or Vector2.INF. Used to turn the
## champion toward what it is about to hit: on a phone the player has no way to
## aim, so pressing an ability has to mean "hit that one".
func _aim_point() -> Vector2:
	if _hero == null or _hero.body == null:
		return Vector2.INF
	var env: Dictionary = _enemy_context()
	var bodies: Array[Combatant] = env["bodies"]
	var points: PackedVector2Array = env["points"]
	var here: Vector2 = _hero.ground_position()
	var target: Combatant = Combat.nearest_enemy(here, _hero.body.team,
		bodies, points)
	if target == null:
		return Vector2.INF
	return points[bodies.find(target)]


# ------------------------------------------------------------------------------
# Input
# ------------------------------------------------------------------------------

## Releases only, and deliberately BEFORE the GUI gets a look in.
##
## A finger that starts a walk on open ground and then lifts over an ability key
## has its release consumed by that key, so `_unhandled_input` never sees it and
## `_holding` stays true for the rest of the region — the champion keeps
## re-pathing to wherever the finger last was. The press still goes through the
## normal route, which is what lets the keys steal it; it is only the end of the
## gesture that has to be unconditional.
##
## Nothing is consumed here. This is an observer, not a handler.
func _input(e: InputEvent) -> void:
	if not _holding:
		return
	if e is InputEventScreenTouch:
		var t := e as InputEventScreenTouch
		if not t.pressed and t.index == _hold_index:
			_release()
	elif e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if not mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_release()


func _unhandled_input(e: InputEvent) -> void:
	if _hero == null:
		return

	if e is InputEventScreenTouch or e is InputEventMouseButton:
		if e is InputEventMouseButton:
			var mb := e as InputEventMouseButton
			# iOS synthesises a click from every touch, so one tap arrives twice.
			# Both would path to the same place, but the duplicate costs a whole
			# A* search on a 300-cell grid for nothing.
			if mb.button_index != MOUSE_BUTTON_LEFT \
					or mb.device == InputEvent.DEVICE_ID_EMULATION:
				return
		if not e.pressed:
			_release()
			return
		# THE SECOND GUARD. The keys consume their own presses, so in practice
		# this never fires — but iOS synthesises a mouse event from every touch,
		# and a synthesised event is a second event with its own path through the
		# input stack. A geometric test cannot be bypassed by one.
		if _hud != null and _hud.blocks_point(e.position):
			return
		_holding = true
		_hold_index = (e as InputEventScreenTouch).index \
			if e is InputEventScreenTouch else -1
		_hold_at = e.position
		_order_move(e.position)
	elif e is InputEventScreenDrag or e is InputEventMouseMotion:
		if _holding:
			_hold_at = e.position
	elif e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_1: _use(0)
			KEY_2: _use(1)
			KEY_3: _use(2)
			KEY_4: _use(3)
			KEY_ESCAPE: get_tree().quit()


func _release() -> void:
	_holding = false
	_hold_index = -1


func _on_hud_action(slot: int) -> void:
	_use(slot)


## The one door every action goes through, whether it came from a thumb or a
## number key, so the two can never drift apart.
func _use(slot: int) -> void:
	if _hero == null:
		return
	_hero.use_ability(slot, _aim_point())


func _process(_d: float) -> void:
	# Held finger: keep re-issuing toward where it is now, so dragging steers
	# rather than requiring a tap per step. Re-pathing every frame would be
	# wasteful, so only when the target has moved meaningfully.
	if _holding and _hero != null and not _hero.is_busy():
		if not _hero.is_moving():
			_order_move(_hold_at)


func _order_move(screen: Vector2) -> void:
	# Checked here as well as on the press, because a drag that wanders over the
	# pad would otherwise keep issuing orders from under the player's thumb.
	if _hud != null and _hud.blocks_point(screen):
		return
	var g: Vector2 = _cam.screen_to_ground(screen)
	if g == Vector2.INF:
		return
	_hero.move_to(g, true)
