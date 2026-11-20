class_name Wallet
extends RefCounted
# ------------------------------------------------------------------------------
# The three currencies.
#
#   GOLD            earned by selling loot; spends at the merchant. Soft, common.
#   GEMS            unlock a SPECIFIC champion you have chosen. Premium, scarce.
#   SPAWN CRYSTALS  unlock a RANDOM champion. Premium, scarce.
#
# All three are sold as consumable IAP packs, which puts this file squarely in
# the path of App Store review. Two rules follow from that and are enforced
# here rather than trusted to callers:
#
#   * Balances can never go negative. A spend that cannot be afforded is
#     refused and reported, not clamped — clamping silently loses a purchase
#     the player may have paid money for.
#   * Every grant and every spend carries a REASON string. When a player writes
#     in claiming their gems vanished, the ledger is the only thing that can
#     answer them, and it has to exist before the complaint, not after.
# ------------------------------------------------------------------------------

enum Kind { GOLD, GEMS, CRYSTALS }

const KIND_NAMES: Dictionary = {
	Kind.GOLD: "Gold", Kind.GEMS: "Gems", Kind.CRYSTALS: "Spawn Crystals",
}

signal changed(kind: int, amount: int, balance: int, reason: String)

var gold: int = 0
var gems: int = 0
var crystals: int = 0

## Recent transactions, newest last. Capped — this is a support aid, not an
## audit log, and it has to fit in a save file.
const LEDGER_MAX: int = 200
var ledger: Array[Dictionary] = []


func balance(kind: int) -> int:
	match kind:
		Kind.GOLD: return gold
		Kind.GEMS: return gems
		_: return crystals


func can_afford(kind: int, amount: int) -> bool:
	return amount >= 0 and balance(kind) >= amount


## Add currency. `reason` is mandatory in spirit — pass something meaningful
## ("iap:gems_medium", "sell:Keen Blade", "duplicate:brom").
func grant(kind: int, amount: int, reason: String) -> void:
	if amount <= 0:
		return
	_apply(kind, amount)
	_record(kind, amount, reason)


## Spend currency. Returns false and changes NOTHING if it cannot be afforded.
func spend(kind: int, amount: int, reason: String) -> bool:
	if amount <= 0:
		return true
	if not can_afford(kind, amount):
		return false
	_apply(kind, -amount)
	_record(kind, -amount, reason)
	return true


func _apply(kind: int, delta: int) -> void:
	match kind:
		Kind.GOLD: gold = maxi(gold + delta, 0)
		Kind.GEMS: gems = maxi(gems + delta, 0)
		_: crystals = maxi(crystals + delta, 0)


func _record(kind: int, delta: int, reason: String) -> void:
	ledger.append({"k": kind, "d": delta, "b": balance(kind), "why": reason})
	if ledger.size() > LEDGER_MAX:
		ledger = ledger.slice(ledger.size() - LEDGER_MAX)
	changed.emit(kind, delta, balance(kind), reason)


func describe() -> String:
	return "%d gold, %d gems, %d crystals" % [gold, gems, crystals]


func to_dict() -> Dictionary:
	return {"gold": gold, "gems": gems, "crystals": crystals, "ledger": ledger}


static func from_dict(d: Dictionary) -> Wallet:
	var w := Wallet.new()
	w.gold = maxi(int(d.get("gold", 0)), 0)
	w.gems = maxi(int(d.get("gems", 0)), 0)
	w.crystals = maxi(int(d.get("crystals", 0)), 0)
	for e in d.get("ledger", []):
		w.ledger.append(e)
	return w
