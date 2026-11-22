extends SceneTree
# ------------------------------------------------------------------------------
# THE PRODUCTS THAT HAVE TO EXIST IN APP STORE CONNECT, AND THE CHECK THAT THE
# APP IS ASKING FOR THE RIGHT ONES.
#
# An in-app purchase has two halves that live in different places: the
# catalogue in IAPCatalog.gd, and nine records a human creates by hand in App
# Store Connect. If the two disagree by one character, StoreKit returns no
# product for that id, Store.price_text() stays empty, and the row is disabled
# forever with "Price unavailable" — on a shipped build, for everyone, with no
# error anywhere. It is not a crash and no test of either half alone can see
# it.
#
# Two things here:
#
#   1. A CHECK, run in CI. Product ids must be prefixed with the bundle
#      identifier out of export_presets.cfg, because App Store Connect will
#      not accept an id outside the app's own namespace — so a renamed bundle
#      silently invalidates all nine products, and the first sign of it is a
#      store that sells nothing.
#
#   2. A MANIFEST, printed. The exact strings to paste into App Store Connect,
#      generated from the catalogue rather than written out by hand, because a
#      list of product ids typed twice is a list that will differ.
#
#   godot --headless --path . --script tools/iapmanifest.gd
# ------------------------------------------------------------------------------

var _fails: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _init() -> void:
	var bundle: String = _bundle_id()
	print("\n=== the app and the catalogue agree ===")
	check("export_presets.cfg declares a bundle identifier",
		not bundle.is_empty(), bundle)

	# THE CROSS-FILE CHECK. This is the whole reason this harness exists:
	# nothing else in the project reads both files.
	check("the product prefix is the bundle id plus a dot",
		IAPCatalog.PRODUCT_PREFIX == bundle + ".",
		"'%s' vs '%s.'" % [IAPCatalog.PRODUCT_PREFIX, bundle])

	var packs: Array = IAPCatalog.all()
	check("the catalogue is not empty", not packs.is_empty(),
		"%d packs" % packs.size())

	var ids: Dictionary = {}
	var bad_prefix: int = 0
	var bad_shape: int = 0
	var unpriced: int = 0
	for pack in packs:
		var p := pack as IAPCatalog.Pack
		if p == null:
			continue
		ids[p.product_id] = int(ids.get(p.product_id, 0)) + 1
		if not p.product_id.begins_with(IAPCatalog.PRODUCT_PREFIX):
			bad_prefix += 1
		# App Store Connect product ids are alphanumerics, dots, underscores
		# and hyphens. A space or a capital in one is accepted by this code
		# and rejected by the store, which again shows up only as a product
		# that does not exist.
		for c in p.product_id:
			if not (c.is_valid_identifier() or c in ".-_" or c.is_valid_int()):
				bad_shape += 1
				break
		if p.amount <= 0:
			unpriced += 1

	check("every product id is inside the app's own namespace",
		bad_prefix == 0, "%d outside" % bad_prefix)
	check("every product id is a shape App Store Connect accepts",
		bad_shape == 0, "%d malformed" % bad_shape)
	check("no product id is declared twice", ids.size() == packs.size(),
		"%d unique of %d" % [ids.size(), packs.size()])
	check("every pack actually grants something", unpriced == 0,
		"%d grant nothing" % unpriced)

	# EVERY PACK THAT PAYS OUT A RANDOM DRAW MUST BE FLAGGED FOR DISCLOSURE.
	# Derived in IAPCatalog from the payout rather than declared, so this is
	# checking the derivation rather than a hand-maintained list — a crystal
	# pack that slipped through unflagged could be sold without the odds.
	var undisclosed: int = 0
	for pack in packs:
		var p := pack as IAPCatalog.Pack
		if p.crystal_payout() > 0 and not p.requires_odds_disclosure:
			undisclosed += 1
	check("every pack paying out a random draw requires the odds sheet",
		undisclosed == 0, "%d unflagged" % undisclosed)

	# The published odds have to be a real distribution, or the disclosure is
	# a set of numbers that do not add up.
	check("the published crystal odds sum to one", CrystalOdds.sums_to_one())

	_print_manifest(packs)

	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


## The bundle identifier the iOS export is configured with.
func _bundle_id() -> String:
	var f := FileAccess.open("res://export_presets.cfg", FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var line: String = f.get_line().strip_edges()
		if not line.begins_with("application/bundle_identifier="):
			continue
		return line.split("=", true, 1)[1].strip_edges().trim_prefix("\"") \
			.trim_suffix("\"")
	return ""


## What a human has to create in App Store Connect. Printed, not asserted:
## the records cannot be made from here, and a list of ids typed out twice is
## a list that will eventually differ.
func _print_manifest(packs: Array) -> void:
	print("\n=== App Store Connect: create these products ===")
	print("  Type for ALL of them: Consumable In-App Purchase.")
	print("  Consumables are deliberate — the currency is spent, so there is")
	print("  nothing to restore and no restore control is required.")
	print("")
	print("  %-44s %-26s %s" % ["PRODUCT ID", "REFERENCE NAME", "GRANTS"])
	for pack in packs:
		var p := pack as IAPCatalog.Pack
		if p == null:
			continue
		var grants: String = "%d %s" % [p.amount,
			String(Wallet.KIND_NAMES.get(p.kind, ""))]
		if p.bonus > 0:
			grants += " +%d bonus" % p.bonus
		if p.crystals_bonus > 0:
			grants += " +%d crystal(s)" % p.crystals_bonus
		if p.requires_odds_disclosure:
			grants += "   [random draw — odds disclosure required]"
		print("  %-44s %-26s %s" % [p.product_id, p.title, grants])
	print("")
	print("  Until those records exist AND an iOS StoreKit plugin registering")
	print("  the '%s' singleton is in the build, Store._choose_backend()"
		% Store.NATIVE_SINGLETON)
	print("  reports the store unavailable on device and the screen says so.")
	print("  That is the correct behaviour, not a bug — but it is also not a")
	print("  store that can take a payment.")
