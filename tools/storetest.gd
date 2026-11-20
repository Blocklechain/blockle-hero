extends SceneTree
# Proves the purchase seam. Three things are being defended here, in order of
# how much they would cost to get wrong:
#
#   1. LOOT-BOX ODDS. Every number on the disclosure screen is recomputed from
#      CrystalOdds here and compared character for character, so a tuning change
#      that leaves the published odds behind fails this test instead of shipping
#      wrong numbers to App Review.
#   2. GRANT ONCE. A transaction id pays out exactly once, including when the
#      store re-delivers it and including across a save/load.
#   3. NO FREE CURRENCY. Nothing grants without a backend event, and no pack is
#      offered without a real price behind it.

var fails: int = 0

func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	var heroes: PackedStringArray = HeroRig.animated_heroes()
	if heroes.is_empty():
		print("no hero models found"); quit(); return

	# `autosave` stays off for every Store built here: a test must never write
	# over the save file of whoever is running it.
	var roster := Roster.create(heroes, 4242)
	var store := Store.for_account(roster)
	store.autosave = false
	root.add_child(store)

	var granted: Array[String] = []
	var refused: Array[String] = []
	store.purchase_granted.connect(
		func(pid: String, txn: String) -> void: granted.append(pid + "|" + txn))
	store.purchase_refused.connect(
		func(pid: String, why: String) -> void: refused.append(pid + "|" + why))

	var crystal_pack: String = IAPCatalog.PRODUCT_PREFIX + "crystals.ten"
	var gold_pack: String = IAPCatalog.PRODUCT_PREFIX + "gold.small"

	# --- nothing is purchasable before the store is opened -------------
	print("\n=== the store is shut until it is opened ===")
	check("no backend before begin()", not store.available(),
		store.unavailable_reason())
	check("no price before begin()", store.price_text(crystal_pack).is_empty())
	check("purchase refused with no backend",
		not store.purchase(crystal_pack, true).is_empty(),
		refused[-1] if refused.size() > 0 else "")
	check("...and granted nothing", roster.wallet.crystals == 0)

	store.begin()
	store.poll()
	print("  backend: %s   native singleton present: %s" % [
		"simulated" if store.backend() == Store.BackendKind.SIMULATED
		else ("native" if store.backend() == Store.BackendKind.NATIVE else "none"),
		Engine.has_singleton(Store.NATIVE_SINGLETON)])
	check("a debug desktop run gets the SIMULATED backend",
		store.backend() == Store.BackendKind.SIMULATED and store.available())
	check("prices arrive from the backend, not from the code",
		store.price_text(gold_pack) == Store.SimulatedBackend.PRICE_TEXT,
		store.price_text(gold_pack))
	check("no currency amount is ever invented locally",
		not store.price_text(gold_pack).contains("$"))

	# --- the odds disclosure, recomputed ------------------------------
	print("\n=== published odds vs the CrystalOdds table ===")
	var rows: Array[Dictionary] = Store.odds_rows()
	var text: String = store.disclosure_text(crystal_pack)
	check("one row per tier in the table",
		rows.size() == CrystalOdds.ODDS.size(),
		"%d rows, %d tiers" % [rows.size(), CrystalOdds.ODDS.size()])

	var all_match: bool = true
	var in_text: bool = true
	var agrees_with_crystalodds: bool = true
	var ordered: bool = true
	var last_tier: int = Item.Rarity.LEGENDARY + 1
	for r in rows:
		var tier: int = int(r["tier"])
		var want: float = CrystalOdds.odds_for(tier)
		var shown: float = String(r["percent"]).rstrip("%").to_float() / 100.0
		var exact: bool = absf(float(r["probability"]) - want) < 1e-12
		var printed: bool = absf(shown - want) < 0.00005
		if not (exact and printed):
			all_match = false
		if not text.contains(String(r["name"])) \
				or not text.contains(String(r["percent"])):
			in_text = false
		# The pre-existing CrystalOdds.disclosure_text() is an independent
		# formatting of the same table. If either one ever grows its own copy of
		# the numbers, these two stop agreeing.
		if not CrystalOdds.disclosure_text().contains(String(r["percent"])):
			agrees_with_crystalodds = false
		if tier >= last_tier:
			ordered = false
		last_tier = tier
		print("    %-10s %7s  table %7.4f  duplicate %5d Gold" % [
			r["name"], r["percent"], want, int(r["duplicate_gold"])])
	check("every printed percentage IS the table's own number", all_match)
	check("every tier and percentage appears in the disclosure text", in_text)
	check("CrystalOdds' own disclosure prints the same numbers",
		agrees_with_crystalodds)
	check("rows read rarest first", ordered)
	check("the published rates sum to 1.0",
		absf(Store.odds_total() - 1.0) < 0.0001 and CrystalOdds.sums_to_one(),
		"sum %.6f" % Store.odds_total())

	# --- the pity rule is an odd, so it is disclosed too --------------
	print("\n=== the pity guarantee is disclosed ===")
	check("the threshold is stated",
		text.contains(str(CrystalOdds.PITY_THRESHOLD)),
		"every %d crystals" % CrystalOdds.PITY_THRESHOLD)
	var pity: Array[Dictionary] = Store.pity_rows()
	var e: float = CrystalOdds.odds_for(Item.Rarity.EPIC)
	var l: float = CrystalOdds.odds_for(Item.Rarity.LEGENDARY)
	var pity_sum: float = 0.0
	var pity_ok: bool = true
	for r in pity:
		pity_sum += float(r["probability"])
		var want: float = (l if int(r["tier"]) == Item.Rarity.LEGENDARY else e) \
			/ maxf(e + l, 0.0001)
		if absf(float(r["probability"]) - want) > 1e-9:
			pity_ok = false
		if not text.contains(String(r["percent"])):
			pity_ok = false
		print("    guaranteed crystal: %-10s %7s" % [r["name"], r["percent"]])
	check("the guaranteed crystal's own split is published and exact",
		pity_ok and absf(pity_sum - 1.0) < 0.0001, "sum %.4f" % pity_sum)

	roster.crystals_since_epic = CrystalOdds.PITY_THRESHOLD - 1
	check("the player's live pity progress is disclosed",
		store.pity_progress_text().contains("guaranteed"),
		store.pity_progress_text())
	roster.crystals_since_epic = 3
	check("...and reflects the real counter",
		store.pity_progress_text().contains("3"),
		store.pity_progress_text())

	# --- which products the disclosure covers -------------------------
	print("\n=== disclosure covers every random-champion pack ===")
	var needing: PackedStringArray = IAPCatalog.products_needing_disclosure()
	var covered: bool = true
	var flag_matches_rule: bool = true
	for p in IAPCatalog.all():
		var pack: IAPCatalog.Pack = p as IAPCatalog.Pack
		var random: bool = pack.crystal_payout() > 0
		if random != needing.has(pack.product_id):
			covered = false
		if pack.requires_odds_disclosure != IAPCatalog.pack_needs_disclosure(pack):
			flag_matches_rule = false
	check("flagged if and only if the pack pays out crystals", covered,
		", ".join(needing))
	check("the stored flag cannot drift from the rule", flag_matches_rule)
	check("gem and gold packs are NOT loot boxes",
		not needing.has(gold_pack)
		and not needing.has(IAPCatalog.PRODUCT_PREFIX + "gems.large"))

	# A bundle is the drift that would actually happen: gold as the headline
	# currency with a few crystals thrown in. It must be a loot box by payout,
	# with nobody having to remember to say so.
	var bundle := IAPCatalog.Pack.new()
	bundle.product_id = IAPCatalog.PRODUCT_PREFIX + "bundle.test"
	bundle.kind = Wallet.Kind.GOLD
	bundle.amount = 5000
	bundle.crystals_bonus = 2
	check("a gold bundle carrying crystals needs the odds screen",
		IAPCatalog.pack_needs_disclosure(bundle) and bundle.crystal_payout() == 2)

	# --- the gate ------------------------------------------------------
	print("\n=== a crystal pack cannot be bought past the odds screen ===")
	var before: int = roster.wallet.crystals
	var blocked: String = store.purchase(crystal_pack)
	check("refused without acknowledgement", blocked.to_lower().contains("odds"),
		blocked)
	check("...and nothing was granted", roster.wallet.crystals == before)
	check("gold needs no odds screen", store.purchase(gold_pack).is_empty())
	store.poll()
	check("the gold purchase paid out",
		roster.wallet.gold > 250, "%d gold" % roster.wallet.gold)

	var pack_total: int = IAPCatalog.by_id(crystal_pack).total()
	check("accepted with acknowledgement",
		store.purchase(crystal_pack, true).is_empty())
	check("a second tap is refused while the first is in flight",
		not store.purchase(crystal_pack, true).is_empty(), refused[-1])
	store.poll()
	check("the crystal pack paid out once, in full",
		roster.wallet.crystals == before + pack_total,
		"%d -> %d crystals" % [before, roster.wallet.crystals])
	check("a grant is announced", granted.size() == 2,
		", ".join(granted))

	# --- grant once, no matter how often it is delivered --------------
	print("\n=== one transaction grants once ===")
	var sim: Store.SimulatedBackend = store.simulated()
	var held: int = roster.wallet.crystals
	var redeemed_before: int = roster.redeemed_txns.size()
	var complaints: int = refused.size()
	sim.redeliver_last()
	store.poll()
	check("a RE-DELIVERED transaction grants nothing",
		roster.wallet.crystals == held
		and roster.redeemed_txns.size() == redeemed_before,
		"%d crystals, %d receipts" % [roster.wallet.crystals,
			roster.redeemed_txns.size()])
	check("...and is finished so the store stops offering it",
		sim.finished.size() >= 3, "%d finished" % sim.finished.size())
	# A purchase the player made last week, re-offered by the store, must not
	# produce an error message about a purchase they already have.
	check("no error was shown for it", refused.size() == complaints,
		"%d refusals before, %d after" % [complaints, refused.size()])

	var manual: String = "2000000912345678"
	check("a direct redeem grants", store.redeem(gold_pack, manual).is_empty())
	var gold_after: int = roster.wallet.gold
	check("the same id again grants nothing",
		store.redeem(gold_pack, manual) == Store.ALREADY_GRANTED
		and roster.wallet.gold == gold_after, "%d gold" % gold_after)
	check("a purchase with no transaction id is refused",
		not store.redeem(gold_pack, "").is_empty(),
		store.redeem(gold_pack, ""))
	check("an unknown product is refused",
		not store.redeem("org.blockle.hero.nope", "txn-nope").is_empty())
	check("the receipt is in the wallet ledger",
		JSON.stringify(roster.wallet.ledger).contains("iap:%s#%s"
			% [gold_pack, manual]))

	# --- it survives the save file ------------------------------------
	print("\n=== the record is in the one save file ===")
	var reloaded := Roster.from_dict(roster.to_dict(), heroes)
	check("transaction ids survive save/load",
		reloaded.redeemed_txns.size() == roster.redeemed_txns.size()
		and reloaded.has_redeemed(manual),
		"%d receipts" % reloaded.redeemed_txns.size())
	var store2 := Store.for_account(reloaded)
	store2.autosave = false
	root.add_child(store2)
	store2.begin()
	store2.poll()
	var reloaded_gold: int = reloaded.wallet.gold
	check("a reload cannot re-grant a past transaction",
		store2.redeem(gold_pack, manual) == Store.ALREADY_GRANTED
		and reloaded.wallet.gold == reloaded_gold)
	check("the save carries no second purchase file",
		roster.to_dict().has("iap_txns"))

	var capped := Roster.create(heroes, 7)
	for i in range(Roster.REDEEMED_MAX + 120):
		capped.mark_redeemed("txn-%d" % i)
	check("the receipt list is bounded",
		capped.redeemed_txns.size() == Roster.REDEEMED_MAX,
		"%d kept" % capped.redeemed_txns.size())
	check("...keeping the newest",
		capped.has_redeemed("txn-%d" % (Roster.REDEEMED_MAX + 119)))

	# --- a refused payment pays out nothing ---------------------------
	print("\n=== a cancelled payment ===")
	var gold_before: int = roster.wallet.gold
	var told: int = refused.size()
	sim.fail_next = true
	check("the purchase starts", store.purchase(gold_pack).is_empty())
	store.poll()
	check("a cancelled payment grants nothing",
		roster.wallet.gold == gold_before, "%d gold" % gold_before)
	check("...and is reported to the player", refused.size() == told + 1,
		refused[-1] if refused.size() > 0 else "")
	check("the pack can be bought again after a cancellation",
		store.purchase(gold_pack).is_empty())
	store.poll()

	# --- never sell a loot box the game cannot honour -----------------
	print("\n=== odds that cannot be paid are not sold ===")
	check("the real roster can pay out every published tier",
		store.odds_are_payable())
	var thin := Roster.new()
	# Commons only, so the Legendary rate the disclosure prints is unachievable
	# and `Roster.open_crystal()` would refund instead of paying out.
	thin.catalogue = Champion.of_rarity(heroes, Item.Rarity.COMMON)
	var store3 := Store.for_account(thin)
	store3.autosave = false
	root.add_child(store3)
	store3.begin()
	store3.poll()
	check("a catalogue missing a tier cannot sell crystals",
		not store3.odds_are_payable()
		and not store3.offer_blocked_reason(crystal_pack).is_empty(),
		store3.offer_blocked_reason(crystal_pack))
	check("...but gold is still for sale", store3.can_offer(gold_pack))

	print("\n=== the disclosure screen, as the player sees it ===")
	print(store.disclosure_text(crystal_pack))

	print("\n=== %d failure(s) ===" % fails)
	quit()
