class_name Stash
extends RefCounted
# ------------------------------------------------------------------------------
# The pooled inventory — THE one thing shared across every champion.
#
# Levels and skill points belong to a single hero and never transfer. Gear is the
# opposite: one stash for the whole roster, so a legendary dropped by a level-50
# Mage is waiting for the level-1 Fighter you start tomorrow. That asymmetry is
# the point. Starting a new champion costs you nothing you have earned, and the
# stash is what makes the hundredth restart feel different from the first.
#
# An item is in exactly one place: loose in the stash, or equipped by exactly one
# champion. Equipping from the pool removes it from the pool, so two heroes can
# never wear the same sword — the shared part is the POOL, not the item.
# ------------------------------------------------------------------------------

## Items not currently worn by anyone.
var items: Array[Item] = []

## hero_name -> { slot -> Item }
var equipped: Dictionary = {}

## Everything is capped so a save file cannot grow without bound. When the stash
## is full, the pickup is refused rather than silently dropping the best item.
const CAPACITY: int = 300


func count() -> int:
	return items.size()


func is_full() -> bool:
	return items.size() >= CAPACITY


## Returns false when there is no room — the caller should tell the player, not
## quietly discard loot.
func add(it: Item) -> bool:
	if is_full():
		return false
	items.append(it)
	return true


func remove_at(index: int) -> Item:
	if index < 0 or index >= items.size():
		return null
	var it: Item = items[index]
	items.remove_at(index)
	return it


func find_index(item_id: int) -> int:
	for i in range(items.size()):
		if items[i].id == item_id:
			return i
	return -1


# ------------------------------------------------------------------------------
# Equipment
# ------------------------------------------------------------------------------

func gear_of(hero: String) -> Dictionary:
	if not equipped.has(hero):
		equipped[hero] = {}
	return equipped[hero]


func equipped_in(hero: String, slot: int) -> Item:
	return gear_of(hero).get(slot, null)


## Move an item from the pool onto a champion. Anything already in that slot
## goes back to the pool, so nothing is ever destroyed by a swap.
func equip(hero: String, item_id: int) -> bool:
	var idx: int = find_index(item_id)
	if idx < 0:
		return false
	var it: Item = items[idx]
	var gear: Dictionary = gear_of(hero)

	var previous: Item = gear.get(it.slot, null)
	items.remove_at(idx)
	gear[it.slot] = it
	if previous != null:
		items.append(previous)
	return true


func unequip(hero: String, slot: int) -> bool:
	var gear: Dictionary = gear_of(hero)
	var it: Item = gear.get(slot, null)
	if it == null:
		return false
	if is_full():
		return false          # nowhere to put it; refuse rather than delete
	gear.erase(slot)
	items.append(it)
	return true


# ------------------------------------------------------------------------------
# What the gear is worth
# ------------------------------------------------------------------------------

## Attribute bonuses from everything a champion is wearing.
func gear_stats(hero: String) -> Stats:
	var s := Stats.new()
	for slot in gear_of(hero).keys():
		var it: Item = gear_of(hero)[slot]
		if it != null:
			s = s.plus(it.bonus)
	return s


## Flat weapon damage. Unarmed is deliberately not zero — a champion with an
## empty weapon slot should be weak, not harmless.
func weapon_power(hero: String) -> float:
	var it: Item = equipped_in(hero, Item.Slot.WEAPON)
	return it.power if it != null else 2.0


## Flat armour from every non-weapon piece.
func armour(hero: String) -> float:
	var total: float = 0.0
	for slot in gear_of(hero).keys():
		if slot == Item.Slot.WEAPON:
			continue
		var it: Item = gear_of(hero)[slot]
		if it != null:
			total += it.power
	return total


## The best item in the pool for this champion's slot, if it beats what they
## have on. Drives the "upgrade available" marker — with a 300-item pool and 200
## champions, making the player compare by hand is not a real option.
func best_upgrade(hero: String, cls: int, slot: int) -> Item:
	var current: Item = equipped_in(hero, slot)
	var floor_score: float = current.score_for(cls) if current != null else 0.0
	var best: Item = null
	var best_score: float = floor_score
	for it in items:
		if it.slot != slot:
			continue
		var sc: float = it.score_for(cls)
		if sc > best_score:
			best_score = sc
			best = it
	return best


## Every slot where the pool holds something better. Returns slot -> Item.
func all_upgrades(hero: String, cls: int) -> Dictionary:
	var out: Dictionary = {}
	for slot in Item.Slot.values():
		var it: Item = best_upgrade(hero, cls, slot)
		if it != null:
			out[slot] = it
	return out


## Equip the best available item in every slot. A convenience, but an important
## one: it is what makes picking up a champion you have not played in weeks
## pleasant instead of a twenty-minute inventory chore.
func auto_equip(hero: String, cls: int) -> int:
	var changed: int = 0
	for slot in Item.Slot.values():
		var it: Item = best_upgrade(hero, cls, slot)
		if it != null and equip(hero, it.id):
			changed += 1
	return changed


# ------------------------------------------------------------------------------
# Save / load
# ------------------------------------------------------------------------------

func to_dict() -> Dictionary:
	var loose: Array = []
	for it in items:
		loose.append(it.to_dict())
	var worn: Dictionary = {}
	for hero in equipped.keys():
		var gear: Dictionary = equipped[hero]
		var per: Dictionary = {}
		for slot in gear.keys():
			per[str(slot)] = (gear[slot] as Item).to_dict()
		worn[hero] = per
	return {"items": loose, "equipped": worn}


static func from_dict(d: Dictionary) -> Stash:
	var s := Stash.new()
	for raw in d.get("items", []):
		s.items.append(Item.from_dict(raw))
	var worn: Dictionary = d.get("equipped", {})
	for hero in worn.keys():
		var per: Dictionary = {}
		var saved: Dictionary = worn[hero]
		for slot_str in saved.keys():
			per[int(slot_str)] = Item.from_dict(saved[slot_str])
		s.equipped[hero] = per
	return s
