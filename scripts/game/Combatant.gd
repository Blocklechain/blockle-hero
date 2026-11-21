class_name Combatant
extends RefCounted
# ------------------------------------------------------------------------------
# Anything that can fight: the player's champion and every enemy.
#
# Health, status effects, and the damage calculation all live here, so a hero
# and a skeleton resolve a hit through exactly the same code. The moment the
# player's damage formula and the enemy's are written separately they drift, and
# the character sheet starts promising numbers the game does not honour.
#
# This class is pure data and maths — no nodes, no scene tree. That keeps it
# testable headlessly (see tools/combattest.gd), which matters because combat
# balance is the thing most likely to be quietly wrong.
# ------------------------------------------------------------------------------

signal damaged(amount: float, crit: bool, source: String)
signal healed(amount: float)
signal died()
signal status_applied(kind: int, duration: float)

enum Team { PLAYER, ENEMY }

var display_name: String = ""
var team: int = Team.ENEMY
var level: int = 1
var stats: Stats = Stats.new()
var school: int = HeroClass.School.MELEE

var health: float = 1.0
var max_health: float = 1.0
var weapon_power: float = 0.0
var armour: float = 0.0

## A flat scale on everything this combatant deals out, 1.0 for the player and
## for any enemy at full strength.
##
## It exists because attack power is `stats + weapon`, and the STATS are most
## of it — an enemy champion at level 1 brings about 21 points of stat damage
## and 4 of weapon. Scaling the weapon alone, which is what the early-campaign
## ramp used to do, moved a 25-damage hit to 21. A difficulty ramp has to reach
## the whole number or it is not a ramp.
##
## Separate from outgoing_multiplier(), which is the WEAKEN status: that one is
## transient and part of the fight, this one is how the encounter was built.
var damage_scale: float = 1.0

var effects: Array[StatusEffect] = []
var alive: bool = true

## Deterministic roll stream. Combat that reroll differently on replay cannot be
## debugged from a save, so crits and dodges come from the seeded hash too.
var rng_seed: int = 0
var _rolls: int = 0

## Callables run on every combatant the instant it is created, passed the new
## Combatant.
##
## WHY A HOOK ON THE CONSTRUCTOR RATHER THAN AT THE SPAWN SITES: feedback — the
## hit thud, the death cue — has to cover the player's champion AND every enemy,
## and enemies will be spawned from several places (campaign waves, bosses,
## summons) over time. Anything a spawner has to remember is something the next
## spawner will forget, and the symptom is an enemy that dies in total silence,
## which nobody notices in review because nothing is obviously broken. `make()`
## is the one door every combatant comes through, so the wiring lives there.
##
## Empty by default, so the headless balance tests are unaffected.
##
## CONSTRUCT THROUGH `make()`, NOT `Combatant.new()`: a bare `new()` cannot be
## hooked, so a combatant built that way is born with no feedback attached.
static var on_spawn: Array[Callable] = []


static func make(name: String, team: int, level: int, stats: Stats,
		school: int, weapon: float, armour_v: float, seed: int) -> Combatant:
	var c := Combatant.new()
	c.display_name = name
	c.team = team
	c.level = level
	c.stats = stats
	c.school = school
	c.weapon_power = weapon
	c.armour = armour_v
	c.rng_seed = seed
	c.max_health = stats.max_health(level) + armour_v * 2.0
	c.health = c.max_health

	# Fully built before any hook sees it — a listener that reads max_health on
	# spawn (a health bar does) must not be handed a half-initialised combatant.
	#
	# `is_valid()` because a hook outlives the node that registered it: reloading
	# the scene frees the audio/HUD node while its Callable is still in the
	# static array, and calling that is an error on every single spawn.
	for hook in on_spawn:
		if hook.is_valid():
			hook.call(c)
	return c


func _roll() -> float:
	_rolls += 1
	return Rng.unit2(rng_seed, _rolls, 6151)


# ------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------

func apply(effect: StatusEffect) -> void:
	# Refresh rather than stack the same kind. Stacking stuns is how a player
	# ends up unable to act for six seconds and puts the phone down.
	for e in effects:
		if e.kind == effect.kind:
			e.remaining = maxf(e.remaining, effect.remaining)
			e.magnitude = maxf(e.magnitude, effect.magnitude)
			return
	effects.append(effect)
	status_applied.emit(effect.kind, effect.remaining)


func has(kind: int) -> bool:
	for e in effects:
		if e.kind == kind and not e.is_expired():
			return true
	return false


func effect_of(kind: int) -> StatusEffect:
	for e in effects:
		if e.kind == kind and not e.is_expired():
			return e
	return null


func is_stunned() -> bool:
	return has(StatusEffect.Kind.STUN)


