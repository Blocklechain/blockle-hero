extends SceneTree
# ------------------------------------------------------------------------------
# Is an elite pack actually something to be afraid of?
#
# scripts/game/Elite.gd claims seventeen traits, and the expensive failure is not
# a trait that is wrong — it is a trait that is INERT. This project has shipped
# five features wired to nothing, each of them with a passing test that checked
# a signal was emitted rather than that anything happened. So every assertion
# below measures an EFFECT on a Combatant: health moved, a status stuck, a
# victim walked away poisoned, two spawns exist, the ground hurt someone.
#
# THE REASON THIS FILE WAS REWRITTEN. Its previous version hard-coded a list of
# nine traits. Elite.gd had grown to twelve, `roll()` divides by COUNT, and so
# a QUARTER of every elite pack in the game was rolling Rimeclad, Undying or
# Sundering — three traits with no arm in apply(), no arm in on_hit(), no arm in
# proven(), and in one case a function (incoming_multiplier) that the file's own
# documentation described and that did not exist. All three marked their ring on
# the ground, named themselves in the death log, and did nothing whatsoever. The
# harness could not see them because its list did not mention them.
#
# So the list is no longer a list. `Elite.ALL` is derived beside the enum, every
# table is asserted against it, and every per-trait loop below walks it. A trait
# that is added to the enum and nowhere else now fails this file immediately.
#
# The specific things it is here to catch, all of which compile:
#
#   * a trait that roll() can never produce, so it exists only in the enum
#   * A TRAIT THAT roll() CAN produce AND THAT NOTHING IMPLEMENTS
#   * a table (name, blurb, colour) with a hole in it
#   * apply() called twice — a respawn, a retry, a rebuilt wave — squaring
#     Brutal's damage or Brood's health, which is exactly what the shipped
#     version did before the idempotence guard
#   * a ward that reads as a shield in the HUD while health drops behind it
#   * on_hit firing for traits that have no on-hit effect (a Swift elite that
#     poisons is a Venomous elite with the wrong ring)
#   * a frenzy that is connected but never escalates
#   * a mender that heals the nearest instead of the most wounded, which the
#     player cannot learn to play around
#   * a Brood whose spawns are themselves Brood — a map that cannot be cleared
#   * a rot pool that keeps hurting after its art has gone, or outlives its
#     own timer
#   * a resistance so total that a whole mage element cannot clear the map
#   * an Undying that rises twice, or forever
#   * a Sundering that strips the player's BURN — an elite curing the player
#   * a Galvanic fed past its cap into something nothing can outrun
#   * a damage CAP so tight that no amount of hitting finishes it, or so loose
#     that the trait wearing it is a ring around nothing
#   * a damage cap that hands back health the elite never had, so its bar goes
#     UP while the player is hitting it
#   * an elite that swallows a burn and is paid MORE than the burn was worth,
#     which is a fire mage making it tankier by casting
#   * a resistance that a re-cast silently undoes, so the trait works once per
#     fight and then stops — the quietest version of "wired to nothing" there is
#   * AN UNKILLABLE ELITE. Any of the above can produce one, and an immortal
#     elite in a lane is an unfinishable map and a lost save. Every trait is
#     put through a kill loop with a hard cap.
#
# THE SIXTH PASS. The two assertions the fourth pass left behind for exactly this
# — "every trait that claims no hook is live from apply()+on_hit() alone" and
# "every applied trait proves itself on its own body" — were FAILING on Adamant,
# Gorging and Emberclad, three traits the fifth pass declared, tabled, coloured,
# documented at length and never implemented. They are implemented now, with a
# section each below. Three more assertions in the pool section were also failing
# and also real: float drift in pool_tick dropped a bite mid-life and landed a
# free one after the puddle's art had removed itself.
#
# SECTIONS ARE COUNTED. A runtime error aborts the rest of its function and
# GDScript carries on, so a crash would otherwise be reported as zero
# failures. If any section does not reach its own last line, the count at the
# bottom fails the run.
#
#   godot --headless --path . --script tools/elitetest.gd
# ------------------------------------------------------------------------------

const Elite := preload("res://scripts/game/Elite.gd")
const Spells := preload("res://scripts/game/MageSpells.gd")

## NOT a second list. Taken from the file under test, which is the whole point:
## a hand-written copy is what let three traits ship inert.
const ALL: Array = Elite.ALL

## Traits that must do something when their owner's hit lands, and — by being
## absent — the ones that must NOT. Hand-written on purpose, because this is the
## one claim the implementation cannot be asked to confirm about itself: a trait
## that was quietly given an on-hit effect it should not have would otherwise
## agree with whatever Elite.gd happened to do.
const ON_HIT_TRAITS: Array = [
	Elite.Trait.VENOMOUS, Elite.Trait.FESTERING, Elite.Trait.MENDING,
	Elite.Trait.SUNDERING, Elite.Trait.SHACKLING,
]

## Traits whose headline effect lands at SPAWN, so a body that never had apply()
## called on it must fail proven() for all of them. The on-hit traits cannot be
## in here: on_hit() is dispatched on the trait it is handed, so it will poison
## for anybody.
const SPAWN_TRAITS: Array = [
	Elite.Trait.SWIFT, Elite.Trait.WARDED, Elite.Trait.BRUTAL,
	Elite.Trait.FRENZIED, Elite.Trait.BROOD, Elite.Trait.UNBOWED,
	Elite.Trait.RIMECLAD, Elite.Trait.UNDYING, Elite.Trait.GALVANIC,
	Elite.Trait.ADAMANT, Elite.Trait.GORGING, Elite.Trait.EMBERCLAD,
]

const SECTIONS: int = 21

var fails: int = 0
var done: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_the_roll()
	_the_tables()
	_the_idempotence()
	_the_ward()
	_the_on_hit()
	_the_frenzy()
	_the_mending()
	_the_brood()
	_the_pool()
	_the_unbowed()
	_the_rime()
	_the_undying()
	_the_sundering()
	_the_shackle()
	_the_galvanic()
	_the_adamant()
	_the_gorge()
	_the_emberclad()
	_the_kill()
	_the_marks()
	_the_audit()

	print("\n=== %d of %d sections completed ===" % [done, SECTIONS])
	if done != SECTIONS:
		# Loud and fatal: a section that stopped early took its assertions
		# with it, and the ones it never reached are not passes.
		fails += 1
		push_error("elitetest: %d section(s) aborted part-way — "
			% (SECTIONS - done) + "a runtime error above is being hidden")
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------
# Bodies
# ------------------------------------------------------------------------------

## A plain enemy, no trait. Armour 0 on purpose: mitigation() is then exactly
## zero, so the health arithmetic in these tests is the damage dealt and a
## failure is never ambiguous between "the trait is wrong" and "armour ate it".
func foe(armour: float = 0.0, level: int = 10) -> Combatant:
	return Combatant.make("foe", Combatant.Team.ENEMY, level,
		Stats.make(14, 10, 6, 12), HeroClass.School.MELEE, 6.0, armour, 4242)


func hero() -> Combatant:
	return Combatant.make("hero", Combatant.Team.PLAYER, 10,
		Stats.make(12, 12, 8, 12), HeroClass.School.MELEE, 6.0, 0.0, 77)


## An elite with `t` on it, built and applied.
func elite(t: int, armour: float = 0.0) -> Combatant:
	var b: Combatant = foe(armour)
	Elite.apply(b, t)
	return b


func near(a: float, b: float, eps: float = 0.01) -> bool:
	return absf(a - b) <= eps


## Everything currently on a body, as one comparable string.
##
## Used instead of counting effects because Sundering REMOVES one: a test that
## only watched the count grow would read a successful strip as "did nothing",
## which is the exact mistake that hides an inert trait.
func finger(c: Combatant) -> String:
	var parts: PackedStringArray = []
	for e in c.effects:
		parts.append("%d:%.2f" % [e.kind, e.magnitude])
	parts.sort()
	return ",".join(parts)


## A victim carrying what a real player carries into a fight: a ward off their
## slot-3 button and a burst of speed. Sundering needs something to tear off,
## and a bare target would let it pass by doing nothing.
func warded_hero() -> Combatant:
	var v: Combatant = hero()
	v.apply(StatusEffect.make(StatusEffect.Kind.SHIELD, 20.0, 40.0, "slot3"))
	v.apply(StatusEffect.make(StatusEffect.Kind.HASTE, 20.0, 0.25, "slot3"))
	return v


# ------------------------------------------------------------------------------
# 1. Every trait is reachable, and the same walk-in is the same elite
# ------------------------------------------------------------------------------

func _the_roll() -> void:
	print("\n=== roll() can produce every trait ===")
	var seen: Dictionary = {}
	var out_of_range: int = 0
	for seed in [1, 7, 99, 31337]:
		for i in range(2000):
			var t: int = Elite.roll(seed, i)
			seen[t] = int(seen.get(t, 0)) + 1
			if t <= Elite.Trait.NONE or t > Elite.COUNT:
				out_of_range += 1

	var missing: PackedStringArray = []
	for t in ALL:
		if not seen.has(t):
			missing.append(Elite.name_of(t))
	check("every trait in the enum is reachable from roll()",
		missing.is_empty(), "missing: %s" % ", ".join(missing))
	check("...and roll() never returns NONE or a trait that does not exist",
		out_of_range == 0, "%d stray" % out_of_range)

	# No trait may be rare enough to never be met: a one-in-a-thousand elite is
	# a trait the player will never learn.
	var floor_share: float = 0.5 / float(Elite.COUNT)
	var total: float = 8000.0
	var rarest: String = ""
	var rarest_share: float = 1.0
	for t in ALL:
		var share: float = float(seen.get(t, 0)) / total
		if share < rarest_share:
			rarest_share = share
			rarest = Elite.name_of(t)
	check("...and none of them is vanishingly rare", rarest_share >= floor_share,
		"rarest %s at %.1f%%" % [rarest, rarest_share * 100.0])

	# Seeded, because an elite that is a different elite every time the player
	# walks back into the same map cannot be prepared for.
	var stable: bool = true
	for i in range(200):
		if Elite.roll(31337, i) != Elite.roll(31337, i):
			stable = false
	var moves: bool = false
	for i in range(200):
		if Elite.roll(31337, i) != Elite.roll(99, i):
			moves = true
	check("the same spawn rolls the same elite every walk-in",
		stable and moves, "stable per seed, different across seeds")
	done += 1


