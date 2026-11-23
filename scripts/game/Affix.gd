class_name Affix
extends RefCounted
# ------------------------------------------------------------------------------
# WHAT MAKES ONE DROP DIFFERENT FROM THE NEXT.
#
# Item.roll already produced varied NUMBERS — it spreads a rarity budget over
# the four attributes with a seeded shuffle, so no two rares are arithmetically
# identical. What it could not produce is IDENTITY. Every piece was the same
# stat block with different magnitudes and a name assembled from one adjective
# and one noun, which means the player has nothing to recognise, nothing to
# remember, and nothing to hunt for. An ARPG runs on "I want THAT one", and
# there was no "that one" to want.
#
# So: a table of prefixes and suffixes, each one a NAMED thing that moves a
# SPECIFIC stat, and a short list of named uniques at Legendary that each break
# one rule of the fight.
#
# THREE CONSTRAINTS THIS FILE KEEPS:
#
#   * DETERMINISTIC FROM (SEED, ITEM). `roll()` is a pure function; the caller
#     passes the item's own id as the seed (Item.id is already a hash of the
#     region seed and the kill ordinal). The whole chain downstream of this
#     depends on that property: Loot re-derives a drop from a save, a replay
#     reproduces a fight, and a savescum must not reroll a legendary.
#   * ONLY WIRED CHANNELS. Every affix moves one of five numbers that the game
#     ALREADY reads: the four attributes, through Stash.gear_stats ->
#     Roster.effective_stats -> Combatant; or `power`, through
#     Stash.weapon_power / Stash.armour -> Combatant. There is deliberately no
#     "+crit" affix, because crit is derived from Agility (Stats.crit_chance)
#     and an affix that moved it would have to invent a storage field and a
#     reader, which is how this project has shipped five features connected to
#     nothing. A unique's RULE is the one exception, and it is inert until a
#     combat reader exists — see UNIQUES.
#   * NAMES, NOT SLUGS. The id is never shown. Fragments are display text and
#     assemble into "Ashen Greaves of the Hollow".
#
# NOTHING HERE TOUCHES Item.gd OR Loot.gd. `apply()` is the whole integration
# surface: it mutates one Item in the three ways the rest of the game can
# already see.
# ------------------------------------------------------------------------------


# ------------------------------------------------------------------------------
# What an affix can move
# ------------------------------------------------------------------------------

## The five channels. The first four are deliberately numbered to match
## Stats.Attr, but nothing relies on that coincidence — STAT_ATTR is the map.
enum Stat { STRENGTH, AGILITY, INTELLECT, CONSTITUTION, POWER }

const STAT_ATTR: Dictionary = {
	Stat.STRENGTH: Stats.Attr.STRENGTH,
	Stat.AGILITY: Stats.Attr.AGILITY,
	Stat.INTELLECT: Stats.Attr.INTELLECT,
	Stat.CONSTITUTION: Stats.Attr.CONSTITUTION,
}

enum Kind { PREFIX, SUFFIX }


# ------------------------------------------------------------------------------
# How much, and how many
# ------------------------------------------------------------------------------

## How many affixes each rarity rolls.
##
## MONOTONIC BY CONTRACT. A player who sees an epic with fewer lines than a rare
## concludes the rarity colours are decoration, and that is the one thing a loot
## system cannot afford to be. tools/affixtest.gd asserts it across a sweep, and
## the selection in `roll()` clamps to the eligible pool size — which is a
## function of the SLOT, never of the rarity — so the guarantee survives a slot
## with a short table.
const RARITY_COUNT: Dictionary = {
	Item.Rarity.COMMON: 0,
	Item.Rarity.UNCOMMON: 1,
	Item.Rarity.RARE: 2,
	Item.Rarity.EPIC: 3,
	Item.Rarity.LEGENDARY: 4,
}

