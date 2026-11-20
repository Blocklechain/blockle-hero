class_name MageSpells
extends RefCounted
# ------------------------------------------------------------------------------
# A unique spellbook for every mage.
#
# Roughly a third of 200 heroes are mages, so "every mage has unique spells"
# means about 200 distinct spells. Hand-authoring that many well is not
# realistic, and hand-authoring them badly is worse than sharing — 200 spells
# that are all slightly different numbers is noise, not variety.
#
# So spells are COMPOSED from three axes:
#
#   ELEMENT    fire, frost, storm, shadow, arcane, venom, radiance
#              decides the signature status effect and the name's first half
#   FORM       bolt, lance, cone, nova, storm, chain, orb
#              decides the targeting shape and the name's second half
#   ROLE       which of the three rig slots it fills
#
# 7 elements x 7 forms is 49 shapes before any numeric variation, and a mage's
# identity is its ELEMENT — every spell it owns shares one, so a Frost mage
# plays like a Frost mage across all three buttons rather than being a bag of
# unrelated tricks.
#
# STILL EXACTLY THREE ABILITIES, and still the same slot grammar as the other
# classes (damage / control / self). The rig has three ability clips and the
# player has three buttons; uniqueness goes into what the buttons DO, never into
# how many there are.
#
# BALANCE: every spell is rolled inside tight bands and `tools/combattest.gd`
# asserts the spread between the strongest and weakest mage kit stays small.
# Unique must not mean unequal, or the roster collapses to whichever mage rolled
# the best numbers.
# ------------------------------------------------------------------------------

enum Element { FIRE, FROST, STORM, SHADOW, ARCANE, VENOM, RADIANCE }

const ELEMENT_NAMES: Dictionary = {
	Element.FIRE: "Fire", Element.FROST: "Frost", Element.STORM: "Storm",
	Element.SHADOW: "Shadow", Element.ARCANE: "Arcane", Element.VENOM: "Venom",
	Element.RADIANCE: "Radiance",
}

## What each element does on top of damage. This is the mechanical identity.
const ELEMENT_STATUS: Dictionary = {
	Element.FIRE: StatusEffect.Kind.BURN,
	Element.FROST: StatusEffect.Kind.SLOW,
	Element.STORM: StatusEffect.Kind.STUN,
	Element.SHADOW: StatusEffect.Kind.WEAKEN,
	Element.ARCANE: -1,                        # no rider — pure damage instead
	Element.VENOM: StatusEffect.Kind.BURN,
	Element.RADIANCE: -1,                      # pays out as healing instead
}

## Arcane and Radiance trade their status rider for something else, so they are
## not simply worse. Arcane hits harder; Radiance heals the caster.
const ELEMENT_DAMAGE_BONUS: Dictionary = {
	Element.FIRE: 0.0, Element.FROST: 0.0, Element.STORM: -0.10,
	Element.SHADOW: 0.0, Element.ARCANE: 0.22, Element.VENOM: 0.0,
	Element.RADIANCE: -0.05,
}

const ELEMENT_WORD: Dictionary = {
	Element.FIRE: ["Ember", "Cinder", "Pyre", "Ash"],
	Element.FROST: ["Rime", "Frost", "Glacier", "Hoar"],
	Element.STORM: ["Thunder", "Tempest", "Levin", "Gale"],
	Element.SHADOW: ["Umbra", "Night", "Dusk", "Gloom"],
	Element.ARCANE: ["Aether", "Rune", "Sigil", "Prism"],
	Element.VENOM: ["Blight", "Spore", "Mire", "Thorn"],
	Element.RADIANCE: ["Dawn", "Halo", "Lumen", "Sun"],
}

enum Form { BOLT, LANCE, CONE, NOVA, STORM, CHAIN, ORB }

const FORM_WORD: Dictionary = {
	Form.BOLT: "bolt", Form.LANCE: "lance", Form.CONE: "breath",
	Form.NOVA: "nova", Form.STORM: "storm", Form.CHAIN: "arc", Form.ORB: "orb",
}

