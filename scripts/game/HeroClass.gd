class_name HeroClass
extends RefCounted
# ------------------------------------------------------------------------------
# The three archetypes, and what each one is actually made of.
#
#   FIGHTER   melee, Strength and Constitution. Tough, close, reliable.
#   RANGER    ranged, Agility. Fast, critical, fragile.
#   MAGE      spells, Intellect. Highest damage ceiling, lowest health.
#
# A class is three things: where it starts, how it grows automatically, and which
# attribute its damage reads from. Everything else — gear, skill points, level —
# is identical machinery across all of them, so adding a fourth archetype later
# is a table entry rather than a new code path.
#
# The per-level growth is deliberately NOT the whole progression. It is about
# two thirds of the attribute gain; the rest comes from skill points the player
# spends. A character that levels entirely on rails has no decisions in it, and
# one with no automatic growth punishes a player who spends badly.
# ------------------------------------------------------------------------------

enum Kind { FIGHTER, RANGER, MAGE }

## Which attribute a class's attacks scale from.
enum School { MELEE, RANGED, SPELL }

const NAMES: Dictionary = {
	Kind.FIGHTER: "Fighter", Kind.RANGER: "Ranger", Kind.MAGE: "Mage",
}

# Starting attributes at level 1. Totals are equal (36) across classes on
# purpose — a class should feel different, not numerically better.
const BASE: Dictionary = {
	Kind.FIGHTER: [13.0, 7.0, 4.0, 12.0],
	Kind.RANGER: [8.0, 14.0, 5.0, 9.0],
	Kind.MAGE: [5.0, 7.0, 15.0, 9.0],
}

# Automatic attribute gain per level, in STR/AGI/INT/CON order.
const GROWTH: Dictionary = {
	Kind.FIGHTER: [1.10, 0.45, 0.20, 0.95],
	Kind.RANGER: [0.55, 1.15, 0.30, 0.70],
	Kind.MAGE: [0.25, 0.50, 1.25, 0.70],
}

const SCHOOL_OF: Dictionary = {
	Kind.FIGHTER: School.MELEE,
	Kind.RANGER: School.RANGED,
	Kind.MAGE: School.SPELL,
}

## The attribute a class most wants from gear and skill points. Used to sort
## loot and to warn a player who is about to spend badly, never to forbid it —
## an Agility Fighter is a strange build, not an illegal one.
const PRIMARY: Dictionary = {
	Kind.FIGHTER: Stats.Attr.STRENGTH,
	Kind.RANGER: Stats.Attr.AGILITY,
	Kind.MAGE: Stats.Attr.INTELLECT,
}


static func display_name(k: int) -> String:
	return String(NAMES.get(k, "Unknown"))


static func school_of(k: int) -> int:
	return int(SCHOOL_OF.get(k, School.MELEE))


static func primary_attr(k: int) -> int:
	return int(PRIMARY.get(k, Stats.Attr.STRENGTH))


static func base_stats(k: int) -> Stats:
	var b: Array = BASE.get(k, BASE[Kind.FIGHTER])
	return Stats.make(b[0], b[1], b[2], b[3])


## Attributes gained automatically between level 1 and `level`.
static func growth_to(k: int, level: int) -> Stats:
	var g: Array = GROWTH.get(k, GROWTH[Kind.FIGHTER])
	var n: float = float(maxi(level - 1, 0))
	return Stats.make(g[0] * n, g[1] * n, g[2] * n, g[3] * n)


# Which class is a given hero? The 200 models came from a project with no class
# system, so there is no authored answer — derive one from the name so it is at
# least STABLE (the same hero is always the same class) and evenly spread.
#
# When the roster gets authored classes, this becomes the fallback for anything
# not in the table.
static func for_hero(hero_name: String) -> int:
	var h: int = Rng.seed_of(0x5EED, hero_name)
	return h % 3