## Magnitude multiplier per rarity. A legendary is not just wider, it rolls from
## a strictly better band, so the floor of a legendary beats the floor of a rare
## on the same line.
const RARITY_SCALE: Dictionary = {
	Item.Rarity.COMMON: 0.70,
	Item.Rarity.UNCOMMON: 0.85,
	Item.Rarity.RARE: 1.00,
	Item.Rarity.EPIC: 1.20,
	Item.Rarity.LEGENDARY: 1.45,
}

## Item level's share. Flat and linear, matching Stats' deliberate refusal to
## scale quadratically: an affix at level 60 is worth about eight times one at
## level 1, which keeps a drop interesting without making the last act's numbers
## unreadable.
const ILVL_BASE: float = 0.75
const ILVL_PER_LEVEL: float = 0.09

## Odds that a Legendary in a slot that HAS a unique comes out as that unique.
## Low on purpose: a unique the player sees every third legendary is a stat
## block with a fixed name, not a trophy.
const UNIQUE_CHANCE: float = 0.18

## Independent streams off the one seed. Distinct primes because Rng's third
## argument is a salt, not an index — reusing one would correlate the affix
## choice with the magnitude it rolls.
const SALT_PICK: int = 7307
const SALT_MAG: int = 7321
const SALT_NOUN: int = 7333
const SALT_PLAIN: int = 7349
const SALT_UNIQUE: int = 7351


# ------------------------------------------------------------------------------
# The table
#
# `slots` empty means any slot. Weights are relative within whatever survives
# the slot filter, so restricting an affix to weapons makes it commoner ON
# weapons rather than rarer overall — which is what "Keen" ought to mean.
#
# `lo`/`hi` are the magnitude range BEFORE rarity and item level; the declared
# range for a real roll is magnitude_range(), and that is what the harness
# asserts against.
# ------------------------------------------------------------------------------

const ANY: Array = []
const WEAPON_ONLY: Array = [Item.Slot.WEAPON]
const ARMOUR_ONLY: Array = [Item.Slot.HEAD, Item.Slot.CHEST, Item.Slot.HANDS,
	Item.Slot.FEET, Item.Slot.RING, Item.Slot.AMULET]
const WORN_HEAVY: Array = [Item.Slot.HEAD, Item.Slot.CHEST, Item.Slot.FEET]
const STRIKING: Array = [Item.Slot.WEAPON, Item.Slot.CHEST, Item.Slot.HANDS]
const JEWELLERY: Array = [Item.Slot.WEAPON, Item.Slot.RING, Item.Slot.AMULET]
const HELD: Array = [Item.Slot.WEAPON, Item.Slot.HANDS, Item.Slot.RING]
const REGALIA: Array = [Item.Slot.HEAD, Item.Slot.AMULET, Item.Slot.RING]

const PREFIXES: Array = [
	{"id": "keen", "frag": "Keen", "stat": Stat.POWER,
		"lo": 2.0, "hi": 4.0, "w": 10.0, "slots": WEAPON_ONLY},
	{"id": "hardened", "frag": "Hardened", "stat": Stat.POWER,
		"lo": 2.0, "hi": 4.0, "w": 10.0, "slots": ARMOUR_ONLY},
	{"id": "gilded", "frag": "Gilded", "stat": Stat.CONSTITUTION,
		"lo": 1.0, "hi": 3.0, "w": 9.0, "slots": ANY},
	{"id": "runed", "frag": "Runed", "stat": Stat.INTELLECT,
		"lo": 1.0, "hi": 3.0, "w": 9.0, "slots": ANY},
	{"id": "ashen", "frag": "Ashen", "stat": Stat.STRENGTH,
		"lo": 1.0, "hi": 3.0, "w": 9.0, "slots": ANY},
	{"id": "frostbound", "frag": "Frostbound", "stat": Stat.AGILITY,
		"lo": 1.0, "hi": 3.0, "w": 9.0, "slots": ANY},
	{"id": "thornclad", "frag": "Thornclad", "stat": Stat.POWER,
		"lo": 1.5, "hi": 3.0, "w": 7.0, "slots": ARMOUR_ONLY},
	{"id": "hollowforged", "frag": "Hollowforged", "stat": Stat.AGILITY,
		"lo": 2.0, "hi": 4.0, "w": 6.0, "slots": ANY},
	{"id": "stormtouched", "frag": "Stormtouched", "stat": Stat.AGILITY,
		"lo": 2.0, "hi": 4.5, "w": 5.0, "slots": HELD},
	{"id": "mirebound", "frag": "Mirebound", "stat": Stat.CONSTITUTION,
		"lo": 2.0, "hi": 4.5, "w": 5.0, "slots": WORN_HEAVY},
	{"id": "bonecarved", "frag": "Bonecarved", "stat": Stat.STRENGTH,
		"lo": 2.0, "hi": 4.5, "w": 5.0, "slots": STRIKING},
	{"id": "voidetched", "frag": "Voidetched", "stat": Stat.INTELLECT,
		"lo": 2.0, "hi": 5.0, "w": 4.0, "slots": JEWELLERY},
	{"id": "emberforged", "frag": "Emberforged", "stat": Stat.POWER,
		"lo": 2.5, "hi": 5.0, "w": 3.0, "slots": ANY},
]

