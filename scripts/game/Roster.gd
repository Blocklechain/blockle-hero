class_name Roster
extends RefCounted

# Preloaded by path: a new class_name is absent from Godot's global cache
# until the editor reimports, and the headless harnesses load this directly.
const Training := preload("res://scripts/game/Training.gd")
# ------------------------------------------------------------------------------
# The player's account: which champions they own, each one's own progression,
# the shared stash, the wallet, and campaign unlocks.
#
# The whole save file is this object. Note what is shared and what is not,
# because the distinction is the design:
#
#   PER CHAMPION   level, experience, skill points        (HeroProgress)
#   SHARED         gear, gold, gems, crystals, tier unlock
#
# Starting a new champion costs none of the shared things and none of another
# champion's progress. That is what makes a 200-hero roster a reason to replay
# rather than 200 identical grinds.
# ------------------------------------------------------------------------------

signal champion_unlocked(hero: String, rarity: int, was_duplicate: bool)
signal tier_unlocked(tier: int)
## Every map of one difficulty is now cleared. Fires once, on the clear that
## completed it, never again on a replay.
signal difficulty_completed(tier: int)
## The one-time clear reward was actually paid. `crystals` is what the wallet
## gained, so a listener can never report a payout that did not happen.
signal difficulty_reward_granted(tier: int, crystals: int)

const SAVE_PATH: String = "user://roster.json"
const SAVE_VERSION: int = 1

var wallet: Wallet = Wallet.new()
var stash: Stash = Stash.new()

## hero_name -> HeroProgress, for owned champions only.
var owned: Dictionary = {}

## Highest campaign tier unlocked, account-wide.
var unlocked_tier: int = Campaign.Tier.NORMAL

## Which maps have been cleared, per difficulty: tier -> { map_index: true }.
##
## A SET, not a count. Re-clearing map 7 writes the same key a second time, so
## no amount of replaying can make the campaign look longer than it is — which
## is the only thing standing between a replay and a second free crystal.
var cleared_maps: Dictionary = {}

## Difficulties whose one-time clear reward has been paid: tier -> true.
##
## A FLAG, deliberately, and separate from `cleared_maps`. "Has been paid" must
## not be derivable from progress, because progress is re-achievable; a player
## who clears the last map, replays it, and reloads the save has to end up with
## exactly one crystal in all three cases.
var difficulty_claimed: Dictionary = {}

## Crystals opened since the last Epic-or-better, for the pity guarantee.
var crystals_since_epic: int = 0

## Deterministic stream for crystal rolls. Stored so a reload cannot re-roll a
## crystal the player already opened.
var crystal_seed: int = 0

## FURTHEST REACHED IN EACH NON-CAMPAIGN MODE, keyed by
## GameMode.record_key(). A descent ends in death, so a record that was only
## written on a clean exit would record nothing at all — Play banks this
## every wave. Kept in the save rather than on the object as metadata,
## because metadata on a RefCounted is not serialised and the score would
## quietly vanish on restart.
var mode_records: Dictionary = {}

## TRAINING SLOTS — champions earning XP while the app is shut. See
## Training.gd, and note the clock is treated as hostile there.
var training_slots: Array = []
## How many slots have been paid for. The first is free.
var slots_unlocked: int = 1


## Best depth/crown reached in a mode, 0 if never played.
## Make sure there is a Slot object for every possible slot, so callers can
## index without checking. Unlocked-ness is a separate count, not a shorter
## array — an array that changes length is a migration waiting to go wrong.
func _ensure_slots() -> void:
	while training_slots.size() < Training.SLOTS_MAX:
		training_slots.append(Training.Slot.new())


func _training_to_list() -> Array:
	_ensure_slots()
	var out: Array = []
	for sl in training_slots:
		out.append((sl as Training.Slot).to_dict())
	return out


## The slot at [index], or null if there is no such slot.
func slot(index: int) -> Training.Slot:
	_ensure_slots()
	if index < 0 or index >= training_slots.size():
		return null
	return training_slots[index] as Training.Slot