# ------------------------------------------------------------------------------
# 2. THE TABLES HAVE NO HOLES, AND NOTHING IS DECLARED WITHOUT BEING WIRED
#
# This is the section whose absence let three traits ship doing nothing.
# ------------------------------------------------------------------------------

func _the_tables() -> void:
	print("\n=== the enum, the tables and the hook list all agree ===")
	check("ALL and COUNT describe the same number of traits",
		ALL.size() == Elite.COUNT, "%d listed, COUNT %d"
			% [ALL.size(), Elite.COUNT])
	check("...and COUNT is the enum's size, so roll() cannot miss one",
		Elite.COUNT == Elite.Trait.size() - 1,
		"%d of %d enum entries" % [Elite.COUNT, Elite.Trait.size()])

	var holes: PackedStringArray = []
	for t in ALL:
		if Elite.name_of(t) == "" or Elite.blurb_of(t) == "" \
				or not Elite.COLOURS.has(t):
			holes.append(str(t))
	check("every trait has a name, a blurb and a colour", holes.is_empty(),
		"holes at enum value(s): %s" % ", ".join(holes))
	check("...and no table carries an entry for a trait that does not exist",
		Elite.NAMES.size() == Elite.COUNT
			and Elite.BLURBS.size() == Elite.COUNT
			and Elite.COLOURS.size() == Elite.COUNT,
		"%d names, %d blurbs, %d colours"
			% [Elite.NAMES.size(), Elite.BLURBS.size(), Elite.COLOURS.size()])

	# EVERY TRAIT NOT IN NEEDS_HOOK MUST BE LIVE ON ITS OWN. Play.gd already
	# calls apply() and on_hit(); anything that needs more than those two has to
	# say so in NEEDS_HOOK, and anything that does not say so has to work.
	var inert: PackedStringArray = []
	for t in ALL:
		if Elite.NEEDS_HOOK.has(t):
			continue
		if not Elite.proven(t, elite(t)):
			inert.append(Elite.name_of(t))
	check("every trait that claims no hook is live from apply()+on_hit() alone",
		inert.is_empty(), "inert: %s" % ", ".join(inert))

	# And the four that DO need a hook are not allowed to be elites that do
	# nothing until somebody wires them: each must already change something at
	# spawn or on a landed hit.
	var dead_on_arrival: PackedStringArray = []
	for t in Elite.NEEDS_HOOK.keys():
		var body: Combatant = elite(int(t))
		var plain: Combatant = foe()
		var at_spawn: bool = not body.effects.is_empty() \
			or not near(body.max_health, plain.max_health) \
			or not near(body.damage_scale, plain.damage_scale)
		var victim: Combatant = warded_hero()
		var before: String = finger(victim)
		var self_before: float = body.health
		body.health = body.max_health * 0.5
		self_before = body.health
		Elite.on_hit(int(t), body, victim)
		var on_a_hit: bool = finger(victim) != before or body.health > self_before
		# A clad's live half is neither of those two: it is what the element it
		# has an opinion about does differently, so both are asked directly.
		if int(t) == Elite.Trait.RIMECLAD:
			body.apply(StatusEffect.make(StatusEffect.Kind.SLOW, 2.0, 0.5, "x"))
			at_spawn = not body.has(StatusEffect.Kind.SLOW)
		if int(t) == Elite.Trait.EMBERCLAD:
			var fuse: StatusEffect = StatusEffect.make(StatusEffect.Kind.BURN,
				4.0, 10.0, "x")
			var cadence: float = fuse.tick_every
			body.apply(fuse)
			at_spawn = fuse.tick_every > cadence
		if not at_spawn and not on_a_hit:
			dead_on_arrival.append(Elite.name_of(int(t)))
	check("...and the hooked traits still do something before anyone calls them",
		dead_on_arrival.is_empty(), "do nothing yet: %s"
			% ", ".join(dead_on_arrival))
	# FIVE, AND THE FIFTH SHARES THE FOURTH'S CALL. Emberclad is listed because
	# the list is keyed by trait and this harness reads it to decide which traits
	# are allowed to be less than whole — but CLAD means it adds no new hook, so
	# the count of distinct CALLS requested has not moved.
	var calls: Dictionary = {}
	for h in Elite.NEEDS_HOOK.values():
		calls[String(h).split(" ")[0]] = true
	check("...the hook list names traits and nothing else",
		Elite.NEEDS_HOOK.size() == 5
			and Elite.NEEDS_HOOK.has(Elite.Trait.MENDING)
			and Elite.NEEDS_HOOK.has(Elite.Trait.BROOD)
			and Elite.NEEDS_HOOK.has(Elite.Trait.FESTERING)
			and Elite.NEEDS_HOOK.has(Elite.Trait.RIMECLAD)
			and Elite.NEEDS_HOOK.has(Elite.Trait.EMBERCLAD),
		"%d declared" % Elite.NEEDS_HOOK.size())
	check("...and the two clads ask for ONE call between them, not two",
		calls.size() == Elite.NEEDS_HOOK.size() - 1
			and String(Elite.NEEDS_HOOK[Elite.Trait.EMBERCLAD]).begins_with(
				"Elite.incoming_multiplier()"),
		"%d distinct call(s) for %d trait(s)"
			% [calls.size(), Elite.NEEDS_HOOK.size()])
	done += 1


# ------------------------------------------------------------------------------
# 3. apply() twice is apply() once
# ------------------------------------------------------------------------------

func _the_idempotence() -> void:
	print("\n=== apply() does not stack on itself ===")
	for t in ALL:
		var once: Combatant = elite(t)
		var twice: Combatant = elite(t)
		Elite.apply(twice, t)
		Elite.apply(twice, t)

		var same: bool = near(once.damage_scale, twice.damage_scale) \
			and near(once.max_health, twice.max_health) \
			and near(once.health, twice.health) \
			and once.effects.size() == twice.effects.size()
		# The magnitudes too, not just the count: a second HASTE refreshes
		# rather than appends, so a doubled bonus would hide behind an
		# unchanged effect count.
		for kind in [StatusEffect.Kind.HASTE, StatusEffect.Kind.SHIELD,
				StatusEffect.Kind.SLOW]:
			var a: StatusEffect = once.effect_of(kind)
			var b: StatusEffect = twice.effect_of(kind)
			if (a == null) != (b == null):
				same = false
			elif a != null and not near(a.magnitude, b.magnitude):
				same = false
		# And no second watcher. Three traits connect a listener in apply(), and
		# two listeners on one body would double every reaction — a Galvanic fed
		# twice per stun, an Undying that could rise off one lethal hit twice.
		if once.status_applied.get_connections().size() \
				!= twice.status_applied.get_connections().size() \
				or once.damaged.get_connections().size() \
				!= twice.damaged.get_connections().size():
			same = false
		check("%s survives a double apply unchanged" % Elite.name_of(t), same,
			"dmg x%.2f, hp %.0f, %d listener(s)" % [twice.damage_scale,
				twice.max_health, twice.status_applied.get_connections().size()
					+ twice.damaged.get_connections().size()])

	# And the body remembers which trait it got, which is what makes the guard
	# possible at all — and what lets a system holding only a Combatant ask.
	var b2: Combatant = elite(Elite.Trait.BRUTAL)
	var scale: float = b2.damage_scale
	Elite.apply(b2, Elite.Trait.SWIFT)
	check("a second, different trait is refused (one trait, not a stack)",
		Elite.trait_of(b2) == Elite.Trait.BRUTAL
			and not b2.has(StatusEffect.Kind.HASTE)
			and near(b2.damage_scale, scale),
		Elite.name_of(Elite.trait_of(b2)))
	check("a body with no trait reports NONE",
		Elite.trait_of(foe()) == Elite.Trait.NONE
			and Elite.trait_of(null) == Elite.Trait.NONE)
	done += 1


# ------------------------------------------------------------------------------
# 4. A ward has to be broken before health moves
# ------------------------------------------------------------------------------

func _the_ward() -> void:
	print("\n=== the ward comes off before the health ===")
	var w: Combatant = elite(Elite.Trait.WARDED)
	var hp: float = w.max_health
	var ward: float = hp * Elite.WARD_FRACTION
	check("it spawns with a ward worth a share of its health",
		w.has(StatusEffect.Kind.SHIELD)
			and near(w.effect_of(StatusEffect.Kind.SHIELD).magnitude, ward),
		"%.0f of %.0f hp" % [ward, hp])

	# Everything short of the ward's value leaves health untouched.
	var bites: int = 0
	while w.has(StatusEffect.Kind.SHIELD) and bites < 50:
		w.take_hit(ward * 0.25, "test")
		bites += 1
		if not near(w.health, hp):
			break
	check("...health does not move while the ward holds", near(w.health, hp),
		"%.1f of %.0f after %d hits" % [w.health, hp, bites])
	check("...and the ward is gone once it has absorbed its worth",
		not w.has(StatusEffect.Kind.SHIELD), "%d hits" % bites)

	# And now it bleeds like anything else.
	w.take_hit(ward * 0.25, "test")
	check("...then the very next hit takes health",
		w.health < hp and near(w.health, hp - ward * 0.25),
		"%.1f of %.0f" % [w.health, hp])

	# The ward is a share of health, so it scales — a flat ward would be
	# everything at level 1 and nothing at level 60.
	var low: Combatant = foe(0.0, 1)
	Elite.apply(low, Elite.Trait.WARDED)
	check("...the ward scales with the elite it is on",
		near(low.effect_of(StatusEffect.Kind.SHIELD).magnitude,
			low.max_health * Elite.WARD_FRACTION)
			and low.max_health < hp,
		"level 1: %.0f" % low.effect_of(StatusEffect.Kind.SHIELD).magnitude)
	done += 1


# ------------------------------------------------------------------------------
# 5. on_hit fires for the traits that have one, and only those
# ------------------------------------------------------------------------------