const SUFFIXES: Array = [
	{"id": "bear", "frag": "of the Bear", "stat": Stat.STRENGTH,
		"lo": 2.0, "hi": 4.0, "w": 10.0, "slots": ANY},
	{"id": "hawk", "frag": "of the Hawk", "stat": Stat.AGILITY,
		"lo": 2.0, "hi": 4.0, "w": 10.0, "slots": ANY},
	{"id": "sage", "frag": "of the Sage", "stat": Stat.INTELLECT,
		"lo": 2.0, "hi": 4.0, "w": 10.0, "slots": ANY},
	{"id": "mountain", "frag": "of the Mountain", "stat": Stat.CONSTITUTION,
		"lo": 2.0, "hi": 4.0, "w": 10.0, "slots": ANY},
	{"id": "embers", "frag": "of Embers", "stat": Stat.POWER,
		"lo": 2.0, "hi": 4.0, "w": 8.0, "slots": ANY},
	{"id": "tide", "frag": "of the Tide", "stat": Stat.CONSTITUTION,
		"lo": 2.5, "hi": 5.0, "w": 7.0, "slots": ANY},
	{"id": "dusk", "frag": "of Dusk", "stat": Stat.AGILITY,
		"lo": 2.5, "hi": 5.0, "w": 7.0, "slots": ANY},
	{"id": "wolf", "frag": "of the Wolf", "stat": Stat.STRENGTH,
		"lo": 2.5, "hi": 5.0, "w": 7.0, "slots": ANY},
	{"id": "hollow", "frag": "of the Hollow", "stat": Stat.INTELLECT,
		"lo": 3.0, "hi": 6.0, "w": 5.0, "slots": ANY},
	{"id": "marches", "frag": "of the Bone Marches", "stat": Stat.POWER,
		"lo": 3.0, "hi": 6.0, "w": 4.0, "slots": ANY},
	{"id": "longdark", "frag": "of the Long Dark", "stat": Stat.INTELLECT,
		"lo": 3.0, "hi": 6.5, "w": 3.0, "slots": JEWELLERY},
	{"id": "reach", "frag": "of the Howling Reach", "stat": Stat.STRENGTH,
		"lo": 3.0, "hi": 6.5, "w": 3.0, "slots": STRIKING},
	{"id": "crown", "frag": "of the Shattered Crown", "stat": Stat.CONSTITUTION,
		"lo": 3.5, "hi": 7.0, "w": 2.0, "slots": REGALIA},
]


# ------------------------------------------------------------------------------
# Nouns
#
# Owned here rather than borrowed from Item.PREFIX / Item.ARMOUR_NOUN on
# purpose: naming is this file's job now, and reaching into another script's
# tables would mean a tuning pass on one of them silently renames every drop in
# the other.
# ------------------------------------------------------------------------------

