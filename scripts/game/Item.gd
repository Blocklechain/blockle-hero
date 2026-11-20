class_name Item
extends RefCounted
# ------------------------------------------------------------------------------
# A weapon or piece of armour.
#
# ITEMS ARE NEVER VISIBLE ON THE CHARACTER. That is a design decision, and it
# also happens to be the only honest option: the 200 hero models are single
# static meshes with no sockets, no skeleton and no separable parts, so there is
# nothing to attach a sword to. Making gear invisible turns a hard constraint
# into a clean rule — and saves authoring several thousand attachment assets.
#
# What gear does instead is move numbers, and the numbers are the same four
# attributes the character sheet already shows, so the player can always read
# exactly what a drop is worth without a visual language to learn.
# ------------------------------------------------------------------------------

enum Slot { WEAPON, HEAD, CHEST, HANDS, FEET, RING, AMULET }

const SLOT_NAMES: Dictionary = {
	Slot.WEAPON: "Weapon", Slot.HEAD: "Head", Slot.CHEST: "Chest",
	Slot.HANDS: "Hands", Slot.FEET: "Feet", Slot.RING: "Ring",
	Slot.AMULET: "Amulet",
}

enum Rarity { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY }

const RARITY_NAMES: Dictionary = {
	Rarity.COMMON: "Common", Rarity.UNCOMMON: "Uncommon", Rarity.RARE: "Rare",
	Rarity.EPIC: "Epic", Rarity.LEGENDARY: "Legendary",
}

const RARITY_COLOURS: Dictionary = {
	Rarity.COMMON: Color("c8c8c8"), Rarity.UNCOMMON: Color("6fd36f"),
	Rarity.RARE: Color("5aa8ff"), Rarity.EPIC: Color("c06bff"),
	Rarity.LEGENDARY: Color("ffa534"),
}

## How many attributes a piece rolls, and how much total budget it gets, by
## rarity. More affixes AND bigger numbers, so a legendary is distinct in kind
## rather than just a bigger common.
const RARITY_AFFIXES: Dictionary = {
	Rarity.COMMON: 1, Rarity.UNCOMMON: 2, Rarity.RARE: 3,
	Rarity.EPIC: 4, Rarity.LEGENDARY: 4,
}
const RARITY_BUDGET: Dictionary = {
	Rarity.COMMON: 1.0, Rarity.UNCOMMON: 1.6, Rarity.RARE: 2.4,
	Rarity.EPIC: 3.4, Rarity.LEGENDARY: 4.8,
}

## Weapons carry damage; armour carries defence. Both still roll attributes.
const SLOT_WEIGHT: Dictionary = {
	Slot.WEAPON: 1.25, Slot.CHEST: 1.15, Slot.HEAD: 1.0, Slot.HANDS: 0.85,
	Slot.FEET: 0.85, Slot.RING: 0.75, Slot.AMULET: 0.9,
}

var id: int = 0
var item_name: String = ""
var slot: int = Slot.WEAPON
var rarity: int = Rarity.COMMON
var item_level: int = 1
var bonus: Stats = null
## Flat damage on weapons, flat armour on everything else.
var power: float = 0.0


# ------------------------------------------------------------------------------
# Generation
# ------------------------------------------------------------------------------

## Roll an item. Deterministic in (seed, roll_id) so a given kill always drops
## the same thing — which matters for save integrity and for reproducing bugs.
static func roll(seed: int, roll_id: int, ilvl: int, rar: int,
		slot_hint: int = -1) -> Item:
	var it := Item.new()
	it.id = Rng.hash2(seed, roll_id, 7717)
	it.item_level = maxi(ilvl, 1)
	it.rarity = rar
	it.slot = slot_hint if slot_hint >= 0 else \
		int(Rng.hash2(seed, roll_id, 11) % Slot.size())

	var budget: float = float(RARITY_BUDGET[rar]) \
		* float(SLOT_WEIGHT.get(it.slot, 1.0)) \
		* (2.0 + float(it.item_level) * 0.55)

	# Spread the budget over N distinct attributes, weighted randomly rather
	# than evenly — two rares of the same level should still feel different.
	var n: int = int(RARITY_AFFIXES[rar])
	var attrs: Array = [Stats.Attr.STRENGTH, Stats.Attr.AGILITY,
		Stats.Attr.INTELLECT, Stats.Attr.CONSTITUTION]
	# Deterministic shuffle.
	for i in range(attrs.size() - 1, 0, -1):
		var j: int = int(Rng.hash2(seed, roll_id * 31 + i, 23) % (i + 1))
		var tmp = attrs[i]
		attrs[i] = attrs[j]
		attrs[j] = tmp

	var weights: Array = []
	var wsum: float = 0.0
	for i in range(n):
		var w: float = 0.5 + Rng.unit2(seed, roll_id * 17 + i, 29)
		weights.append(w)
		wsum += w

	it.bonus = Stats.new()
	for i in range(n):
		var share: float = budget * (float(weights[i]) / maxf(wsum, 0.0001))
		it.bonus.add_attr(int(attrs[i]), roundf(share))

	# Legendaries put a thumb on the scale: one attribute gets a real spike, so
	# they read as special instead of merely large.
	if rar == Rarity.LEGENDARY:
		it.bonus.add_attr(int(attrs[0]), roundf(budget * 0.35))

	it.power = roundf((4.0 + float(it.item_level) * 1.8)
		* float(SLOT_WEIGHT.get(it.slot, 1.0))
		* (1.0 + float(rar) * 0.22))

	it.item_name = _name_for(seed, roll_id, it)
	return it


