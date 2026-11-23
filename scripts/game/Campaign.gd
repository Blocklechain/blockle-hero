class_name Campaign
extends RefCounted

## Preloaded by path, not by bare class_name: Affix.gd is newer than the
## editor's global class cache, and every headless harness loads this file
## directly. See tools/classcheck.gd.
const AffixC := preload("res://scripts/game/Affix.gd")
# ------------------------------------------------------------------------------
# The campaign: ONE HUNDRED maps in ten acts, replayed at eight difficulties.
#
# A "region" and a "map" are the same thing here; the older vocabulary survives
# in region_count()/region_seed()/region_title() because the UI and Roster call
# them, and renaming a public API is not worth a 100-map renumbering.
#
# SHAPE: 10 acts x 10 maps. Ten is picked so an act is a sitting (ten lanes) and
# the act number alone tells the player how far in they are — with 4 acts of 25
# the act label would say almost nothing, and with 20 acts of 5 the act names
# become filler.
#
# THE BIOME LIST NO LONGER SETS THE LENGTH. It used to: 16 biomes meant 16
# regions. 100 maps against 16 biomes means the list is SAMPLED, and how it is
# sampled is the dread curve's business (see biome_at and dread below), not a
# modulo. Early acts draw the temperate head of Biome.IDS, late acts the
# hostile tail, and acts overlap by design so a biome recurs a few maps later
# at a higher level rather than being used once and retired.
#
# DIFFICULTY TIERS are the replay engine. Finishing the campaign unlocks the
# next tier, which is the same hundred maps with harder enemies and better
# loot. A tier is NOT a separate build of the world — the same seed produces the
# same terrain, so the player learns a place and then returns to it outmatched.
#
# EIGHT TIERS, ONE CURVE. There used to be five hand-written dictionaries keyed
# off the tier enum (min level, enemy level, health, damage, XP, loot). Eight
# tiers would have meant forty hand-typed numbers and five separate chances to
# forget tier 8 in one table while adding it to another — the exact failure the
# roadmap calls out. They are now FUNCTIONS sampling documented curves, fitted
# to the four shipped tiers so Normal..Eternal balance does not move (every
# fitted value lands within one level / 3% of what shipped), and extended
# upward by continuing the same curve rather than by invention.
#
# Two unlock scopes, deliberately different:
#   * TIER unlocks are account-wide. Clear Veteran once and every champion may
#     enter it — otherwise each of 139 heroes would have to grind the same
#     ladder, which is busywork, not replayability.
#   * LEVELS and SKILL POINTS stay per champion (see HeroProgress). That is
#     where the restart actually means something.
# ------------------------------------------------------------------------------

## The eight difficulties, in order. NORMAL..ETERNAL keep their old ordinals so
## every save file, every `tiers_cleared` and every unlock written before the
## widening still means what it meant.
enum Tier {
	NORMAL, VETERAN, MERCILESS, ETERNAL,
	INFERNAL, ABYSSAL, NIGHTMARE, OBLIVION,
}

## Indexed by tier, NOT a dictionary: a missing entry is then a parse-time
## length mismatch the test catches, instead of a silent "?" at runtime.
const TIER_NAMES: PackedStringArray = [
	"Normal", "Veteran", "Merciless", "Eternal",
	"Infernal", "Abyssal", "Nightmare", "Oblivion",
]

const MAPS_PER_ACT: int = 10
const ACT_COUNT: int = 10
const MAP_COUNT: int = MAPS_PER_ACT * ACT_COUNT

## How many biomes one act visits. Four gives an act a recognisable palette set
## while still letting the band slide the length of Biome.IDS across ten acts.
const BIOME_BAND: int = 4

## Enemy levels gained across the hundred maps of a single difficulty. Kept at
## the value the 16-region campaign used (level 1 at the start, 16 at the end)
## so the within-tier ramp is unchanged — 100 maps stretch it, they do not
## steepen it.
const LEVEL_SPAN: float = 15.0

# --- the tier curves ----------------------------------------------------------
#
# ONE SHAPE, used six times: a first step, then steps that shrink by a constant
# factor. Write k(t) for the number of whole steps taken by tier t,
#
#   k(t) = 1 + decay + decay^2 + ... + decay^(t-1)   (see _steps)
#
# and a level number is step * k(t) while a multiplier is first_step ^ k(t) —
# the same curve read additively or multiplicatively.
#
# WHY IT DECAYS rather than being a straight line or a plain geometric: the four
# shipped tiers already decelerate (health x2.6, x2.5, x2.31 per step; gates
# +17, +16, +14), levels are bounded by HeroProgress.MAX_LEVEL so a constant
# step runs off the character sheet by tier 5, and a plain geometric extended to
# eight tiers overshoots hard (x610 health instead of x287).
#
# EVERY DECAY BELOW IS A FIT, not a feel: solved so tiers 1, 2 and 4 land on
# their shipped values exactly, which leaves tier 3 within 2.6% and every level
# within one level. tools/campaigntest.gd re-measures all four against the old
# tables, so a later tweak that moves Normal..Eternal fails a check.