func slot_is_unlocked(index: int) -> bool:
	return index >= 0 and index < slots_unlocked


## Buy the next slot. Returns false when there is none left or the gold is
## not there — the caller shows why, this only decides.
func unlock_slot() -> bool:
	if slots_unlocked >= Training.SLOTS_MAX:
		return false
	var cost: int = Training.cost_of(slots_unlocked)
	if cost > 0 and not wallet.spend(Wallet.Kind.GOLD, cost, "training slot"):
		return false
	slots_unlocked += 1
	_ensure_slots()
	return true


## Put a champion in a slot. Starting the clock is the whole operation.
func begin_training(index: int, who: String, now: int) -> bool:
	if not slot_is_unlocked(index) or not owns(who):
		return false
	# ONE SLOT PER CHAMPION. Two slots training the same hero would stack
	# their rates, which is a cap that is not a cap.
	for i in range(slots_unlocked):
		var other: Training.Slot = slot(i)
		if i != index and other != null and other.hero == who:
			return false
	var sl: Training.Slot = slot(index)
	if sl == null:
		return false
	sl.hero = who
	sl.since = now
	sl.high_water = now
	return true


## Bank what a slot has earned and restart its clock.
##
## Returns how much XP was granted. Claiming an empty or barely-started slot
## is a no-op rather than an error: the UI calls this on open to refresh.
func claim_training(index: int, now: int) -> float:
	var sl: Training.Slot = slot(index)
	if sl == null or sl.is_empty() or not slot_is_unlocked(index):
		return 0.0
	var res: Array = sl.elapsed_at(now)
	if bool(res[1]):
		# Clock went backwards — re-anchor and bank nothing. Crossing a
		# timezone must not corrupt a save, and must not pay out either.
		sl.since = now
		return 0.0
	sl.high_water = maxi(sl.high_water, now)

	var p: HeroProgress = progress(sl.hero)
	if p == null:
		return 0.0
	var gained: float = Training.xp_for(p, float(res[0]))
	if gained < Training.MIN_CLAIM_XP:
		return 0.0
	p.gain_xp(gained)
	# The clock restarts from NOW, so the time spent is spent — a claim does
	# not roll the uncounted remainder forward into the next stretch, which
	# would make a capped slot keep paying.
	sl.since = now
	return gained


## What a slot would pay right now, without taking it.
func pending_training(index: int, now: int) -> float:
	var sl: Training.Slot = slot(index)
	if sl == null or sl.is_empty() or not slot_is_unlocked(index):
		return 0.0
	var res: Array = sl.elapsed_at(now)
	if bool(res[1]):
		return 0.0
	var p: HeroProgress = progress(sl.hero)
	return Training.xp_for(p, float(res[0])) if p != null else 0.0


func best_in_mode(key: String) -> int:
	return int(mode_records.get(key, 0))


## Record a run if it beat the previous best. Returns true when it did, so a
## caller can say "new best" without asking twice.
func note_mode_run(key: String, reached: int) -> bool:
	if key.is_empty() or reached <= best_in_mode(key):
		return false
	mode_records[key] = reached
	return true
var crystals_opened: int = 0

## StoreKit transaction ids that have already paid out, oldest first. THE
## purchase invariant lives here: `Store.redeem()` refuses any id in this list,
## so a transaction the store re-delivers — which it does for every transaction
## until the app finishes it, and again after a reinstall — can only ever grant
## once.
##
## It is in the save file rather than a side file on purpose. Two files can
## disagree about what was paid, and that disagreement is always resolved in the
## direction of granting twice.
const REDEEMED_MAX: int = 500
var redeemed_txns: PackedStringArray = PackedStringArray()

