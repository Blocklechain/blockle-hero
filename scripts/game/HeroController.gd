class_name HeroController
extends Node3D
# ------------------------------------------------------------------------------
# The player: tap a spot, walk there, hit things.
#
# Movement is path-following over the terrain's walk grid rather than physics.
# A Diablo-style game wants the hero to go where you pointed, predictably, on a
# phone where you cannot see your own finger — a rigid body shoved around by
# forces gives you sliding, catching on scenery, and a different result each
# time you tap the same place.
#
# Height is sampled from the heightfield every frame instead of raycast, which
# is exact, free, and cannot fall through a chunk boundary.
#
# ANIMATION: this class never touches an AnimationPlayer. It tells `HeroRig`
# which canonical state it is in and how fast it is going; the rig decides
# whether that means a clip or the procedural stand-in. See HeroRig.gd — the
# models are not rigged yet.
# ------------------------------------------------------------------------------

signal arrived()
signal ability_used(slot: int)
## Emitted when the swing actually lands, which is when damage should resolve —
## not when the button was pressed.
signal cast_landed(ability: Ability)

## The ability waiting to resolve, set on press and consumed when it lands.
var pending_cast: Ability = null

const WALK_SPEED: float = 3.4          # m/s
const RUN_SPEED: float = 6.2
const TURN_RATE: float = 12.0          # radians/s
const ARRIVE_EPSILON: float = 0.22     # m
const ATTACK_RANGE: float = 2.2        # m

## How many waypoints ahead to consider when cutting corners. 14 cells at 0.5 m
## is ~7 m of smoothing, which is more than enough to look natural and short
## enough that the line tests stay cheap.
const LOOKAHEAD: int = 14

var rig: HeroRig
var terrain: Terrain
var pathing: Pathing

## Combat state. Null until setup_combat() is called, so the controller is still
## usable on its own for movement tests.
var body: Combatant = null
var abilities: Array[Ability] = []
var basic: Ability = null
var _cooldowns: Dictionary = {}       # ability id -> seconds remaining

var _path: PackedVector2Array = PackedVector2Array()
var _leg: int = 0
var _speed: float = RUN_SPEED
var _busy_until: float = 0.0           # locked out while an ability plays
var _facing: float = 0.0

## Logs the blocked-step and lost-line-of-sight branches. Off by default; both
## were deadlocks during development and this is how they were found.
static var debug_stalls: bool = false


func setup(t: Terrain, hero: String, at: Vector2) -> bool:
	terrain = t
	pathing = Pathing.new(t)

	rig = HeroRig.new()
	add_child(rig)
	if not rig.load_hero(hero):
		return false
	rig.state_finished.connect(_on_rig_state_finished)

	# Cell CENTRE, not corner — standing exactly on a boundary makes every
	# line-of-sight test from the spawn ambiguous.
	var start: Vector2 = pathing.nearest_walkable_centre(at)
	position = Vector3(start.x, t.height_at(start), start.y)
	return true


## Give this champion a combat body and its class kit. Separate from setup()
## so movement can be tested without dragging in the whole combat system.
func setup_combat(c: Combatant, cls: int, hero: String = "") -> void:
	body = c
	basic = Ability.basic_attack(cls)
	# Passes the hero name, which is what gives every mage its own spellbook.
	abilities = Ability.for_hero(hero if hero != "" else rig.hero_name, cls)
	_cooldowns.clear()


func ability_in_slot(slot: int) -> Ability:
	if slot <= 0:
		return basic
	return abilities[slot - 1] if slot - 1 < abilities.size() else null


func cooldown_left(slot: int) -> float:
	var a: Ability = ability_in_slot(slot)
	return float(_cooldowns.get(a.id, 0.0)) if a != null else 0.0


func cooldown_fraction(slot: int) -> float:
	var a: Ability = ability_in_slot(slot)
	if a == null or a.cooldown <= 0.0:
		return 0.0
	return clampf(cooldown_left(slot) / a.cooldown, 0.0, 1.0)


## STUNNED CHAMPIONS CANNOT ACT. That is what separates a stun from a slow.
func is_stunned() -> bool:
	return body != null and body.is_stunned()


func ground_position() -> Vector2:
	return Vector2(position.x, position.z)


func is_moving() -> bool:
	return _leg < _path.size()


func is_busy() -> bool:
	return _busy_until > 0.0