const PREFIX: PackedStringArray = [
	"Worn", "Keen", "Hardened", "Gilded", "Runed", "Ashen", "Frostbound",
	"Thornclad", "Hollow", "Stormtouched", "Mirebound", "Voidetched",
]
const WEAPON_NOUN: PackedStringArray = [
	"Blade", "Axe", "Maul", "Spear", "Bow", "Sceptre", "Stave", "Dagger",
]
const ARMOUR_NOUN: Dictionary = {
	Slot.HEAD: "Helm", Slot.CHEST: "Mail", Slot.HANDS: "Gauntlets",
	Slot.FEET: "Greaves", Slot.RING: "Band", Slot.AMULET: "Pendant",
}
const SUFFIX: PackedStringArray = [
	"of the Bear", "of the Hawk", "of the Sage", "of the Mountain",
	"of Embers", "of the Tide", "of Dusk", "of the Wolf",
]


static func _name_for(seed: int, roll_id: int, it: Item) -> String:
	var p: String = PREFIX[int(Rng.hash2(seed, roll_id, 41) % PREFIX.size())]
	var noun: String = WEAPON_NOUN[int(Rng.hash2(seed, roll_id, 43) % WEAPON_NOUN.size())] \
		if it.slot == Slot.WEAPON else String(ARMOUR_NOUN.get(it.slot, "Relic"))
	# Only better items earn a suffix; a common should look plain at a glance.
	if it.rarity >= Rarity.RARE:
		var s: String = SUFFIX[int(Rng.hash2(seed, roll_id, 47) % SUFFIX.size())]
		return "%s %s %s" % [p, noun, s]
	return "%s %s" % [p, noun]


# ------------------------------------------------------------------------------

func rarity_name() -> String:
	return String(RARITY_NAMES.get(rarity, "?"))


func slot_name() -> String:
	return String(SLOT_NAMES.get(slot, "?"))


func colour() -> Color:
	return RARITY_COLOURS.get(rarity, Color.WHITE)


## A single number for "is this better", used to sort a stash and to flag an
## upgrade. Weighted toward the class's primary attribute, because 8 Intellect
## is worthless to a Fighter and the list should say so.
func score_for(cls: int) -> float:
	var pa: int = HeroClass.primary_attr(cls)
	var s: float = power * 0.8
	for a in [Stats.Attr.STRENGTH, Stats.Attr.AGILITY,
			Stats.Attr.INTELLECT, Stats.Attr.CONSTITUTION]:
		var v: float = bonus.get_attr(a)
		if a == pa:
			s += v * 2.0
		elif a == Stats.Attr.CONSTITUTION:
			s += v * 1.2          # survivability is never dead weight
		else:
			s += v * 0.35
	return s


func describe() -> String:
	var parts: PackedStringArray = []
	for a in [Stats.Attr.STRENGTH, Stats.Attr.AGILITY,
			Stats.Attr.INTELLECT, Stats.Attr.CONSTITUTION]:
		var v: float = bonus.get_attr(a)
		if v > 0.0:
			parts.append("+%.0f %s" % [v, Stats.ATTR_SHORT[a]])
	var tag: String = "dmg" if slot == Slot.WEAPON else "armour"
	return "%s [%s] i%d  %.0f %s  %s" % [item_name, rarity_name(),
		item_level, power, tag, ", ".join(parts)]


func to_dict() -> Dictionary:
	return {"id": id, "name": item_name, "slot": slot, "rarity": rarity,
		"ilvl": item_level, "power": power, "bonus": bonus.to_dict()}


static func from_dict(d: Dictionary) -> Item:
	var it := Item.new()
	it.id = int(d.get("id", 0))
	it.item_name = String(d.get("name", ""))
	it.slot = int(d.get("slot", Slot.WEAPON))
	it.rarity = int(d.get("rarity", Rarity.COMMON))
	it.item_level = int(d.get("ilvl", 1))
	it.power = float(d.get("power", 0.0))
	it.bonus = Stats.from_dict(d.get("bonus", {}))
	return it
