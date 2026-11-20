class_name Stats
extends RefCounted
# ------------------------------------------------------------------------------
# The four attributes, and everything combat reads off them.
#
#   STRENGTH      melee damage, and what you can carry
#   AGILITY       ranged damage, attack speed, crit, dodge
#   INTELLECT     spell damage and mana
#   CONSTITUTION  health and resistance
#
# Every number a fight needs is DERIVED here and nowhere else. If damage is
# computed in one place and the character sheet estimates it in another, the two
# drift and the sheet starts lying to the player — which is the fastest way to
# lose their trust in a progression system.
#
# Attributes come from three sources that stack: the class baseline, automatic
# per-level growth, and the skill points the player spent by hand. Keeping them
# separate (rather than one running total) means a respec is just discarding the
# third bucket, and the sheet can show "14 (+4)" honestly.
# ------------------------------------------------------------------------------

enum Attr { STRENGTH, AGILITY, INTELLECT, CONSTITUTION }

const ATTR_NAMES: Dictionary = {
	Attr.STRENGTH: "Strength",
	Attr.AGILITY: "Agility",
	Attr.INTELLECT: "Intellect",
	Attr.CONSTITUTION: "Constitution",
}

const ATTR_SHORT: Dictionary = {
	Attr.STRENGTH: "STR", Attr.AGILITY: "AGI",
	Attr.INTELLECT: "INT", Attr.CONSTITUTION: "CON",
}

var strength: float = 0.0
var agility: float = 0.0
var intellect: float = 0.0
var constitution: float = 0.0


static func make(st: float, ag: float, intl: float, con: float) -> Stats:
	var s := Stats.new()
	s.strength = st
	s.agility = ag
	s.intellect = intl
	s.constitution = con
	return s


func get_attr(a: int) -> float:
	match a:
		Attr.STRENGTH: return strength
		Attr.AGILITY: return agility
		Attr.INTELLECT: return intellect
		_: return constitution


func add_attr(a: int, v: float) -> void:
	match a:
		Attr.STRENGTH: strength += v
		Attr.AGILITY: agility += v
		Attr.INTELLECT: intellect += v
		_: constitution += v


func plus(o: Stats) -> Stats:
	return Stats.make(strength + o.strength, agility + o.agility,
		intellect + o.intellect, constitution + o.constitution)


func scaled(k: float) -> Stats:
	return Stats.make(strength * k, agility * k, intellect * k, constitution * k)


func copy() -> Stats:
	return Stats.make(strength, agility, intellect, constitution)


func total() -> float:
	return strength + agility + intellect + constitution


func to_dict() -> Dictionary:
	return {"str": strength, "agi": agility, "int": intellect, "con": constitution}


static func from_dict(d: Dictionary) -> Stats:
	return Stats.make(float(d.get("str", 0.0)), float(d.get("agi", 0.0)),
		float(d.get("int", 0.0)), float(d.get("con", 0.0)))


func describe() -> String:
	return "STR %.0f  AGI %.0f  INT %.0f  CON %.0f" % [
		strength, agility, intellect, constitution]


# ------------------------------------------------------------------------------
# Derived combat values
#
# Deliberately linear in the attributes. Linear scaling is easy for a player to
# reason about ("ten more Strength is twelve more damage"), easy to balance, and
# does not explode at high level the way quadratic scaling does. The interesting
# decisions should come from gear and skills, not from an attribute curve nobody
# can predict.
# ------------------------------------------------------------------------------

const BASE_HEALTH: float = 50.0
const HEALTH_PER_CON: float = 12.0
const HEALTH_PER_LEVEL: float = 8.0

const BASE_DAMAGE: float = 5.0
const DAMAGE_PER_STR: float = 1.20          # melee
const DAMAGE_PER_AGI: float = 1.10          # ranged
const DAMAGE_PER_INT: float = 1.30          # spell

const BASE_MANA: float = 20.0
const MANA_PER_INT: float = 8.0

const BASE_CRIT: float = 0.03
const CRIT_PER_AGI: float = 0.0040
const CRIT_CAP: float = 0.60

const BASE_DODGE: float = 0.0
const DODGE_PER_AGI: float = 0.0030
const DODGE_CAP: float = 0.40

const HASTE_PER_AGI: float = 0.0120         # fraction of extra attack speed
const HASTE_CAP: float = 1.00               # at most double speed


func max_health(level: int) -> float:
	return BASE_HEALTH + constitution * HEALTH_PER_CON \
		+ float(level - 1) * HEALTH_PER_LEVEL


func max_mana() -> float:
	return BASE_MANA + intellect * MANA_PER_INT


func melee_damage() -> float:
	return BASE_DAMAGE + strength * DAMAGE_PER_STR


func ranged_damage() -> float:
	return BASE_DAMAGE + agility * DAMAGE_PER_AGI


func spell_damage() -> float:
	return BASE_DAMAGE + intellect * DAMAGE_PER_INT


## Damage for whichever school this class actually fights with.
func damage_for(school: int) -> float:
	match school:
		HeroClass.School.MELEE: return melee_damage()
		HeroClass.School.RANGED: return ranged_damage()
		_: return spell_damage()


func crit_chance() -> float:
	return minf(BASE_CRIT + agility * CRIT_PER_AGI, CRIT_CAP)


func dodge_chance() -> float:
	return minf(BASE_DODGE + agility * DODGE_PER_AGI, DODGE_CAP)


## Attack-speed multiplier: 1.0 is the base rate.
func haste() -> float:
	return 1.0 + minf(agility * HASTE_PER_AGI, HASTE_CAP)