const NOUNS: Dictionary = {
	Item.Slot.WEAPON: ["Blade", "Axe", "Maul", "Spear", "Bow", "Sceptre",
		"Stave", "Dagger"],
	Item.Slot.HEAD: ["Helm", "Hood", "Circlet"],
	Item.Slot.CHEST: ["Mail", "Cuirass", "Hauberk"],
	Item.Slot.HANDS: ["Gauntlets", "Grips", "Bracers"],
	Item.Slot.FEET: ["Greaves", "Boots", "Sabatons"],
	Item.Slot.RING: ["Band", "Signet", "Loop"],
	Item.Slot.AMULET: ["Pendant", "Amulet", "Torc"],
}

## Used ONLY when nothing rolled a prefix and nothing rolled a suffix, which in
## practice means a Common. A bare "Helm" reads as a placeholder; a plain
## adjective reads as a cheap helm, which is what it is.
const PLAIN: Array = ["Worn", "Plain", "Rough", "Chipped", "Serviceable"]


# ------------------------------------------------------------------------------
# Named uniques
#
# Legendary only, one per slot, each with ONE rule. One and not three: a unique
# the player has to read twice is a stat block with extra steps, and the whole
# value of a named item is that its name is shorthand for a sentence.
#
# THE RULE IS DATA, NOT CODE. Each `rule` is a dictionary the combat layer
# reads; this file contains no combat logic and never will, because a rule
# implemented here would run in whatever order the loot system happens to apply
# it in rather than in the order a fight resolves. Every rule is also expressed
# in terms of machinery that ALREADY EXISTS — StatusEffect.Kind.BURN, SLOW,
# SHIELD and HASTE are all live, and Elite.gd drives three of them today — so
# none of this needs a new system, only a reader.
#
# UNTIL THAT READER EXISTS, `rule.text` MUST NOT BE SHOWN. A name promising "a
# second target" on an item that does not hit a second target is worse than a
# plain legendary. `apply()` therefore writes the unique's NAME and its numbers
# and nothing else; the text ships when Combatant can honour it. See the
# integration note at the end of this file.
#
# The names are all canon places (Biome.IDS, Campaign.act_name) — no new lore.
# ------------------------------------------------------------------------------

const UNIQUES: Array = [
	{
		"id": "tidebreak", "name": "Tidebreak", "slot": Item.Slot.WEAPON,
		"power_mult": 1.22,
		"rule": {
			"id": "second_target", "value": 0.55,
			"text": "Your basic attack also strikes the next nearest enemy "
				+ "for 55% damage.",
		},
	},
	{
		"id": "gloomroot_diadem", "name": "The Gloomroot Diadem",
		"slot": Item.Slot.HEAD, "power_mult": 1.18,
		"rule": {
			"id": "kill_heals", "value": 0.07,
			"text": "Every kill restores 7% of your maximum health.",
		},
	},
	{
		"id": "ashwastes_carapace", "name": "The Ashwastes Carapace",
		"slot": Item.Slot.CHEST, "power_mult": 1.25,
		"rule": {
			"id": "ward_when_low", "threshold": 0.33, "value": 0.25,
			"effect": StatusEffect.Kind.SHIELD, "duration": 6.0, "once": true,
			"text": "Below a third health, a ward absorbs 25% of your maximum "
				+ "health. Once per fight.",
		},
	},
	{
		"id": "stormreach_grips", "name": "Stormreach Grips",
		"slot": Item.Slot.HANDS, "power_mult": 1.18,
		"rule": {
			"id": "crit_burns", "value": 0.12, "duration": 4.0,
			"effect": StatusEffect.Kind.BURN,
			"text": "Critical hits set the target burning.",
		},
	},
	{
		"id": "mistmoor_greaves", "name": "The Mistmoor Greaves",
		"slot": Item.Slot.FEET, "power_mult": 1.18,
		"rule": {
			"id": "desperate_speed", "threshold": 0.33, "value": 0.45,
			"effect": StatusEffect.Kind.HASTE,
			"text": "Below a third health, you move 45% faster.",
		},
	},
	{
		"id": "voidrift_signet", "name": "The Voidrift Signet",
		"slot": Item.Slot.RING, "power_mult": 1.20,
		"rule": {
			"id": "thorns", "value": 0.30,
			"text": "Reflects 30% of the damage you take back at the attacker.",
		},
	},
	{
		"id": "duskvale_pendant", "name": "The Duskvale Pendant",
		"slot": Item.Slot.AMULET, "power_mult": 1.20,
		"rule": {
			"id": "slow_on_hit", "value": 0.30, "duration": 2.0,
			"effect": StatusEffect.Kind.SLOW,
			"text": "Your hits slow the target by 30% for two seconds.",
		},
	},
]


