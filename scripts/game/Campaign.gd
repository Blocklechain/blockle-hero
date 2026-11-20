class_name Campaign
extends RefCounted
# ------------------------------------------------------------------------------
# The campaign: sixteen regions in four acts, replayed at rising difficulty.
#
# The acts ARE the biome list in Biome.IDS order, which is already arranged as a
# difficulty ramp — pastoral, then harsh, then hostile, then unreal, then the
# citadel. Nothing here duplicates that ordering; it reads it, so adding a biome
# extends the campaign automatically.
#
# DIFFICULTY TIERS are the replay engine. Finishing the campaign unlocks the next
# tier, which is the same sixteen regions with harder enemies and better loot. A
# tier is NOT a separate build of the world — the same seed produces the same
# terrain, so the player learns a place and then returns to it outmatched.
#
# Two unlock scopes, deliberately different:
#   * TIER unlocks are account-wide. Clear Veteran once and every champion may
#     enter it — otherwise each of 200 heroes would have to grind the same
#     ladder, which is busywork, not replayability.
#   * LEVELS and SKILL POINTS stay per champion (see HeroProgress). That is
#     where the restart actually means something.
# ------------------------------------------------------------------------------

enum Tier { NORMAL, VETERAN, MERCILESS, ETERNAL }

const TIER_NAMES: Dictionary = {
	Tier.NORMAL: "Normal", Tier.VETERAN: "Veteran",
	Tier.MERCILESS: "Merciless", Tier.ETERNAL: "Eternal",
}

## Minimum champion level before a tier may be entered. A gate, not a wall —
## it stops a level-1 hero wandering into Merciless and being deleted, which
## reads as a bug rather than a challenge.
const TIER_MIN_LEVEL: Dictionary = {
	Tier.NORMAL: 1, Tier.VETERAN: 18, Tier.MERCILESS: 34, Tier.ETERNAL: 48,
}

## Per-tier scaling. Health climbs faster than damage on purpose: fights should
## get longer and more demanding, not become one-shot coin flips.
const TIER_ENEMY_LEVEL: Dictionary = {
	Tier.NORMAL: 0, Tier.VETERAN: 16, Tier.MERCILESS: 32, Tier.ETERNAL: 46,
}
const TIER_HEALTH: Dictionary = {
	Tier.NORMAL: 1.0, Tier.VETERAN: 2.6, Tier.MERCILESS: 6.5, Tier.ETERNAL: 15.0,
}
const TIER_DAMAGE: Dictionary = {
	Tier.NORMAL: 1.0, Tier.VETERAN: 1.9, Tier.MERCILESS: 3.4, Tier.ETERNAL: 5.8,
}
const TIER_XP: Dictionary = {
	Tier.NORMAL: 1.0, Tier.VETERAN: 2.2, Tier.MERCILESS: 4.5, Tier.ETERNAL: 8.0,
}
## Extra chance of each drop upgrading one rarity step.
const TIER_LOOT_BONUS: Dictionary = {
	Tier.NORMAL: 0.0, Tier.VETERAN: 0.12, Tier.MERCILESS: 0.26, Tier.ETERNAL: 0.42,
}

const REGIONS_PER_ACT: int = 4


# ------------------------------------------------------------------------------
# Structure
# ------------------------------------------------------------------------------

static func region_count() -> int:
	return Biome.IDS.size()


static func act_count() -> int:
	return int(ceil(float(region_count()) / float(REGIONS_PER_ACT)))


static func biome_at(index: int) -> String:
	return Biome.IDS[clampi(index, 0, region_count() - 1)]


static func act_of(index: int) -> int:
	return index / REGIONS_PER_ACT


static func act_name(act: int) -> String:
	const NAMES: PackedStringArray = ["The Green Road", "The Long Dark",
		"The Bone Marches", "The Shattered Crown"]
	return NAMES[clampi(act, 0, NAMES.size() - 1)]


static func region_title(index: int) -> String:
	return "%s — %s" % [act_name(act_of(index)),
		Biome.display_name(biome_at(index))]


## The world seed for a region. Depends on the campaign seed and the region
## index but NOT on the tier, so Veteran Greenwood is the same ground as Normal
## Greenwood. Returning to a place you know, outmatched, is the point.
static func region_seed(campaign_seed: int, index: int) -> int:
	return Rng.seed_of(campaign_seed, "region.%d" % index)


# ------------------------------------------------------------------------------
# Difficulty
# ------------------------------------------------------------------------------

static func tier_name(tier: int) -> String:
	return String(TIER_NAMES.get(tier, "?"))


## Enemy level for a region at a tier. Within a tier the ramp is gentle; the
## step between tiers is what actually raises the bar.
static func enemy_level(index: int, tier: int) -> int:
	var within: float = float(index) / float(maxi(region_count() - 1, 1))
	var base: float = 1.0 + within * 15.0
	return int(round(base + float(TIER_ENEMY_LEVEL.get(tier, 0))))


static func enemy_health_mult(tier: int) -> float:
	return float(TIER_HEALTH.get(tier, 1.0))


static func enemy_damage_mult(tier: int) -> float:
	return float(TIER_DAMAGE.get(tier, 1.0))


## XP for one kill, before the tier multiplier is applied to the encounter.
static func xp_per_kill(index: int, tier: int) -> float:
	var lv: int = enemy_level(index, tier)
	return (6.0 + float(lv) * 2.4) * float(TIER_XP.get(tier, 1.0))


static func can_enter(tier: int, hero: HeroProgress, unlocked_tier: int) -> bool:
	if tier > unlocked_tier:
		return false
	return hero.level >= int(TIER_MIN_LEVEL.get(tier, 1))


## Why a tier is refused, for the UI. Empty string means it is enterable.
static func entry_blocked_reason(tier: int, hero: HeroProgress,
		unlocked_tier: int) -> String:
	if tier > unlocked_tier:
		return "Clear %s to unlock" % tier_name(tier - 1)
	var need: int = int(TIER_MIN_LEVEL.get(tier, 1))
	if hero.level < need:
		return "Requires level %d" % need
	return ""


# ------------------------------------------------------------------------------
# Loot
# ------------------------------------------------------------------------------

## Roll a rarity. Base weights are deliberately steep — a legendary has to be
## rare enough that the stash stays interesting after a hundred hours — and the
## tier bonus promotes a roll rather than reshaping the whole table.
static func roll_rarity(seed: int, roll_id: int, tier: int) -> int:
	var r: float = Rng.unit2(seed, roll_id, 5501)
	var rarity: int
	if r < 0.58:
		rarity = Item.Rarity.COMMON
	elif r < 0.83:
		rarity = Item.Rarity.UNCOMMON
	elif r < 0.955:
		rarity = Item.Rarity.RARE
	elif r < 0.994:
		rarity = Item.Rarity.EPIC
	else:
		rarity = Item.Rarity.LEGENDARY

	if Rng.unit2(seed, roll_id, 5503) < float(TIER_LOOT_BONUS.get(tier, 0.0)):
		rarity = mini(rarity + 1, Item.Rarity.LEGENDARY)
	return rarity


## Items dropped by clearing a region, already rolled at the right level.
static func roll_region_loot(seed: int, index: int, tier: int,
		count: int = 3) -> Array[Item]:
	var out: Array[Item] = []
	var ilvl: int = enemy_level(index, tier)
	for i in range(count):
		var rid: int = index * 1000 + tier * 100 + i
		out.append(Item.roll(seed, rid, ilvl, roll_rarity(seed, rid, tier)))
	return out