func _the_on_hit() -> void:
	print("\n=== what a landed hit leaves behind ===")
	for t in ALL:
		var e: Combatant = elite(t)
		# Carrying a ward and a haste, so a trait that STRIPS something shows up
		# as loudly as one that applies something.
		var v: Combatant = warded_hero()
		var before: String = finger(v)
		# Wounded, so a heal on the attacker's side is measurable at all.
		e.health = e.max_health * 0.5
		var before_self: float = e.health
		Elite.on_hit(t, e, v)

		var touched_victim: bool = finger(v) != before
		var healed_self: bool = e.health > before_self
		var expected: bool = ON_HIT_TRAITS.has(t)
		var fired: bool = touched_victim or healed_self
		check("%s on_hit %s" % [Elite.name_of(t),
			"lands something" if expected else "does nothing"],
			fired == expected,
			"victim [%s] -> [%s], self %+.1f hp"
				% [before, finger(v), e.health - before_self])

	# The specific effect of each, because "something changed" is not enough:
	# a trait that applied the wrong status would pass the loop above.
	var ven: Combatant = elite(Elite.Trait.VENOMOUS)
	var v1: Combatant = hero()
	Elite.on_hit(Elite.Trait.VENOMOUS, ven, v1)
	var burn: StatusEffect = v1.effect_of(StatusEffect.Kind.BURN)
	check("...Venomous leaves a burn that scales off its attack",
		burn != null
			and near(burn.magnitude,
				ven.attack_power() * Elite.VENOM_FRACTION, 0.05),
		"%.2f/tick for %.1fs" % [
			burn.magnitude if burn != null else 0.0,
			burn.remaining if burn != null else 0.0])

	var rot: Combatant = elite(Elite.Trait.FESTERING)
	var v2: Combatant = hero()
	var hit_before: float = v2.attack_power()
	Elite.on_hit(Elite.Trait.FESTERING, rot, v2)
	check("...Festering saps the victim's own damage",
		v2.has(StatusEffect.Kind.WEAKEN) and v2.attack_power() < hit_before,
		"%.1f -> %.1f dmg" % [hit_before, v2.attack_power()])

	var mend: Combatant = elite(Elite.Trait.MENDING)
	mend.health = mend.max_health * 0.5
	var mend_before: float = mend.health
	Elite.on_hit(Elite.Trait.MENDING, mend, hero())
	check("...Mending closes its own wounds as it feeds",
		near(mend.health - mend_before,
			mend.attack_power() * Elite.MEND_SELF_FRACTION, 0.05),
		"+%.1f hp" % (mend.health - mend_before))
	# Capped, or every mender would be a damage sponge with no ceiling.
	mend.health = mend.max_health
	Elite.on_hit(Elite.Trait.MENDING, mend, hero())
	check("...and cannot heal past full", near(mend.health, mend.max_health),
		"%.1f of %.0f" % [mend.health, mend.max_health])

	# A corpse is not a target: status on a dead body shows up in the log as
	# a bug report, and a strip spent on a corpse is a ward the player watched
	# survive the hit that killed them.
	var dead: Combatant = warded_hero()
	dead.alive = false
	var n: String = finger(dead)
	for t2 in ON_HIT_TRAITS:
		Elite.on_hit(t2, ven, dead)
	check("...nothing is applied to, or torn off, a corpse",
		finger(dead) == n, "[%s]" % finger(dead))
	done += 1


# ------------------------------------------------------------------------------
# 6. Frenzied gets faster as it loses health
# ------------------------------------------------------------------------------

func _the_frenzy() -> void:
	print("\n=== the frenzy builds as it bleeds ===")
	var f: Combatant = elite(Elite.Trait.FRENZIED)
	var at_full: float = f.move_multiplier()
	check("it is visibly keyed-up before it is touched",
		f.has(StatusEffect.Kind.HASTE) and at_full > 1.0,
		"x%.2f move" % at_full)

	# Measured as MOVEMENT, not as the magnitude of a status: haste only means
	# anything because Combatant.move_multiplier reads it, and that is the
	# link that would break silently.
	var steps: Array = []
	for i in range(4):
		f.take_hit(f.max_health * 0.2, "test")
		steps.append(f.move_multiplier())
	var rising: bool = true
	var prev: float = at_full
	for s in steps:
		if float(s) <= prev:
			rising = false
		prev = float(s)
	check("...and moves faster at every step down", rising,
		"x%.2f -> %s" % [at_full,
			", ".join(steps.map(func(x): return "%.2f" % float(x)))])
	check("...reaching the full frenzy near death",
		f.move_multiplier() >= 1.0 + Elite.FRENZY_MAX * 0.6,
		"x%.2f at %.0f%% hp" % [f.move_multiplier(),
			f.health_fraction() * 100.0])

	# A frenzy that receded when the elite was healed would have the player
	# watching an enemy's speed flicker with nothing to attribute it to.
	var peak: float = f.move_multiplier()
	f.heal(f.max_health)
	f.take_hit(1.0, "test")
	check("...and never winds back down once it is up",
		f.move_multiplier() >= peak - 0.001,
		"x%.2f at full health" % f.move_multiplier())

	# The watch is per-elite, not global: a Frenzied elite must not speed up
	# because something else got hit.
	var plain: Combatant = elite(Elite.Trait.BRUTAL)
	plain.take_hit(plain.max_health * 0.6, "test")
	check("...a non-Frenzied elite gains nothing from bleeding",
		not plain.has(StatusEffect.Kind.HASTE)
			and near(plain.move_multiplier(), 1.0),
		"x%.2f move" % plain.move_multiplier())
	done += 1


# ------------------------------------------------------------------------------
# 7. Mending puts the pack back up
# ------------------------------------------------------------------------------

func _the_mending() -> void:
	print("\n=== the mender picks the worst wound ===")
	var m: Combatant = elite(Elite.Trait.MENDING)
	var full: Combatant = foe()
	var scratched: Combatant = foe()
	scratched.health = scratched.max_health * 0.8
	var dying: Combatant = foe()
	dying.health = dying.max_health * 0.15
	var corpse: Combatant = foe()
	corpse.health = 0.0
	corpse.alive = false

	var before: float = dying.health
	# Ordered so the WRONG answers come first: a mender that healed the first
	# entry, or the first wounded entry, passes nothing here.
	var healed: float = Elite.mend(Elite.Trait.MENDING, m,
		[full, scratched, corpse, dying])
	check("it heals the most wounded packmate", dying.health > before
		and healed > 0.0, "+%.1f hp to the one at 15%%" % healed)
	check("...and not the one that was merely scratched",
		near(scratched.health, scratched.max_health * 0.8),
		"%.1f hp" % scratched.health)
	check("...nor the one at full health",
		near(full.health, full.max_health))
	check("...nor the corpse", near(corpse.health, 0.0) and not corpse.alive)
	check("...by an amount that scales off its own attack",
		near(healed, m.attack_power() * Elite.MEND_PACK_FRACTION, 0.05),
		"%.1f" % healed)

	# Itself is not a packmate: on_hit is its self-heal, and a pulse that also
	# topped itself up would make it a lifesteal trait by accident.
	m.health = m.max_health * 0.1
	var self_before: float = m.health
	check("...it does not pulse itself",
		near(Elite.mend(Elite.Trait.MENDING, m, [m]), 0.0)
			and near(m.health, self_before),
		"%.1f hp" % m.health)
	check("...a full pack gets nothing (no wasted pulse)",
		near(Elite.mend(Elite.Trait.MENDING, m, [full]), 0.0))
	check("...and no other trait mends at all",
		near(Elite.mend(Elite.Trait.SWIFT, m, [dying]), 0.0)
			and near(Elite.mend(Elite.Trait.NONE, m, [dying]), 0.0))

	# A dead mender stops mending. Called from a brain tick, this is the frame
	# between death and the corpse being pruned.
	m.alive = false
	check("...a dead mender heals nobody",
		near(Elite.mend(Elite.Trait.MENDING, m, [dying]), 0.0))
	done += 1


# ------------------------------------------------------------------------------
# 8. Brood is two creatures, and the spawns are not elites
# ------------------------------------------------------------------------------

func _the_brood() -> void:
	print("\n=== the brood bursts ===")
	var plain: Combatant = foe()
	var b: Combatant = elite(Elite.Trait.BROOD)
	check("it is bloated, and slow with it",
		b.max_health > plain.max_health
			and near(b.max_health, plain.max_health * Elite.BROOD_BLOAT)
			and b.move_multiplier() < 1.0,
		"%.0f hp, x%.2f move" % [b.max_health, b.move_multiplier()])
	check("...and it spawns at the health it advertises",
		near(b.health, b.max_health))

	var kids: Array = Elite.split(Elite.Trait.BROOD, b)
	check("it bursts into exactly %d" % Elite.SPLIT_COUNT,
		kids.size() == Elite.SPLIT_COUNT, "%d spawn(s)" % kids.size())

	var all_lesser: bool = not kids.is_empty()
	var any_elite: bool = false
	for k in kids:
		var kid := k as Combatant
		if kid == null:
			all_lesser = false
			continue
		if kid.max_health >= b.max_health or kid.health > kid.max_health \
				or kid.damage_scale >= b.damage_scale \
				or kid.attack_power() >= b.attack_power() \
				or not kid.alive:
			all_lesser = false
		if Elite.trait_of(kid) != Elite.Trait.NONE:
			any_elite = true
	check("...and each one is genuinely lesser", all_lesser,
		"%.0f hp vs %.0f, %.1f dmg vs %.1f" % [
			(kids[0] as Combatant).max_health, b.max_health,
			(kids[0] as Combatant).attack_power(), b.attack_power()])

	# THE UNFINISHABLE-MAP CHECK. A spawn that carried the trait would split
	# again, and again.
	check("...the spawns are NOT elites, so nothing splits forever",
		not any_elite, "trait_of(spawn) = %s"
			% Elite.name_of(Elite.trait_of(kids[0] as Combatant)))
	check("...the whole brood is still less than the parent was",
		(kids[0] as Combatant).max_health
			+ (kids[1] as Combatant).max_health < b.max_health,
		"%.0f vs %.0f" % [(kids[0] as Combatant).max_health
			+ (kids[1] as Combatant).max_health, b.max_health])
	check("...two spawns of the same parent roll differently",
		(kids[0] as Combatant).rng_seed != (kids[1] as Combatant).rng_seed)
	check("...and the same parent bursts the same way twice",
		(Elite.split(Elite.Trait.BROOD, b)[0] as Combatant).rng_seed
			== (kids[0] as Combatant).rng_seed, "seeded")
	check("...no other trait splits",
		Elite.split(Elite.Trait.VENOMOUS, b).is_empty()
			and Elite.split(Elite.Trait.BROOD, null).is_empty())
	done += 1


# ------------------------------------------------------------------------------
# 9. The ground a Festering elite died on
# ------------------------------------------------------------------------------