## Level gate per tier. Fitted to the shipped gates 1 / 18 / 34 / 48.
const GATE_STEP: float = 18.0
const GATE_DECAY: float = 0.889

## Enemy level added by the tier. Fitted to the shipped 0 / 16 / 32 / 46.
const LEVEL_STEP: float = 16.0
const LEVEL_DECAY: float = 0.958

## Health climbs faster than damage ON PURPOSE: fights should get longer and
## more demanding, not become one-shot coin flips. FIRST is what tier 1 does to
## tier 0 (the shipped x2.6 / x1.9 / x2.2); DECAY shrinks every step after.
const HEALTH_FIRST: float = 2.6
const HEALTH_DECAY: float = 0.9437
const DAMAGE_FIRST: float = 1.9
const DAMAGE_DECAY: float = 0.9102
const XP_FIRST: float = 2.2
const XP_DECAY: float = 0.8738

## Extra chance of each drop upgrading one rarity step. Fitted exactly to the
## shipped 0 / 0.12 / 0.26 / 0.42 (steps of 0.12, 0.14, 0.16 — an accelerating
## line), then capped: above ~0.85 nearly every roll promotes and the rarity
## table stops meaning anything.
const LOOT_STEP: float = 0.12
const LOOT_ACCEL: float = 0.01
const LOOT_CAP: float = 0.85


# ------------------------------------------------------------------------------
# Structure
# ------------------------------------------------------------------------------

static func map_count() -> int:
	return MAP_COUNT


## Kept for callers that predate the 100-map campaign (UiShell, CampaignScreen,
## Roster.maps_per_difficulty). A region IS a map.
static func region_count() -> int:
	return MAP_COUNT


static func act_count() -> int:
	return ACT_COUNT


static func maps_per_act() -> int:
	return MAPS_PER_ACT


static func act_of(index: int) -> int:
	return clampi(index, 0, MAP_COUNT - 1) / MAPS_PER_ACT


## Position of a map inside its act, 0-based.
static func stage_in_act(index: int) -> int:
	return clampi(index, 0, MAP_COUNT - 1) % MAPS_PER_ACT


## THE DREAD CURVE, 0 at map 1 and 1 at map 100.
##
## This is the single number the whole presentation reads — biome choice, the
## palette/fog shift applied on top of the biome, concept-art prompts, encounter
## density, elite rate, how far down the lane the boss sits. It lives here, in
## the file that owns campaign position, so that nothing re-derives its own idea
## of "scary" and map 60 cannot end up looking menacing, playing like map 10 and
## scoring like map 90.
##
## Deliberately LINEAR and deliberately tier-independent: it is a position on
## the campaign, not a difficulty. A system that wants a different response
## curve (fog, say, which reads better easing in late) should shape dread
## itself, so the shaping is visible at the call site.
static func dread(index: int) -> float:
	return clampf(float(index) / float(maxi(MAP_COUNT - 1, 1)), 0.0, 1.0)


## Dread quantised into `bands` buckets, for anything that cannot be continuous
## — the concept-art plates are generated per biome x dread band, not per map.
static func dread_band(index: int, bands: int) -> int:
	var n: int = maxi(bands, 1)
	return clampi(int(floor(dread(index) * float(n))), 0, n - 1)


## The biome of a map.
##
## Each act visits a sliding window of BIOME_BAND consecutive entries of
## Biome.IDS, whose start walks from the head of the list (pastoral) to the tail
## (unreal, then the citadel) across the ten acts; inside an act the window is
## traversed in order, so the last map of act 10 is the last biome in the list —
## the throne — and the first map of act 1 is the first.
##
## Windows OVERLAP between acts (act 1 ends in frostcrag, act 2 opens in
## tidebreak). That is wanted: it gives a hundred maps a vocabulary of about
## four biomes at a time, revisits one a few maps later at a higher enemy level,
## and still moves the whole vocabulary toward the hostile end. Everything is
## derived from Biome.IDS.size(), so adding a biome re-spaces the campaign
## instead of being ignored.
static func biome_at(index: int) -> String:
	var ids: PackedStringArray = Biome.IDS
	var n: int = ids.size()
	if n <= 0:
		return ""
	var i: int = clampi(index, 0, MAP_COUNT - 1)
	var band: int = clampi(BIOME_BAND, 1, n)
	var last_start: int = n - band
	var acts: int = maxi(ACT_COUNT - 1, 1)
	var start: int = int(floor(float(act_of(i)) * float(last_start) / float(acts)))
	var step: int = int(floor(float(stage_in_act(i)) * float(band)
		/ float(MAPS_PER_ACT)))
	return ids[clampi(start + step, 0, n - 1)]


