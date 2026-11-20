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
#     pack therefore carries `requires_odds_disclosure = true`, and the store UI
#     must refuse to present such a pack without showing
#     CrystalOdds.disclosure_text(). `tools/oddstest.gd` asserts both that the
#     flag is set and that the published numbers match the actual roll.
#
# Prices here are the tier NAMES, not amounts — the real price comes from App
# Store Connect at runtime and must be displayed from the StoreKit product, not
# from a hardcoded string, or the app lies to players in other currencies.
# ------------------------------------------------------------------------------

const PRODUCT_PREFIX: String = "org.blockle.hero."

class Pack extends RefCounted:
	var product_id: String = ""
	var title: String = ""
	var kind: int = Wallet.Kind.GOLD
	var amount: int = 0
	## Extra granted on top of `amount`, for the larger packs.
	var bonus: int = 0
	var requires_odds_disclosure: bool = false

	func total() -> int:
		return amount + bonus

	func describe() -> String:
		var b: String = "  (+%d bonus)" % bonus if bonus > 0 else ""
		return "%-34s %-22s %5d %s%s" % [product_id, title, total(),
			String(Wallet.KIND_NAMES[kind]), b]


static func _pack(id: String, title: String, kind: int, amount: int,
		bonus: int = 0) -> Pack:
	var p := Pack.new()
	p.product_id = PRODUCT_PREFIX + id
	p.title = title
	p.kind = kind
	p.amount = amount
	p.bonus = bonus
	# Crystals are the randomised product. Gems can BUY crystals indirectly, but
	# a gem itself buys a champion the player picks, so it is not a random draw.
	p.requires_odds_disclosure = kind == Wallet.Kind.CRYSTALS
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
static func grant(roster: Roster, product_id: String) -> bool:
	var p: Pack = by_id(product_id)
	if p == null:
		push_error("IAPCatalog: unknown product " + product_id)
		return false
	roster.wallet.grant(p.kind, p.total(), "iap:" + product_id)
	return true


## Every product that may not be shown without the odds screen.
static func products_needing_disclosure() -> PackedStringArray:
	var out := PackedStringArray()
	for p in all():
		if (p as Pack).requires_odds_disclosure:
			out.append((p as Pack).product_id)
	return out
