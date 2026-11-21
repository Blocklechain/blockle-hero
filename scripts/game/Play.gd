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

## WHICH MAP THIS IS, and the campaign it belongs to.
##
## Encounter.build() needs both: the map index picks the cast, the pack count,
## the elite rate and how far down the lane the boss stands, and the campaign
## seed is what makes map 7 of YOUR campaign the same map every time you play
## it. Neither was ever passed, which is the whole reason a campaign map was
## empty — the encounter builder was complete, tested and never called.
@export var region_index: int = 0
@export var campaign_seed: int = 0

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

## Which world generator this scene uses. LANE is the campaign; PvP will set
## ARENA when it exists. Settable from outside before the scene is added, the
## same way `biome` and `hero` are.
var layout_kind: int = Terrain.Kind.LANE

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

## The movement stick, and the live touches NOT claimed by it or the HUD.
##
## Pinch needs two fingers that are genuinely free: the stick owns one and the
## ability keys own others, so pinching while walking must not be read as the
## stick jumping across the screen. Tracking position by index is what keeps
## the three input sources from stealing each other's fingers.
var _stick: Joystick = null
var _free_touches: Dictionary = {}        # index -> Vector2
var _pinch_prev: float = -1.0

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

	# Added ABOVE the HUD in draw order but below it in input priority: the
	# stick runs in _input (which sees events before _unhandled_input) yet only
	# consumes presses inside its own zone, so the ability keys on the right
	# keep working while a thumb is on the stick.
	_stick = Joystick.new()
	_stick.name = "Joystick"
	_stick.moved.connect(_on_stick)
	add_child(_stick)

	_account = _resolve_roster()
	_build_loot_ground()

	_builder = WorldBuilder.new()
	add_child(_builder)
	_builder.progress.connect(func(s: String, f: float):
		_hud.set_message("%s  %d%%" % [s, int(f * 100.0)], true))
	_builder.finished.connect(_on_world_ready)
	# PASS THE LAYOUT KIND EXPLICITLY.
	#
	# WorldBuilder.build() defaults `kind` to Kind.ARENA so that callers written
	# before lanes existed kept the map they already built — and this caller was
	# never updated, so every campaign map was still an arena. The lane
	# generator, the spine encounters and the dread curve were all being built
	# and then not used by the one scene that plays them.
	_builder.build(world_seed, biome, maxi(region_cells, 32), 0.5,
		Layout.Sym.ASYMMETRIC, 11, layout_kind)


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
	_hud.set_message("Drag anywhere on the left to move. The keys on the right are your four actions. Pinch to zoom.")

	# AFTER the champion exists: every spawn is placed relative to where the
	# player stands, so this cannot run before `at` is a real position.
	_populate(ter, plan, at, pick)

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
# Populating the region
# ------------------------------------------------------------------------------

## How far an enemy will notice the champion and come for them, in metres.
## Generous enough that walking into a pack starts a fight, short enough that
## the whole map does not converge on the player at once.
const AGGRO: float = 18.0
## A boss holds its ground at the end of the lane until you are close.
const AGGRO_BOSS: float = 26.0
## How close an enemy wants to be before it swings.
const REACH: float = 2.6
## Re-think this often, in seconds. Enemies do not need a decision every frame,
## and 139 rigs asking the pathfinder sixty times a second does not ship.
const THINK: float = 0.35

var _brain_t: float = 0.0


## Put the map's encounters in the world.
##
## THE SEAM THAT WAS NEVER CLOSED. Encounter.build() and Encounter.body_for()
## were both written, both unit-tested and both unreachable: nothing in the
## playable scene called either, so every campaign map generated its lane, its
## packs and its boss and then loaded an empty region. A test that exercises a
## generator proves the generator works, not that the game uses it.
func _populate(ter: Terrain, plan: Layout, player_at: Vector2,
		player_hero: String) -> void:
	var playable: PackedStringArray = HeroRig.animated_heroes()
	if playable.is_empty():
		return
	var pathing := Pathing.new(ter)
	var spawns: Array = Encounter.build(region_index, tier, campaign_seed,
		playable, player_hero, pathing, player_at, plan)

	var made: int = 0
	for s in spawns:
		var spawn := s as Encounter.Spawn
		if spawn == null:
			continue
		var foe := HeroController.new()
		add_child(foe)
		if not foe.setup(ter, spawn.hero, spawn.at):
			# A hero whose model will not load is skipped, not fatal: one bad
			# rig must not empty the rest of the map.
			foe.queue_free()
			continue
		# Bosses and elites read as dangerous by being BIGGER. It is the one
		# cue that survives a small screen with a thumb over half of it.
		foe.scale = Vector3.ONE * spawn.size
		foe.setup_combat(Encounter.body_for(spawn, tier),
			spawn.cls, spawn.hero)
		foe.cast_landed.connect(_on_enemy_cast.bind(foe))
		add_enemy(foe.body, foe)
		made += 1

	print("region %d tier %d: %d enemies" % [region_index, tier, made])
	if made == 0:
		# Loud, because an empty map is the exact failure this function exists
		# to end and it is invisible from inside the game.
		push_warning("Encounter.build placed nothing for region %d"
			% region_index)