static func act_name(act: int) -> String:
	const NAMES: PackedStringArray = [
		"The Green Road", "The Broken Shore", "The Long Dark",
		"The Howling Reach", "Under Dusk", "The Thornfields",
		"The Bone Marches", "The Ash Hollows", "The Glass Wastes",
		"The Shattered Crown",
	]
	return NAMES[clampi(act, 0, NAMES.size() - 1)]


## A map's name. Carries the stage number because ten maps share an act and
## four biomes, so "The Bone Marches — Boneyard" alone is not a unique place.
static func region_title(index: int) -> String:
	return "%s %d — %s" % [act_name(act_of(index)), stage_in_act(index) + 1,
		Biome.display_name(biome_at(index))]


## The world seed for a map. Depends on the campaign seed and the map index but
## NOT on the tier, so Veteran Greenwood is the same ground as Normal Greenwood.
## Returning to a place you know, outmatched, is the point.
static func region_seed(campaign_seed: int, index: int) -> int:
	return Rng.seed_of(campaign_seed, "region.%d" % index)


# ------------------------------------------------------------------------------
# Difficulty
# ------------------------------------------------------------------------------

## THE FIRST "HARD" TIER. Below it an enemy fights with two actions; from it
## they gain a third. Named rather than written as a bare 2 at the call site,
## because moving the step is a balance decision and it should be one edit.
const HARD_TIER: int = Tier.MERCILESS


## How many of an enemy's four actions it is allowed to use at `tier`.
##
## Counts ACTIONS, basic attack included — an enemy always has its basic, so
## the figures here are "basic + 1", "basic + 2" and the whole kit. Low tiers
## are a champion and its signature move; Oblivion is the full kit including
## the stun, the dash and the self-buff, and is meant to be read as a different
## fight rather than the same fight with bigger numbers.
## THE OPENING IS A TUTORIAL, AND IT HAS TO BEHAVE LIKE ONE.
##
## Enemies in this game are other champions, built from the same stat block the
## player's champion is — so a level-1 enemy on map 1 was hitting for 25 of a
## fresh champion's 164 health, with seventeen of them on the map. Seven hits
## and the run was over, before the player had bought a single item or learned
## which button was which.
##
## This scales an early enemy's damage down and ramps it back to full over the
## first stretch of the campaign. MERCY_FLOOR is tuned so the first map lands
## 1-2 damage per hit; combattest asserts the resulting number rather than the
## constant, so the tuning cannot drift out from under the intent when the stat
## formulas change.
##
## It FADES WITH DIFFICULTY. A player on Oblivion has cleared the campaign
## seven times and does not need a tutorial, so the ramp shortens tier by tier
## and is gone entirely at the top.
const MERCY_FLOOR: float = 0.055
## How many maps the ramp covers at Normal.
const MERCY_MAPS: float = 22.0
## Shape of the ramp. Above 1 keeps the opening gentle and does the climbing
## later; at or below 1 the ramp is over before the player has any gear.
const MERCY_EASE: float = 1.6
## Health is nerfed far less than damage: trash that dies instantly is as dull
## as trash that one-shots you, and the complaint was about dying.
const MERCY_HEALTH_FLOOR: float = 0.38


## How much of their full strength enemies on `index` bring, 0..1.
static func mercy(index: int, tier: int) -> float:
	var f: float = float(clampi(tier, 0, max_tier())) / float(max_tier())
	# BOTH ends move with the tier. Shortening the ramp alone left map 1 at the
	# same floor on every difficulty — Eternal opened exactly as softly as
	# Normal and only caught up sooner, which is not what a harder difficulty
	# means.
	var start: float = lerpf(MERCY_FLOOR, 1.0, f)
	var span: float = MERCY_MAPS * (1.0 - f)
	if span <= 0.0 or float(index) >= span:
		return 1.0
	# Eased rather than linear: the first few maps stay gentle and the curve
	# does most of its climbing once the player has gear and a level or two.
	#
	# THE EXPONENT MUST BE ABOVE 1. At 0.75 it did the exact opposite of the
	# line above — fast early, flat late — and map 6 was already landing 11 of
	# a fresh champion's 164 health.
	var k: float = pow(float(index) / span, MERCY_EASE)
	return lerpf(start, 1.0, k)