## shape, range, arc, max targets — the delivery of each form.
const FORM_SHAPE: Dictionary = {
	Form.BOLT: [Ability.Shape.SINGLE, 11.0, 0.0, 1],
	Form.LANCE: [Ability.Shape.ARC, 13.0, 25.0, 3],
	Form.CONE: [Ability.Shape.ARC, 8.0, 75.0, 5],
	Form.NOVA: [Ability.Shape.CIRCLE, 5.5, 0.0, 8],
	Form.STORM: [Ability.Shape.CIRCLE, 7.5, 0.0, 6],
	Form.CHAIN: [Ability.Shape.ARC, 10.0, 50.0, 4],
	Form.ORB: [Ability.Shape.SINGLE, 9.0, 0.0, 2],
}

## Per-target damage, set so every form has the SAME expected throughput once
## you account for how many things it realistically hits.
##
## The first pass set these by feel and the balance test caught a 3.06x spread
## between the weakest and strongest mage — a nova hitting five enemies was
## worth triple a bolt hitting one, so a mage's power came down to which form it
## happened to roll. That is exactly the failure "unique spells" invites.
##
## Now each value is derived: blended = SINGLE_WEIGHT * d + GROUP_WEIGHT * d *
## min(targets, GROUP_SIZE), solved so blended == TARGET_THROUGHPUT for every
## form. Variety lives in reach, shape and element — never in raw power.
const SINGLE_WEIGHT: float = 0.40     # share of fights that are one target
const GROUP_WEIGHT: float = 0.60      # share that are a pack
const GROUP_SIZE: int = 5             # typical pack a spell can catch
const TARGET_THROUGHPUT: float = 1.90

const FORM_DAMAGE: Dictionary = {
	Form.BOLT: 1.90, Form.ORB: 1.19, Form.LANCE: 0.86, Form.CHAIN: 0.68,
	Form.CONE: 0.56, Form.STORM: 0.56, Form.NOVA: 0.56,
}

## Forms that may carry a mage's DAMAGE button. Deliberately the focused ones:
## a player whose only damage spell is a wide nova is helpless against a boss,
## and they never chose that. The wide shapes live on the control slot instead.
const SLOT1_FORMS: Array = [Form.BOLT, Form.ORB, Form.LANCE, Form.CHAIN]

## Forms for the CONTROL button, which wants to catch a group.
const SLOT2_FORMS: Array = [Form.CONE, Form.NOVA, Form.STORM, Form.CHAIN]


## The blended throughput of a form at a given per-target damage. Used both to
## derive FORM_DAMAGE above and by the balance test, so the two cannot drift.
static func blended_value(form: int, damage: float) -> float:
	var n: int = int(FORM_SHAPE[form][3])
	return SINGLE_WEIGHT * damage \
		+ GROUP_WEIGHT * damage * float(mini(n, GROUP_SIZE))


static func element_of(hero: String) -> int:
	return int(Rng.seed_of(0xE1E3, hero) % Element.size())


static func element_name(hero: String) -> String:
	return String(ELEMENT_NAMES[element_of(hero)])


static func _name(hero: String, elem: int, form: int, salt: int) -> String:
	var words: Array = ELEMENT_WORD[elem]
	var w: String = String(words[int(Rng.hash2(Rng.seed_of(0xBEEF, hero), salt, 13)
		% words.size())])
	return "%s%s" % [w, String(FORM_WORD[form])]


