class_name Quest
extends RefCounted
# ------------------------------------------------------------------------------
# REASONS TO GO SOMEWHERE SPECIFIC.
#
# The campaign is a hundred maps and the only instruction is "next". Nothing
# ever sends a player BACK to map 23, and nothing ever says "that one, for
# this reason" — so the maps behind you are dead content and the one in front
# is the only one that exists.
#
# A quest is a reason: clear this stage, bring back something rare from that
# one. It is deliberately NOT a story system or a world to walk around; it is
# a short list of objectives over things the game already does, which is what
# makes it affordable and what makes it verifiable.
#
# ------------------------------------------------------------------------------
# THE RULE THAT SHAPES EVERYTHING HERE: A QUEST MUST BE COMPLETABLE WHEN IT IS
# OFFERED.
#
# An objective the player cannot finish is worse than no objective at all —
# it sits on the board forever, and they do not find out it was impossible,
# they conclude the drop rate is broken or that they are doing it wrong. Two
# ways that happens, both easy to write by accident:
#
#   * NAMING A MAP THEY CANNOT REACH. Regions are gated — region N is sealed
#     until N-1 is cleared — so a quest for map 60 offered to someone who has
#     unlocked 12 is a permanent blocker. Offers are drawn only from what is
#     already open.
#
#   * ASKING FOR A RARITY THE TIER CANNOT DROP. Loot.rarity_ceiling() caps
#     what a difficulty is allowed to produce. A Legendary quest on a tier
#     whose ceiling is Rare cannot be completed by any amount of grinding.
#
# Both are checked in offer(), and questtest asserts it over every tier and
# every state of progress rather than trusting the arithmetic.
# ------------------------------------------------------------------------------

# A SCRIPT CANNOT NAME ITSELF by class_name until the editor has rebuilt the
# global cache, so `Quest.new()` inside Quest.gd fails to compile on a fresh
# checkout — the same class-cache trap as everywhere else, but turned inward.
# Preloading itself resolves to the same resource and works either way.
const Self := preload("res://scripts/game/Quest.gd")

## What a quest asks for. Each maps onto something the game ALREADY reports at
## the end of a run — no new tracking, and nothing that needs the player to
## have the app open at the right moment.
enum Kind {
	## Clear a named region. The simplest, and the one that sends a player
	## back to a map they have already beaten.
	CLEAR_MAP,
	## Bring back a drop of at least a given rarity from a named region.
	FIND_RARITY,
	## Bring back a given equipment slot from a named region — the quest for
	## when what you need is boots, not "something good".
	FIND_SLOT,
	## Kill a number of elites, anywhere.
	SLAY_ELITES,
	## Reach a depth in a Descent.
	REACH_DEPTH,
}

var kind: int = Kind.CLEAR_MAP
## Region this quest is about, or -1 when it does not care.
var region: int = -1
## Rarity or slot wanted, by Kind. -1 when unused.
var want: int = -1
## How many are needed, and how many have been seen.
var need: int = 1
var done: int = 0
## Difficulty this was offered at; a quest is completed on the tier it names,
## because a Legendary from Normal is not the same ask as one from Merciless.
var tier: int = 0
var reward_gold: int = 0
var reward_crystals: int = 0
## Set once claimed, so a finished quest is not paid twice.
var claimed: bool = false


func is_complete() -> bool:
	return done >= need


# ------------------------------------------------------------------------------
# Offering
# ------------------------------------------------------------------------------

## Highest rarity that may be asked for at [tier], or -1 if none can.
static func top_rarity(tier: int) -> int:
	return Loot.rarity_ceiling(tier)


