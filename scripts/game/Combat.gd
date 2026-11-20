class_name Combat
extends RefCounted
# ------------------------------------------------------------------------------
# Resolving an ability: who it hits, what it does to them, what it does to the
# caster.
#
# Kept as pure functions over Combatants and positions, with no nodes involved,
# so the whole of combat can be simulated headlessly. Balance is the easiest
# thing in a game to get quietly wrong, and a system you can only test by
# playing it is a system nobody re-tests after a tuning change.
# ------------------------------------------------------------------------------

## One resolved cast.
class Result extends RefCounted:
	var hit: Array[Combatant] = []
	var killed: Array[Combatant] = []
	var total_damage: float = 0.0
	var crits: int = 0
	var dodges: int = 0
	var healed: float = 0.0

	func describe() -> String:
		return "%d hit, %.0f dmg, %d crit, %d dodged, %d killed" % [
			hit.size(), total_damage, crits, dodges, killed.size()]


## Everything a cast needs to know about the world, without touching the world.
class Context extends RefCounted:
	var caster: Combatant
	var origin: Vector2 = Vector2.ZERO
	var facing: float = 0.0
	## Candidate targets with their positions, parallel arrays.
	var targets: Array[Combatant] = []
	var positions: PackedVector2Array = PackedVector2Array()


## Execute an ability. Returns what happened, so the caller can play effects,
## float numbers and award experience without re-deriving any of it.
static func cast(ability: Ability, ctx: Context) -> Result:
	var r := Result.new()
	var caster: Combatant = ctx.caster
	if caster == null or not caster.alive:
		return r

	# --- what the caster does to itself ---------------------------------
	if ability.heal_fraction > 0.0:
		var amount: float = caster.max_health * ability.heal_fraction
		caster.heal(amount)
		r.healed += amount

	if ability.self_applies >= 0:
		var mag: float = ability.self_magnitude
		# A shield with no authored magnitude scales off the caster, so one
		# number works for a level 1 and a level 60 champion.
		if ability.self_applies == StatusEffect.Kind.SHIELD and mag <= 0.0:
			mag = caster.max_health * 0.30
		caster.apply(StatusEffect.make(ability.self_applies,
			ability.self_duration, mag, ability.id))

	if ability.shape == Ability.Shape.SELF:
		return r

	# --- who it reaches --------------------------------------------------
	var candidates: Array = []
	for i in range(ctx.targets.size()):
		var t: Combatant = ctx.targets[i]
		if t == null or not t.alive or t.team == caster.team:
			continue
		var p: Vector2 = ctx.positions[i] if i < ctx.positions.size() else Vector2.ZERO
		if not ability.covers(ctx.origin, ctx.facing, p):
			continue
		candidates.append({"c": t, "d": ctx.origin.distance_squared_to(p)})

	# Nearest first, so a single-target ability always picks the obvious one
	# rather than whichever happened to be earlier in the array.
	candidates.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))

	var limit: int = maxi(ability.max_targets, 1)
	for i in range(mini(limit, candidates.size())):
		var t: Combatant = candidates[i]["c"]
		var out: Dictionary = caster.strike(t, ability.damage_mult, ability.title)
		r.hit.append(t)
		if bool(out["dodged"]):
			r.dodges += 1
			continue
		r.total_damage += float(out["damage"])
		if bool(out["crit"]):
			r.crits += 1
		if bool(out["killed"]):
			r.killed.append(t)
			continue

		# Status only lands on something still standing — applying a stun to a
		# corpse shows up in the log as a bug report.
		if ability.applies >= 0:
			var mag: float = ability.applies_magnitude
			if ability.applies == StatusEffect.Kind.BURN and mag <= 0.0:
				mag = caster.attack_power() * 0.18
			t.apply(StatusEffect.make(ability.applies,
				ability.applies_duration, mag, ability.id))

	return r


## Nearest living enemy of `team`, or null.
static func nearest_enemy(from: Vector2, team: int, targets: Array[Combatant],
		positions: PackedVector2Array, max_range: float = INF) -> Combatant:
	var best: Combatant = null
	var best_d: float = max_range * max_range
	for i in range(targets.size()):
		var t: Combatant = targets[i]
		if t == null or not t.alive or t.team == team:
			continue
		var d: float = from.distance_squared_to(positions[i])
		if d < best_d:
			best_d = d
			best = t
	return best
