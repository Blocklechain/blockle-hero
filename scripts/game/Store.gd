class_name Store
extends Node
# ------------------------------------------------------------------------------
# The one seam between money and currency. Everything the game knows about
# buying anything goes through this node: the product list, the localized price
# string, the loot-box odds gate, and the single idempotent grant.
#
# WHAT IS REAL AND WHAT IS NOT — stated plainly, because an honest seam that
# looks like a working purchase path is worse than no seam at all:
#
#   REAL   the catalogue, the odds disclosure and the refusal to buy a crystal
#          pack without it, the receipt-keyed grant that cannot run twice, the
#          rule that currency only ever enters from a backend event, and the
#          simulated backend used in the editor.
#
#   NOT REAL — NO STOREKIT SHIPS IN THIS REPOSITORY. Godot 4.7 has no in-app
#          purchase API of its own, so a device build cannot transact until the
#          iOS `InAppStore` plugin is added to the export. Until that day
#          `available()` is false on iOS and the UI must present the store as
#          unavailable. There is deliberately no fallback that "pretends" — a
#          button that takes a tap and hands out gems for free is both a
#          revenue hole and a review rejection.
#
#   NOT REAL — RECEIPT VALIDATION. `redeem()` trusts the backend event it is
#          handed. Nothing here verifies an App Store signature, because there
#          is no server to verify it against: this game's save file is local and
#          its currency is local with it. A jailbroken device can therefore mint
#          currency, which is accepted for consumables in a single-player game
#          and is exactly why `IAPCatalog` says the balance is not
#          authoritative. Do NOT reuse this seam for anything tradable between
#          players without server-side verification against the App Store
#          Server API first.
#
# THE INVARIANT, in one sentence: `IAPCatalog.grant()` runs at most once per
# StoreKit transaction id, ever, on this device. The store re-delivers every
# transaction until the app finishes it — and again after a reinstall — so
# "grant on delivery" without a record pays out the same purchase repeatedly.
# The record is the transaction-id list inside `user://roster.json` (see
# `Roster.redeemed_txns`), never a second file, because two files can disagree
# and the disagreement always resolves in favour of granting again.
# ------------------------------------------------------------------------------

## The singleton an iOS in-app-purchase plugin must register. The contract this
## node is written against is the godot-ios-plugins `InAppStore` one:
##
##   set_auto_finish_transaction(bool)
##   request_product_info({"product_ids": PackedStringArray})
##   purchase({"product_id": String})     -> OK / error
##   finish_transaction(product_id: String)
##   get_pending_event_count() / pop_pending_event() -> Dictionary
##
## Auto-finish is switched OFF: the app must finish a transaction only after the
## grant is on disk, or a crash in between loses a purchase the player paid for.
const NATIVE_SINGLETON: String = "InAppStore"

## Returned by `redeem()` when a transaction has already paid out. Not an error
## the player should ever see — it is the normal result of the store re-offering
## an unfinished transaction.
const ALREADY_GRANTED: String = "Already granted"

enum BackendKind { NONE, NATIVE, SIMULATED }

## A purchase completed and the currency is in the wallet (already saved).
signal purchase_granted(product_id: String, transaction_id: String)
## A purchase did not happen, with a reason fit to show the player.
signal purchase_refused(product_id: String, reason: String)
## Localized price strings arrived (or changed). Until this fires, no price.
signal prices_updated()
## No purchase is possible at all. `reason` is fit to show the player.
signal store_unavailable(reason: String)

## The account the grant lands in. Without it nothing can be redeemed.
var roster: Roster = null

## Write the save file after a grant. Only ever false in tests — a real purchase
## that is not on disk before the transaction is finished is a lost purchase.
var autosave: bool = true

var _backend: int = BackendKind.NONE
var _impl: Backend = null
var _unavailable_reason: String = "The store has not been opened yet."
## product_id -> localized price string, straight from the store. Never built
## locally: a hardcoded "$4.99" is wrong in every other currency on earth.
var _prices: Dictionary = {}
## product_id -> true while a purchase is with the store, so a double tap cannot
## open two payment sheets for the same pack.
var _in_flight: Dictionary = {}


static func for_account(account: Roster) -> Store:
	var s := Store.new()
	s.name = "Store"
	s.roster = account
	return s


# ------------------------------------------------------------------------------
# Availability
# ------------------------------------------------------------------------------

## Pick the backend and ask for prices. Safe to call again (on resume, say).
func begin() -> void:
	_choose_backend()
	if _impl == null:
		store_unavailable.emit(_unavailable_reason)
		return
	_impl.request_prices(product_ids())