## Build a quest the player can actually finish.
##
## [furthest] is the highest region index they have unlocked on [tier].
## Everything is drawn from inside that, so an offer is never a blocker.
static func offer(seed: int, index: int, tier: int, furthest: int,
		power: int) -> Quest:
	var q := Self.new()
	q.tier = clampi(tier, 0, Campaign.tier_count() - 1)

	var open: int = clampi(furthest, 0, Campaign.map_count() - 1)
	# Weight toward the recent half of what is open: a quest for map 2 when
	# you are on map 40 is busywork, and one for the map you are standing on
	# is not a reason to go anywhere.
	var lo: int = int(float(open) * 0.35)
	var span: int = maxi(open - lo, 0)
	q.region = lo + int(Rng.unit2(seed, index, 3) * float(span + 1))
	q.region = clampi(q.region, 0, open)

	var ceiling: int = top_rarity(q.tier)
	# KIND IS CHOSEN FROM WHAT IS POSSIBLE, not chosen and then validated —
	# a rarity quest is simply not in the pool when the tier cannot drop
	# anything worth asking for.
	var pool: Array[int] = [Kind.CLEAR_MAP, Kind.SLAY_ELITES, Kind.REACH_DEPTH]
	if ceiling >= Item.Rarity.UNCOMMON:
		pool.append(Kind.FIND_RARITY)
		pool.append(Kind.FIND_SLOT)
	q.kind = pool[int(Rng.unit2(seed, index, 11) * float(pool.size()))
		% pool.size()]

	match q.kind:
		Kind.CLEAR_MAP:
			q.need = 1
		Kind.FIND_RARITY:
			# Never the ceiling itself on the lowest tiers — asking for the
			# rarest thing a difficulty can produce is a quest measured in
			# hours. One below, and never under Uncommon.
			var want_r: int = clampi(ceiling - 1, Item.Rarity.UNCOMMON,
				Item.Rarity.LEGENDARY)
			q.want = mini(want_r, ceiling)
			q.need = 1
		Kind.FIND_SLOT:
			q.want = int(Rng.unit2(seed, index, 17)
				* float(Item.Slot.size())) % Item.Slot.size()
			q.need = 1
		Kind.SLAY_ELITES:
			# Scaled to what the roster can field: a level 50 player killing
			# 6 elites is not an objective.
			q.need = clampi(5 + int(float(power) * 0.35), 5, 40)
		Kind.REACH_DEPTH:
			q.need = clampi(4 + int(float(power) * 0.25), 4, 30)

	# ---- reward ----------------------------------------------------------
	# SCALED TO THE ROSTER, not to the map. A quest that pays what map 3 paid
	# is an insult at level 40, and the player's level is the thing that says
	# what their time is worth.
	var base: int = 220 + power * 95
	var effort: float = 1.0
	match q.kind:
		Kind.FIND_RARITY: effort = 1.9 + 0.5 * float(maxi(q.want, 0))
		Kind.FIND_SLOT: effort = 1.5
		Kind.SLAY_ELITES: effort = 1.6
		Kind.REACH_DEPTH: effort = 1.8
	# Harder difficulties pay more for the same words.
	effort *= 1.0 + 0.12 * float(q.tier)
	q.reward_gold = int(float(base) * effort)
	# Crystals are the premium currency, so they are rare and only for the
	# objectives that actually cost an evening.
	q.reward_crystals = 1 if (q.kind == Kind.FIND_RARITY
		and q.want >= Item.Rarity.EPIC) else 0
	return q


# ------------------------------------------------------------------------------
# Progress
# ------------------------------------------------------------------------------

## A run finished. [summary] is what Play reports on a clear.
##
## Returns true when this call advanced the quest, so a caller can say so
## without diffing.
func note_run(summary: Dictionary) -> bool:
	if is_complete():
		return false
	var ran_region: int = int(summary.get("region", -1))
	var ran_tier: int = int(summary.get("tier", -1))
	var before: int = done

	match kind:
		Kind.CLEAR_MAP:
			if ran_region == region and ran_tier == tier \
					and bool(summary.get("cleared_this_run", false)):
				done = need
		Kind.FIND_RARITY:
			if ran_region == region and ran_tier == tier:
				done += int(summary.get("drops_at_least_%d" % want, 0))
		Kind.FIND_SLOT:
			if ran_region == region and ran_tier == tier:
				done += int(summary.get("drops_slot_%d" % want, 0))
		Kind.SLAY_ELITES:
			# Anywhere, any difficulty — this one is about play, not place.
			done += int(summary.get("elites_killed", 0))
		Kind.REACH_DEPTH:
			done = maxi(done, int(summary.get("depth_reached", 0)))

	done = mini(done, need)
	return done != before


# ------------------------------------------------------------------------------
# Words
# ------------------------------------------------------------------------------

func title() -> String:
	match kind:
		Kind.CLEAR_MAP:
			return "Clear %s" % Campaign.region_title(region)
		Kind.FIND_RARITY:
			return "Bring back %s gear" % Item.RARITY_NAMES.get(want, "rare")
		Kind.FIND_SLOT:
			return "Bring back %s" % Item.SLOT_NAMES.get(want, "gear")
		Kind.SLAY_ELITES:
			return "Slay %d elites" % need
		Kind.REACH_DEPTH:
			return "Reach depth %d" % need
	return "Contract"


func detail() -> String:
	var where: String = Campaign.region_title(region)
	var diff: String = Campaign.tier_name(tier)
	match kind:
		Kind.CLEAR_MAP:
			return "On %s." % diff
		Kind.FIND_RARITY, Kind.FIND_SLOT:
			return "From %s, on %s." % [where, diff]
		Kind.SLAY_ELITES:
			return "Anywhere. Elites are the ones with a mark."
		Kind.REACH_DEPTH:
			return "In a Descent."
	return ""


func progress_text() -> String:
	if need <= 1:
		return "Done" if is_complete() else "Not yet"
	return "%d / %d" % [done, need]


# ------------------------------------------------------------------------------
# Storage
# ------------------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"kind": kind, "region": region, "want": want, "need": need,
		"done": done, "tier": tier, "gold": reward_gold,
		"crystals": reward_crystals, "claimed": claimed,
	}


static func from_dict(d: Dictionary) -> Quest:
	var q := Self.new()
	q.kind = int(d.get("kind", Kind.CLEAR_MAP))
	q.region = int(d.get("region", -1))
	q.want = int(d.get("want", -1))
	q.need = maxi(int(d.get("need", 1)), 1)
	q.done = maxi(int(d.get("done", 0)), 0)
	q.tier = int(d.get("tier", 0))
	q.reward_gold = int(d.get("gold", 0))
	q.reward_crystals = int(d.get("crystals", 0))
	q.claimed = bool(d.get("claimed", false))
	return q
