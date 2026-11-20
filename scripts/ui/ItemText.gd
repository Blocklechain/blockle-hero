class_name ItemText
extends RefCounted
# ------------------------------------------------------------------------------
# How an item is written out in a list.
#
# Item.describe() exists for the headless tools and is column-aligned for a
# terminal. On a phone the name has to be its own line in the rarity colour and
# everything else has to fit in one subtitle, so the formatting lives here
# rather than being bent out of Item.gd — which this screen layer may only read.
#
# ITEMS ARE INVISIBLE ON THE CHARACTER by design (see Item.gd). That makes these
# strings the entire presentation of a piece of gear, which is why the subtitle
# always carries slot, item level, power AND every attribute: there is no model
# to glance at instead.
# ------------------------------------------------------------------------------

## "+8 STR, +3 CON", or "" when a piece rolled nothing (it cannot, but a save
## edited by hand can).
static func attrs(it: Item) -> String:
	var parts: PackedStringArray = []
	for a in [Stats.Attr.STRENGTH, Stats.Attr.AGILITY, Stats.Attr.INTELLECT,
			Stats.Attr.CONSTITUTION]:
		var v: float = it.bonus.get_attr(a)
		if v > 0.0:
			parts.append("+%.0f %s" % [v, String(Stats.ATTR_SHORT[a])])
	return ", ".join(parts)


## "Weapon · i12 · 26 damage · +8 STR, +3 CON"
static func summary(it: Item) -> String:
	var power_tag: String = "damage" if it.slot == Item.Slot.WEAPON else "armour"
	var line: String = "%s · i%d · %.0f %s" % [it.slot_name(), it.item_level,
		it.power, power_tag]
	var bonus: String = attrs(it)
	return line + ("  ·  " + bonus if bonus != "" else "")


## How this piece compares with what the champion is wearing in that slot, for
## the class that would wear it. Returns "" when there is nothing to compare —
## an empty slot is handled by the caller, which can say "fills an empty slot"
## rather than an arithmetic delta nobody asked for.
static func delta_text(candidate: Item, current: Item, cls: int) -> String:
	if current == null:
		return "Fills an empty slot"
	var d: float = candidate.score_for(cls) - current.score_for(cls)
	if absf(d) < 0.5:
		return "About the same as equipped"
	if d > 0.0:
		return "Better than equipped by %.0f" % d
	return "Worse than equipped by %.0f" % absf(d)


static func delta_colour(candidate: Item, current: Item, cls: int) -> Color:
	if current == null:
		return HeroTheme.ACCENT
	var d: float = candidate.score_for(cls) - current.score_for(cls)
	if d > 0.5:
		return HeroTheme.ACCENT
	if d < -0.5:
		return HeroTheme.FAINT
	return HeroTheme.DIM


## The short right-hand figure on a row: the class-weighted rating. One number
## the player can sort a 300-item stash by, matching Item.score_for() exactly so
## the list and the "better available" marker can never disagree.
static func rating(it: Item, cls: int) -> String:
	return "%.0f" % it.score_for(cls)