## Every hero the player may be GRANTED: starters, gem unlocks, crystal rolls
## and the roster screen's locked list all come from here.
##
## This is the ANIMATED set only (`HeroRig.animated_heroes()`), never the full
## 200-hero art set. 61 heroes could not be auto-rigged, and an unlock system
## that can pay out a skeleton-less hero would hand a paying player a sliding
## T-pose. Gating the catalogue is the single choke point that makes that
## impossible — every grant path reads this array, so none of them needs its own
## check. See `HeroRig.animated_heroes()` for the full rationale.
var catalogue: PackedStringArray = PackedStringArray()


## `playable` must be the animated roster; callers pass
## `HeroRig.animated_heroes()`. It is a parameter rather than a direct call so
## tests can drive a small deterministic catalogue.
static func create(playable: PackedStringArray, seed: int = 20261119) -> Roster:
	var r := Roster.new()
	r.catalogue = playable
	r.crystal_seed = seed
	for h in Champion.starters(playable):
		r._grant_champion(h)
	# A small float so the first merchant visit is not a locked door.
	r.wallet.grant(Wallet.Kind.GOLD, 250, "new_account")
	return r


# ------------------------------------------------------------------------------
# Ownership
# ------------------------------------------------------------------------------

func owns(hero: String) -> bool:
	return owned.has(hero)


func progress(hero: String) -> HeroProgress:
	return owned.get(hero, null)


func owned_names() -> PackedStringArray:
	var out := PackedStringArray()
	for k in owned.keys():
		out.append(String(k))
	out.sort()
	return out


func locked_names() -> PackedStringArray:
	var out := PackedStringArray()
	for h in catalogue:
		if not owned.has(h):
			out.append(h)
	return out


## Is this hero one the game may hand out? False for a static-only hero that an
## older save owns — it stays playable, it just can never be granted again.
func is_playable(hero: String) -> bool:
	return catalogue.has(hero)


## Everything the roster screen should LIST: the catalogue plus any hero a save
## already owns that is no longer in it. Ownership is never revoked by hiding a
## hero — the player keeps and can still play what they unlocked before the
## roster was gated, loading through the tex/ fallback in `HeroRig._resolve`.
func all_known_names() -> PackedStringArray:
	var seen: Dictionary = {}
	for h in catalogue:
		seen[h] = true
	for k in owned.keys():
		seen[String(k)] = true
	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


# THE choke point: every grant in the game lands here. Refusing anything outside
# the catalogue means no future unlock path can leak a hero with no rigged
# model, even if it forgets to check.
func _grant_champion(hero: String) -> void:
	if owned.has(hero):
		return
	if not catalogue.has(hero):
		push_error("Roster: refusing to grant '%s' — not on the playable roster"
			% hero)
		return
	owned[hero] = HeroProgress.create(hero)


# ------------------------------------------------------------------------------
# Unlocking
# ------------------------------------------------------------------------------

## Unlock a SPECIFIC champion with gems. Returns "" on success, or a reason.
func unlock_with_gems(hero: String) -> String:
	if not catalogue.has(hero):
		return "Unknown champion"
	if owns(hero):
		return "Already owned"
	var cost: int = Champion.gem_cost(hero)
	if not wallet.can_afford(Wallet.Kind.GEMS, cost):
		return "Needs %d gems" % cost
	wallet.spend(Wallet.Kind.GEMS, cost, "unlock:%s" % hero)
	_grant_champion(hero)
	champion_unlocked.emit(hero, Champion.rarity_of(hero), false)
	return ""


