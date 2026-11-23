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
# whether that means a clip or the procedural stand-in. See HeroRig.gd.
#
# The one exception is being HURT, which is not a state: `rig.flinch()` layers a
# reaction over whatever is playing, because no hero was delivered with a `hit`
# clip and because losing your swing every time you are grazed feels terrible.
# ------------------------------------------------------------------------------

signal arrived()
signal ability_used(slot: int)
## Emitted when the swing actually lands, which is when damage should resolve —
## not when the button was pressed.
signal cast_landed(ability: Ability)

## FOR THE HUD. `body` does not exist until setup_combat() runs, so a HUD built
## at scene start cannot connect to `body.damaged` itself — by the time the
## champion has a combat body the HUD has already missed its chance. These two
## exist from construction and simply forward.
##
## Floating damage numbers, the health bar and the hurt vignette all read
## `took_damage`; `champion_died` is the defeat screen's cue. Enemy numbers come
## from `Combatant.on_spawn` instead, which sees every combatant in the game.
signal took_damage(amount: float, crit: bool, source: String)
signal champion_died()

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

## Joystick state. Vector2.ZERO means the stick is released and the path
## follower owns movement again.
var _drive: Vector2 = Vector2.ZERO
var _drive_run: bool = true

## Displacement in progress. A charge travels over the cast; a blink is a
## single hop resolved when the clip lands.
var _dash_from: Vector2 = Vector2.ZERO
var _dash_to: Vector2 = Vector2.ZERO
var _dash_t: float = 0.0
var _dash_time: float = 0.0
var _busy_until: float = 0.0           # locked out while an ability plays
## Whether the ability currently playing plants the feet. See Ability.rooted.
var _cast_rooted: bool = true
## The heading the cast was aimed at, held for its duration so movement cannot
## rotate the hero off their own aim. NAN when nothing is being cast.
var _cast_facing: float = NAN

## How fast a champion moves while casting a non-rooted ability.
##
## NOT 1.0, and the reason is animation rather than balance: there is a single
## AnimationPlayer here and no blend tree, so the cast clip REPLACES the run
## clip for its duration — at full speed the body slides across the ground with
## its legs still. At 55% the slide reads as a committed stride into the swing,
## which is the look most mobile ARPGs settle on for exactly this reason.
##
## Fixing it properly means an AnimationTree with an upper-body mask over all
## 139 rigs. That is a real piece of work and this is the honest interim.
const CAST_MOVE_SCALE: float = 0.55

## ---- THE DODGE ROLL ---------------------------------------------------------
##
## A committed, cooldown-gated escape, which is the one defensive verb the game
## did not have: every other way of not being hit was a passive stat or a lucky
## dodge_chance roll. Boss AoE telegraphs for ~0.9 s and there was nothing to
## DO with that warning except already be standing somewhere else.
##
## The numbers are the whole design, so they are named rather than inlined:
##
##   DISTANCE 4.6 m  further than a boss slam's radius from its edge, so a roll
##                   started inside the ring clears it, and short enough that it
##                   is not a free reposition across the arena.
##   TIME 0.30 s     the roll is committed: nothing can be done during it, which
##                   is what makes spending it a decision rather than a reflex.
##   IFRAME 0.22 s   DELIBERATELY SHORTER THAN THE ROLL. The last ~27% is
##                   recovery with no protection, so a roll read early still
##                   gets punished and spamming it into an attack does not work.
##                   Equal windows would make the roll a strictly-better "do not
##                   take damage" button.
##   COOLDOWN 1.1 s  longer than the roll by enough that two rolls cannot chain
##                   into permanent immunity.
##
## There is NO roll clip. The 139 rigs are Mixamo exports with idle/walk/run/
## attack/ability/hit/death and nothing else, so the roll plays RUN at speed.
## The feel has to come from the ease curve and the i-frame rather than from
## animation, and pretending otherwise would mean a missing-clip fallback
## standing the champion still in the middle of their own dodge.
const DODGE_DISTANCE: float = 4.6
const DODGE_TIME: float = 0.30
const DODGE_IFRAME: float = 0.22
const DODGE_COOLDOWN: float = 1.1