## The three spells for one mage. Deterministic in the hero's name, so a
## champion's kit is the same on every device and after every reinstall, with
## no table to ship.
static func for_hero(hero: String) -> Array[Ability]:
	var seed: int = Rng.seed_of(0x57E11, hero)
	var elem: int = element_of(hero)
	var status: int = int(ELEMENT_STATUS[elem])
	var dmg_bonus: float = float(ELEMENT_DAMAGE_BONUS[elem])

	# --- slot 1: the damage spell ---------------------------------------
	var form1: int = int(SLOT1_FORMS[int(Rng.hash2(seed, 1, 17) % SLOT1_FORMS.size())])
	var s1 := _build(hero, elem, form1, 1, seed, 101)
	s1.cooldown = snappedf(3.0 + Rng.range2(seed, 2, 19, 0.0, 1.6), 0.1)
	# Damage scales WITH cooldown, so a longer wait hits proportionally harder.
	# Without this, cooldown is a second hidden power axis and a mage that rolled
	# 3.0s simply out-damages one that rolled 4.6s by half again.
	s1.damage_mult = float(FORM_DAMAGE[form1]) * (1.0 + dmg_bonus) \
		* (s1.cooldown / 3.8)
	if status >= 0:
		s1.applies = status
		s1.applies_duration = snappedf(3.0 + Rng.range2(seed, 3, 23, 0.0, 2.0), 0.1)
	if elem == Element.RADIANCE:
		s1.heal_fraction = 0.05
	s1.description = "A %s %s." % [element_name(hero).to_lower(),
		String(FORM_WORD[form1])]

	# --- slot 2: the control spell --------------------------------------
	# Always a stun, whatever the element — the slot grammar has to hold across
	# every class and every hero, or the player cannot rely on button two.
	var form2: int = int(SLOT2_FORMS[int(Rng.hash2(seed, 4, 29) % SLOT2_FORMS.size())])
	var s2 := _build(hero, elem, form2, 2, seed, 202)
	s2.cooldown = snappedf(8.0 + Rng.range2(seed, 6, 37, 0.0, 3.0), 0.1)
	# Control spells trade damage for the stun; same cooldown normalisation.
	s2.damage_mult = float(FORM_DAMAGE[form2]) * 0.55 * (s2.cooldown / 9.5)
	s2.applies = StatusEffect.Kind.STUN
	s2.applies_duration = snappedf(1.6 + Rng.range2(seed, 7, 41, 0.0, 0.8), 0.1)
	s2.description = "Locks enemies to a walk, and stops them striking back."

	# --- slot 3: the self spell -----------------------------------------
	var s3 := Ability.new()
	s3.id = "%s_self" % hero
	s3.slot = 3
	s3.shape = Ability.Shape.SELF
	s3.damage_mult = 0.0
	s3.cooldown = snappedf(12.0 + Rng.range2(seed, 8, 43, 0.0, 4.0), 0.1)
	# Element decides what "defend yourself" means for this mage.
	match elem:
		Element.RADIANCE, Element.FIRE:
			s3.title = _name(hero, elem, Form.ORB, 303)
			s3.heal_fraction = snappedf(0.22 + Rng.range2(seed, 9, 47, 0.0, 0.10), 0.01)
			s3.description = "Draw on the light to mend your wounds."
		Element.STORM, Element.VENOM:
			s3.title = _name(hero, elem, Form.CHAIN, 303)
			s3.self_applies = StatusEffect.Kind.HASTE
			s3.self_duration = snappedf(4.5 + Rng.range2(seed, 10, 53, 0.0, 2.0), 0.1)
			s3.self_magnitude = snappedf(0.45 + Rng.range2(seed, 11, 59, 0.0, 0.25), 0.01)
			s3.description = "Quicken — move faster for a short while."
		_:
			s3.title = _name(hero, elem, Form.ORB, 303)
			s3.self_applies = StatusEffect.Kind.SHIELD
			s3.self_duration = snappedf(8.0 + Rng.range2(seed, 12, 61, 0.0, 4.0), 0.1)
			s3.self_magnitude = 0.0       # scales off max health at cast time
			s3.description = "A barrier that drinks the next blows."

	return [s1, s2, s3] as Array[Ability]


static func _build(hero: String, elem: int, form: int, slot: int,
		seed: int, salt: int) -> Ability:
	var shape: Array = FORM_SHAPE[form]
	var a := Ability.new()
	a.id = "%s_s%d" % [hero, slot]
	a.title = _name(hero, elem, form, salt)
	a.slot = slot
	a.shape = int(shape[0])
	a.range_m = float(shape[1])
	a.arc_degrees = float(shape[2])
	a.max_targets = int(shape[3])
	return a


## Rough power score for one kit, used by the balance test. Not a game-facing
## number — it exists so a tuning change that makes one element dominate shows
## up as a failing test rather than as a player complaint months later.
static func kit_power(hero: String) -> float:
	var total: float = 0.0
	for a in for_hero(hero):
		var rate: float = 1.0 / maxf(a.cooldown, 0.5)
		# Blended across single-target and group fights, the same assumption
		# FORM_DAMAGE is derived from — one encounter model, used everywhere.
		var per_cast: float = SINGLE_WEIGHT * a.damage_mult \
			+ GROUP_WEIGHT * a.damage_mult * float(mini(a.max_targets, GROUP_SIZE))
		total += per_cast * rate
		if a.applies == StatusEffect.Kind.STUN:
			total += 0.35 * rate
		if a.self_applies == StatusEffect.Kind.SHIELD:
			total += 0.30 * rate
		if a.self_applies == StatusEffect.Kind.HASTE:
			total += a.self_magnitude * 0.5 * rate
		total += a.heal_fraction * 2.0 * rate
	return total