## Movement multiplier from every source. A stun forces a walk AND slows it —
## the forced walk is applied by the controller, this is the extra penalty.
func move_multiplier() -> float:
	var m: float = 1.0
	if is_stunned():
		m *= StatusEffect.STUN_SPEED_MULT
	var slow: StatusEffect = effect_of(StatusEffect.Kind.SLOW)
	if slow != null:
		m *= clampf(1.0 - slow.magnitude, 0.15, 1.0)
	var haste: StatusEffect = effect_of(StatusEffect.Kind.HASTE)
	if haste != null:
		m *= 1.0 + haste.magnitude
	return clampf(m, 0.1, 3.0)


## Abilities are locked out while stunned. That is what makes a stun a control
## effect rather than a cosmetic slow.
func can_act() -> bool:
	return alive and not is_stunned()


func outgoing_multiplier() -> float:
	var w: StatusEffect = effect_of(StatusEffect.Kind.WEAKEN)
	return clampf(1.0 - (w.magnitude if w != null else 0.0), 0.1, 1.0)


func tick(delta: float) -> void:
	if not alive:
		return
	var expired: Array[StatusEffect] = []
	for e in effects:
		e.remaining -= delta
		if e.kind == StatusEffect.Kind.BURN:
			e.tick_in -= delta
			while e.tick_in <= 0.0 and e.remaining > -e.tick_every:
				e.tick_in += e.tick_every
				# Burn bypasses armour — it is already a small number, and
				# mitigating it twice makes it worthless at high level.
				_take_raw(e.magnitude, false, e.source)
		if e.is_expired():
			expired.append(e)
	for e in expired:
		effects.erase(e)


# ------------------------------------------------------------------------------
# Damage
# ------------------------------------------------------------------------------

## Armour mitigation, as a fraction of damage removed.
##
## Diminishing returns by construction: armour / (armour + K) can approach but
## never reach 1, so no amount of stacking makes a character immortal, and the
## level term keeps a level-5 breastplate from trivialising level-50 content.
const ARMOUR_K: float = 60.0
const ARMOUR_PER_LEVEL: float = 9.0
const MAX_MITIGATION: float = 0.80

func mitigation() -> float:
	var k: float = ARMOUR_K + float(level) * ARMOUR_PER_LEVEL
	return minf(armour / (armour + k), MAX_MITIGATION)


## Base hit before ability multipliers.
func attack_power() -> float:
	return (stats.damage_for(school) + weapon_power) \
		* outgoing_multiplier() * damage_scale


## Resolve an attack from `self` against `target`.
## Returns { "damage", "crit", "dodged", "killed" }.
func strike(target: Combatant, multiplier: float = 1.0,
		label: String = "") -> Dictionary:
	if not alive or target == null or not target.alive:
		return {"damage": 0.0, "crit": false, "dodged": false, "killed": false}

	# Dodge first: a dodged hit does nothing at all, including no crit, which
	# keeps the combat log readable.
	if target._roll() < target.stats.dodge_chance():
		return {"damage": 0.0, "crit": false, "dodged": true, "killed": false}

	var crit: bool = _roll() < stats.crit_chance()
	var raw: float = attack_power() * multiplier * (2.0 if crit else 1.0)
	var dealt: float = raw * (1.0 - target.mitigation())
	var killed: bool = target._take_raw(dealt, crit,
		label if label != "" else display_name)
	return {"damage": dealt, "crit": crit, "dodged": false, "killed": killed}


## Apply damage that has already been mitigated. Returns true if this killed.
func _take_raw(amount: float, crit: bool, source: String) -> bool:
	if not alive or amount <= 0.0:
		return false

	# Shields soak first and are consumed by what they absorb.
	var shield: StatusEffect = effect_of(StatusEffect.Kind.SHIELD)
	if shield != null:
		var absorbed: float = minf(shield.magnitude, amount)
		shield.magnitude -= absorbed
		amount -= absorbed
		if shield.magnitude <= 0.0:
			effects.erase(shield)
		if amount <= 0.0:
			return false

	health = maxf(health - amount, 0.0)
	damaged.emit(amount, crit, source)
	if health <= 0.0:
		alive = false
		died.emit()
		return true
	return false


func heal(amount: float) -> void:
	if not alive or amount <= 0.0:
		return
	var before: float = health
	health = minf(health + amount, max_health)
	healed.emit(health - before)


func health_fraction() -> float:
	return clampf(health / maxf(max_health, 0.0001), 0.0, 1.0)


func status_line() -> String:
	if effects.is_empty():
		return ""
	var parts: PackedStringArray = []
	for e in effects:
		parts.append("%s %.1fs" % [e.name_of(), maxf(e.remaining, 0.0)])
	return ", ".join(parts)