var _dodge_cd: float = 0.0
var _iframe: float = 0.0
var _dodging: bool = false

var _facing: float = 0.0

## Metres walked since the last footstep cue. Steps are fired per DISTANCE, not
## per second, so a walk and a run both sound like the same legs at different
## speeds instead of the walk sounding like slow motion.
var _stride_left: float = 0.0
const STRIDE: float = 1.05             # m between footfalls

## How long the corpse is left on the ground before anything may clear it. Not
## enforced here — the rig simply holds the last frame of its ~5.8 s death clip
## — but the number a caller should wait for before despawning.
const CORPSE_LINGER: float = 2.5

var _dead: bool = false

## Logs the blocked-step and lost-line-of-sight branches. Off by default; both
## were deadlocks during development and this is how they were found.
static var debug_stalls: bool = false


func setup(t: Terrain, hero: String, at: Vector2) -> bool:
	terrain = t
	pathing = Pathing.new(t)

	# Booted from here rather than from the scene, because this is the narrowest
	# point every playable path goes through — the game scene and every tools/
	# harness build their hero this way. Idempotent, and it also arms the
	# Combatant.on_spawn hook that gives enemies their hit and death cues.
	# `self` so it does not have to rely on Engine.get_main_loop(); see boot().
	Audio.boot(self)

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
	Audio.boot(self)
	body = c
	basic = Ability.basic_attack(cls)
	# Passes the hero name, which is what gives every mage its own spellbook.
	abilities = Ability.for_hero(hero if hero != "" else rig.hero_name, cls)
	_cooldowns.clear()

	# THE CHAMPION'S BODY IS WHERE DAMAGE AND DEATH BECOME VISIBLE. Both signals
	# existed and neither had a listener, so taking a hit and being killed looked
	# and sounded exactly like nothing happening.
	if not c.damaged.is_connected(_on_body_damaged):
		c.damaged.connect(_on_body_damaged)
	if not c.died.is_connected(_on_body_died):
		c.died.connect(_on_body_died)


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


## True once this champion has been killed. A dead champion is inert: it takes
## no orders, runs no movement, and its rig is latched to the death clip.
func is_dead() -> bool:
	return _dead


func ground_position() -> Vector2:
	return Vector2(position.x, position.z)


func is_moving() -> bool:
	# Either source of motion counts. Reporting false while the stick is
	# held would tell callers the champion is standing still mid-run.
	return _drive != Vector2.ZERO or _leg < _path.size()


func is_busy() -> bool:
	return _busy_until > 0.0


# ------------------------------------------------------------------------------
# Orders
# ------------------------------------------------------------------------------

## Walk to a world-space point. Returns false if nowhere reachable.
func move_to(target: Vector2, run: bool = true) -> bool:
	if _dead or is_busy():
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
	# Release the stick too. stop() means "cease moving", and leaving
	# _drive set would have the champion keep walking off a stop order.
	_drive = Vector2.ZERO