## The whole unique table. Exposed so a codex screen, a quest ("find a unique")
## or a test can enumerate them without duplicating the list.
static func uniques() -> Array:
	return UNIQUES


static func unique_for_slot(slot: int) -> Dictionary:
	for u in UNIQUES:
		if int(u["slot"]) == slot:
			return u
	return {}


static func unique_by_id(id: String) -> Dictionary:
	for u in UNIQUES:
		if String(u["id"]) == id:
			return u
	return {}


# ------------------------------------------------------------------------------
# Magnitudes
# ------------------------------------------------------------------------------

static func ilvl_scale(ilvl: int) -> float:
	return ILVL_BASE + float(maxi(ilvl, 1)) * ILVL_PER_LEVEL


## THE DECLARED RANGE of one affix at one rarity and item level, as integers.
##
## This is the contract `roll()` is held to, and the harness asserts every
## rolled magnitude against it. Rounded here rather than at the point of use so
## that the published range and the rolled value cannot disagree by a half —
## the bug where a tooltip says "2 to 5" and the item shows 6.
##
## The floor is 1, never 0. A "+0 Strength" line is worse than no line: it
## occupies a row, costs an affix slot the rarity promised, and reads as a bug.
static func magnitude_range(a: Dictionary, rarity: int, ilvl: int) -> Vector2:
	var k: float = float(RARITY_SCALE.get(rarity, 1.0)) * ilvl_scale(ilvl)
	var lo: float = maxf(1.0, roundf(float(a["lo"]) * k))
	var hi: float = maxf(lo, roundf(float(a["hi"]) * k))
	return Vector2(lo, hi)


## One magnitude, uniform over the integers in the declared range.
##
## Integer-indexed rather than lerp-and-round: lerp of two already-rounded
## bounds biases the ends and, with an unlucky float, can land a hair outside
## them. Indexing cannot leave the range by construction.
static func magnitude_for(a: Dictionary, rarity: int, ilvl: int, seed: int,
		index: int) -> float:
	var r: Vector2 = magnitude_range(a, rarity, ilvl)
	var span: int = int(r.y - r.x) + 1
	var u: float = Rng.unit2(seed, index, SALT_MAG)
	return minf(r.x + floorf(u * float(span)), r.y)


static func count_for(rarity: int) -> int:
	return int(RARITY_COUNT.get(rarity, 0))


# ------------------------------------------------------------------------------
# Rolling
# ------------------------------------------------------------------------------

## Every affix a slot may carry, prefixes first, in table order.
##
## Order matters: it is the sampling order, so it has to be stable across runs
## and across platforms. Iterating the consts guarantees that; a Dictionary's
## key order would not.
static func eligible(slot: int) -> Array:
	var out: Array = []
	for a in PREFIXES:
		if _fits(a, slot):
			out.append(a)
	for a in SUFFIXES:
		if _fits(a, slot):
			out.append(a)
	return out


static func _fits(a: Dictionary, slot: int) -> bool:
	var slots: Array = a["slots"]
	return slots.is_empty() or slots.has(slot)


static func kind_of(a: Dictionary) -> int:
	# Derived from which table it came out of rather than stored on the entry,
	# so a prefix can never be mislabelled a suffix by a typo in the table.
	for p in PREFIXES:
		if p["id"] == a["id"]:
			return Kind.PREFIX
	return Kind.SUFFIX


