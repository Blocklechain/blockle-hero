class_name Champion
extends RefCounted
# ------------------------------------------------------------------------------
# What a champion IS, before anyone has played it: its rarity tier and what that
# tier is worth.
#
# Rarity uses the same five-step ladder as items, so the player learns one
# colour language for the whole game.
#
# THE BALANCE DECISION, stated plainly: rarity is a MODEST stat multiplier, not
# a tier list. A Legendary champion is about 24% stronger than a Common at the
# same level — enough to feel like a prize, far too little to make the other 190
# heroes pointless. Build the gap any wider and the roster collapses to "play
# the legendary", which throws away the replayability the whole design exists
# for. Skill points and gear both out-weigh rarity by a wide margin.
# ------------------------------------------------------------------------------

## Reuses Item.Rarity so the colours and names match across the whole game.
const RARITY_STAT_MULT: Dictionary = {
	Item.Rarity.COMMON: 1.00,
	Item.Rarity.UNCOMMON: 1.06,
	Item.Rarity.RARE: 1.12,
	Item.Rarity.EPIC: 1.18,
	Item.Rarity.LEGENDARY: 1.24,
}

## How the 200 heroes are distributed. Deliberately steep at the top: a
## legendary has to be genuinely scarce for a gem to feel worth saving for.
const RARITY_WEIGHTS: Dictionary = {
	Item.Rarity.COMMON: 0.50,
	Item.Rarity.UNCOMMON: 0.26,
	Item.Rarity.RARE: 0.15,
	Item.Rarity.EPIC: 0.07,
	Item.Rarity.LEGENDARY: 0.02,
}

## Gems to unlock a SPECIFIC champion you have chosen. Steeper than the random
## route, because picking exactly the hero you want is the premium action.
const GEM_COST: Dictionary = {
	Item.Rarity.COMMON: 8,
	Item.Rarity.UNCOMMON: 20,
	Item.Rarity.RARE: 45,
	Item.Rarity.EPIC: 110,
	Item.Rarity.LEGENDARY: 300,
}

## Gold paid out when a champion is already owned and a crystal duplicates it.
## A duplicate must never be nothing — that is the single most resented outcome
## in any random-unlock system.
const DUPLICATE_GOLD: Dictionary = {
	Item.Rarity.COMMON: 150,
	Item.Rarity.UNCOMMON: 400,
	Item.Rarity.RARE: 1100,
	Item.Rarity.EPIC: 3000,
	Item.Rarity.LEGENDARY: 9000,
}


## A champion's rarity, derived from its name so it is STABLE — the same hero is
## always the same tier, on every device and every reinstall, with no table to
## ship or migrate. Uses the avalanche hash, so neighbouring names do not land
## in the same bucket.
static func rarity_of(hero_name: String) -> int:
	var r: float = float(Rng.seed_of(0xC0FFEE, hero_name) % 1000000) / 1000000.0
	var acc: float = 0.0
	for tier in [Item.Rarity.COMMON, Item.Rarity.UNCOMMON, Item.Rarity.RARE,
			Item.Rarity.EPIC, Item.Rarity.LEGENDARY]:
		acc += float(RARITY_WEIGHTS[tier])
		if r < acc:
			return tier
	return Item.Rarity.COMMON


static func stat_multiplier(hero_name: String) -> float:
	return float(RARITY_STAT_MULT.get(rarity_of(hero_name), 1.0))


static func gem_cost(hero_name: String) -> int:
	return int(GEM_COST.get(rarity_of(hero_name), 999))


static func duplicate_gold(hero_name: String) -> int:
	return int(DUPLICATE_GOLD.get(rarity_of(hero_name), 100))


static func rarity_name(hero_name: String) -> String:
	return String(Item.RARITY_NAMES.get(rarity_of(hero_name), "?"))


static func colour(hero_name: String) -> Color:
	return Item.RARITY_COLOURS.get(rarity_of(hero_name), Color.WHITE)


## Every champion of a given rarity. Used by the crystal roll and by the roster
## screen's filters.
static func of_rarity(all_heroes: PackedStringArray, tier: int) -> PackedStringArray:
	var out := PackedStringArray()
	for h in all_heroes:
		if rarity_of(h) == tier:
			out.append(h)
	return out


## The champions every player starts with: a Fighter, a Ranger and a Mage, so
## all three schools are playable before anything is unlocked. Chosen as the
## first Common of each class in roster order, so the starting three are the
## same for everyone and cost nobody a gem.
static func starters(all_heroes: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for want_class in [HeroClass.Kind.FIGHTER, HeroClass.Kind.RANGER,
			HeroClass.Kind.MAGE]:
		for h in all_heroes:
			if HeroClass.for_hero(h) == want_class \
					and rarity_of(h) == Item.Rarity.COMMON:
				out.append(h)
				break
	return out