func available() -> bool:
	return _impl != null


func unavailable_reason() -> String:
	return "" if available() else _unavailable_reason


func backend() -> int:
	return _backend


# The platform decides, never a setting. The simulated backend must be
# unreachable in anything a player could install: it is debug builds only, and
# iOS always takes the native path even when that path is missing, so a release
# build can never hand out currency for free.
func _choose_backend() -> void:
	_impl = null
	if OS.get_name() == "iOS":
		if not Engine.has_singleton(NATIVE_SINGLETON):
			_backend = BackendKind.NONE
			_unavailable_reason = "In-app purchases are unavailable in this build."
			return
		var native := NativeBackend.new(Engine.get_singleton(NATIVE_SINGLETON))
		if not native.available():
			_backend = BackendKind.NONE
			_unavailable_reason = native.why
			return
		_backend = BackendKind.NATIVE
		_impl = native
		return

	if OS.is_debug_build():
		_backend = BackendKind.SIMULATED
		_impl = SimulatedBackend.new()
		return

	_backend = BackendKind.NONE
	_unavailable_reason = "In-app purchases are only available on iOS."


## The editor/desktop backend, for anyone who needs it in a test or a tool.
## Null unless `begin()` chose it, which only happens in a debug build.
func simulated() -> SimulatedBackend:
	return _impl as SimulatedBackend


# ------------------------------------------------------------------------------
# Products and prices
# ------------------------------------------------------------------------------

static func product_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for p in IAPCatalog.all():
		out.append((p as IAPCatalog.Pack).product_id)
	return out


## The store's own localized price, or "" if it has not arrived. An empty string
## means DO NOT OFFER: the UI has nothing truthful to put on the button.
func price_text(product_id: String) -> String:
	return String(_prices.get(product_id, ""))


## "" when the pack may be presented for sale, otherwise the reason it may not,
## phrased for the player. The UI should disable rather than hide, so a pack
## does not silently vanish from a list people have learned the shape of.
func offer_blocked_reason(product_id: String) -> String:
	var p: IAPCatalog.Pack = IAPCatalog.by_id(product_id)
	if p == null:
		return "This pack is no longer available."
	if not available():
		return _unavailable_reason
	if price_text(product_id).is_empty():
		return "Price unavailable."
	if IAPCatalog.pack_needs_disclosure(p):
		# Selling a loot box whose published odds cannot be met is worse than
		# not selling it. Both halves are checked: the table has to be a real
		# distribution, and every tier in it has to have a champion to pay out.
		if not CrystalOdds.sums_to_one():
			return "Spawn crystals are unavailable."
		if not odds_are_payable():
			return "Spawn crystals are unavailable."
	return ""


func can_offer(product_id: String) -> bool:
	return offer_blocked_reason(product_id).is_empty()


## Does the roster actually contain a champion at every tier the odds publish?
## If not, `Roster.open_crystal()` refunds instead of paying out, and the
## published odds would be a number the game cannot honour.
func odds_are_payable() -> bool:
	if roster == null:
		return false
	for tier in CrystalOdds.ODDS.keys():
		if CrystalOdds.odds_for(tier) <= 0.0:
			continue
		if Champion.of_rarity(roster.catalogue, tier).is_empty():
			return false
	return true


# ------------------------------------------------------------------------------
# Loot-box odds disclosure — Guideline 3.1.1
# ------------------------------------------------------------------------------
# Every number below is read out of CrystalOdds at call time. None of it is
# typed in twice. That is the whole point: a disclosure screen that keeps its
# own copy of the odds is a disclosure screen that will eventually be wrong,
# and wrong published odds are the rejection (or the regulator), not the typo.

## One row per champion tier, rarest first, ready to lay out in a table:
##   tier            Item.Rarity
##   name            "Legendary"
##   probability     0.01
##   percent         "1.00%"
##   duplicate_gold  what it converts to if already owned
static func odds_rows() -> Array[Dictionary]:
	var tiers: Array = CrystalOdds.ODDS.keys()
	tiers.sort()
	tiers.reverse()
	var rows: Array[Dictionary] = []
	for tier in tiers:
		var pr: float = CrystalOdds.odds_for(tier)
		rows.append({
			"tier": int(tier),
			"name": String(Item.RARITY_NAMES.get(tier, "?")),
			"probability": pr,
			"percent": "%.2f%%" % (pr * 100.0),
			"duplicate_gold": int(Champion.DUPLICATE_GOLD.get(tier, 0)),
		})
	return rows


