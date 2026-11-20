class_name IAPCatalog
extends RefCounted
# ------------------------------------------------------------------------------
# The in-app purchases: gem packs, gold packs and spawn crystal packs.
#
# All CONSUMABLE products — they are spent, and a player can buy the same pack
# again. Consumables are not restorable, which is correct here and is why the
# balance must be persisted server-side or at minimum receipt-validated before
# it is trusted; a purely local balance is trivially edited.
#
# COMPLIANCE, not decoration:
#   * Guideline 3.1.1 — digital content must be sold through Apple IAP. These
#     product IDs are the only way currency enters the game legitimately.
#   * Guideline 3.1.1 (loot boxes) — spawn crystals grant a RANDOMISED champion
#     for money, so the odds must be disclosed BEFORE purchase. Every crystal
#     pack therefore carries `requires_odds_disclosure = true`, and
#     `Store.purchase()` refuses outright to buy one until the caller confirms
#     the odds screen was shown. `tools/metatest.gd` asserts the published
#     numbers match the actual roll; `tools/storetest.gd` asserts the gate
#     cannot be skipped and that the printed odds are the table's own numbers.
#
# Prices here are the tier NAMES, not amounts — the real price comes from App
# Store Connect at runtime and must be displayed from the StoreKit product, not
# from a hardcoded string, or the app lies to players in other currencies.
#
# Nothing here transacts. `Store` is the only thing that may call `grant()`, and
# only once per StoreKit transaction id; see Store.gd for the payment seam and
# for an explicit list of what is and is not real yet.
# ------------------------------------------------------------------------------

const PRODUCT_PREFIX: String = "org.blockle.hero."

class Pack extends RefCounted:
	var product_id: String = ""
	var title: String = ""
	var kind: int = Wallet.Kind.GOLD
	var amount: int = 0
	## Extra granted on top of `amount`, for the larger packs.
	var bonus: int = 0
	## Spawn crystals bundled onto a pack whose main currency is NOT crystals.
	## A crystal pack's own extras go in `bonus`; this field exists so that the
	## day someone ships "Gold Hoard + 3 crystals", the pack is a loot box by
	## construction and `crystal_payout()` says so without anyone remembering to
	## tick a flag.
	var crystals_bonus: int = 0
	var requires_odds_disclosure: bool = false

	func total() -> int:
		return amount + bonus

	## How many RANDOM champion draws this pack pays out. The disclosure rule is
	## derived from this number, never from the product id or the currency kind.
	func crystal_payout() -> int:
		return total() if kind == Wallet.Kind.CRYSTALS else crystals_bonus

	func describe() -> String:
		var b: String = "  (+%d bonus)" % bonus if bonus > 0 else ""
		var c: String = "  (+%d crystals)" % crystals_bonus \
			if crystals_bonus > 0 else ""
		return "%-34s %-22s %5d %s%s%s" % [product_id, title, total(),
			String(Wallet.KIND_NAMES[kind]), b, c]


## A pack may not be PRESENTED without the odds screen if buying it can produce
## a random champion. One rule, applied to the payout rather than to the product
## name, so a new bundle cannot slip past review by not looking like a crystal.
static func pack_needs_disclosure(p: Pack) -> bool:
	return p != null and p.crystal_payout() > 0


static func _pack(id: String, title: String, kind: int, amount: int,
		bonus: int = 0, crystals_bonus: int = 0) -> Pack:
	var p := Pack.new()
	p.product_id = PRODUCT_PREFIX + id
	p.title = title
	p.kind = kind
	p.amount = amount
	p.bonus = bonus
	p.crystals_bonus = crystals_bonus
	# Derived, not declared. Gems can be spent on a champion the player PICKS,
	# so a gem pack is not a random draw; anything that pays out crystals is.
	p.requires_odds_disclosure = pack_needs_disclosure(p)
	return p


static func all() -> Array:
	return [
		# --- gold: the soft currency, cheapest tier -----------------------
		_pack("gold.small", "Pouch of Gold", Wallet.Kind.GOLD, 5000),
		_pack("gold.medium", "Chest of Gold", Wallet.Kind.GOLD, 16000, 2000),
		_pack("gold.large", "Hoard of Gold", Wallet.Kind.GOLD, 45000, 10000),

		# --- gems: unlock a champion you CHOOSE ---------------------------
		_pack("gems.small", "Handful of Gems", Wallet.Kind.GEMS, 50),
		_pack("gems.medium", "Casket of Gems", Wallet.Kind.GEMS, 160, 20),
		_pack("gems.large", "Vault of Gems", Wallet.Kind.GEMS, 420, 90),

		# --- spawn crystals: RANDOM champion. Odds disclosure required. ---
		_pack("crystals.single", "Spawn Crystal", Wallet.Kind.CRYSTALS, 1),
		_pack("crystals.ten", "Crystal Cluster", Wallet.Kind.CRYSTALS, 10, 1),
		_pack("crystals.thirty", "Crystal Geode", Wallet.Kind.CRYSTALS, 30, 5),
	]


static func by_id(product_id: String) -> Pack:
	for p in all():
		if (p as Pack).product_id == product_id:
			return p
	return null


## Apply a VERIFIED purchase. The caller must have validated the StoreKit
## receipt first — this function deliberately knows nothing about payment, so
## there is no path where a client-side claim grants currency on its own.
##
## NOT IDEMPOTENT ON ITS OWN, and deliberately so: nothing here could tell two
## taps of one button from two genuine purchases. `Store.redeem()` owns that
## decision, keyed on the transaction id, and is the only caller. `transaction_id`
## is threaded through purely so the wallet ledger names the receipt that paid —
## when a player writes in, "iap:...#2000000912345678" is the thing that can be
## looked up in App Store Connect.
static func grant(roster: Roster, product_id: String,
		transaction_id: String = "") -> bool:
	var p: Pack = by_id(product_id)
	if p == null:
		push_error("IAPCatalog: unknown product " + product_id)
		return false
	var why: String = "iap:" + product_id
	if not transaction_id.is_empty():
		why += "#" + transaction_id
	roster.wallet.grant(p.kind, p.total(), why)
	# A bundled crystal payout is a second currency out of one purchase, so it
	# is a second ledger line under the same receipt.
	if p.kind != Wallet.Kind.CRYSTALS and p.crystals_bonus > 0:
		roster.wallet.grant(Wallet.Kind.CRYSTALS, p.crystals_bonus, why)
	return true


## Every product that may not be shown without the odds screen. Covers any pack
## that pays out crystals, including a non-crystal bundle that throws some in.
static func products_needing_disclosure() -> PackedStringArray:
	var out := PackedStringArray()
	for p in all():
		if pack_needs_disclosure(p as Pack):
			out.append((p as Pack).product_id)
	return out