# ------------------------------------------------------------------------------
# Orders
# ------------------------------------------------------------------------------

## Walk to a world-space point. Returns false if nowhere reachable.
func move_to(target: Vector2, run: bool = true) -> bool:
	if is_busy():
		return false
	_speed = RUN_SPEED if run else WALK_SPEED
	var p: PackedVector2Array = pathing.find(ground_position(), target)
	if p.size() < 2:
		_path = PackedVector2Array()
		return false
	_path = p
	# Skip waypoint 0 — it is the cell the hero is already standing in, and
	# steering toward it produces a visible stutter on the first step.
	_leg = 1
	return true


func stop() -> void:
	_path = PackedVector2Array()
	_leg = 0


## Use an ability. Slot 0 is the basic attack; 1-3 are the three per-hero
## abilities the animation pass is producing.
func use_ability(slot: int, facing_target: Vector2 = Vector2.INF) -> bool:
	if is_busy():
		return false
	# Locked out while stunned. A stun that only slowed you would be a slow.
	if is_stunned():
		return false
	var ab: Ability = ability_in_slot(slot)
	if ab != null and float(_cooldowns.get(ab.id, 0.0)) > 0.0:
		return false
	stop()
	if facing_target != Vector2.INF:
		var d: Vector2 = facing_target - ground_position()
		if d.length_squared() > 0.0001:
			_facing = atan2(d.x, d.y)
	# The animation comes from the ability, which maps slots 1-3 onto the three
	# clips every model is rigged with.
	rig.set_state(ab.anim_state() if ab != null else HeroRig.State.ATTACK)
	if ab != null:
		_cooldowns[ab.id] = ab.cooldown
		pending_cast = ab
	# The rig reports its own duration, which is the clip length once rigged and
	# a fixed stand-in time until then — so timing stays consistent either way.
	_busy_until = 10.0        # cleared by state_finished; a safety ceiling only
	ability_used.emit(slot)
	return true