func _the_pool() -> void:
	print("\n=== the rot pool denies its ground ===")
	var r: Combatant = elite(Elite.Trait.FESTERING)
	var pool: Dictionary = Elite.death_pool(Elite.Trait.FESTERING, r)
	check("a Festering death leaves a pool with real numbers",
		not pool.is_empty() and float(pool["dps"]) > 0.0
			and float(pool["radius"]) > 1.0
			and near(float(pool["left"]), Elite.POOL_SECONDS),
		"%.1f dps, %.1fm, %.1fs" % [pool["dps"], pool["radius"], pool["left"]])
	check("...and no other trait leaves one",
		Elite.death_pool(Elite.Trait.BRUTAL, r).is_empty()
			and Elite.death_pool(Elite.Trait.FESTERING, null).is_empty())

	var v: Combatant = hero()
	var outside: Combatant = hero()
	var start: float = v.health
	var dealt: float = 0.0
	# Ten frames per second for its whole life, which is how Play will drive it.
	for i in range(int(Elite.POOL_SECONDS * 10.0)):
		dealt += Elite.pool_tick(pool, 0.1, [v])
	check("...standing in it costs health over time",
		v.health < start and dealt > 0.0,
		"%.1f damage over %.0fs" % [dealt, Elite.POOL_SECONDS])
	check("...at the rate it advertised",
		near(dealt, float(pool["dps"]) * Elite.POOL_SECONDS, 0.5),
		"%.1f vs %.1f expected"
			% [dealt, float(pool["dps"]) * Elite.POOL_SECONDS])
	check("...and anyone who stayed out of it is untouched",
		near(outside.health, outside.max_health))

	# It ends. A hazard that outlives its own timer is the worst version of
	# this bug: invisible, permanent, and it kills the player in a cleared map.
	check("...it runs out", near(float(pool["left"]), 0.0),
		"%.2fs left" % float(pool["left"]))
	var after: float = v.health
	for i in range(20):
		Elite.pool_tick(pool, 0.1, [v])
	check("...and a spent pool never hurts anyone again", near(v.health, after),
		"%.1f hp" % v.health)

	# Armour applies, because the pool goes through take_hit like every other
	# source. A hazard that ignored gear would make the gear worthless against
	# the one mechanic the player is meant to build around.
	var soft: Combatant = hero()
	var armoured: Combatant = foe(100.0)
	var p2: Dictionary = Elite.death_pool(Elite.Trait.FESTERING, r)
	for i in range(5):
		Elite.pool_tick(p2, 0.1, [soft, armoured])
	var soft_lost: float = soft.max_health - soft.health
	var hard_lost: float = armoured.max_health - armoured.health
	check("...armour mitigates it like any other hit",
		hard_lost < soft_lost and hard_lost > 0.0,
		"%.1f vs %.1f through %.0f%% mitigation"
			% [hard_lost, soft_lost, armoured.mitigation() * 100.0])

	# A corpse in the puddle is not a punching bag.
	var body: Combatant = hero()
	body.alive = false
	check("...corpses in it are left alone",
		near(Elite.pool_tick(p2, 1.0, [body]), 0.0))

	# THE ART AND THE DAMAGE SHARE ONE CLOCK. The mark reads the same
	# Dictionary pool_tick advances, so it cannot linger after the hazard is
	# gone or vanish while it is still hurting.
	var holder := Node3D.new()
	var p3: Dictionary = Elite.death_pool(Elite.Trait.FESTERING, r)
	var art: Node3D = Elite.pool_mark(holder, Vector3(1, 0, 2), p3)
	var fade: Node = art.get_node_or_null("PoolFade") if art != null else null
	if fade == null and art != null:
		for c in art.get_children():
			if c is Elite.PoolFade:
				fade = c
	check("the pool is drawn where it fell",
		art != null and art.name == "RotPool"
			and art.position.is_equal_approx(Vector3(1, 0, 2))
			and fade != null,
		"%d child node(s)" % (art.get_child_count() if art != null else 0))
	var bright: float = 0.0
	if fade != null:
		(fade as Elite.PoolFade)._process(0.0)
		bright = (fade as Elite.PoolFade).fill.albedo_color.a
		# Advance the HAZARD, not the art, and the art must follow.
		Elite.pool_tick(p3, Elite.POOL_SECONDS, [])
		(fade as Elite.PoolFade)._process(0.0)
	check("...it dims with the hazard's own clock, not a second one",
		fade != null and (fade as Elite.PoolFade).fill.albedo_color.a < bright,
		"alpha %.2f -> %.2f" % [bright,
			(fade as Elite.PoolFade).fill.albedo_color.a if fade != null
				else 0.0])
	check("...and takes itself away when the hazard is spent",
		art != null and art.is_queued_for_deletion())
	holder.free()
	done += 1


# ------------------------------------------------------------------------------
# 10. Control slides off an Unbowed elite — but only control
# ------------------------------------------------------------------------------

func _the_unbowed() -> void:
	print("\n=== the unbowed cannot be held ===")
	var u: Combatant = elite(Elite.Trait.UNBOWED)
	var walk: float = u.move_multiplier()

	u.apply(StatusEffect.make(StatusEffect.Kind.STUN, 3.0, 0.0, "nova"))
	check("a stun does not stick to it",
		not u.is_stunned() and u.can_act()
			and not u.has(StatusEffect.Kind.STUN),
		"can_act %s" % u.can_act())

	u.apply(StatusEffect.make(StatusEffect.Kind.SLOW, 3.0, 0.5, "frost"))
	check("...nor a slow, and its speed is untouched",
		not u.has(StatusEffect.Kind.SLOW) and near(u.move_multiplier(), walk),
		"x%.2f move" % u.move_multiplier())

	# Repeatedly, not just the first time: Combatant.apply only emits
	# status_applied for a NEW kind, so a version of this that worked once and
	# then quietly stopped is the obvious failure mode.
	var stuck: int = 0
	for i in range(8):
		u.apply(StatusEffect.make(StatusEffect.Kind.STUN, 2.0, 0.0, "nova"))
		if u.is_stunned():
			stuck += 1
	check("...eight stuns in a row all slide off", stuck == 0,
		"%d stuck" % stuck)

	# CONTROL IMMUNITY, NOT DAMAGE IMMUNITY. If this arm fails, the trait is
	# an invulnerability trait wearing the wrong name.
	u.apply(StatusEffect.make(StatusEffect.Kind.BURN, 4.0, 5.0, "fire"))
	u.apply(StatusEffect.make(StatusEffect.Kind.WEAKEN, 4.0, 0.3, "shadow"))
	check("...but a burn and a weaken land normally",
		u.has(StatusEffect.Kind.BURN) and u.has(StatusEffect.Kind.WEAKEN),
		u.status_line())
	var hp: float = u.health
	u.tick(1.0)
	check("...and the burn it is carrying actually burns it", u.health < hp,
		"%.1f -> %.1f hp" % [hp, u.health])

	# IT GAINS NOTHING FROM BEING CONTROLLED. That is Galvanic's job, and the
	# two must not be the same elite with different rings.
	check("...and shrugging a stun off does not make it faster",
		not u.has(StatusEffect.Kind.HASTE) and near(u.move_multiplier(), walk),
		"x%.2f move" % u.move_multiplier())

	# Everything else can still be held, so this is a property of the TRAIT
	# and not something that leaked onto every combatant.
	var other: Combatant = elite(Elite.Trait.SWIFT)
	other.apply(StatusEffect.make(StatusEffect.Kind.STUN, 2.0, 0.0, "nova"))
	check("...other elites are still stunnable", other.is_stunned(),
		"Swift: %s" % other.status_line())
	done += 1


# ------------------------------------------------------------------------------
# 11. Rimeclad: the cold does nothing, the heat does double
# ------------------------------------------------------------------------------

func _the_rime() -> void:
	print("\n=== the rime turns the cold and feeds the fire ===")
	var r: Combatant = elite(Elite.Trait.RIMECLAD)
	var walk: float = r.move_multiplier()
	r.apply(StatusEffect.make(StatusEffect.Kind.SLOW, 4.0, 0.5, "frost"))
	check("frost's slow slides off it", not r.has(StatusEffect.Kind.SLOW)
		and near(r.move_multiplier(), walk), "x%.2f move" % r.move_multiplier())

	# NOT Unbowed. An element trait that also could not be stunned would teach
	# the player the wrong rule off whichever of the two they met first.
	r.apply(StatusEffect.make(StatusEffect.Kind.STUN, 2.0, 0.0, "storm"))
	check("...but a stun still lands, so it is not Unbowed in a blue ring",
		r.is_stunned(), "can_act %s" % r.can_act())

	# The burn side, measured as DAMAGE and not as a magnitude: an amplified
	# number that nothing ticks is the inert half of this trait.
	var rime: Combatant = elite(Elite.Trait.RIMECLAD)
	var plain: Combatant = elite(Elite.Trait.BRUTAL)
	for b in [rime, plain]:
		(b as Combatant).apply(StatusEffect.make(StatusEffect.Kind.BURN,
			4.0, 10.0, "fire"))
	var amped: StatusEffect = rime.effect_of(StatusEffect.Kind.BURN)
	check("...a burn on it bites harder and lasts longer",
		amped != null
			and near(amped.magnitude, 10.0 * (1.0 + Elite.RIME_BURN_BONUS))
			and near(amped.remaining, 4.0 * Elite.RIME_BURN_LONGER),
		"%.1f/tick for %.1fs" % [amped.magnitude, amped.remaining])
	var rime_hp: float = rime.health
	var plain_hp: float = plain.health
	rime.tick(2.0)
	plain.tick(2.0)
	check("...and the extra actually comes off its health",
		(rime_hp - rime.health) > (plain_hp - plain.health) * 1.5,
		"%.1f vs %.1f over 2s"
			% [rime_hp - rime.health, plain_hp - plain.health])

	# Refreshed, not compounded. The handler mutates the effect in place, so a
	# second application must not multiply it again — an elite whose burn grows
	# every time the mage re-casts would be killed by its own trait.
	var was: float = rime.effect_of(StatusEffect.Kind.BURN).magnitude
	rime.apply(StatusEffect.make(StatusEffect.Kind.BURN, 4.0, 10.0, "fire"))
	check("...a re-cast refreshes the burn without compounding it",
		near(rime.effect_of(StatusEffect.Kind.BURN).magnitude, was),
		"%.1f/tick" % rime.effect_of(StatusEffect.Kind.BURN).magnitude)

	# The damage half, which is the part that needs a hook in Combat.gd.
	check("frost damage is resisted and fire damage is amplified",
		Elite.incoming_multiplier(Elite.Trait.RIMECLAD, Spells.Element.FROST)
			< 1.0
			and Elite.incoming_multiplier(Elite.Trait.RIMECLAD,
				Spells.Element.FIRE) > 1.0,
		"frost x%.2f, fire x%.2f" % [
			Elite.incoming_multiplier(Elite.Trait.RIMECLAD,
				Spells.Element.FROST),
			Elite.incoming_multiplier(Elite.Trait.RIMECLAD,
				Spells.Element.FIRE)])
	var neutral: PackedStringArray = []
	for e in range(Spells.Element.size()):
		if e == Spells.Element.FROST or e == Spells.Element.FIRE:
			continue
		if not near(Elite.incoming_multiplier(Elite.Trait.RIMECLAD, e), 1.0):
			neutral.append(String(Spells.ELEMENT_NAMES[e]))
	check("...every other element is untouched", neutral.is_empty(),
		"moved: %s" % ", ".join(neutral))
	check("...a non-mage hit has no element, so it is never resisted",
		near(Elite.incoming_multiplier(Elite.Trait.RIMECLAD, -1), 1.0))
	var opinionated: PackedStringArray = []
	for t in ALL:
		# The two clads are the only traits allowed an element opinion, and CLAD
		# is the list of them — read from the file under test so a third one
		# cannot be added without appearing here.
		if Elite.CLAD.has(t):
			continue
		for e in range(Spells.Element.size()):
			if not near(Elite.incoming_multiplier(t, e), 1.0):
				opinionated.append(Elite.name_of(t))
				break
	check("...and no trait outside the two clads resists anything",
		opinionated.is_empty() and Elite.CLAD.size() == 2,
		"also resisting: %s" % ", ".join(opinionated))

	# THE UNFINISHABLE-MAP CHECK FOR THIS TRAIT. A mage's whole spellbook is one
	# element, so a true immunity would hand a frost mage an elite they cannot
	# kill. A quarter is "do not bother"; zero is a lost save.
	check("...the resistance is partial, so a frost build can still clear it",
		Elite.RIME_FROST_TAKEN > 0.0)
	var frost_only: Combatant = elite(Elite.Trait.RIMECLAD)
	var bite: float = frost_only.max_health * 0.2
	var swings: int = 0
	while frost_only.alive and swings < 400:
		frost_only.take_hit(bite * Elite.incoming_multiplier(
			Elite.Trait.RIMECLAD, Spells.Element.FROST), "Frost")
		swings += 1
	check("...and a frost mage with nothing else does kill it",
		not frost_only.alive, "%d casts at a quarter damage" % swings)
	done += 1