## Open one spawn crystal: a RANDOM champion, at the published odds.
##
## Returns { "hero", "rarity", "duplicate", "gold" }, or {} if none to spend.
## A duplicate pays gold rather than nothing — an unlock system that can hand
## back literally nothing is the fastest way to make a paying player quit.
func open_crystal() -> Dictionary:
	if not wallet.can_afford(Wallet.Kind.CRYSTALS, 1):
		return {}
	wallet.spend(Wallet.Kind.CRYSTALS, 1, "open_crystal")

	var roll_id: int = crystals_opened
	crystals_opened += 1
	var rarity: int = CrystalOdds.roll_rarity(crystal_seed, roll_id,
		crystals_since_epic)

	if rarity >= Item.Rarity.EPIC:
		crystals_since_epic = 0
	else:
		crystals_since_epic += 1

	var pool: PackedStringArray = Champion.of_rarity(catalogue, rarity)
	if pool.is_empty():
		# No champion exists at that tier — refund rather than consume the
		# crystal for nothing. Possible if the catalogue is small in testing.
		wallet.grant(Wallet.Kind.CRYSTALS, 1, "refund:empty_pool")
		return {}

	var hero: String = pool[int(Rng.hash2(crystal_seed, roll_id, 97) % pool.size())]
	var dup: bool = owns(hero)
	var gold: int = 0
	if dup:
		gold = Champion.duplicate_gold(hero)
		wallet.grant(Wallet.Kind.GOLD, gold, "duplicate:%s" % hero)
	else:
		_grant_champion(hero)

	champion_unlocked.emit(hero, rarity, dup)
	return {"hero": hero, "rarity": rarity, "duplicate": dup, "gold": gold}


# ------------------------------------------------------------------------------
# Purchases — the idempotency record, not the payment
# ------------------------------------------------------------------------------

func has_redeemed(transaction_id: String) -> bool:
	return not transaction_id.is_empty() \
		and redeemed_txns.has(transaction_id)


## Remember that a transaction paid out. Bounded because the save file is, and
## safe to bound because `Store` finishes a transaction the moment the save
## succeeds: a still-unfinished one is re-delivered long before another 500
## purchases could push it off the end.
func mark_redeemed(transaction_id: String) -> void:
	if transaction_id.is_empty() or redeemed_txns.has(transaction_id):
		return
	redeemed_txns.append(transaction_id)
	if redeemed_txns.size() > REDEEMED_MAX:
		redeemed_txns = redeemed_txns.slice(
			redeemed_txns.size() - REDEEMED_MAX)


# ------------------------------------------------------------------------------
# Campaign
# ------------------------------------------------------------------------------

## Record that a champion finished the campaign at a tier. Unlocks the next tier
## ACCOUNT-WIDE — making every one of 200 heroes climb the same ladder would be
## busywork, not replay value.
func complete_campaign(hero: String, tier: int) -> void:
	var p: HeroProgress = progress(hero)
	if p != null:
		p.tiers_cleared = maxi(p.tiers_cleared, tier)
	if tier >= unlocked_tier and unlocked_tier < Campaign.max_tier():
		unlocked_tier += 1
		tier_unlocked.emit(unlocked_tier)


# ------------------------------------------------------------------------------
# Clearing a difficulty — one spawn crystal, once ever
# ------------------------------------------------------------------------------

## What clearing an entire difficulty pays. Named rather than inlined so the
## test can assert the payout instead of restating it.
const DIFFICULTY_REWARD_CRYSTALS: int = 1


## How many difficulties exist, read off the enum itself rather than copied.
## Campaign is widening from four tiers to eight; a hardcoded 4 or 8 here would
## go stale in a file nobody thinks to look at, and the symptom would be a
## reward that never pays (or pays on an incomplete difficulty).
static func difficulty_count() -> int:
	return Campaign.Tier.size()


## How many maps one difficulty contains — Campaign's number, not ours.
static func maps_per_difficulty() -> int:
	return Campaign.region_count()


## Can this map be entered yet?
##
## THE CAMPAIGN IS A SEQUENCE. The first map of a difficulty is always open;
## every other one needs the map before it cleared on that same difficulty.
## Without this the whole hundred-map ladder was a menu — a new player could
## tap region 100 from a standing start, walk into enemies forty levels above
## them, and never see the maps the curve was built out of.
##
## Per DIFFICULTY, deliberately. Clearing map 7 on Normal does not open map 7
## on Nightmare; replaying a difficulty means replaying it.
func is_map_unlocked(tier: int, index: int) -> bool:
	if index <= 0:
		return true
	if index >= maps_per_difficulty():
		return false
	return is_map_cleared(tier, index - 1)