# ------------------------------------------------------------------------------
# Per-frame
# ------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if body != null:
		body.tick(delta)
	for k in _cooldowns.keys():
		var left: float = float(_cooldowns[k]) - delta
		_cooldowns[k] = maxf(left, 0.0)

	if _busy_until > 0.0:
		_busy_until -= delta
		_apply_facing(delta)
		return

	if _leg >= _path.size():
		rig.set_locomotion(0.0)
		rig.set_state(HeroRig.State.IDLE)
		_apply_facing(delta)
		return

	var here: Vector2 = ground_position()

	# Retire waypoints the hero has reached OR walked past.
	#
	# Proximity alone is not enough: cutting a corner means never passing within
	# ARRIVE_EPSILON of the waypoints being skipped, so `_leg` stalls and the
	# follower keeps re-deciding from an index it walked past minutes ago. The
	# second test handles that — but it only advances when the next waypoint is
	# both nearer AND on a clear line, so a path that loops back on itself
	# cannot trick it into skipping the loop.
	while _leg < _path.size():
		if here.distance_to(_path[_leg]) < ARRIVE_EPSILON:
			_leg += 1
			continue
		if _leg + 1 < _path.size() \
				and here.distance_to(_path[_leg + 1]) <= here.distance_to(_path[_leg]) \
				and pathing.clear_line(here, _path[_leg + 1]):
			_leg += 1
			continue
		break
	if _leg >= _path.size():
		stop()
		rig.set_locomotion(0.0)
		rig.set_state(HeroRig.State.IDLE)
		arrived.emit()
		return

	# Corner-cutting, decided fresh from where the hero IS. Steer at the
	# furthest waypoint still on a clear straight line — smooth diagonal motion
	# without ever committing to a line the hero has drifted off.
	#
	# Steering only — `_leg` is NOT moved here. Committing it to the lookahead
	# result races the index forward 14 waypoints per frame while the hero moves
	# a tenth of a metre; it hits the end of the path in seconds and then steers
	# straight at the final goal through whatever lies between.
	var aim: int = _lookahead(here)
	if aim < 0:
		# Nothing on the path is in line of sight. The hero has drifted into a
		# pocket — nudge it onto a known-good cell and re-plan from there, which
		# is a sub-metre correction and the only thing that reliably breaks the
		# deadlock. Repathing alone just reproduces the same blocked first step.
		var snap: Vector2 = pathing.nearest_walkable_centre(here)
		position = Vector3(snap.x, terrain.height_at(snap), snap.y)
		if debug_stalls:
			print("[hero] no line of sight; snapped (%.2f, %.2f) -> (%.2f, %.2f)" % [
				here.x, here.y, snap.x, snap.y])
		if not move_to(_path[_path.size() - 1], _speed >= RUN_SPEED):
			stop()
		return

	var goal: Vector2 = _path[aim]
	var to_goal: Vector2 = goal - here
	var dist: float = to_goal.length()
	if dist < 0.0001:
		_leg += 1
		return

	# THE STUN RULE. A stunned champion is forced out of a run and down to a
	# walk, then slowed further on top of that. They keep steering — being
	# unable to move at all reads as the game having frozen, and on a
	# touchscreen the player will assume the tap was lost. See StatusEffect.gd.
	var stunned: bool = is_stunned()
	var speed: float = WALK_SPEED if stunned else _speed
	if body != null:
		speed *= body.move_multiplier()

	var dir: Vector2 = to_goal / dist
	var step: float = minf(speed * delta, dist)
	var next: Vector2 = here + dir * step

	# The lookahead only ever returns a target on a verified clear line, and
	# _path[_leg] is an adjacent walkable cell, so a blocked step here means the
	# walk grid changed under us (a prop placed late, a destructible removed).
	# Re-path rather than walk into it — and crucially, do NOT return without
	# moving, or a persistently blocked cell deadlocks the hero on the spot.
	if not pathing.is_walkable(next):
		if debug_stalls:
			print("[hero] blocked step (%.2f, %.2f) -> (%.2f, %.2f)" % [
				here.x, here.y, next.x, next.y])
		if not move_to(_path[_path.size() - 1], _speed >= RUN_SPEED):
			stop()
		return

	position = Vector3(next.x, terrain.height_at(next), next.y)
	_facing = atan2(dir.x, dir.y)
	_apply_facing(delta)

	# A stunned champion plays WALK even when ordered to run — the drop from a
	# run to a walk is the readable signal that something hit you, and it needs
	# no bespoke stagger clip for 200 models.
	var running: bool = (_speed >= RUN_SPEED - 0.01) and not stunned
	rig.set_locomotion(1.0 if running else 0.45)
	rig.set_state(HeroRig.State.RUN if running else HeroRig.State.WALK)


# The furthest waypoint reachable in a straight line from `here`, searched
# backwards from the end of a bounded window so the common case — a long clear
# run — exits on the first test. The window keeps this O(1)-ish per frame
# instead of scanning a 300-cell path.
func _lookahead(here: Vector2) -> int:
	var i: int = mini(_leg + LOOKAHEAD, _path.size() - 1)
	# Includes `_leg` itself, and returns -1 when even that is not reachable.
	# Falling back to `_leg` unverified was the last deadlock: corner-cutting
	# drifts the hero off the path, a wall ends up between it and `_path[_leg]`,
	# and the follower confidently steers into it every frame.
	while i >= _leg:
		if pathing.clear_line(here, _path[i]):
			return i
		i -= 1
	return -1


func _apply_facing(delta: float) -> void:
	# Shortest-arc turn toward the heading, so crossing the +/-PI seam does not
	# spin the hero the long way round.
	var cur: float = rotation.y
	var diff: float = wrapf(_facing - cur, -PI, PI)
	rotation.y = cur + clampf(diff, -TURN_RATE * delta, TURN_RATE * delta)


func _on_rig_state_finished(st: int) -> void:
	if st in [HeroRig.State.ATTACK, HeroRig.State.ABILITY_1,
			HeroRig.State.ABILITY_2, HeroRig.State.ABILITY_3,
			HeroRig.State.HIT]:
		_busy_until = 0.0
		# Damage lands at the END of the animation, not the start. Resolving on
		# the button press means a swing connects before the weapon has moved,
		# which looks wrong and lets a player cancel out of the recovery while
		# keeping the hit.
		if pending_cast != null:
			var ab: Ability = pending_cast
			pending_cast = null
			cast_landed.emit(ab)
		rig.set_state(HeroRig.State.IDLE)


# ------------------------------------------------------------------------------
# Debug
# ------------------------------------------------------------------------------

func path_points() -> PackedVector2Array:
	return _path