## Enemies decide what to do, a few times a second.
func _think(delta: float) -> void:
	if _hero == null or _hero.is_dead():
		return
	_brain_t -= delta
	if _brain_t > 0.0:
		return
	_brain_t = THINK

	var here: Vector2 = _hero.ground_position()
	for n in _enemy_nodes:
		var foe := n as HeroController
		if foe == null or foe.is_dead() or foe.body == null:
			continue
		if foe.is_busy() or foe.is_stunned():
			continue
		var at: Vector2 = foe.ground_position()
		var gap: float = at.distance_to(here)
		var notice: float = AGGRO_BOSS if foe.scale.y >= Encounter.BOSS_SIZE \
			else AGGRO
		if gap > notice:
			continue
		if gap <= REACH:
			foe.stop()
			foe.use_ability(_choose_action(foe, gap), here)
		elif not foe.is_moving():
			foe.move_to(here, true)


## Which of its actions this enemy uses, out of the ones the difficulty lets it.
##
## THE DIFFICULTY IS THE KIT, not just the numbers. Below Merciless an enemy is
## its basic attack and its signature ability; from Merciless it gains a
## second; only at Oblivion does it bring everything, which means the stun, the
## charge and the self-heal all arrive at once and the fight is a different
## shape rather than the same shape with more health.
##
## Within the allowance it prefers the strongest action that is off cooldown
## and actually in range — highest slot first, since slot order is roughly
## power order in every kit — and falls back to the basic, which has no
## cooldown and is therefore always available.
func _choose_action(foe: HeroController, gap: float) -> int:
	var allowed: int = Campaign.enemy_actions(tier)
	for slot in range(allowed - 1, 0, -1):
		var ab: Ability = foe.ability_in_slot(slot)
		if ab == null:
			continue
		if foe.cooldown_left(slot) > 0.0:
			continue
		# A ranged ability used point blank is fine; a short one used from
		# across the field whiffs and puts itself on cooldown for nothing.
		if ab.shape != Ability.Shape.SELF and gap > ab.range_m:
			continue
		return slot
	return 0


## An enemy's swing lands. Same resolution path as the champion's, with the
## champion as the only possible target — without this enemies would animate
## attacks that never did anything, which looks exactly like a broken game.
func _on_enemy_cast(ability: Ability, foe: HeroController) -> void:
	if foe == null or foe.body == null or _hero == null or _hero.body == null:
		return
	var ctx := Combat.Context.new()
	ctx.caster = foe.body
	ctx.origin = foe.ground_position()
	ctx.facing = foe.rotation.y
	var targets: Array[Combatant] = [_hero.body]
	ctx.targets = targets
	ctx.positions = PackedVector2Array([_hero.ground_position()])
	Combat.cast(ability, ctx)
	_show_cast(ability, foe, _hero.ground_position())


## Draw the ability.
##
## ONE PLACE FOR BOTH SIDES. An effect the champion gets and the enemies do not
## tells the player, wrongly, that the enemy attack was a miss — so the player's
## cast and the enemy's cast come through the same call, and the only thing
## that differs is whose signature Vfx reads.
func _show_cast(ability: Ability, caster: HeroController,
		target: Vector2) -> void:
	if caster == null or ability == null or caster.rig == null:
		return
	var who: String = caster.rig.hero_name
	if who == "":
		return
	Vfx.play(self, ability, who, HeroClass.for_hero(who),
		caster.ground_position(), caster.rotation.y,
		target if target != Vector2.INF else caster.ground_position())


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
	_show_cast(ability, _hero, _aim_point())


## The nearest living enemy's ground position, or Vector2.INF. Used to turn the
## champion toward what it is about to hit: on a phone the player has no way to
## aim, so pressing an ability has to mean "hit that one".
func _aim_point(ability: Ability = null) -> Vector2:
	if _hero == null or _hero.body == null:
		return Vector2.INF
	var env: Dictionary = _enemy_context()
	var bodies: Array[Combatant] = env["bodies"]
	var points: PackedVector2Array = env["points"]
	var here: Vector2 = _hero.ground_position()

	# AIMED AT SOMETHING IT CAN ACTUALLY HIT. Picking the globally nearest
	# enemy and turning to face it is not auto-target if that enemy is twelve
	# metres away and the ability reaches three — Combat.cast then finds
	# nothing inside the cone and the press is spent on empty ground, which
	# reads as the button being broken.
	if ability != null and ability.range_m > 0.0:
		var best: Vector2 = Vector2.INF
		var best_d: float = INF
		for i in range(bodies.size()):
			if bodies[i] == null or not bodies[i].alive:
				continue
			if bodies[i].team == _hero.body.team:
				continue
			var d: float = here.distance_to(points[i])
			if d <= ability.range_m and d < best_d:
				best_d = d
				best = points[i]
		if best != Vector2.INF:
			return best
		# Nothing in reach: fall through and still turn toward the nearest, so
		# the champion faces the fight rather than casting over its shoulder.

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

	# THE STICK GETS FIRST REFUSAL. It runs in _input and consumes what it
	# claims, so a press that becomes a stick never reaches here — but the
	# zone test is repeated because iOS synthesises a mouse event from every
	# touch and a synthesised event takes its own path through the stack.
	if _stick != null and e is InputEventScreenTouch \
		and (e as InputEventScreenTouch).pressed \
		and _stick.claims((e as InputEventScreenTouch).position):
		return

	if _track_pinch(e):
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