## The furthest map that can be entered on `tier` — the first uncleared one.
## What the campaign screen opens on, so the player lands where they left off
## rather than back at map 1 every time.
func furthest_unlocked(tier: int) -> int:
	for i in range(maps_per_difficulty()):
		if not is_map_cleared(tier, i):
			return i
	return maps_per_difficulty() - 1


# ------------------------------------------------------------------------------
# Respec
# ------------------------------------------------------------------------------

## What undoing a build costs, before the per-point part. Deliberately small:
## the fee exists so that a build is a DECISION, not so that trying a second
## one is a punishment.
const RESPEC_BASE: int = 50
## Added per point being refunded, so a level-60 champion's full rebuild costs
## real money while a level-3 champion's two points costs pocket change.
const RESPEC_PER_POINT: int = 25


## Gold to refund every point `hero` has spent. Zero when there is nothing to
## undo, so the UI never has to special-case a free respec it cannot perform.
func respec_cost(hero: String) -> int:
	var p: HeroProgress = progress(hero)
	if p == null:
		return 0
	var n: int = p.spent_points()
	if n <= 0:
		return 0
	return RESPEC_BASE + RESPEC_PER_POINT * n


## Charge for and perform a respec. Returns "" on success, or the reason it
## was refused.
##
## THE SINGLE CHOKE POINT, for the same reason unlock_with_gems is: the price
## must be read, checked and taken in one place, or a second caller appears
## that refunds the points and forgets the gold.
func respec(hero: String) -> String:
	var p: HeroProgress = progress(hero)
	if p == null:
		return "No such champion."
	var n: int = p.spent_points()
	if n <= 0:
		return "%s has no spent points to refund." % ChampionName.of(hero)
	var cost: int = respec_cost(hero)
	if wallet.balance(Wallet.Kind.GOLD) < cost:
		return "Refunding %s's points costs %d gold — you have %d." % [
			ChampionName.of(hero), cost, wallet.balance(Wallet.Kind.GOLD)]
	# Charged BEFORE the points move. If anything below ever fails the player
	# is out the gold with their build intact, which they can see and report;
	# the other order silently gives away free respecs forever.
	if not wallet.spend(Wallet.Kind.GOLD, cost, "respec"):
		return "Could not take the %d gold." % cost
	p.respec()
	return ""


func is_map_cleared(tier: int, index: int) -> bool:
	return (cleared_maps.get(tier, {}) as Dictionary).has(index)


## Cleared maps of a difficulty, counting only indices the campaign actually
## has. Counting raw keys instead would let a save written against a longer
## campaign (or a junk index) read as complete on a shorter one.
func cleared_map_count(tier: int) -> int:
	var done: Dictionary = cleared_maps.get(tier, {})
	if done.is_empty():
		return 0
	var n: int = 0
	for i in range(maps_per_difficulty()):
		if done.has(i):
			n += 1
	return n


func is_difficulty_cleared(tier: int) -> bool:
	var total: int = maps_per_difficulty()
	return total > 0 and cleared_map_count(tier) >= total


func difficulty_reward_claimed(tier: int) -> bool:
	return bool(difficulty_claimed.get(tier, false))


## Record that a map was beaten, and pay the difficulty's clear reward if this
## was the last one outstanding. Returns the crystals granted — 0 on every call
## but the one that finishes the difficulty for the first time, so a caller can
## show "+1 Spawn Crystal" without having to know whether it had been paid.
func record_map_cleared(tier: int, index: int) -> int:
	if tier < 0 or tier >= difficulty_count():
		return 0
	if index < 0 or index >= maps_per_difficulty():
		return 0
	var was_complete: bool = is_difficulty_cleared(tier)
	var done: Dictionary = cleared_maps.get(tier, {})
	done[index] = true
	cleared_maps[tier] = done
	if not was_complete and is_difficulty_cleared(tier):
		difficulty_completed.emit(tier)
	return _claim_difficulty_reward(tier)