## Use an ability. Slot 0 is the basic attack; 1-3 are the three per-hero
## abilities the animation pass is producing.
func use_ability(slot: int, facing_target: Vector2 = Vector2.INF) -> bool:
	if _dead or is_busy():
		return false
	# Locked out while stunned. A stun that only slowed you would be a slow.
	if is_stunned():
		return false
	var ab: Ability = ability_in_slot(slot)
	if ab != null and float(_cooldowns.get(ab.id, 0.0)) > 0.0:
		return false
	# A SELF-MOVING ABILITY IS ALWAYS ROOTED, whatever it declares: a dash that
	# could also be steered would fight its own _advance_dash for the champion's
	# position, and the loser is whichever ran last that frame.
	_cast_rooted = ab == null or ab.rooted or ab.move_kind != Ability.Move.NONE
	if _cast_rooted:
		stop()
	else:
		# The PATH is dropped but the STICK is not. A click-to-move order was
		# aimed at where the player wanted to be before they decided to cast,
		# and resuming it afterwards sends them somewhere they have stopped
		# wanting to go; a held stick is a live statement of intent.
		_path = PackedVector2Array()
		_leg = 0
	if facing_target != Vector2.INF:
		var d: Vector2 = facing_target - ground_position()
		if d.length_squared() > 0.0001:
			_facing = atan2(d.x, d.y)
			# HELD FOR THE WHOLE CAST. Without this the facing snaps back to the
			# direction of travel on the next frame, so a cone fired while
			# running sideways comes out sideways — the aim the player took is
			# discarded one frame after they took it.
			_cast_facing = _facing
	# The animation comes from the ability, which maps slots 1-3 onto the three
	# clips every model is rigged with.
	rig.set_state(ab.anim_state() if ab != null else HeroRig.State.ATTACK)
	if ab != null:
		_cooldowns[ab.id] = ab.cooldown
		pending_cast = ab
	# The rig reports its own duration, which is the clip length once rigged and
	# a fixed stand-in time until then — so timing stays consistent either way.
	if ab != null and ab.move_kind != Ability.Move.NONE:
		_begin_dash(ab, facing_target)
	_busy_until = 10.0        # cleared by state_finished; a safety ceiling only
	# The cast sounds on the PRESS even though the damage lands at the end of the
	# clip, because the sound is the game acknowledging the button. Waiting for
	# the swing to connect would make every tap feel like it was dropped.
	Audio.ability(slot)
	ability_used.emit(slot)
	return true


# ------------------------------------------------------------------------------
# Per-frame
# ------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	# A CORPSE DOES NOT TICK. Everything below steers, re-paths and — in the idle
	# branch — calls rig.set_state(IDLE) every frame, which would stand the body
	# back up one frame after it died. Status effects stop too: burning a corpse
	# down past zero re-emits `died`.
	if _dead:
		return
	if body != null:
		body.tick(delta)
	for k in _cooldowns.keys():
		var left: float = float(_cooldowns[k]) - delta
		_cooldowns[k] = maxf(left, 0.0)

	_dodge_cd = maxf(_dodge_cd - delta, 0.0)

	# THE I-FRAME EXPIRES ON ITS OWN CLOCK, not with the roll. DODGE_IFRAME is
	# shorter than DODGE_TIME on purpose, so the tail of the roll is recovery
	# the player can still be punished during.
	if _iframe > 0.0:
		_iframe = maxf(_iframe - delta, 0.0)
		if _iframe == 0.0 and body != null:
			body.invulnerable = false

	# A ROLL IN PROGRESS OUTRANKS EVERYTHING. It is checked before _busy_until
	# because dodge() clears that anyway, and before the stick, because a roll
	# that could be steered mid-air is not a commitment.
	if _dodging:
		_advance_dash(delta)
		if _dash_time == 0.0:
			_dodging = false
			# Belt and braces: if the frame pacing ever let the roll outlast its
			# own i-frame timer, invulnerability must not survive the roll.
			if _iframe == 0.0 and body != null:
				body.invulnerable = false
		return

	if _busy_until > 0.0:
		_busy_until -= delta
		if _dash_time > 0.0:
			_advance_dash(delta)
			_apply_facing(delta)
			return
		# THIS RETURN IS WHAT USED TO FREEZE THE CHAMPION. Every cast, for the
		# length of its clip, with the stick held. Now only a rooted cast stops;
		# anything else keeps walking at CAST_MOVE_SCALE while the clip plays.
		if _cast_rooted:
			_apply_facing(delta)
			return
		if _drive != Vector2.ZERO:
			_drive_step(delta, CAST_MOVE_SCALE)
		_apply_facing(delta)
		return

	# THE JOYSTICK PATH. A held stick is a direction, not a destination, so it
	# bypasses the path follower entirely — planning a route to a point one frame
	# ahead and re-planning next frame would burn an A* every tick and still
	# steer worse than going straight where the thumb points.
	if _drive != Vector2.ZERO:
		_drive_step(delta)
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
	_face_travel(dir)
	_apply_facing(delta)

	# Footsteps, metered by ground covered. `step` is the distance actually moved
	# this frame and so already carries the stun slow and every speed multiplier,
	# which means a crawling stunned hero's footfalls slow down for free.
	_stride_left -= step
	if _stride_left <= 0.0:
		_stride_left = STRIDE
		Audio.footstep()

	# A stunned champion plays WALK even when ordered to run — the drop from a
	# run to a walk is the readable signal that something hit you, and it needs
	# no bespoke stagger clip for 200 models.
	var running: bool = (_speed >= RUN_SPEED - 0.01) and not stunned
	rig.set_locomotion(1.0 if running else 0.45)
	rig.set_state(HeroRig.State.RUN if running else HeroRig.State.WALK)