## What the published rates add up to. Shown to nobody; asserted by the test,
## because a table that does not sum to 1 is a table that is lying about one of
## its tiers.
static func odds_total() -> float:
	var total: float = 0.0
	for tier in CrystalOdds.ODDS.keys():
		total += CrystalOdds.odds_for(tier)
	return total


## The pity guarantee's own odds. A guaranteed Epic-or-better is still a random
## outcome, so the split between Epic and Legendary on that crystal is disclosed
## too — an undisclosed pity timer is an undisclosed odd. Derived the same way
## `CrystalOdds.roll_rarity()` derives it, from the base weights.
static func pity_rows() -> Array[Dictionary]:
	var e: float = CrystalOdds.odds_for(Item.Rarity.EPIC)
	var l: float = CrystalOdds.odds_for(Item.Rarity.LEGENDARY)
	var denom: float = maxf(e + l, 0.0001)
	var rows: Array[Dictionary] = []
	for pair in [[Item.Rarity.LEGENDARY, l], [Item.Rarity.EPIC, e]]:
		var pr: float = float(pair[1]) / denom
		rows.append({
			"tier": int(pair[0]),
			"name": String(Item.RARITY_NAMES.get(pair[0], "?")),
			"probability": pr,
			"percent": "%.2f%%" % (pr * 100.0),
		})
	return rows


## The odds table as display lines, rarest first.
static func odds_table_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for r in odds_rows():
		out.append("%-10s  %7s   duplicate pays %d Gold" % [
			r["name"], r["percent"], r["duplicate_gold"]])
	return out


## Where the player stands against the guarantee right now. This is part of the
## disclosure, not a courtesy: the base rates are not the player's real odds on
## their next crystal if the pity counter is nearly full.
func pity_progress_text() -> String:
	if roster == null:
		return ""
	var since: int = maxi(roster.crystals_since_epic, 0)
	var left: int = maxi(CrystalOdds.PITY_THRESHOLD - since, 1)
	if left <= 1:
		return "Your next spawn crystal is the guaranteed Epic or better."
	return "You have opened %d crystals since your last Epic or better. The guarantee lands within %d more." \
		% [since, left]


## The screen a crystal pack may not be sold without. `product_id` is optional:
## pass it and the text names the pack and how many draws it buys, which is what
## "disclosed before purchase" means in practice.
func disclosure_text(product_id: String = "") -> String:
	var lines := PackedStringArray()
	var p: IAPCatalog.Pack = IAPCatalog.by_id(product_id)
	if p != null and p.crystal_payout() > 0:
		lines.append("%s — %d spawn crystals, %d random champion draws." % [
			p.title, p.crystal_payout(), p.crystal_payout()])
		lines.append("")
	lines.append("Each spawn crystal grants one random champion.")
	lines.append("Chance of each champion tier, per crystal:")
	for line in odds_table_lines():
		lines.append("    " + line)
	lines.append("")
	lines.append("A champion of Epic tier or better is guaranteed at least once every %d crystals."
		% CrystalOdds.PITY_THRESHOLD)
	var pity := PackedStringArray()
	for r in pity_rows():
		pity.append("%s %s" % [r["name"], r["percent"]])
	lines.append("On that guaranteed crystal the champion is " + ", ".join(pity) + ".")
	var progress: String = pity_progress_text()
	if not progress.is_empty():
		lines.append(progress)
	lines.append("")
	lines.append("A champion you already own converts to Gold at the rate above.")
	lines.append("Spawn crystals are consumed when opened and cannot be restored or refunded by the app.")
	return "\n".join(lines)


# ------------------------------------------------------------------------------
# Buying
# ------------------------------------------------------------------------------

## Start a purchase. Returns "" if the payment sheet was asked for, otherwise
## the reason it was not — the same string that is emitted on
## `purchase_refused`, so a caller can either await the signal or read the
## return value.
##
## `odds_acknowledged` must be true for any pack that pays out crystals, and the
## only honest way to set it is from the screen that actually displayed
## `disclosure_text()`. This gate is here rather than in the UI because the UI is
## the part most likely to be rewritten.
func purchase(product_id: String, odds_acknowledged: bool = false) -> String:
	var blocked: String = offer_blocked_reason(product_id)
	if not blocked.is_empty():
		return _refuse(product_id, blocked)
	if roster == null:
		return _refuse(product_id, "No account is loaded.")

	var p: IAPCatalog.Pack = IAPCatalog.by_id(product_id)
	if IAPCatalog.pack_needs_disclosure(p) and not odds_acknowledged:
		return _refuse(product_id,
			"The spawn crystal odds must be shown before purchase.")
	if _in_flight.has(product_id):
		return _refuse(product_id, "This purchase is already in progress.")

	_in_flight[product_id] = true
	_impl.begin_purchase(product_id)
	return ""