## THE single place a clear reward can be paid. Both guards are load-bearing:
## the claimed flag defeats a replay, and the completeness test defeats a caller
## that reports a clear the save does not support.
func _claim_difficulty_reward(tier: int) -> int:
	if difficulty_reward_claimed(tier) or not is_difficulty_cleared(tier):
		return 0
	# Claimed before granted. If anything after this line ever goes wrong the
	# failure is an unpaid crystal, which a player reports and support can fix;
	# the other order fails by paying twice, silently, forever.
	difficulty_claimed[tier] = true
	wallet.grant(Wallet.Kind.CRYSTALS, DIFFICULTY_REWARD_CRYSTALS,
		"difficulty_cleared:%d" % tier)
	difficulty_reward_granted.emit(tier, DIFFICULTY_REWARD_CRYSTALS)
	return DIFFICULTY_REWARD_CRYSTALS


# ------------------------------------------------------------------------------
# Effective stats — the one place everything is combined
# ------------------------------------------------------------------------------

## A champion's final attributes: class baseline + level growth + spent skill
## points, scaled by champion rarity, plus everything they are wearing.
##
## Rarity multiplies only the champion's OWN attributes, never gear. Otherwise a
## legendary would compound with every drop and the roster really would collapse
## to one hero.
func effective_stats(hero: String) -> Stats:
	var p: HeroProgress = progress(hero)
	if p == null:
		return Stats.new()
	var own: Stats = p.base_stats().scaled(Champion.stat_multiplier(hero))
	return own.plus(stash.gear_stats(hero))


func effective_damage(hero: String) -> float:
	var p: HeroProgress = progress(hero)
	if p == null:
		return 0.0
	return effective_stats(hero).damage_for(p.school()) \
		+ stash.weapon_power(hero)


func effective_health(hero: String) -> float:
	var p: HeroProgress = progress(hero)
	if p == null:
		return 0.0
	return effective_stats(hero).max_health(p.level) + stash.armour(hero) * 2.0


func sheet(hero: String) -> String:
	var p: HeroProgress = progress(hero)
	if p == null:
		return "%s — locked" % hero
	var s: Stats = effective_stats(hero)
	return "%-10s %-9s %-10s L%-3d  %s  dmg %.0f  hp %.0f  pts %d" % [
		hero, Champion.rarity_name(hero), p.class_name_str(), p.level,
		s.describe(), effective_damage(hero), effective_health(hero),
		p.unspent_points()]


# ------------------------------------------------------------------------------
# Save / load
# ------------------------------------------------------------------------------

func to_dict() -> Dictionary:
	var heroes: Dictionary = {}
	for k in owned.keys():
		heroes[k] = (owned[k] as HeroProgress).to_dict()
	return {
		"version": SAVE_VERSION,
		"wallet": wallet.to_dict(),
		"stash": stash.to_dict(),
		"owned": heroes,
		"tier": unlocked_tier,
		"crystal_seed": crystal_seed,
		"mode_records": mode_records,
		"slots_unlocked": slots_unlocked,
		"training": _training_to_list(),
		"crystals_opened": crystals_opened,
		"since_epic": crystals_since_epic,
		"iap_txns": redeemed_txns,
		# Written as string-keyed lists of ints because that is what JSON can
		# carry back: object keys are always strings, so the int tier keys are
		# stringified here deliberately rather than by accident on reload.
		"cleared_maps": _cleared_maps_to_json(),
		"claimed_difficulties": _claimed_to_json(),
	}


func _cleared_maps_to_json() -> Dictionary:
	var out: Dictionary = {}
	for tier in cleared_maps.keys():
		var done: Dictionary = cleared_maps[tier]
		var indices: Array[int] = []
		for i in done.keys():
			indices.append(int(i))
		indices.sort()  # Stable bytes, so two equal saves compare equal.
		out[str(int(tier))] = indices
	return out