# ------------------------------------------------------------------------------
# 12. Undying: the kill that was not one
# ------------------------------------------------------------------------------

func _the_undying() -> void:
	print("\n=== it gets back up, once ===")
	var u: Combatant = elite(Elite.Trait.UNDYING)
	# A one-element Array, not an int: GDScript lambdas capture local values by
	# COPY, so `deaths += 1` inside the closure would increment a copy and this
	# whole check would read zero deaths no matter what happened. An Array is a
	# reference, so the counter is the same object inside and out.
	var deaths: Array = [0]
	u.died.connect(func() -> void: deaths[0] = int(deaths[0]) + 1)
	var walk: float = u.move_multiplier()
	check("it starts with exactly one rise in hand",
		Elite.rises_left(u) == Elite.UNDYING_RISES,
		"%d rise(s)" % Elite.rises_left(u))

	# A hit that would kill anything else.
	var killed: bool = u.take_hit(u.max_health * 10.0, "test")
	check("a lethal hit does not kill it",
		u.alive and u.health > 0.0 and not killed and int(deaths[0]) == 0,
		"%.1f of %.0f hp, take_hit said killed=%s"
			% [u.health, u.max_health, killed])
	check("...it comes back on a known share of its bar",
		near(u.health, u.max_health * Elite.UNDYING_FRACTION, 0.5),
		"%.0f%%" % (u.health_fraction() * 100.0))
	check("...and comes back faster, so the player can see it happened",
		u.has(StatusEffect.Kind.HASTE) and u.move_multiplier() > walk,
		"x%.2f -> x%.2f move" % [walk, u.move_multiplier()])
	check("...and it has no rises left", Elite.rises_left(u) == 0)

	# THE SECOND DEATH IS REAL. This is the arm that separates a mechanic from
	# an immortal elite in a lane the player has to clear.
	var killed2: bool = u.take_hit(u.max_health * 10.0, "test")
	check("the second lethal hit kills it for good",
		not u.alive and u.health <= 0.0 and killed2 and int(deaths[0]) == 1,
		"died fired %d time(s)" % int(deaths[0]))

	# Chipped to death rather than burst, which is the path that goes through
	# `damaged` many times and could spend a rise it has not got.
	var chipped: Combatant = elite(Elite.Trait.UNDYING)
	var rounds: int = 0
	while chipped.alive and rounds < 400:
		chipped.take_hit(chipped.max_health * 0.07, "chip")
		rounds += 1
	check("...and chipping it down kills it too, after exactly one rise",
		not chipped.alive and Elite.rises_left(chipped) == 0,
		"%d small hits" % rounds)

	# A burn tick is a different damage path into the same signal.
	var burnt: Combatant = elite(Elite.Trait.UNDYING)
	burnt.apply(StatusEffect.make(StatusEffect.Kind.BURN, 60.0,
		burnt.max_health * 0.5, "fire"))
	var ticks: int = 0
	while burnt.alive and ticks < 400:
		burnt.tick(0.5)
		ticks += 1
	check("...and a burn can finish it, rise and all", not burnt.alive,
		"%d ticks" % ticks)

	check("no other trait gets back up",
		Elite.rises_left(elite(Elite.Trait.BRUTAL)) == 0
			and Elite.rises_left(foe()) == 0
			and Elite.rises_left(null) == 0)
	var ordinary: Combatant = elite(Elite.Trait.SWIFT)
	check("...an ordinary elite dies to the first lethal hit",
		ordinary.take_hit(ordinary.max_health * 10.0, "test")
			and not ordinary.alive)
	done += 1


# ------------------------------------------------------------------------------
# 13. Sundering tears the player's wards off — and only its wards
# ------------------------------------------------------------------------------

func _the_sundering() -> void:
	print("\n=== it tears your wards off, one per hit ===")
	var s: Combatant = elite(Elite.Trait.SUNDERING)
	var v: Combatant = warded_hero()
	var fast: float = v.move_multiplier()
	Elite.on_hit(Elite.Trait.SUNDERING, s, v)
	check("the shield goes first — the one a cooldown was spent on",
		not v.has(StatusEffect.Kind.SHIELD) and v.has(StatusEffect.Kind.HASTE),
		"[%s]" % finger(v))
	check("...and only one ward per hit", near(v.move_multiplier(), fast),
		"x%.2f move" % v.move_multiplier())

	Elite.on_hit(Elite.Trait.SUNDERING, s, v)
	check("...the haste goes on the next one",
		not v.has(StatusEffect.Kind.HASTE)
			and v.move_multiplier() < fast,
		"x%.2f -> x%.2f move" % [fast, v.move_multiplier()])

	# A victim with nothing left is not an error, and the strip must not fall
	# through onto something it should never take.
	var bare: Combatant = hero()
	bare.apply(StatusEffect.make(StatusEffect.Kind.BURN, 5.0, 3.0, "fire"))
	bare.apply(StatusEffect.make(StatusEffect.Kind.WEAKEN, 5.0, 0.2, "rot"))
	var before: String = finger(bare)
	for i in range(4):
		Elite.on_hit(Elite.Trait.SUNDERING, s, bare)
	check("...it never strips a burn or a weaken — that would CURE the player",
		finger(bare) == before, "[%s]" % finger(bare))

	# A shield it broke must stay broken: the player's ward absorbing damage
	# after it visibly tore off would be the worst reading of this.
	var torn: Combatant = warded_hero()
	Elite.on_hit(Elite.Trait.SUNDERING, torn, torn)
	var hp: float = torn.health
	torn.take_hit(10.0, "test")
	check("...and health moves immediately once the ward is gone",
		torn.health < hp, "%.1f -> %.1f hp" % [hp, torn.health])

	var other: Combatant = warded_hero()
	var kept: String = finger(other)
	for t in ALL:
		if t == Elite.Trait.SUNDERING:
			continue
		Elite.on_hit(t, s, other)
	check("no other trait tears a ward off",
		other.has(StatusEffect.Kind.SHIELD)
			and other.has(StatusEffect.Kind.HASTE),
		"[%s] -> [%s]" % [kept, finger(other)])
	done += 1


# ------------------------------------------------------------------------------
# 14. Shackling: you cannot walk away from it
# ------------------------------------------------------------------------------

func _the_shackle() -> void:
	print("\n=== the shackle drags, and does not root ===")
	var s: Combatant = elite(Elite.Trait.SHACKLING)
	var v: Combatant = hero()
	var free: float = v.move_multiplier()
	Elite.on_hit(Elite.Trait.SHACKLING, s, v)
	# THE MOVEMENT, not the status: a slow matters only because
	# move_multiplier() reads it, and that is the link that breaks silently.
	check("its bite slows the player down", v.has(StatusEffect.Kind.SLOW)
		and v.move_multiplier() < free,
		"x%.2f -> x%.2f move" % [free, v.move_multiplier()])
	check("...by the amount it advertises",
		near(v.effect_of(StatusEffect.Kind.SLOW).magnitude,
			Elite.SHACKLE_MAGNITUDE),
		"%.2f" % v.effect_of(StatusEffect.Kind.SLOW).magnitude)

	# A LIMP, NOT A ROOT, and the abilities stay available. "I tapped and
	# nothing happened" is the failure StatusEffect.gd opens by refusing.
	check("...but it is a limp, not a root",
		v.move_multiplier() > 0.4 and Elite.SHACKLE_MAGNITUDE < 0.6,
		"x%.2f move" % v.move_multiplier())
	check("...and the player can still fight back",
		v.can_act() and not v.is_stunned())

	# Refreshed per hit, never stacked into a root.
	for i in range(6):
		Elite.on_hit(Elite.Trait.SHACKLING, s, v)
	check("...six hits in a row do not stack into a root",
		v.effects.filter(func(e): return e.kind == StatusEffect.Kind.SLOW) \
			.size() == 1
			and near(v.effect_of(StatusEffect.Kind.SLOW).magnitude,
				Elite.SHACKLE_MAGNITUDE),
		"%d slow(s), x%.2f move"
			% [v.effects.size(), v.move_multiplier()])

	# IT LIFTS. A slow that outlived the fight would read as the player's own
	# gear breaking, which is the bug report nobody can diagnose.
	v.tick(Elite.SHACKLE_SECONDS + 0.2)
	check("...and it lifts the moment it stops connecting",
		not v.has(StatusEffect.Kind.SLOW) and near(v.move_multiplier(), free),
		"x%.2f move after %.1fs" % [v.move_multiplier(),
			Elite.SHACKLE_SECONDS + 0.2])

	var other: Combatant = hero()
	for t in ALL:
		if t == Elite.Trait.SHACKLING:
			continue
		Elite.on_hit(t, s, other)
	check("no other trait shackles", not other.has(StatusEffect.Kind.SLOW),
		"[%s]" % finger(other))
	done += 1


