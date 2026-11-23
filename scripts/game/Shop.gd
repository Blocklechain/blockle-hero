class_name Shop
extends RefCounted

## Preloaded by path, not by bare class_name: Affix.gd is newer than the
## editor's global class cache, and every headless harness loads this file
## directly. See tools/classcheck.gd.
const AffixC := preload("res://scripts/game/Affix.gd")
# ------------------------------------------------------------------------------
# The merchant: sell loot for gold, buy gear with it.
#
# Gold's only job is to be the floor under the loot system. Most drops are not
# upgrades, and a game where 90% of what you pick up is literally worthless
# teaches players to stop picking things up. Selling turns the chaff into
# progress toward something chosen rather than something rolled.
#
# Buy prices are deliberately well above sell prices. If the spread were thin,
# the optimal play would be to grind gold and buy every slot, which makes the
# whole loot table pointless.
# ------------------------------------------------------------------------------

const SELL_BASE: float = 6.0
const SELL_PER_ILVL: float = 2.2
## Multiplier on sell value by rarity.
const SELL_RARITY: Dictionary = {
	Item.Rarity.COMMON: 1.0, Item.Rarity.UNCOMMON: 2.2, Item.Rarity.RARE: 5.0,
	Item.Rarity.EPIC: 12.0, Item.Rarity.LEGENDARY: 30.0,
}
## Buying costs this much more than selling the same piece returns.
const BUY_MARKUP: float = 4.5

## How many pieces the merchant offers at once, and how often the list rolls over.
const OFFER_COUNT: int = 6


static func sell_value(it: Item) -> int:
	return int(round((SELL_BASE + float(it.item_level) * SELL_PER_ILVL)
		* float(SELL_RARITY.get(it.rarity, 1.0))))


static func buy_price(it: Item) -> int:
	return int(round(float(sell_value(it)) * BUY_MARKUP))


## Sell an item out of the stash. Returns gold paid, or 0 if it was not there.
static func sell(roster: Roster, item_id: int) -> int:
	var idx: int = roster.stash.find_index(item_id)
	if idx < 0:
		return 0
	var it: Item = roster.stash.items[idx]
	var gold: int = sell_value(it)
	roster.stash.remove_at(idx)
	roster.wallet.grant(Wallet.Kind.GOLD, gold, "sell:%s" % it.item_name)
	return gold


## Sell everything the given champion would never want — the single most
## requested feature in any loot game, and the reason a 300-slot stash stays
## usable instead of becoming a chore.
static func sell_all_below(roster: Roster, cls: int, min_rarity: int) -> int:
	var total: int = 0
	var keep: Array[Item] = []
	for it in roster.stash.items:
		if it.rarity < min_rarity:
			total += sell_value(it)
		else:
			keep.append(it)
	if total > 0:
		roster.stash.items = keep
		roster.wallet.grant(Wallet.Kind.GOLD, total, "sell_all")
	return total


## The merchant's current stock. Deterministic in (seed, refresh), so the same
## shop shows the same goods until it rolls over — a list that reshuffles every
## time it is opened invites savescumming.
static func offers(seed: int, refresh: int, ilvl: int, tier: int) -> Array[Item]:
	var out: Array[Item] = []
	for i in range(OFFER_COUNT):
		var rid: int = refresh * 100 + i
		var rarity: int = Campaign.roll_rarity(seed, rid, tier)
		# The merchant never stocks legendaries; those have to be earned.
		rarity = mini(rarity, Item.Rarity.EPIC)
		# Dressed like a drop: a merchant selling plain gear while every kill
		# drops affixed gear makes the shop strictly pointless.
		var stock: Item = Item.roll(seed, rid + 90000, ilvl, rarity)
		AffixC.dress(stock)
		out.append(stock)
	return out


## Buy a specific offer. Returns "" on success or a reason.
static func buy(roster: Roster, it: Item) -> String:
	if roster.stash.is_full():
		return "Stash is full"
	var price: int = buy_price(it)
	if not roster.wallet.can_afford(Wallet.Kind.GOLD, price):
		return "Needs %d gold" % price
	roster.wallet.spend(Wallet.Kind.GOLD, price, "buy:%s" % it.item_name)
	roster.stash.add(it)
	return ""