## Roll the affixes for one item.
##
## `seed` MUST BE PER-ITEM. Pass the item's own id — Item.id is already
## Rng.hash2(region_seed, roll_id, 7717), so (seed, item) in, same affixes out,
## which is the property Loot's whole determinism argument rests on. Passing a
## region seed here would give every drop in a region with the same slot,
## rarity and level the same affixes; use seed_for() if all you have is a
## stream.
##
## Returns everything a caller could want and nothing it has to recompute:
##
##   name         String, ready to show
##   unique       "" or a UNIQUES id
##   affixes      Array of { id, kind, frag, stat, mag, line }
##   attrs        Stats.Attr -> float, to add straight onto Item.bonus
##   power_bonus  float, to add onto Item.power
##   power_mult   float, 1.0 unless a unique
##   rules        Array of rule dictionaries (empty unless a unique)
##   lines        PackedStringArray, one per affix, for a tooltip
static func roll(seed: int, slot: int, rarity: int, ilvl: int) -> Dictionary:
	var pool: Array = eligible(slot)
	var want: int = mini(count_for(rarity), pool.size())

	# Weighted sample WITHOUT replacement. Two "of the Hawk" lines on one item
	# is not variety, it is a bug the player reads as one.
	var avail: Array = pool.duplicate()
	var picked: Array = []
	for i in range(want):
		var total: float = 0.0
		for a in avail:
			total += maxf(float(a["w"]), 0.0)
		if total <= 0.0:
			break
		var r: float = Rng.unit2(seed, 1000 + i, SALT_PICK) * total
		var at: int = avail.size() - 1
		for j in range(avail.size()):
			r -= maxf(float(avail[j]["w"]), 0.0)
			if r <= 0.0:
				at = j
				break
		picked.append(avail[at])
		avail.remove_at(at)

	var unique_id: String = _unique_id(seed, slot, rarity)
	var out: Dictionary = {
		"slot": slot, "rarity": rarity, "ilvl": maxi(ilvl, 1),
		"unique": unique_id,
		"affixes": [], "attrs": {}, "power_bonus": 0.0, "power_mult": 1.0,
		"rules": [], "lines": PackedStringArray(),
	}

	for i in range(picked.size()):
		var a: Dictionary = picked[i]
		var mag: float = magnitude_for(a, rarity, ilvl, seed, 2000 + i)
		var stat: int = int(a["stat"])
		out["affixes"].append({
			"id": String(a["id"]), "kind": kind_of(a), "frag": String(a["frag"]),
			"stat": stat, "mag": mag, "line": line_for(stat, mag, slot),
		})
		if stat == Stat.POWER:
			out["power_bonus"] = float(out["power_bonus"]) + mag
		else:
			var attr: int = int(STAT_ATTR[stat])
			out["attrs"][attr] = float(out["attrs"].get(attr, 0.0)) + mag
		out["lines"].append(line_for(stat, mag, slot))

	if unique_id != "":
		var u: Dictionary = unique_by_id(unique_id)
		out["power_mult"] = float(u.get("power_mult", 1.0))
		out["rules"].append(u["rule"])

	out["name"] = name_for(seed, slot, out["affixes"], unique_id)
	return out


## A per-item seed from a stream, for callers that only have (seed, ordinal).
## Salted away from Item.roll's own 7717 so the affixes do not correlate with
## the attribute spread the same ordinal produced.
static func seed_for(stream_seed: int, roll_id: int) -> int:
	return Rng.hash2(stream_seed, roll_id, 6151)


static func _unique_id(seed: int, slot: int, rarity: int) -> String:
	if rarity < Item.Rarity.LEGENDARY:
		return ""
	var u: Dictionary = unique_for_slot(slot)
	if u.is_empty():
		return ""
	if Rng.unit2(seed, slot, SALT_UNIQUE) >= UNIQUE_CHANCE:
		return ""
	return String(u["id"])


