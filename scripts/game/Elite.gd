class_name Elite
extends RefCounted
# ------------------------------------------------------------------------------
# What makes an elite worth noticing.
#
# Elites already existed — Encounter marks roughly a tenth of a pack as one and
# scales them 1.18x — and they fought EXACTLY like the trash around them. A
# slightly bigger champion with slightly more health is not an elite, it is a
# rounding error, and the player had no reason to treat it differently or even
# to spot it.
#
# Each one now carries a single trait that changes how the fight goes, and
# wears its colour so the decision is available BEFORE the first hit lands.
# One trait, not a stack of them: two modifiers on one enemy is a soup the
# player cannot read, and the whole point is readability.
#
# EVERY TRAIT RIDES AN EXISTING SYSTEM. Swift is a permanent haste, Warded is a
# shield, Brutal is the damage scale the difficulty ramp already uses, and
# Venomous is the burn that fire spells apply. Nothing here is a special case
# in the combat loop, which is why none of it can drift out of sync with it.
# ------------------------------------------------------------------------------

enum Trait { NONE, SWIFT, WARDED, BRUTAL, VENOMOUS }

const COUNT: int = 4

const NAMES: Dictionary = {
	Trait.SWIFT: "Swift",
	Trait.WARDED: "Warded",
	Trait.BRUTAL: "Brutal",
	Trait.VENOMOUS: "Venomous",
}

## What each one looks like at a glance. Chosen to be unmistakable from each
## other at a thumb's distance on a phone, not to be pretty.
const COLOURS: Dictionary = {
	Trait.SWIFT: Color("5ad7ff"),      # quick, cold blue
	Trait.WARDED: Color("ffd75a"),     # gold, like a barrier
	Trait.BRUTAL: Color("ff4d3d"),     # red, like a threat
	Trait.VENOMOUS: Color("7ce04a"),   # green, like poison
}

## How long "permanent" is. Longer than any region will last; the effect is
## cleaned up with the body rather than expiring.
const FOREVER: float = 100000.0

## Movement and attack speed a Swift elite gains.
const SWIFT_HASTE: float = 0.45
## Share of its own maximum health a Warded elite absorbs before taking any.
const WARD_FRACTION: float = 0.6
## Extra damage a Brutal elite deals.
const BRUTAL_BONUS: float = 0.5
## Burn a Venomous elite leaves on every hit.
const VENOM_SECONDS: float = 4.0
const VENOM_FRACTION: float = 0.12


## Which trait this elite has. Seeded, so the same spawn on the same map is
## the same elite every time the player walks in.
static func roll(seed: int, index: int) -> int:
	return 1 + int(Rng.unit2(seed, index, 991) * float(COUNT)) % COUNT


static func name_of(t: int) -> String:
	return String(NAMES.get(t, ""))


static func colour_of(t: int) -> Color:
	return COLOURS.get(t, Color.WHITE)


## Put the trait on `body`. Called once, at spawn.
static func apply(body: Combatant, t: int) -> void:
	if body == null:
		return
	match t:
		Trait.SWIFT:
			body.apply(StatusEffect.make(StatusEffect.Kind.HASTE,
				FOREVER, SWIFT_HASTE, "elite_swift"))
		Trait.WARDED:
			body.apply(StatusEffect.make(StatusEffect.Kind.SHIELD,
				FOREVER, body.max_health * WARD_FRACTION, "elite_warded"))
		Trait.BRUTAL:
			# Multiplies whatever the difficulty ramp already set, so a Brutal
			# elite on map 1 is still inside the opening's mercy.
			body.damage_scale *= 1.0 + BRUTAL_BONUS
		Trait.VENOMOUS:
			pass    # lands on the victim, not the caster — see on_hit()


## What a Venomous elite leaves behind when it connects. Called from the
## cast-resolution path, so it rides the same hit the damage did.
static func on_hit(t: int, attacker: Combatant, victim: Combatant) -> void:
	if t != Trait.VENOMOUS or victim == null or attacker == null:
		return
	if not victim.alive:
		return
	victim.apply(StatusEffect.make(StatusEffect.Kind.BURN, VENOM_SECONDS,
		attacker.attack_power() * VENOM_FRACTION, "elite_venom"))


## The ring an elite wears. Same machinery as the veteran mark, one ring, in
## the trait's colour — so "which of these is dangerous" is answered from
## across the field rather than by reading a health bar.
static func mark(on: Node3D, t: int) -> Node3D:
	if on == null or t == Trait.NONE:
		return null
	var mark := Node3D.new()
	mark.name = "EliteMark"
	on.add_child(mark)

	var mi := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.74
	torus.outer_radius = 0.86
	torus.rings = 18
	torus.ring_segments = 4
	mi.mesh = torus
	mi.material_override = Vfx._glow(colour_of(t), 1.8)
	mi.position.y = 0.06
	mark.add_child(mi)

	var spin := Vfx.VeteranSpin.new()
	spin.rings = [mi]
	mark.add_child(spin)
	return mark