## Pay out a verified transaction, exactly once. Returns "" when this call is
## what granted it, `ALREADY_GRANTED` when an earlier one did, or a reason.
##
## Both halves — the transaction-id record and the currency — live in the same
## Roster and are written by the same `save()`, so there is no window where one
## landed and the other did not. A crash before the save loses both, and the
## store re-delivers the transaction because it was never finished.
func redeem(product_id: String, transaction_id: String) -> String:
	if roster == null:
		return "No account is loaded."
	if transaction_id.is_empty():
		# No id means no idempotency key, and no idempotency key means we cannot
		# promise to grant only once. Refusing is the safe direction.
		return "This purchase has no transaction id."
	if IAPCatalog.by_id(product_id) == null:
		return "This pack is no longer available."
	if roster.has_redeemed(transaction_id):
		return ALREADY_GRANTED

	roster.mark_redeemed(transaction_id)
	if not IAPCatalog.grant(roster, product_id, transaction_id):
		return "This pack is no longer available."
	if autosave and not roster.save():
		# Deliberately not finishing the transaction: leaving it open is what
		# makes the store hand it back next launch, which is the only way the
		# player ever sees this purchase again.
		push_error("Store: granted %s but could not save; transaction left open"
			% product_id)
		return ""
	_finish(transaction_id)
	return ""


# ------------------------------------------------------------------------------
# Backend events
# ------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	poll()


## Drain whatever the backend has queued. Called from `_process` when this node
## is in the tree, and directly by tools and tests. Returns how many events were
## handled.
func poll() -> int:
	if _impl == null:
		return 0
	var events: Array[Dictionary] = _impl.drain()
	for e in events:
		_handle(e)
	return events.size()


func _handle(e: Dictionary) -> void:
	match String(e.get("type", "")):
		"prices":
			var got: Dictionary = e.get("prices", {})
			for k in got.keys():
				_prices[String(k)] = String(got[k])
			prices_updated.emit()
		"purchased":
			var pid: String = String(e.get("product", ""))
			var txn: String = String(e.get("txn", ""))
			_in_flight.erase(pid)
			var reason: String = redeem(pid, txn)
			if reason.is_empty():
				purchase_granted.emit(pid, txn)
			elif reason == ALREADY_GRANTED:
				# A re-delivered transaction. Finish it so the store stops
				# offering it, and say nothing: the player bought this, has it,
				# and does not need an error about it.
				_finish(txn)
			else:
				purchase_refused.emit(pid, reason)
		"failed":
			var fid: String = String(e.get("product", ""))
			_in_flight.erase(fid)
			purchase_refused.emit(fid, String(e.get("reason", "")))
		_:
			push_warning("Store: ignoring unknown store event " + str(e))


func _finish(transaction_id: String) -> void:
	if _impl != null:
		_impl.finish(transaction_id)


func _refuse(product_id: String, reason: String) -> String:
	purchase_refused.emit(product_id, reason)
	return reason


# ------------------------------------------------------------------------------
# Backends
#
# The payment mechanism, behind five calls. A backend reports results ONLY by
# queueing events for `drain()` and never by returning them, because the native
# one cannot answer synchronously — a payment sheet takes as long as the player
# takes. Everything above this line is therefore identical for both.
# ------------------------------------------------------------------------------

class Backend extends RefCounted:
	## Why this backend cannot be used, in words fit to show the player.
	var why: String = ""

	func available() -> bool:
		return false

	func request_prices(_ids: PackedStringArray) -> void:
		pass

	func begin_purchase(_product_id: String) -> void:
		pass

	## Tell the store the goods are delivered. Called only once the grant is on
	## disk — until then the transaction has to stay open, because an open
	## transaction is the only thing that brings a lost purchase back.
	func finish(_transaction_id: String) -> void:
		pass

	func drain() -> Array[Dictionary]:
		return []