## One tooltip line. POWER reads as damage on a weapon and armour everywhere
## else, matching Item.describe() so the stash row and the tooltip agree.
static func line_for(stat: int, mag: float, slot: int) -> String:
	if stat == Stat.POWER:
		return "+%.0f %s" % [mag, "dmg" if slot == Item.Slot.WEAPON
			else "armour"]
	return "+%.0f %s" % [mag, String(Stats.ATTR_SHORT[int(STAT_ATTR[stat])])]


# ------------------------------------------------------------------------------
# Naming
# ------------------------------------------------------------------------------

## Assemble a name from what rolled: "Ashen Greaves of the Hollow".
##
## `affixes` is `roll()`'s own list (or anything with `kind` and `frag`). Only
## the FIRST prefix and the FIRST suffix reach the name — a four-affix legendary
## stacking every fragment it rolled produces a sentence, not a name, and the
## extra affixes still show as lines.
##
## NO ID EVER REACHES THIS. Ids are snake_case internal keys; `frag` is the
## display text. The parts are filtered for emptiness before joining, which is
## the only way a double space could get in.
static func name_for(seed: int, slot: int, affixes: Array,
		unique_id: String = "") -> String:
	if unique_id != "":
		var u: Dictionary = unique_by_id(unique_id)
		if not u.is_empty():
			return String(u["name"])

	var prefix: String = ""
	var suffix: String = ""
	for a in affixes:
		var frag: String = String(a["frag"]).strip_edges()
		if frag == "":
			continue
		if int(a["kind"]) == Kind.PREFIX:
			if prefix == "":
				prefix = frag
		elif suffix == "":
			suffix = frag

	var nouns: Array = NOUNS.get(slot, ["Relic"])
	var noun: String = String(nouns[int(Rng.hash2(seed, slot, SALT_NOUN)
		% nouns.size())])

	var parts: PackedStringArray = []
	if prefix != "":
		parts.append(prefix)
	elif suffix == "":
		# Nothing rolled at all. A bare noun reads as missing data, so an
		# unremarkable adjective says "cheap" instead of "broken".
		parts.append(String(PLAIN[int(Rng.hash2(seed, slot, SALT_PLAIN)
			% PLAIN.size())]))
	parts.append(noun)
	if suffix != "":
		parts.append(suffix)
	return " ".join(parts)


# ------------------------------------------------------------------------------
# Integration
# ------------------------------------------------------------------------------

## Stamp a roll onto a real item.
##
## THE ENTIRE SURFACE this file presents to the rest of the game, and
## deliberately only three fields wide — the name the player reads, the
## attributes Stash.gear_stats sums, and the power Stash.weapon_power / armour
## return. All three are already plumbed into Combatant, so an affix changes a
## fight the moment it is applied and nothing new has to be wired for it.
##
## CALL IT ONCE per item. It adds rather than assigns (the item already carries
## Item.roll's budget, which must not be thrown away), so a second call would
## double the bonuses and rename the piece again.
##
## Returns the roll, so a caller can log it or hand the rules on.
static func apply(it: Item, rolled: Dictionary) -> Dictionary:
	if it == null or rolled.is_empty():
		return rolled
	var attrs: Dictionary = rolled.get("attrs", {})
	for attr in attrs.keys():
		it.bonus.add_attr(int(attr), float(attrs[attr]))
	it.power = roundf((it.power + float(rolled.get("power_bonus", 0.0)))
		* float(rolled.get("power_mult", 1.0)))
	var nm: String = String(rolled.get("name", ""))
	if nm != "":
		it.item_name = nm
	return rolled


## Roll and apply in one call, which is all Loot needs.
##
## Keyed on the item's own id so the same drop is the same item on reload — see
## roll()'s note. Nothing else about the item is read, so this is safe to call
## immediately after Item.roll and nowhere else.
static func dress(it: Item) -> Dictionary:
	if it == null:
		return {}
	return apply(it, roll(it.id, it.slot, it.rarity, it.item_level))
