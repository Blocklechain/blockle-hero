class_name Roster
extends RefCounted
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

const SAVE_PATH: String = "user://roster.json"
const SAVE_VERSION: int = 1

var wallet: Wallet = Wallet.new()
var stash: Stash = Stash.new()

## hero_name -> HeroProgress, for owned champions only.
var owned: Dictionary = {}

## Highest campaign tier unlocked, account-wide.
var unlocked_tier: int = Campaign.Tier.NORMAL

## Crystals opened since the last Epic-or-better, for the pity guarantee.
var crystals_since_epic: int = 0

## Deterministic stream for crystal rolls. Stored so a reload cannot re-roll a
## crystal the player already opened.
var crystal_seed: int = 0
var crystals_opened: int = 0

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
# Campaign
# ------------------------------------------------------------------------------

## Record that a champion finished the campaign at a tier. Unlocks the next tier
## ACCOUNT-WIDE — making every one of 200 heroes climb the same ladder would be
## busywork, not replay value.
func complete_campaign(hero: String, tier: int) -> void:
	var p: HeroProgress = progress(hero)
	if p != null:
		p.tiers_cleared = maxi(p.tiers_cleared, tier)
	if tier >= unlocked_tier and unlocked_tier < Campaign.Tier.ETERNAL:
		unlocked_tier += 1
		tier_unlocked.emit(unlocked_tier)


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
		"crystals_opened": crystals_opened,
		"since_epic": crystals_since_epic,
	}


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
	r.unlocked_tier = clampi(int(d.get("tier", 0)), 0, Campaign.Tier.ETERNAL)
	r.crystal_seed = int(d.get("crystal_seed", 20261119))
	r.crystals_opened = int(d.get("crystals_opened", 0))
	r.crystals_since_epic = int(d.get("since_epic", 0))
	var heroes: Dictionary = d.get("owned", {})
	for k in heroes.keys():
		r.owned[k] = HeroProgress.from_dict(heroes[k])
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