## Steer continuously toward `dir` (world XZ, any length; magnitude 0..1 scales
## the speed so a half-pushed stick walks). Vector2.ZERO releases the stick.
##
## Clears any tap-to-move path: the two are different intents and letting a
## stale path survive means releasing the stick teleports the hero's attention
## back to wherever it was last told to go.
func drive(dir: Vector2, run: bool = true) -> void:
	if _dead:
		return
	var mag: float = minf(dir.length(), 1.0)
	if mag < 0.001:
		_drive = Vector2.ZERO
		return
	_drive = (dir / dir.length()) * mag
	_drive_run = run
	if not _path.is_empty():
		_path.clear()
		_leg = 0


## True while the stick is held — the HUD dims the tap-to-move affordance.
func is_driven() -> bool:
	return _drive != Vector2.ZERO


## Roll. Returns false when the champion cannot right now, so a HUD button can
## grey itself out instead of lying about being available.
##
## `dir` is a ground-space direction; Vector2.ZERO rolls the way they face,
## which is what pressing the button with no stick input means.
##
## A ROLL CANCELS A CAST, including a rooted one. Being locked out of the escape
## button by your own ability is the complaint the cast-while-moving change was
## about, and it bites harder here: the entire point is to leave somewhere you
## can see an attack landing. Committing to a wind-up should cost the damage,
## not the next ten seconds of being alive.
##
## It does NOT interrupt a dash. A charge already moving the body would fight
## the roll for the position every frame — the same reason a self-moving ability
## is force-rooted during a cast.
func dodge(dir: Vector2 = Vector2.ZERO) -> bool:
	if _dead or _dodging or _dodge_cd > 0.0 or _dash_time > 0.0:
		return false

	var heading: Vector2 = dir
	if heading.length_squared() < 0.0001:
		heading = Vector2(sin(_facing), cos(_facing))
	heading = heading.normalized()

	var here: Vector2 = ground_position()
	# The same validation a blink gets. A roll ending inside a cliff puts the
	# body off the walk grid with nothing able to route it out.
	var land: Vector2 = _safe_landing(here, heading, DODGE_DISTANCE)
	if here.distance_to(land) < 0.4:
		# Rolling into a wall would spend the cooldown and the i-frames for no
		# movement, which reads as the button being broken rather than as the
		# wall being in the way.
		return false

	# Drop whatever was happening. The path has to go too, or the follower
	# resumes walking to a click the player made before they needed to escape.
	_path = PackedVector2Array()
	_leg = 0
	_busy_until = 0.0
	_cast_rooted = true
	_cast_facing = NAN

	_dodging = true
	_dodge_cd = DODGE_COOLDOWN
	_iframe = DODGE_IFRAME
	if body != null:
		body.invulnerable = true

	_dash_from = here
	_dash_to = land
	_dash_t = 0.0
	_dash_time = DODGE_TIME
	_facing = atan2(heading.x, heading.y)
	rig.set_locomotion(1.0)
	rig.set_state(HeroRig.State.RUN)
	return true


## Seconds until the roll is available again. For the HUD's key, which has to
## show the same number the champion is actually obeying.
func dodge_cooldown_left() -> float:
	return _dodge_cd


## 0..1 of the cooldown still to run, for the key's sweep.
func dodge_cooldown_fraction() -> float:
	return clampf(_dodge_cd / DODGE_COOLDOWN, 0.0, 1.0)