# ------------------------------------------------------------------------------
# 15. Galvanic: control is food
# ------------------------------------------------------------------------------

func _the_galvanic() -> void:
	print("\n=== hold it and it only comes faster ===")
	var g: Combatant = elite(Elite.Trait.GALVANIC)
	var walk: float = g.move_multiplier()
	check("it is an ordinary speed until somebody tries to hold it",
		not g.has(StatusEffect.Kind.HASTE) and near(walk, 1.0),
		"x%.2f move" % walk)

	g.apply(StatusEffect.make(StatusEffect.Kind.STUN, 3.0, 0.0, "nova"))
	check("a stun does not land, and pays it instead",
		not g.is_stunned() and g.can_act() and g.has(StatusEffect.Kind.HASTE)
			and g.move_multiplier() > walk,
		"x%.2f -> x%.2f move" % [walk, g.move_multiplier()])

	var after_stun: float = g.move_multiplier()
	g.apply(StatusEffect.make(StatusEffect.Kind.SLOW, 3.0, 0.6, "frost"))
	check("...a slow does the same, and the two add up",
		not g.has(StatusEffect.Kind.SLOW)
			and g.move_multiplier() > after_stun,
		"x%.2f -> x%.2f move" % [after_stun, g.move_multiplier()])

	# CAPPED. A player with a short-cooldown slow would otherwise feed it until
	# nothing in the game could outrun it, and "I made this unwinnable by
	# playing my own build" is the worst lesson an elite can teach.
	for i in range(40):
		g.apply(StatusEffect.make(StatusEffect.Kind.STUN, 2.0, 0.0, "nova"))
		g.apply(StatusEffect.make(StatusEffect.Kind.SLOW, 2.0, 0.6, "frost"))
	check("...and forty more pieces of control cannot push it past the cap",
		near(g.effect_of(StatusEffect.Kind.HASTE).magnitude,
			Elite.GALVANIC_CAP, 0.001),
		"haste %.2f, cap %.2f, x%.2f move"
			% [g.effect_of(StatusEffect.Kind.HASTE).magnitude,
				Elite.GALVANIC_CAP, g.move_multiplier()])

	# IT GAINS SPEED AND NOTHING ELSE. If this fails, feeding it control is
	# making it tankier, and the trait is a damage sponge in disguise.
	var plain: Combatant = elite(Elite.Trait.BRUTAL)
	check("...it has gained no health and no damage from any of that",
		near(g.max_health, plain.max_health)
			and near(g.health, g.max_health)
			and g.damage_scale <= plain.damage_scale,
		"%.0f hp, dmg x%.2f" % [g.max_health, g.damage_scale])

	# Not damage immunity either.
	g.apply(StatusEffect.make(StatusEffect.Kind.BURN, 4.0, 6.0, "fire"))
	var hp: float = g.health
	g.tick(1.0)
	check("...a burn still lands on it, and still burns",
		g.has(StatusEffect.Kind.BURN) and g.health < hp,
		"%.1f -> %.1f hp" % [hp, g.health])

	# AND A FULLY-FED ONE STILL DIES. Checked here as well as in the kill loop,
	# because the kill loop never controls anything.
	var fed: Combatant = elite(Elite.Trait.GALVANIC)
	for i in range(40):
		fed.apply(StatusEffect.make(StatusEffect.Kind.STUN, 2.0, 0.0, "nova"))
	var rounds: int = 0
	while fed.alive and rounds < 200:
		fed.take_hit(fed.max_health * 0.2, "test")
		rounds += 1
	check("...and a fully-fed Galvanic still dies to ordinary damage",
		not fed.alive, "%d hits" % rounds)

	# Unbowed is the one it must not be confused with, mechanically or visually.
	var unbowed: Combatant = elite(Elite.Trait.UNBOWED)
	unbowed.apply(StatusEffect.make(StatusEffect.Kind.STUN, 2.0, 0.0, "nova"))
	check("Galvanic and Unbowed answer control differently",
		not unbowed.has(StatusEffect.Kind.HASTE)
			and g.has(StatusEffect.Kind.HASTE),
		"Unbowed ignores it, Galvanic eats it")
	done += 1


# ------------------------------------------------------------------------------
# 16. Adamant: the big hit is the wrong hit
# ------------------------------------------------------------------------------

func _the_adamant() -> void:
	print("\n=== no one blow moves it far ===")
	var a: Combatant = elite(Elite.Trait.ADAMANT)
	var cap: float = a.max_health * Elite.ADAMANT_CAP
	var full: float = a.health

	# The biggest blow this game can produce against the smallest cap.
	var killed: bool = a.take_hit(a.max_health * 10.0, "test")
	check("a blow ten times its health takes only its cap",
		a.alive and not killed and near(full - a.health, cap, 0.5),
		"%.1f of %.0f hp off a %.1f cap" % [full - a.health, a.max_health, cap])
	# THE NUMBER THE PLAYER SEES. `damaged` carries the figure the attack rolled,
	# which for this trait is not the figure that came off — a 500 over a bar
	# that moved by 30 reads as the health bar being broken.
	check("...and the number a HUD would float matches what came off",
		near(Elite.shown_damage(a, a.max_health * 10.0), cap, 0.01),
		"%.1f shown" % Elite.shown_damage(a, a.max_health * 10.0))

	# A CAP, NOT A DAMAGE REDUCTION. If this fails the trait is armour with a
	# ring, and every burn tick and pool bite in the game has gone soft.
	var small: float = cap * 0.25
	var before: float = a.health
	a.take_hit(small, "test")
	check("...a hit under the cap still lands in full",
		near(before - a.health, small, 0.01),
		"%.2f of %.2f" % [before - a.health, small])
	check("...and its number is not trimmed either",
		near(Elite.shown_damage(a, small), small, 0.01))

	# IT DIES, and the bar only ever goes down on the way. A cap implemented by
	# giving health back is one arithmetic slip from healing the elite.
	var b: Combatant = elite(Elite.Trait.ADAMANT)
	var hits: int = 0
	var prev: float = b.health
	var went_up: bool = false
	while b.alive and hits < 200:
		b.take_hit(b.max_health * 5.0, "test")
		if b.health > prev + 0.001:
			went_up = true
		prev = b.health
		hits += 1
	var expected: int = ceili(1.0 / Elite.ADAMANT_CAP)
	check("...and enough of those blows still kill it",
		not b.alive and hits <= expected + 1,
		"%d hits, %d expected" % [hits, expected])
	check("...with its health never once going back up", not went_up)

	# THE LEDGER FOLLOWS A HEAL. Capping a blow needs the figure the health came
	# down from, and a stale one would snap the bar back to before a Mending
	# packmate's pulse — the heal visibly undoing itself.
	var h: Combatant = elite(Elite.Trait.ADAMANT)
	h.take_hit(h.max_health * 5.0, "test")
	h.take_hit(h.max_health * 5.0, "test")
	var wounded: float = h.health
	h.heal(h.max_health * 0.1)
	var topped: float = h.health
	h.take_hit(h.max_health * 5.0, "test")
	check("...a heal it was given is not undone by the next capped blow",
		topped > wounded and near(h.health, topped - cap, 0.5),
		"%.1f -> %.1f -> %.1f hp" % [wounded, topped, h.health])

	# A DOT whose ticks are under the cap is untouched by it, so burning it down
	# works exactly as it does on anything else.
	var burnt: Combatant = elite(Elite.Trait.ADAMANT)
	burnt.apply(StatusEffect.make(StatusEffect.Kind.BURN, 300.0,
		burnt.max_health * 0.05, "fire"))
	var ticks: int = 0
	while burnt.alive and ticks < 400:
		burnt.tick(0.5)
		ticks += 1
	check("...and a burn under the cap kills it outright", not burnt.alive,
		"%d ticks" % ticks)

	var plain: Combatant = elite(Elite.Trait.BRUTAL)
	check("no other trait blunts a blow",
		plain.take_hit(plain.max_health * 10.0, "test") and not plain.alive
			and near(Elite.shown_damage(plain, 999.0), 999.0)
			and near(Elite.shown_damage(null, 999.0), 999.0),
		"an ordinary elite dies to one")
	done += 1


# ------------------------------------------------------------------------------
# 17. Gorging: the burn is the wrong burn
# ------------------------------------------------------------------------------

