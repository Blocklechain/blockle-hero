class_name CrystalOdds
extends RefCounted
# ------------------------------------------------------------------------------
# The published odds for spawn crystals, and the roll that must obey them.
#
# THIS IS A COMPLIANCE REQUIREMENT, NOT A DESIGN NOTE.
#
# App Store Review Guideline 3.1.1: apps offering loot boxes or other mechanisms
# that provide RANDOMISED virtual items FOR PURCHASE must disclose the odds of
# receiving each type of item to customers BEFORE purchase. Spawn crystals grant
# a random champion and are sold as consumable IAP, so they are squarely in
# scope. Apps are rejected for omitting this.
#
# So the odds live here, in one table, which is BOTH the thing the roll uses AND
# the thing the disclosure screen prints. They cannot drift apart, because there
# is only one of them — a disclosure that is a hand-maintained copy of the real
# table is how studios end up publishing numbers that are quietly wrong.
#
# `tools/oddstest.gd` rolls a large sample and asserts the observed rates match
# this table, so a tuning change that forgets the disclosure fails the test
# rather than shipping.
# ------------------------------------------------------------------------------

## Probability of each champion rarity from one spawn crystal. Must sum to 1.
const ODDS: Dictionary = {
	Item.Rarity.COMMON: 0.52,
	Item.Rarity.UNCOMMON: 0.28,
	Item.Rarity.RARE: 0.14,
	Item.Rarity.EPIC: 0.05,
	Item.Rarity.LEGENDARY: 0.01,
}

## Guaranteed Epic or better every N crystals without one. A pity timer is good
## design and good compliance: it bounds the worst case a player can experience,
## and it is disclosed alongside the base rates because it changes them.
const PITY_THRESHOLD: int = 30


static func odds_for(rarity: int) -> float:
	return float(ODDS.get(rarity, 0.0))


## The disclosure text. Shown on the crystal pack purchase screen and in the
## crystal-opening screen — "prior to purchase" means the player must be able to
## read this before spending money, not after.
static func disclosure_text() -> String:
	var lines: PackedStringArray = [
		"Spawn Crystal odds — chance of each champion tier per crystal:"]
	for tier in [Item.Rarity.LEGENDARY, Item.Rarity.EPIC, Item.Rarity.RARE,
			Item.Rarity.UNCOMMON, Item.Rarity.COMMON]:
		lines.append("    %-10s  %.2f%%" % [
			String(Item.RARITY_NAMES[tier]), odds_for(tier) * 100.0])
	lines.append("")
	lines.append("A champion of Epic tier or better is guaranteed at least once "
		+ "every %d crystals." % PITY_THRESHOLD)
	lines.append("Already-owned champions convert to Gold at the rate shown on "
		+ "the champion's card.")
	return "\n".join(lines)


## Roll one crystal's rarity. `since_epic` is how many crystals have been opened
## without an Epic+ — passing it in keeps this function pure and testable.
static func roll_rarity(seed: int, roll_id: int, since_epic: int) -> int:
	if since_epic >= PITY_THRESHOLD - 1:
		# Pity: force Epic or Legendary, keeping their relative weighting so the
		# guarantee does not quietly become "always exactly Epic".
		var e: float = odds_for(Item.Rarity.EPIC)
		var l: float = odds_for(Item.Rarity.LEGENDARY)
		var r: float = Rng.unit2(seed, roll_id, 8821)
		return Item.Rarity.LEGENDARY if r < l / maxf(e + l, 0.0001) \
			else Item.Rarity.EPIC

	var roll: float = Rng.unit2(seed, roll_id, 8819)
	var acc: float = 0.0
	# Rarest first so floating-point slop lands in the common bucket rather than
	# inflating the legendary rate.
	for tier in [Item.Rarity.LEGENDARY, Item.Rarity.EPIC, Item.Rarity.RARE,
			Item.Rarity.UNCOMMON]:
		acc += odds_for(tier)
		if roll < acc:
			return tier
	return Item.Rarity.COMMON


## Sanity check used by the test: the table must be a probability distribution.
static func sums_to_one() -> bool:
	var total: float = 0.0
	for k in ODDS.keys():
		total += float(ODDS[k])
	return absf(total - 1.0) < 0.0001