## Set up the displacement for an ability that has one.
##
## THE DESTINATION IS VALIDATED BEFORE THE CHAMPION COMMITS. A blink that lands
## inside terrain is unrecoverable — the body is off the walk grid, pathing
## cannot route out of it, and the player is simply stuck — so the landing is
## walked back toward the caster until it is on walkable ground. Shortening a
## blink is survivable; arriving inside a cliff is not.
func _begin_dash(ab: Ability, target: Vector2) -> void:
	var here: Vector2 = ground_position()
	var dir: Vector2

	match ab.move_kind:
		Ability.Move.CHARGE:
			if target == Vector2.INF:
				dir = Vector2(sin(_facing), cos(_facing))
			else:
				var to: Vector2 = target - here
				dir = to.normalized() if to.length() > 0.001 else Vector2(sin(_facing), cos(_facing))
		Ability.Move.RETREAT:
			dir = -Vector2(sin(_facing), cos(_facing))
		_:
			dir = Vector2(sin(_facing), cos(_facing))

	var want: float = ab.move_distance
	if ab.move_kind == Ability.Move.CHARGE and target != Vector2.INF:
		# Stop at the target rather than through it: a charge that overshoots
		# leaves the fighter past the enemy, facing away, which is the opposite
		# of what the button was for.
		want = minf(want, maxf(here.distance_to(target) - ATTACK_RANGE * 0.8, 0.0))

	_dash_from = here
	_dash_to = _safe_landing(here, dir, want)
	_dash_t = 0.0
	# A blink is instant on arrival; a charge travels. Either way it is bounded
	# by the clip, so the body cannot still be sliding after the swing lands.
	_dash_time = 0.0 if ab.move_kind == Ability.Move.BLINK else 0.26
	if ab.move_kind == Ability.Move.BLINK:
		_place(_dash_to)


## The furthest walkable point along `dir`, stepping back toward the caster.
func _safe_landing(from: Vector2, dir: Vector2, distance: float) -> Vector2:
	if distance <= 0.0 or dir.length_squared() < 0.0001:
		return from
	var unit: Vector2 = dir.normalized()
	var d: float = distance
	while d > 0.5:
		var p: Vector2 = from + unit * d
		if pathing.is_walkable(p):
			return p
		d -= 0.5
	return from


func _advance_dash(delta: float) -> void:
	_dash_t = minf(_dash_t + delta, _dash_time)
	var k: float = _dash_t / maxf(_dash_time, 0.0001)
	# Ease out: a charge leaves hard and arrives settling, which reads as weight
	# rather than as a constant-velocity slide.
	var eased: float = 1.0 - pow(1.0 - k, 2.2)
	_place(_dash_from.lerp(_dash_to, eased))
	if _dash_t >= _dash_time:
		_dash_time = 0.0


func _place(p: Vector2) -> void:
	position = Vector3(p.x, terrain.height_at(p), p.y)


## `scale` slows the step without touching the stick's own magnitude — used
## by the cast path so a non-rooted ability advances at CAST_MOVE_SCALE.
func _drive_step(delta: float, scale: float = 1.0) -> void:
	var here: Vector2 = ground_position()

	# Same stun rule as the path follower: forced down to a walk, then slowed
	# further on top. Kept in step with it deliberately — a stun that reads
	# differently depending on how the player happens to be moving is a bug.
	var stunned: bool = is_stunned()
	var base: float = WALK_SPEED if stunned else (RUN_SPEED if _drive_run else WALK_SPEED)
	var speed: float = base * _drive.length() * scale
	if body != null:
		speed *= body.move_multiplier()

	var dir: Vector2 = _drive.normalized()
	var step: float = speed * delta
	var next: Vector2 = here + dir * step

	# WALL SLIDE. Refusing a blocked step outright makes the hero stick to
	# terrain edges and feels broken under a thumb that is still pushing; try
	# each axis alone so a diagonal into a wall slides along it instead.
	if not pathing.is_walkable(next):
		var slide_x: Vector2 = here + Vector2(dir.x, 0.0) * step
		var slide_y: Vector2 = here + Vector2(0.0, dir.y) * step
		if pathing.is_walkable(slide_x):
			next = slide_x
			dir = Vector2(signf(dir.x), 0.0)
		elif pathing.is_walkable(slide_y):
			next = slide_y
			dir = Vector2(0.0, signf(dir.y))
		else:
			# Wedged into a corner. Hold position but keep facing where the
			# player is pushing, so the stick still feels connected.
			_face_travel(_drive)
			_apply_facing(delta)
			rig.set_locomotion(0.0)
			rig.set_state(HeroRig.State.IDLE)
			return

	position = Vector3(next.x, terrain.height_at(next), next.y)
	_face_travel(dir)
	_apply_facing(delta)

	# Metered by ground actually covered, so the stun slow carries through.
	_stride_left -= step
	if _stride_left <= 0.0:
		_stride_left = STRIDE
		Audio.footstep()

	var running: bool = _drive_run and not stunned and _drive.length() > 0.55
	rig.set_locomotion(_drive.length() if running else minf(_drive.length(), 0.45))
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