func _the_gorge() -> void:
	print("\n=== it swallows the fire and wears it ===")
	var g: Combatant = elite(Elite.Trait.GORGING)
	check("it starts bare, so it is not Warded in a different ring",
		not g.has(StatusEffect.Kind.SHIELD) and g.effects.is_empty(),
		"[%s]" % finger(g))

	var fuse: StatusEffect = StatusEffect.make(StatusEffect.Kind.BURN, 4.0,
		g.max_health * 0.1, "fire")
	var meal: float = Elite.burn_total(fuse)
	g.apply(fuse)
	check("a burn landing on it is swallowed whole",
		not g.has(StatusEffect.Kind.BURN), "[%s]" % finger(g))
	var ward: StatusEffect = g.effect_of(StatusEffect.Kind.SHIELD)
	check("...and comes back as a ward", ward != null and ward.magnitude > 0.0,
		"%.1f ward off a %.1f burn" % [
			ward.magnitude if ward != null else 0.0, meal])
	# THE UNFINISHABLE-MAP CHECK FOR THIS TRAIT. If the ward is worth more than
	# the burn it ate, a fire or venom mage makes it tankier by casting.
	check("...worth strictly less than the burn it ate",
		ward != null and ward.magnitude < meal and Elite.GORGE_WARD < 1.0,
		"%.1f < %.1f" % [ward.magnitude if ward != null else 0.0, meal])

	# The swallowed burn is GONE, not merely hidden: a burn that still ticked
	# while the elite also wore a ward for it would be paying twice.
	var hp: float = g.health
	g.tick(5.0)
	check("...and the swallowed burn never ticks", near(g.health, hp),
		"%.1f hp" % g.health)

	# It wears it like any other ward: health does not move until it is gone.
	# Same machinery as Warded, so it cannot behave differently.
	var worn: float = g.effect_of(StatusEffect.Kind.SHIELD).magnitude
	g.take_hit(worn, "test")
	check("...the ward has to be broken before its health moves",
		near(g.health, hp) and not g.has(StatusEffect.Kind.SHIELD),
		"%.1f hp, [%s]" % [g.health, finger(g)])
	g.take_hit(worn * 0.25, "test")
	check("...then the very next hit takes health", g.health < hp,
		"%.1f -> %.1f hp" % [hp, g.health])

	# CAPPED. A 600-second DOT must not buy it a second health bar.
	var huge: Combatant = elite(Elite.Trait.GORGING)
	huge.apply(StatusEffect.make(StatusEffect.Kind.BURN, 600.0,
		huge.max_health, "pyre"))
	var fat: StatusEffect = huge.effect_of(StatusEffect.Kind.SHIELD)
	check("...a monstrous DOT cannot buy it a second health bar",
		fat != null
			and fat.magnitude <= huge.max_health * Elite.GORGE_WARD_CAP + 0.01,
		"%.1f ward, cap %.1f"
			% [fat.magnitude if fat != null else 0.0,
				huge.max_health * Elite.GORGE_WARD_CAP])
	for i in range(40):
		huge.apply(StatusEffect.make(StatusEffect.Kind.BURN, 600.0,
			huge.max_health, "pyre"))
	var wards: int = 0
	for ef in huge.effects:
		if ef.kind == StatusEffect.Kind.SHIELD:
			wards += 1
	check("...and forty more mouthfuls cannot push it past that cap",
		huge.effect_of(StatusEffect.Kind.SHIELD).magnitude
			<= huge.max_health * Elite.GORGE_WARD_CAP + 0.01 and wards == 1,
		"%.1f ward, %d shield(s), %d effect(s)"
			% [huge.effect_of(StatusEffect.Kind.SHIELD).magnitude, wards,
				huge.effects.size()])

	# A BURN TRAIT, NOT A STATUS TRAIT. If control slid off it too, it is Unbowed
	# with a red ring and the player learns the wrong rule.
	var held: Combatant = elite(Elite.Trait.GORGING)
	held.apply(StatusEffect.make(StatusEffect.Kind.STUN, 2.0, 0.0, "nova"))
	held.apply(StatusEffect.make(StatusEffect.Kind.SLOW, 2.0, 0.4, "frost"))
	held.apply(StatusEffect.make(StatusEffect.Kind.WEAKEN, 2.0, 0.3, "shadow"))
	check("stuns, slows and weakens all still land on it",
		held.is_stunned() and held.has(StatusEffect.Kind.SLOW)
			and held.has(StatusEffect.Kind.WEAKEN)
			and not held.has(StatusEffect.Kind.SHIELD),
		held.status_line())

	# A FIRE MAGE STILL CLEARS THE MAP. Every spell in this game deals direct
	# damage as well as its rider, so the direct half lands and the elite dies —
	# it is slower, which is the lesson, not impossible, which would be a bug.
	var target: Combatant = elite(Elite.Trait.GORGING)
	var casts: int = 0
	while target.alive and casts < 400:
		target.take_hit(target.max_health * 0.12, "Pyre")
		target.apply(StatusEffect.make(StatusEffect.Kind.BURN, 4.0,
			target.max_health * 0.03, "Pyre"))
		casts += 1
	check("...and a fire mage casting nothing else does kill it",
		not target.alive, "%d casts" % casts)

	var other: Combatant = elite(Elite.Trait.SWIFT)
	other.apply(StatusEffect.make(StatusEffect.Kind.BURN, 4.0, 5.0, "fire"))
	check("no other trait swallows a burn",
		other.has(StatusEffect.Kind.BURN)
			and not other.has(StatusEffect.Kind.SHIELD),
		"[%s]" % finger(other))
	done += 1


# ------------------------------------------------------------------------------
# 18. Emberclad: Rimeclad's mirror, and one mechanic rather than two
# ------------------------------------------------------------------------------

func _the_emberclad() -> void:
	print("\n=== the ember turns the fire and the cold undoes it ===")
	var e: Combatant = elite(Elite.Trait.EMBERCLAD)
	var plain: Combatant = elite(Elite.Trait.BRUTAL)
	for b in [e, plain]:
		(b as Combatant).apply(StatusEffect.make(StatusEffect.Kind.BURN,
			4.0, 10.0, "fire"))
	var slug: StatusEffect = e.effect_of(StatusEffect.Kind.BURN)
	# NOT Gorging. The burn stays on it, at its full bite — what changes is how
	# often it bites, which is the only dampening a refresh cannot undo.
	check("a burn stays on it, at its full per-tick bite",
		slug != null and near(slug.magnitude, 10.0)
			and not e.has(StatusEffect.Kind.SHIELD),
		"%.1f/tick, [%s]" % [slug.magnitude if slug != null else 0.0, finger(e)])
	check("...but on a slower cadence",
		slug != null and near(slug.tick_every, 0.5 * Elite.EMBER_BURN_SLOW),
		"every %.2fs" % (slug.tick_every if slug != null else 0.0))

	# MEASURED AS DAMAGE, not as a field: a stretched cadence that nothing reads
	# is the inert half of this trait.
	var e_hp: float = e.health
	var p_hp: float = plain.health
	e.tick(2.0)
	plain.tick(2.0)
	check("...so the fire actually takes less off it",
		(p_hp - plain.health) > (e_hp - e.health) * 1.5,
		"%.1f vs %.1f over 2s" % [e_hp - e.health, p_hp - plain.health])

	# THE RE-CAST. This is the arm that matters most: Combatant.apply refreshes a
	# present kind to the greater magnitude and emits NOTHING, so a version of
	# this trait that dampened the magnitude would be restored to full by the
	# mage's next cast and never re-enter the handler — working once per fight
	# and then silently stopping.
	var cadence: float = e.effect_of(StatusEffect.Kind.BURN).tick_every
	e.apply(StatusEffect.make(StatusEffect.Kind.BURN, 4.0, 10.0, "fire"))
	check("...and a re-cast cannot restore the cadence",
		near(e.effect_of(StatusEffect.Kind.BURN).tick_every, cadence),
		"still every %.2fs"
			% e.effect_of(StatusEffect.Kind.BURN).tick_every)

	# The cold it cannot stand. NOT Rimeclad: the slow lands, and bites harder.
	var f: Combatant = elite(Elite.Trait.EMBERCLAD)
	var walk: float = f.move_multiplier()
	f.apply(StatusEffect.make(StatusEffect.Kind.SLOW, 4.0, 0.4, "frost"))
	var cold: StatusEffect = f.effect_of(StatusEffect.Kind.SLOW)
	check("frost's slow lands on it, deeper and longer than it was cast",
		cold != null and cold.magnitude > 0.4 and cold.remaining > 4.0
			and f.move_multiplier() < walk,
		"%.2f for %.1fs, x%.2f move"
			% [cold.magnitude if cold != null else 0.0,
				cold.remaining if cold != null else 0.0, f.move_multiplier()])
	var deep: Combatant = elite(Elite.Trait.EMBERCLAD)
	deep.apply(StatusEffect.make(StatusEffect.Kind.SLOW, 2.0, 0.75, "glacier"))
	check("...but never deep enough to nail it to the floor",
		deep.effect_of(StatusEffect.Kind.SLOW).magnitude
			<= Elite.EMBER_SLOW_MAX + 0.001
			and deep.move_multiplier() > 0.1,
		"%.2f slow, x%.2f move"
			% [deep.effect_of(StatusEffect.Kind.SLOW).magnitude,
				deep.move_multiplier()])
	f.apply(StatusEffect.make(StatusEffect.Kind.STUN, 2.0, 0.0, "storm"))
	check("...and a stun still lands, so it is not Unbowed in a red ring",
		f.is_stunned(), "can_act %s" % f.can_act())

	# The damage half, which is the one call Combat.cast owes both clads.
	var fire: float = Elite.incoming_multiplier(Elite.Trait.EMBERCLAD,
		Spells.Element.FIRE)
	var frost: float = Elite.incoming_multiplier(Elite.Trait.EMBERCLAD,
		Spells.Element.FROST)
	check("fire damage is resisted and frost damage is amplified",
		fire < 1.0 and frost > 1.0, "fire x%.2f, frost x%.2f" % [fire, frost])
	check("...and it is the exact mirror of Rimeclad, not a second special case",
		near(fire, Elite.incoming_multiplier(Elite.Trait.RIMECLAD,
			Spells.Element.FROST))
			and near(frost, Elite.incoming_multiplier(Elite.Trait.RIMECLAD,
				Spells.Element.FIRE)),
		"rime frost x%.2f, rime fire x%.2f" % [
			Elite.incoming_multiplier(Elite.Trait.RIMECLAD,
				Spells.Element.FROST),
			Elite.incoming_multiplier(Elite.Trait.RIMECLAD,
				Spells.Element.FIRE)])
	var neutral: PackedStringArray = []
	for el in range(Spells.Element.size()):
		if el == Spells.Element.FROST or el == Spells.Element.FIRE:
			continue
		if not near(Elite.incoming_multiplier(Elite.Trait.EMBERCLAD, el), 1.0):
			neutral.append(String(Spells.ELEMENT_NAMES[el]))
	check("...every other element is untouched", neutral.is_empty(),
		"moved: %s" % ", ".join(neutral))

	# ONE MECHANIC WITH TWO SETTINGS, asserted on the table rather than trusted:
	# the clads must be opposites, and each clad's two elements must carry
	# DIFFERENT riders or _clad_bite cannot tell which arm a status belongs to.
	var rime: Dictionary = Elite.CLAD[Elite.Trait.RIMECLAD]
	var ember: Dictionary = Elite.CLAD[Elite.Trait.EMBERCLAD]
	check("the two clads are opposites, not two copies",
		int(rime["resists"]) == int(ember["weak_to"])
			and int(rime["weak_to"]) == int(ember["resists"]),
		"%s/%s vs %s/%s" % [
			Spells.ELEMENT_NAMES[rime["resists"]],
			Spells.ELEMENT_NAMES[rime["weak_to"]],
			Spells.ELEMENT_NAMES[ember["resists"]],
			Spells.ELEMENT_NAMES[ember["weak_to"]]])
	var ambiguous: PackedStringArray = []
	for t in Elite.CLAD.keys():
		var c: Dictionary = Elite.CLAD[t]
		var r1: int = int(Spells.ELEMENT_STATUS[c["resists"]])
		var r2: int = int(Spells.ELEMENT_STATUS[c["weak_to"]])
		if r1 < 0 or r2 < 0 or r1 == r2:
			ambiguous.append(Elite.name_of(int(t)))
	check("...and each clad's two elements carry different riders",
		ambiguous.is_empty(), "ambiguous: %s" % ", ".join(ambiguous))

	# THE UNFINISHABLE-MAP CHECK. A mage's whole spellbook is ONE element, so a
	# fire mage meeting this one must still be able to finish it.
	var fire_only: Combatant = elite(Elite.Trait.EMBERCLAD)
	var bite: float = fire_only.max_health * 0.2
	var casts: int = 0
	while fire_only.alive and casts < 400:
		fire_only.take_hit(bite * fire, "Pyre")
		casts += 1
	check("...and a fire mage with nothing else does kill it",
		not fire_only.alive and Elite.EMBER_FIRE_TAKEN > 0.0,
		"%d casts at a quarter damage" % casts)
	done += 1