## The editor and desktop backend. SIMULATED: it takes no payment, talks to
## nothing, and is unreachable outside a debug build (see `_choose_backend`).
## Its price string says so in words rather than showing a currency amount,
## because a fake "$4.99" in a screenshot is how a fake price reaches a store
## listing.
class SimulatedBackend extends Backend:
	const PRICE_TEXT: String = "Simulated purchase, no charge"

	## Set to make the next `begin_purchase` report a failure instead, so the
	## cancel path can be exercised without a device.
	var fail_next: bool = false
	var finished: PackedStringArray = PackedStringArray()

	var _events: Array[Dictionary] = []
	var _issued: int = 0
	var _last: Dictionary = {}

	func available() -> bool:
		return true

	func request_prices(ids: PackedStringArray) -> void:
		var prices: Dictionary = {}
		for id in ids:
			prices[id] = PRICE_TEXT
		_events.append({"type": "prices", "prices": prices})

	func begin_purchase(product_id: String) -> void:
		if fail_next:
			fail_next = false
			_events.append({"type": "failed", "product": product_id,
				"reason": "The purchase was cancelled."})
			return
		_issued += 1
		_last = {"type": "purchased", "product": product_id,
			"txn": "sim-%d-%s" % [_issued, product_id]}
		_events.append(_last.duplicate())

	## Hand the previous purchase back again, exactly as StoreKit does with a
	## transaction the app never finished. The only way to test the invariant
	## that matters without a device.
	func redeliver_last() -> void:
		if not _last.is_empty():
			_events.append(_last.duplicate())

	func finish(transaction_id: String) -> void:
		finished.append(transaction_id)

	func drain() -> Array[Dictionary]:
		var out: Array[Dictionary] = _events
		_events = []
		return out


## The iOS path. UNEXERCISED: no plugin in this repository registers the
## singleton, so this class has never run against a real StoreKit. It is written
## against the documented `InAppStore` contract listed at the top of this file
## and checks for every method it needs up front, so a plugin with a different
## API makes the store unavailable instead of crashing mid-purchase.
class NativeBackend extends Backend:
	const REQUIRED: Array[String] = [
		"set_auto_finish_transaction", "request_product_info", "purchase",
		"finish_transaction", "get_pending_event_count", "pop_pending_event"]

	## Untyped on purpose: the plugin registers this singleton at runtime, so
	## there is no class to type it against and every call below is a dynamic
	## one guarded by the `REQUIRED` check in `_init`.
	var _s = null
	## transaction id -> product id. StoreKit's `finish_transaction` takes the
	## product while everything above keys on the transaction, so the mapping
	## has to be kept on this side.
	var _txn_products: Dictionary = {}

	func _init(singleton: Object) -> void:
		for m in REQUIRED:
			if singleton == null or not singleton.has_method(m):
				why = "In-app purchases are unavailable in this build."
				return
		_s = singleton
		# Finishing is ours to do, after the grant is on disk.
		_s.set_auto_finish_transaction(false)

	func available() -> bool:
		return _s != null

	func request_prices(ids: PackedStringArray) -> void:
		if _s != null:
			_s.request_product_info({"product_ids": ids})

	func begin_purchase(product_id: String) -> void:
		if _s != null:
			_s.purchase({"product_id": product_id})

	func finish(transaction_id: String) -> void:
		if _s == null:
			return
		var product: String = String(_txn_products.get(transaction_id, ""))
		if product.is_empty():
			push_warning("Store: no product for transaction " + transaction_id)
			return
		_s.finish_transaction(product)
		_txn_products.erase(transaction_id)

	func drain() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		if _s == null:
			return out
		while int(_s.get_pending_event_count()) > 0:
			var raw = _s.pop_pending_event()
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			var ev: Dictionary = _translate(raw)
			if not ev.is_empty():
				out.append(ev)
		return out

	# StoreKit's event shape, mapped onto ours. Unknown events are dropped
	# rather than guessed at.
	func _translate(raw: Dictionary) -> Dictionary:
		var kind: String = String(raw.get("type", ""))
		var ok: bool = String(raw.get("result", "")) == "ok"
		if kind == "product_info":
			var ids: Array = raw.get("ids", [])
			var prices: Array = raw.get("localized_prices", [])
			var out: Dictionary = {}
			for i in range(mini(ids.size(), prices.size())):
				out[String(ids[i])] = String(prices[i])
			return {"type": "prices", "prices": out}
		if kind == "purchase":
			var pid: String = String(raw.get("product_id", ""))
			if not ok:
				return {"type": "failed", "product": pid,
					"reason": "The purchase did not complete."}
			var txn: String = String(raw.get("transaction_id", ""))
			_txn_products[txn] = pid
			return {"type": "purchased", "product": pid, "txn": txn}
		return {}