## Turn to face the direction of travel — UNLESS a cast is holding the aim.
##
## Movement and aiming disagree the moment casting stopped rooting the feet:
## the player lines a cone up on a pack, strafes, and without this the cone
## leaves pointing wherever they happen to be walking. The aim they took wins
## for the length of the cast; travel takes over again when it ends.
func _face_travel(dir: Vector2) -> void:
	if not is_nan(_cast_facing):
		_facing = _cast_facing
		return
	if dir.length_squared() > 0.0001:
		_facing = atan2(dir.x, dir.y)


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
		# The cast is over: movement owns the facing again, and the next cast
		# is free to root or not on its own terms.
		_cast_facing = NAN
		_cast_rooted = true
		rig.set_state(HeroRig.State.IDLE)


# ------------------------------------------------------------------------------
# Taking it
# ------------------------------------------------------------------------------

func _on_body_damaged(amount: float, crit: bool, source: String) -> void:
	# flinch(), not set_state(HIT): the reaction is additive, so being hit while
	# swinging or running shows on the body without cancelling the swing or
	# dropping the hero out of its run cycle. A state change would do both, and
	# the idle branch of _physics_process would overwrite it on the next frame
	# anyway — HIT only ever survived on a hero that was standing perfectly still.
	if rig != null:
		rig.flinch()
	# Forwarded for the HUD's floating numbers; the thud itself comes from the
	# Combatant.on_spawn hook, which covers enemies too.
	took_damage.emit(amount, crit, source)


func _on_body_died() -> void:
	if _dead:
		return
	_dead = true
	stop()
	_busy_until = 0.0
	# Dropped so the end of a death clip cannot resolve the swing the hero was
	# mid-way through when it was killed.
	pending_cast = null
	if rig != null:
		rig.kill()
	champion_died.emit()


## Put this champion back on its feet with the body it has now.
##
## DEATH IS TWO LATCHES, not one: `_dead` here and `is_dead` on the rig. A
## revive that cleared only the body's health left both set, so the champion
## stood there at full health, inert, taking no orders and animating nothing
## — which is exactly what the first version of the party revive did, and it
## reported a healthy partner while leaving a statue on the field.
##
## Only Play's between-waves party revive calls this. Nothing revives an
## enemy, and nothing revives the player's own champion: a run that ends in
## death is supposed to end.
func revive() -> void:
	if not _dead:
		return
	_dead = false
	_busy_until = 0.0
	pending_cast = null
	_cast_facing = NAN
	_cast_rooted = true
	# DYING MID-ROLL LEAVES BOTH LATCHES SET. _physics_process returns early for
	# a corpse, so neither the roll nor its i-frame ever finishes ticking — and a
	# champion revived still flagged invulnerable would be unkillable for the
	# rest of the run.
	_dodging = false
	_iframe = 0.0
	_dodge_cd = 0.0
	_dash_time = 0.0
	if body != null:
		body.invulnerable = false
	stop()
	if rig != null:
		rig.revive()


# ------------------------------------------------------------------------------
# Debug
# ------------------------------------------------------------------------------

func path_points() -> PackedVector2Array:
	return _path