## Track the fingers nobody else claimed and turn two of them into zoom.
##
## Returns true when the event was a pinch and must not also be read as a tap.
## A two-finger gesture that also issued a move order would have the champion
## sprint off every time the player adjusted the camera.
func _track_pinch(e: InputEvent) -> bool:
	if e is InputEventScreenTouch:
		var t2 := e as InputEventScreenTouch
		var claimed: bool = (_stick != null and _stick.is_active() \
			and not _free_touches.has(t2.index) and _stick.claims(t2.position)) \
			or (_hud != null and _hud.blocks_point(t2.position))
		if t2.pressed:
			if not claimed:
				_free_touches[t2.index] = t2.position
		else:
			_free_touches.erase(t2.index)
		# Releasing a finger ends the gesture; the next pair starts fresh rather
		# than measuring against a span from two fingers ago and snapping.
		if _free_touches.size() < 2:
			_pinch_prev = -1.0
		return false

	if e is InputEventScreenDrag:
		var d := e as InputEventScreenDrag
		if not _free_touches.has(d.index):
			return false
		_free_touches[d.index] = d.position
		if _free_touches.size() < 2:
			return false
		var pts: Array = _free_touches.values()
		var span: float = (pts[0] as Vector2).distance_to(pts[1] as Vector2)
		if span < 1.0:
			return true
		if _pinch_prev > 0.0 and _cam != null:
			# Fingers apart = zoom IN (the world grows), which is the gesture
			# every photo viewer has taught; distance grows, so the camera
			# distance must shrink.
			_cam.pinch(_pinch_prev / span)
		_pinch_prev = span
		return true

	return false


## The stick moved. Screen space in, world space out.
##
## ROTATED BY THE CAMERA'S YAW, not used raw. ArpgCamera holds a fixed 35-degree
## yaw and deliberately never turns, so screen-up is not world-north; feeding
## the raw vector to drive() sends the champion off at an angle to the thumb,
## which feels like drift and is the single most common bug in a stick like
## this. Screen -y (up) must become "away from the camera".
func _on_stick(dir: Vector2) -> void:
	if _hero == null or _hero.is_dead():
		return
	if dir == Vector2.ZERO:
		_hero.drive(Vector2.ZERO)
		return
	_hero.drive(ArpgCamera.stick_to_world(dir), _stick.wants_run())


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
	_hero.use_ability(slot, _aim_point(_hero.ability_in_slot(slot)))


func _process(d: float) -> void:
	# Held finger: keep re-issuing toward where it is now, so dragging steers
	# rather than requiring a tap per step. Re-pathing every frame would be
	# wasteful, so only when the target has moved meaningfully.
	if _holding and _hero != null and not _hero.is_busy():
		if not _hero.is_moving():
			_order_move(_hold_at)
	_auto_attack()
	_think(d)


## Swing at whatever is standing next to you, without being told.
##
## A phone ARPG cannot ask the player to tap an attack button once per swing
## while also steering with the other thumb. The basic attack has no cooldown
## and no cost, so there is never a reason NOT to be using it on something in
## reach — holding it back is busywork, not a decision. The three abilities
## stay manual, because those are the decisions.
##
## Deliberately does nothing while the champion is MOVING: walking past an
## enemy should not stop you dead to trade a hit, and a player dragging the
## stick is telling you where they want to be.
func _auto_attack() -> void:
	if _hero == null or _hero.body == null or _hero.is_dead():
		return
	if _hero.is_busy() or _hero.is_moving() or _hero.is_stunned():
		return
	if _stick != null and _stick.is_active():
		return
	var basic: Ability = _hero.ability_in_slot(0)
	if basic == null:
		return
	var at: Vector2 = _aim_point(basic)
	if at == Vector2.INF:
		return
	if _hero.ground_position().distance_to(at) > basic.range_m:
		return
	_hero.use_ability(0, at)


func _order_move(screen: Vector2) -> void:
	# Checked here as well as on the press, because a drag that wanders over the
	# pad would otherwise keep issuing orders from under the player's thumb.
	if _hud != null and _hud.blocks_point(screen):
		return
	var g: Vector2 = _cam.screen_to_ground(screen)
	if g == Vector2.INF:
		return
	_hero.move_to(g, true)
