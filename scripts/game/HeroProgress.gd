class_name HeroProgress
extends RefCounted
# ------------------------------------------------------------------------------
# One champion's own progression. Level, experience, and the skill points the
# player has spent on it.
#
# NOTHING HERE IS SHARED. Each champion levels alone and its skill points belong
# to it — taking a fresh hero into Act I means starting that hero at level 1,
# even if another is level 50. That is the whole replayability engine: 200
# heroes x 3 classes x however many stat builds, and the only thing that carries
# across is the pooled stash (see Stash.gd) and campaign difficulty unlocks.
#
# Because of that, this object is small and self-contained — it has to serialise
# cleanly two hundred times over.
# ------------------------------------------------------------------------------

const MAX_LEVEL: int = 60
const SKILL_POINTS_PER_LEVEL: int = 3

## XP needed to go from `level` to `level + 1`.
##
## A gentle power curve: early levels come fast so a new champion is playable
## within minutes (which matters when the player is expected to start over 200
## times), and later levels stretch out without the wall that an exponential
## curve puts up.
const XP_BASE: float = 80.0
const XP_EXP: float = 1.45


var hero_name: String = ""
var hero_class: int = HeroClass.Kind.FIGHTER
var level: int = 1
var xp: float = 0.0

## Skill points spent per attribute, parallel to Stats.Attr.
var spent: Dictionary = {
	Stats.Attr.STRENGTH: 0, Stats.Attr.AGILITY: 0,
	Stats.Attr.INTELLECT: 0, Stats.Attr.CONSTITUTION: 0,
}

## Highest campaign tier this champion has personally cleared.
var tiers_cleared: int = 0


static func create(name: String, cls: int = -1) -> HeroProgress:
	var p := HeroProgress.new()
	p.hero_name = name
	p.hero_class = cls if cls >= 0 else HeroClass.for_hero(name)
	return p


# ------------------------------------------------------------------------------
# Experience
# ------------------------------------------------------------------------------

static func xp_for_level(lv: int) -> float:
	if lv >= MAX_LEVEL:
		return INF
	return XP_BASE * pow(float(lv), XP_EXP)


func xp_to_next() -> float:
	return xp_for_level(level)


func xp_fraction() -> float:
	var need: float = xp_to_next()
	if need == INF or need <= 0.0:
		return 1.0
	return clampf(xp / need, 0.0, 1.0)


## Award experience. Returns how many levels were gained, so the caller can
## show one "LEVEL UP" per level rather than guessing.
func gain_xp(amount: float) -> int:
	if level >= MAX_LEVEL or amount <= 0.0:
		return 0
	xp += amount
	var gained: int = 0
	# A loop, not a single check: a boss at the end of a long run can carry a
	# champion through several levels at once.
	while level < MAX_LEVEL and xp >= xp_to_next():
		xp -= xp_to_next()
		level += 1
		gained += 1
	if level >= MAX_LEVEL:
		xp = 0.0
	return gained


# ------------------------------------------------------------------------------
# Skill points
# ------------------------------------------------------------------------------

func total_skill_points() -> int:
	return (level - 1) * SKILL_POINTS_PER_LEVEL


func spent_points() -> int:
	var n: int = 0
	for k in spent.keys():
		n += int(spent[k])
	return n


func unspent_points() -> int:
	return total_skill_points() - spent_points()


## Put a point into an attribute. Returns false if there is nothing to spend —
## the caller should treat that as "button does nothing", not an error.
func spend(attr: int, count: int = 1) -> bool:
	if count <= 0 or unspent_points() < count:
		return false
	spent[attr] = int(spent[attr]) + count
	return true


## Refund every point. Respec is cheap by design: with this many champions, a
## player who fears a wasted build simply never experiments.
func respec() -> void:
	for k in spent.keys():
		spent[k] = 0


# ------------------------------------------------------------------------------
# Resulting attributes
# ------------------------------------------------------------------------------

## Attributes from class and level only — no gear, no spent points.
func innate_stats() -> Stats:
	return HeroClass.base_stats(hero_class).plus(
		HeroClass.growth_to(hero_class, level))


## Attributes from spent skill points alone.
func allocated_stats() -> Stats:
	var s := Stats.new()
	for k in spent.keys():
		s.add_attr(int(k), float(spent[k]))
	return s


## Everything the champion has on its own, before equipment.
func base_stats() -> Stats:
	return innate_stats().plus(allocated_stats())


func school() -> int:
	return HeroClass.school_of(hero_class)


func class_name_str() -> String:
	return HeroClass.display_name(hero_class)


# ------------------------------------------------------------------------------
# Save / load
# ------------------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"hero": hero_name, "class": hero_class, "level": level, "xp": xp,
		"tiers": tiers_cleared,
		"spent": {
			"str": int(spent[Stats.Attr.STRENGTH]),
			"agi": int(spent[Stats.Attr.AGILITY]),
			"int": int(spent[Stats.Attr.INTELLECT]),
			"con": int(spent[Stats.Attr.CONSTITUTION]),
		},
	}


static func from_dict(d: Dictionary) -> HeroProgress:
	var p := HeroProgress.new()
	p.hero_name = String(d.get("hero", ""))
	p.hero_class = int(d.get("class", HeroClass.Kind.FIGHTER))
	p.level = clampi(int(d.get("level", 1)), 1, MAX_LEVEL)
	p.xp = float(d.get("xp", 0.0))
	p.tiers_cleared = int(d.get("tiers", 0))
	var sp: Dictionary = d.get("spent", {})
	p.spent[Stats.Attr.STRENGTH] = int(sp.get("str", 0))
	p.spent[Stats.Attr.AGILITY] = int(sp.get("agi", 0))
	p.spent[Stats.Attr.INTELLECT] = int(sp.get("int", 0))
	p.spent[Stats.Attr.CONSTITUTION] = int(sp.get("con", 0))

	# A save written before a rebalance can hold more spent points than the
	# champion is now entitled to. Refund rather than refuse to load — losing a
	# character to a tuning change is unforgivable, and a free respec is not.
	if p.spent_points() > p.total_skill_points():
		p.respec()
	return p