# ------------------------------------------------------------------------------
# 19. NOTHING IS UNKILLABLE
# ------------------------------------------------------------------------------

func _the_kill() -> void:
	print("\n=== every trait dies ===")
	var worst: String = ""
	var worst_cost: float = 0.0
	for t in ALL:
		var e: Combatant = elite(t)
		var punchbag: Combatant = hero()
		var bite: float = e.max_health * 0.2
		var spent: float = 0.0
		var rounds: int = 0
		# The elite fights back while being killed, which is the only way
		# Mending's self-heal and Frenzied's escalation are in play at all.
		while e.alive and rounds < 200:
			Elite.on_hit(t, e, punchbag)
			if punchbag.alive:
				punchbag.heal(punchbag.max_health)
				punchbag.effects.clear()
			e.take_hit(bite, "test")
			e.tick(0.1)
			spent += bite
			rounds += 1
		var cost: float = spent / e.max_health
		if cost > worst_cost:
			worst_cost = cost
			worst = Elite.name_of(t)
		check("%s dies to enough damage" % Elite.name_of(t),
			not e.alive and e.health <= 0.0,
			"%d rounds, %.1fx its health" % [rounds, cost])

	# And none of them is a sponge either: a trait that needed ten times the
	# health bar to chew through is technically killable and practically a
	# wall the player walks away from.
	check("...and none of them costs more than 3x its health bar",
		worst_cost <= 3.0, "worst: %s at %.1fx" % [worst, worst_cost])

	# The same sweep with every trick the player has in hand, because several
	# traits only react to something — control, a ward, a burn — and a kill loop
	# that never does any of it is not the fight the player is in.
	var stubborn: PackedStringArray = []
	for t in ALL:
		var e2: Combatant = elite(t)
		var bag: Combatant = warded_hero()
		var n: int = 0
		while e2.alive and n < 300:
			e2.apply(StatusEffect.make(StatusEffect.Kind.STUN, 1.0, 0.0, "nova"))
			e2.apply(StatusEffect.make(StatusEffect.Kind.SLOW, 1.0, 0.5, "cold"))
			e2.apply(StatusEffect.make(StatusEffect.Kind.BURN, 1.0, 1.0, "fire"))
			Elite.on_hit(t, e2, bag)
			if bag.alive:
				bag.heal(bag.max_health)
			e2.take_hit(e2.max_health * 0.15, "test")
			e2.tick(0.2)
			n += 1
		if e2.alive:
			stubborn.append("%s (%d rounds)" % [Elite.name_of(t), n])
	check("...and every trait still dies with control and burns thrown at it",
		stubborn.is_empty(), "survived: %s" % ", ".join(stubborn))

	# The two spawns a Brood leaves behind die too, which is the half of that
	# mechanic the parent's own kill loop never touches.
	var b: Combatant = elite(Elite.Trait.BROOD)
	var kids: Array = Elite.split(Elite.Trait.BROOD, b)
	var dead_kids: int = 0
	for k in kids:
		var kid := k as Combatant
		var m: int = 0
		while kid.alive and m < 200:
			kid.take_hit(kid.max_health * 0.25, "test")
			m += 1
		if not kid.alive:
			dead_kids += 1
	check("...and so do the spawns it leaves behind",
		dead_kids == kids.size(), "%d of %d" % [dead_kids, kids.size()])
	done += 1


# ------------------------------------------------------------------------------
# 20. Every trait is announced
# ------------------------------------------------------------------------------

func _the_marks() -> void:
	print("\n=== an elite wears what it is ===")
	var holder := Node3D.new()
	var shapes: Dictionary = {}
	for t in ALL:
		var on := Node3D.new()
		holder.add_child(on)
		var m: Node3D = Elite.mark(on, t)
		var meshes: int = 0
		var spins: int = 0
		if m != null:
			for c in m.get_children():
				if c is MeshInstance3D:
					meshes += 1
					if (c as MeshInstance3D).material_override == null:
						meshes -= 1
				elif c is Vfx.VeteranSpin:
					spins += 1
		check("%s is marked, named and described" % Elite.name_of(t),
			m != null and m.name == "EliteMark" and meshes > 0 and spins == 1
				and Elite.name_of(t) != "" and Elite.blurb_of(t) != ""
				and on.get_node_or_null("EliteMark") != null,
			"%d ring(s): %s" % [meshes, Elite.blurb_of(t)])
		# The shape fingerprint, for the readability check below.
		shapes[t] = "%d-%s" % [meshes,
			"halo" if Elite.SHAPES.get(t, {}).get("upright", false) else "flat"]

	# READABLE IN ONE GLANCE. Seventeen traits is well past what colour alone
	# can carry, so every PAIR must differ either in colour by a wide margin or
	# in shape.
	var muddled: PackedStringArray = []
	var closest: float = 9.0
	var closest_pair: String = ""
	for i in range(ALL.size()):
		for j in range(i + 1, ALL.size()):
			var a: int = ALL[i]
			var b: int = ALL[j]
			var ca: Color = Elite.colour_of(a)
			var cb: Color = Elite.colour_of(b)
			var d: float = sqrt(pow(ca.r - cb.r, 2.0) + pow(ca.g - cb.g, 2.0)
				+ pow(ca.b - cb.b, 2.0))
			if d < closest:
				closest = d
				closest_pair = "%s/%s" % [Elite.name_of(a), Elite.name_of(b)]
			if d < 0.25 and String(shapes[a]) == String(shapes[b]):
				muddled.append("%s/%s" % [Elite.name_of(a), Elite.name_of(b)])
	check("no two elites look alike at a thumb's distance",
		muddled.is_empty(), "closest pair %s at %.2f; %s"
			% [closest_pair, closest, "muddled: " + ", ".join(muddled) if not
				muddled.is_empty() else "all distinct"])

	# The ring an existing elite wears must not have moved: its colour is the
	# one cue players have already learnt.
	check("...and the four original marks are unchanged",
		Elite.colour_of(Elite.Trait.SWIFT) == Color("5ad7ff")
			and Elite.colour_of(Elite.Trait.WARDED) == Color("ffd75a")
			and Elite.colour_of(Elite.Trait.BRUTAL) == Color("ff4d3d")
			and Elite.colour_of(Elite.Trait.VENOMOUS) == Color("7ce04a")
			and not Elite.SHAPES.has(Elite.Trait.SWIFT))
	# Held in a var rather than built inline so it can be freed: an orphan node
	# per run is the "1 ObjectDB instance was leaked at exit" that teaches
	# everyone reading this harness's output to ignore leak warnings.
	var bare := Node3D.new()
	check("...an unmarked enemy gets no ring at all",
		Elite.mark(bare, Elite.Trait.NONE) == null
			and Elite.mark(null, Elite.Trait.BRUTAL) == null)
	bare.free()
	holder.free()
	done += 1


# ------------------------------------------------------------------------------
# 21. The audit agrees with reality
# ------------------------------------------------------------------------------

func _the_audit() -> void:
	print("\n=== proven() can tell a live trait from a dead one ===")
	# This is the helper a live-map harness uses instead of a match statement
	# it has to remember to extend — and the version that shipped stopped at
	# nine arms while the enum had twelve, which is precisely how three inert
	# traits passed every check anyone ran.
	var liars: PackedStringArray = []
	for t in ALL:
		if not Elite.proven(t, elite(t)):
			liars.append(Elite.name_of(t))
	check("every applied trait proves itself on its own body",
		liars.is_empty(), "unproven: %s" % ", ".join(liars))

	# And it is not simply returning true: a body that never had the trait
	# applied must fail for every trait whose effect lands at spawn.
	var ghosts: PackedStringArray = []
	for t in SPAWN_TRAITS:
		if Elite.proven(t, foe()):
			ghosts.append(Elite.name_of(t))
	check("...and an ordinary enemy proves none of them",
		ghosts.is_empty(), "false positives: %s" % ", ".join(ghosts))
	check("...NONE and a null body are never 'live'",
		not Elite.proven(Elite.Trait.NONE, foe())
			and not Elite.proven(Elite.Trait.SWIFT, null))

	# The audit must not damage what it audits, or SPEND what it audits — it is
	# called on live enemies in the middle of a map. Undying's one rise is the
	# dangerous one: an audit that killed it to find out whether it comes back
	# would hand the player a free kill.
	var subject: Combatant = elite(Elite.Trait.VENOMOUS)
	var hp: float = subject.health
	Elite.proven(Elite.Trait.VENOMOUS, subject)
	check("...auditing a live elite does not hurt it",
		near(subject.health, hp) and subject.alive, "%.1f hp" % subject.health)

	var risen: Combatant = elite(Elite.Trait.UNDYING)
	var before_hp: float = risen.health
	Elite.proven(Elite.Trait.UNDYING, risen)
	check("...and does not spend an Undying's rise to prove it",
		Elite.rises_left(risen) == Elite.UNDYING_RISES and risen.alive
			and near(risen.health, before_hp),
		"%d rise(s) left" % Elite.rises_left(risen))

	var held: Combatant = elite(Elite.Trait.GALVANIC)
	var walk: float = held.move_multiplier()
	Elite.proven(Elite.Trait.GALVANIC, held)
	check("...nor feed a live Galvanic while checking that it eats control",
		near(held.move_multiplier(), walk)
			and not held.has(StatusEffect.Kind.HASTE),
		"x%.2f move" % held.move_multiplier())
	done += 1