func _claimed_to_json() -> Array[int]:
	var out: Array[int] = []
	for tier in difficulty_claimed.keys():
		if bool(difficulty_claimed[tier]):
			out.append(int(tier))
	out.sort()
	return out


## Loading NEVER filters `owned` against the catalogue. A save written before
## the roster was gated to the animated set may own one of the 61 static-only
## heroes; that champion keeps its level, points and gear and still loads via
## the tex/ fallback. Hiding a hero stops it being handed out, it does not
## confiscate one already earned.
static func from_dict(d: Dictionary, playable: PackedStringArray) -> Roster:
	var r := Roster.new()
	r.catalogue = playable
	r.wallet = Wallet.from_dict(d.get("wallet", {}))
	r.stash = Stash.from_dict(d.get("stash", {}))
	r.unlocked_tier = clampi(int(d.get("tier", 0)), 0, Campaign.max_tier())
	r.crystal_seed = int(d.get("crystal_seed", 20261119))
	# Copied key by key: JSON hands back an untyped Dictionary with string
	# keys and float values, and assigning it wholesale would store depths
	# as floats that then render as "Depth 7.0".
	var recs: Dictionary = d.get("mode_records", {})
	for k in recs.keys():
		r.mode_records[String(k)] = int(recs[k])
	r.slots_unlocked = clampi(int(d.get("slots_unlocked", 1)), 1,
		Training.SLOTS_MAX)
	for sl in d.get("training", []):
		if sl is Dictionary:
			r.training_slots.append(Training.Slot.from_dict(sl))
	# A save from before training existed has none; the getter fills in.
	r._ensure_slots()
	r.crystals_opened = int(d.get("crystals_opened", 0))
	r.crystals_since_epic = int(d.get("since_epic", 0))
	# JSON gives these back as an untyped Array of Variants, so they are copied
	# element by element rather than assigned — a wrong-typed assignment here
	# would silently empty the record and make every past purchase grantable.
	for t in d.get("iap_txns", []):
		r.redeemed_txns.append(String(t))
	var heroes: Dictionary = d.get("owned", {})
	for k in heroes.keys():
		r.owned[k] = HeroProgress.from_dict(heroes[k])
	# A save written before clear-tracking existed has neither field. Defaulting
	# to empty is the whole of the migration: nothing cleared, nothing claimed,
	# so the next genuine clear pays once. The dangerous alternative — inferring
	# "claimed" from an old `tier` or `tiers_cleared` — would hand a returning
	# player up to one crystal per difficulty for maps this save cannot prove
	# they beat. An unpaid crystal is recoverable; eight free ones are not.
	var cleared: Dictionary = d.get("cleared_maps", {})
	for k in cleared.keys():
		# JSON hands back string keys and float values; both are narrowed here,
		# because a float key would never match the int lookups above.
		var tier: int = int(String(k))
		var done: Dictionary = {}
		for i in cleared[k]:
			done[int(i)] = true
		if not done.is_empty():
			r.cleared_maps[tier] = done
	for t in d.get("claimed_difficulties", []):
		r.difficulty_claimed[int(t)] = true
	return r


func save() -> bool:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("Roster: cannot write " + SAVE_PATH)
		return false
	f.store_string(JSON.stringify(to_dict()))
	return true


## `playable` defaults to the animated roster, so no caller can accidentally
## open a save against the full 200-hero art set.
static func load_or_create(playable: PackedStringArray = PackedStringArray()) -> Roster:
	if playable.is_empty():
		playable = HeroRig.animated_heroes()
	if not FileAccess.file_exists(SAVE_PATH):
		return Roster.create(playable)
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return Roster.create(playable)
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Roster: save is corrupt; starting fresh")
		return Roster.create(playable)
	return Roster.from_dict(parsed, playable)