## The same ramp applied to health, which is deliberately much shallower.
static func mercy_health(index: int, tier: int) -> float:
	return lerpf(MERCY_HEALTH_FLOOR, 1.0, mercy(index, tier))


static func enemy_actions(tier: int) -> int:
	if tier >= max_tier():
		return 4        # Oblivion only: everything they have
	if tier >= HARD_TIER:
		return 3        # Merciless and up: one more than the lower tiers
	return 2


static func tier_count() -> int:
	return Tier.size()


static func max_tier() -> int:
	return Tier.size() - 1


static func tier_name(tier: int) -> String:
	var t: int = clampi(tier, 0, TIER_NAMES.size() - 1)
	return TIER_NAMES[t]


## How many whole steps a tier has taken: 1 + decay + decay^2 + ... Every one
## of the six per-tier numbers is this and nothing else — see the curve note.
static func _steps(tier: int, decay: float) -> float:
	var t: int = clampi(tier, 0, max_tier())
	return (1.0 - pow(decay, float(t))) / (1.0 - decay)


## Minimum champion level before a tier may be entered. A gate, not a wall — it
## stops a level-1 hero wandering into Merciless and being deleted, which reads
## as a bug rather than a challenge.
##
## The ladder saturates at HeroProgress.MAX_LEVEL from Infernal up, and that is
## the honest answer rather than a flaw: with a level cap of 60 there is no room
## for eight gates sixteen levels apart. Past Eternal the level gate stops being
## the limiter and clearing the previous tier is.
static func min_level(tier: int) -> int:
	return clampi(int(round(GATE_STEP * _steps(tier, GATE_DECAY))), 1,
		HeroProgress.MAX_LEVEL)


## Enemy levels the tier adds on top of the within-campaign ramp. Not clamped to
## MAX_LEVEL: enemies out-levelling the player is the whole proposition of the
## upper tiers (Loot.item_level clamps what they are allowed to DROP).
static func enemy_level_bonus(tier: int) -> int:
	return int(round(LEVEL_STEP * _steps(tier, LEVEL_DECAY)))


static func enemy_health_mult(tier: int) -> float:
	return pow(HEALTH_FIRST, _steps(tier, HEALTH_DECAY))


static func enemy_damage_mult(tier: int) -> float:
	return pow(DAMAGE_FIRST, _steps(tier, DAMAGE_DECAY))


static func xp_mult(tier: int) -> float:
	return pow(XP_FIRST, _steps(tier, XP_DECAY))


static func loot_bonus(tier: int) -> float:
	var t: float = float(clampi(tier, 0, max_tier()))
	return minf(LOOT_STEP * t + LOOT_ACCEL * t * (t - 1.0), LOOT_CAP)


## Enemy level for a map at a tier. Within a tier the ramp is gentle; the step
## between tiers is what actually raises the bar.
static func enemy_level(index: int, tier: int) -> int:
	var base: float = 1.0 + dread(index) * LEVEL_SPAN
	return int(round(base + float(enemy_level_bonus(tier))))


## XP for one kill, before the tier multiplier is applied to the encounter.
static func xp_per_kill(index: int, tier: int) -> float:
	var lv: int = enemy_level(index, tier)
	return (6.0 + float(lv) * 2.4) * xp_mult(tier)


static func can_enter(tier: int, hero: HeroProgress, unlocked_tier: int) -> bool:
	if tier > unlocked_tier:
		return false
	return hero.level >= min_level(tier)


## Why a tier is refused, for the UI. Empty string means it is enterable.
static func entry_blocked_reason(tier: int, hero: HeroProgress,
		unlocked_tier: int) -> String:
	if tier > unlocked_tier:
		return "Clear %s to unlock" % tier_name(tier - 1)
	var need: int = min_level(tier)
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

	if Rng.unit2(seed, roll_id, 5503) < loot_bonus(tier):
		rarity = mini(rarity + 1, Item.Rarity.LEGENDARY)
	return rarity


## Items dropped by clearing a region, already rolled at the right level.
static func roll_region_loot(seed: int, index: int, tier: int,
		count: int = 3) -> Array[Item]:
	var out: Array[Item] = []
	var ilvl: int = enemy_level(index, tier)
	for i in range(count):
		var rid: int = index * 1000 + tier * 100 + i
		var reward: Item = Item.roll(seed, rid, ilvl,
			roll_rarity(seed, rid, tier))
		AffixC.dress(reward)
		out.append(reward)
	return out
