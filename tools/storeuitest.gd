extends SceneTree
# ------------------------------------------------------------------------------
# THE STORE SCREEN, WHICH IS THE ONE SCREEN WHERE BEING WRONG COSTS MONEY.
#
# Store.gd was complete, unit-tested, and reachable from nothing: no screen in
# the game ever constructed a Store, so the app could not take a payment at
# all. storetest.gd proves the ENGINE is right. This proves the screen is
# wired to it and obeys the three rules that are both App Store requirements
# and plain honesty — each of which fails silently if it breaks:
#
#   * NO PRICE THIS APP MADE UP. Prices come from StoreKit. Before they
#     arrive the row must be unbuyable and must say why, rather than showing
#     a blank, a zero, or a number typed into the source.
#
#   * NO CRYSTAL PACK SOLD WITHOUT THE ODDS ON SCREEN FIRST (Guideline
#     3.1.1). The gate lives in Store.purchase(), which is exactly why this
#     harness attacks it from the UI side: a screen that "forgets" to pass
#     odds_acknowledged must be REFUSED, not quietly allowed.
#
#   * ONE GRANT PER TRANSACTION, FOREVER. The store re-delivers every
#     transaction until the app finishes it, and again after a reinstall.
#     Two grants for one payment is the bug that turns a currency into a
#     faucet, and nothing on screen would show it.
#
# Everything here runs on the SIMULATED backend, which takes no payment and is
# unreachable outside a debug build (Store._choose_backend). No real money and
# no device are involved, and the simulator can do the one thing a device
# cannot do on demand: hand the same transaction back twice.
# ------------------------------------------------------------------------------

const StoreScreenS := preload("res://scripts/ui/StoreScreen.gd")

var _fails: int = 0
var _ran: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _roster() -> Roster:
	return Roster.create(HeroRig.animated_heroes(), 8080)


## A store on the simulated backend.
##
## WITH `with_prices` FALSE IT IS LEFT OUT OF THE TREE, which is the only way
## to hold it in the state every real launch starts in: Store._process() polls
## the backend on every frame, so a Store that is in the tree has its prices
## the moment the harness awaits a frame — and the first version of this
## section asserted "no price yet" against a store that had already answered.
##
## The window is genuinely one frame wide in the simulator and genuinely much
## longer on a device, where asking StoreKit for prices is a network round
## trip. That is exactly why the screen has to render it correctly.
func _store(r: Roster, with_prices: bool = true) -> Store:
	var s := Store.for_account(r)
	s.autosave = false          # Never touch the player's real save file.
	if with_prices:
		root.add_child(s)
	s.begin()
	if with_prices:
		s.poll()
	return s


func _screen(r: Roster, s: Store) -> UiScreen:
	var sc: UiScreen = StoreScreenS.new()
	sc.roster = r
	sc.hero = r.owned_names()[0]
	sc.set("store", s)
	sc.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(sc)
	return sc


func _init() -> void:
	var design := Vector2i(2532, 1170)
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_size = design
	get_root().size = design
	await process_frame

	await _every_pack(); _ran += 1
	await _prices(); _ran += 1
	await _the_odds_gate(); _ran += 1
	await _buying(); _ran += 1
	await _unavailable(); _ran += 1
	await _in_the_shell(); _ran += 1
	print("")
	check("every section ran to completion", _ran == 6, "%d of 6" % _ran)
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


# ---- helpers -----------------------------------------------------------------

func _buttons(node: Node, out: Array = []) -> Array:
	if node is Button:
		out.append(node)
	for c in node.get_children():
		_buttons(c, out)
	return out


func _strings(n: Node, into: PackedStringArray = PackedStringArray()
		) -> PackedStringArray:
	if n is Label and not (n as Label).text.is_empty():
		into.append((n as Label).text)
	elif n is Button and not (n as Button).text.is_empty():
		into.append((n as Button).text)
	for c in n.get_children():
		_strings(c, into)
	return into


func _said(node: Node, needle: String) -> bool:
	for t in _strings(node):
		if t.findn(needle) >= 0:
			return true
	return false


## The buy button for a pack, by the price text it must be showing.
func _buy_buttons(screen: Node) -> Array:
	var out: Array = []
	for b in _buttons(screen):
		var t: String = (b as Button).text
		if t == Store.SimulatedBackend.PRICE_TEXT or t == "Price unavailable":
			out.append(b)
	return out


# ---- every pack is offered ---------------------------------------------------

func _every_pack() -> void:
	print("\n=== every pack is on the shelf ===")
	var r := _roster()
	var s := _store(r)
	var screen := _screen(r, s)
	await process_frame

	# EVERY PRODUCT IN THE CATALOGUE HAS A ROW. A pack declared in App Store
	# Connect and not shown here is revenue the player cannot reach; a row
	# shown here with no product behind it is a button that fails at the
	# payment sheet.
	var titled: int = 0
	for pack in IAPCatalog.all():
		if _said(screen, (pack as IAPCatalog.Pack).title):
			titled += 1
	check("every pack in the catalogue has a row",
		titled == IAPCatalog.all().size(),
		"%d of %d" % [titled, IAPCatalog.all().size()])
	check("...and there is a buy button for each",
		_buy_buttons(screen).size() == IAPCatalog.all().size(),
		"%d buttons" % _buy_buttons(screen).size())

	# WHAT THE CURRENCY DOES, said before the price. Gems buy the champion you
	# point at; crystals buy a draw. Someone about to pay has to be able to
	# tell those apart, and the difference is not obvious from the names.
	check("the screen says gems are a CHOICE", _said(screen, "CHOOSE"))
	check("...and that crystals are RANDOM", _said(screen, "RANDOM"))

	# The bonus is called out rather than folded into one number.
	var bonus_shown: bool = false
	for pack in IAPCatalog.all():
		var p := pack as IAPCatalog.Pack
		if p.bonus > 0 and _said(screen, "bonus"):
			bonus_shown = true
	check("a pack with a bonus says so separately", bonus_shown)

	screen.queue_free()
	s.queue_free()


# ---- prices ------------------------------------------------------------------

func _prices() -> void:
	print("\n=== prices come from the store, never from us ===")
	var r := _roster()
	# NO POLL, so the simulated backend's price event has not been drained
	# and the screen is in the state every real launch starts in.
	var s := _store(r, false)
	var screen := _screen(r, s)
	await process_frame

	var priced: int = 0
	for b in _buy_buttons(screen):
		if (b as Button).text == "Price unavailable":
			priced += 1
	check("before prices arrive, no row shows a price",
		priced == IAPCatalog.all().size(),
		"%d of %d say so" % [priced, IAPCatalog.all().size()])
	var buyable: int = 0
	for b in _buy_buttons(screen):
		if not (b as Button).disabled:
			buyable += 1
	check("...and nothing can be bought", buyable == 0,
		"%d buyable" % buyable)
	check("...and the screen says why, rather than looking empty",
		_said(screen, "Price unavailable"))

	# Now let the prices land, by draining the backend by hand — the store is
	# deliberately not in the tree, so nothing is polling it. The screen must
	# react on its own, because it is connected to prices_updated: a round
	# trip to StoreKit finishes after the screen is already up.
	s.poll()
	await process_frame
	var now_priced: int = 0
	for b in _buy_buttons(screen):
		if (b as Button).text == Store.SimulatedBackend.PRICE_TEXT:
			now_priced += 1
	check("when prices arrive the screen updates itself",
		now_priced == IAPCatalog.all().size(),
		"%d of %d priced" % [now_priced, IAPCatalog.all().size()])

	# THE PRICE ON THE BUTTON IS THE STORE'S STRING, character for character.
	# Not reformatted, not re-rendered into a currency: a localized price is
	# the store's to format, and "$4.99" typed here is wrong in every other
	# storefront on earth.
	var exact: bool = false
	for b in _buy_buttons(screen):
		if (b as Button).text == s.price_text(IAPCatalog.all()[0].product_id):
			exact = true
	check("...verbatim, not reformatted", exact,
		s.price_text(IAPCatalog.all()[0].product_id))

	screen.queue_free()
	s.queue_free()


# ---- the odds gate -----------------------------------------------------------

func _the_odds_gate() -> void:
	print("\n=== a random pack cannot be bought blind ===")
	var r := _roster()
	var s := _store(r)
	var screen := _screen(r, s)
	await process_frame

	var crystal: IAPCatalog.Pack = null
	var gems: IAPCatalog.Pack = null
	for pack in IAPCatalog.all():
		var p := pack as IAPCatalog.Pack
		if IAPCatalog.pack_needs_disclosure(p) and crystal == null:
			crystal = p
		elif not IAPCatalog.pack_needs_disclosure(p) and p.kind == Wallet.Kind.GEMS \
				and gems == null:
			gems = p
	check("the catalogue has a pack that needs disclosure", crystal != null)
	if crystal == null:
		screen.queue_free()
		s.queue_free()
		return

	# THE ENGINE REFUSES AN UNACKNOWLEDGED BUY. Asserted from here as well as
	# in storetest, because this is the call the screen makes and a screen
	# that stops passing the flag must not be able to sell anyway.
	var refused: String = s.purchase(crystal.product_id, false)
	check("buying a crystal pack without acknowledging the odds is refused",
		not refused.is_empty(), refused)
	check("...and nothing was granted",
		r.wallet.balance(Wallet.Kind.CRYSTALS) == 0,
		"%d crystals" % r.wallet.balance(Wallet.Kind.CRYSTALS))

	# PRESSING THE ROW PUTS THE ODDS UP — it does not start a payment.
	var before: int = r.wallet.balance(Wallet.Kind.CRYSTALS)
	screen.call("_on_buy", crystal)
	await process_frame
	check("pressing a crystal pack shows the odds first",
		screen.find_child("OddsText", true, false) != null)
	check("...and starts no payment yet",
		r.wallet.balance(Wallet.Kind.CRYSTALS) == before)

	# THE SHEET HAS TO CONTAIN THE ACTUAL PUBLISHED NUMBERS, read from
	# CrystalOdds at call time. A disclosure screen keeping its own copy of
	# the odds is one that will eventually be wrong, and wrong published odds
	# are the rejection — or the regulator — not the typo.
	var text: Label = screen.find_child("OddsText", true, false) as Label
	var rows_shown: int = 0
	for row in Store.odds_rows():
		if text != null and text.text.find(String(row["percent"])) >= 0:
			rows_shown += 1
	check("the sheet shows every published probability",
		rows_shown == Store.odds_rows().size(),
		"%d of %d tiers" % [rows_shown, Store.odds_rows().size()])
	check("...and says the guarantee threshold",
		text != null and text.text.find(str(CrystalOdds.PITY_THRESHOLD)) >= 0)
	check("...and that crystals cannot be refunded by the app",
		text != null and text.text.findn("cannot be restored") >= 0)

	# "NOT NOW" MUST COST NOTHING.
	var cancel: Button = screen.find_child("OddsCancel", true, false) as Button
	check("the sheet can be dismissed", cancel != null)
	if cancel != null:
		cancel.pressed.emit()
		await process_frame
		check("...and dismissing it buys nothing",
			r.wallet.balance(Wallet.Kind.CRYSTALS) == before
				and screen.find_child("OddsText", true, false) == null)

	# ACCEPTING IS WHAT PAYS.
	screen.call("_on_buy", crystal)
	await process_frame
	var accept: Button = screen.find_child("OddsAccept", true, false) as Button
	check("the sheet has the button that buys", accept != null
		and not accept.disabled)
	if accept != null:
		accept.pressed.emit()
		s.poll()
		await process_frame
		check("...and accepting grants the crystals",
			r.wallet.balance(Wallet.Kind.CRYSTALS) >= crystal.crystal_payout(),
			"%d crystals" % r.wallet.balance(Wallet.Kind.CRYSTALS))
		check("...and the sheet is gone afterwards",
			screen.find_child("OddsText", true, false) == null)

	# A NON-RANDOM PACK MUST NOT BE GATED. Gems buy a champion the player
	# picks, so demanding an odds acknowledgement for them would be a
	# disclosure about randomness that does not exist.
	if gems != null:
		screen.call("_on_buy", gems)
		await process_frame
		check("a gem pack is not put behind an odds sheet",
			screen.find_child("OddsText", true, false) == null)
		s.poll()
		await process_frame
		check("...and buys straight away",
			r.wallet.balance(Wallet.Kind.GEMS) >= gems.amount,
			"%d gems" % r.wallet.balance(Wallet.Kind.GEMS))

	screen.queue_free()
	s.queue_free()


# ---- buying ------------------------------------------------------------------

func _buying() -> void:
	print("\n=== one payment, one grant ===")
	var r := _roster()
	var s := _store(r)
	var screen := _screen(r, s)
	var notices: Array = []
	screen.notified.connect(func(t: String) -> void: notices.append(t))
	await process_frame

	var gold: IAPCatalog.Pack = null
	for pack in IAPCatalog.all():
		if (pack as IAPCatalog.Pack).kind == Wallet.Kind.GOLD:
			gold = pack
			break
	var before: int = r.wallet.balance(Wallet.Kind.GOLD)

	screen.call("_on_buy", gold)
	s.poll()
	await process_frame
	var after: int = r.wallet.balance(Wallet.Kind.GOLD)
	check("a purchase grants the gold", after >= before + gold.amount,
		"%d -> %d" % [before, after])
	check("...and the player is told", notices.size() > 0,
		"" if notices.is_empty() else String(notices[-1]))

	# THE INVARIANT. StoreKit re-delivers every transaction until the app
	# finishes it, and again after a reinstall — so the same transaction
	# arriving twice must pay out exactly once. Two grants for one payment is
	# the bug that turns a currency into a faucet, and nothing on screen
	# would show it.
	s.simulated().redeliver_last()
	s.poll()
	await process_frame
	check("the SAME transaction delivered again grants nothing more",
		r.wallet.balance(Wallet.Kind.GOLD) == after,
		"%d, was %d" % [r.wallet.balance(Wallet.Kind.GOLD), after])

	# And a re-delivered transaction must be FINISHED, or the store keeps
	# handing it back on every launch forever.
	check("...and is finished so the store stops offering it",
		s.simulated().finished.size() >= 2,
		"%d finished" % s.simulated().finished.size())

	# A SECOND TAP WHILE ONE IS IN FLIGHT. On a phone a double tap is one
	# gesture, and two payment sheets for one intent is a double charge.
	var mid: int = r.wallet.balance(Wallet.Kind.GOLD)
	s.purchase(gold.product_id, false)
	var twice: String = s.purchase(gold.product_id, false)
	check("a second tap while a purchase is in flight is refused",
		not twice.is_empty(), twice)
	s.poll()
	await process_frame
	check("...and only one of them paid out",
		r.wallet.balance(Wallet.Kind.GOLD) == mid + gold.amount + gold.bonus,
		"%d -> %d, pack is %d+%d"
			% [mid, r.wallet.balance(Wallet.Kind.GOLD), gold.amount,
				gold.bonus])

	# A CANCELLED PAYMENT MUST SAY SO AND GRANT NOTHING. A player who backs
	# out of the Apple sheet and sees no acknowledgement assumes it worked.
	var held: int = r.wallet.balance(Wallet.Kind.GOLD)
	notices.clear()
	s.simulated().fail_next = true
	screen.call("_on_buy", gold)
	s.poll()
	await process_frame
	check("a cancelled payment grants nothing",
		r.wallet.balance(Wallet.Kind.GOLD) == held)
	check("...and says so rather than failing silently",
		notices.size() > 0, "" if notices.is_empty() else String(notices[-1]))

	screen.queue_free()
	s.queue_free()


# ---- unavailable -------------------------------------------------------------

func _unavailable() -> void:
	print("\n=== a store that cannot sell says so ===")
	var r := _roster()
	# A Store that was never begun has no backend at all, which is the state a
	# device without the StoreKit plugin is in.
	var s := Store.for_account(r)
	s.autosave = false
	root.add_child(s)
	var screen := _screen(r, s)
	await process_frame

	check("an unopened store is unavailable", not s.available())
	check("...and the screen puts the reason on the glass",
		_said(screen, s.unavailable_reason()), s.unavailable_reason())
	# NOT HIDDEN. The packs stay on screen, disabled: a list people have
	# learned the shape of must not silently empty itself, or the screen
	# reads as broken rather than as temporarily closed.
	var titled: int = 0
	for pack in IAPCatalog.all():
		if _said(screen, (pack as IAPCatalog.Pack).title):
			titled += 1
	check("...while still showing the packs, disabled",
		titled == IAPCatalog.all().size(),
		"%d of %d rows" % [titled, IAPCatalog.all().size()])
	var buyable: int = 0
	for b in _buy_buttons(screen):
		if not (b as Button).disabled:
			buyable += 1
	check("...and nothing is buyable", buyable == 0, "%d buyable" % buyable)

	# Pressing one anyway must refuse, not crash and not grant.
	screen.call("_on_buy", IAPCatalog.all()[0])
	await process_frame
	check("pressing a disabled pack grants nothing",
		r.wallet.balance(Wallet.Kind.GOLD) == 250,
		"%d gold" % r.wallet.balance(Wallet.Kind.GOLD))

	# NO RESTORE BUTTON. Every product is a consumable, so there is nothing a
	# restore could return — and a button that cannot do what it says is
	# worse than its absence. Asserted so nobody adds one as decoration.
	var restore: bool = false
	for b in _buttons(screen):
		if (b as Button).text.findn("restore") >= 0:
			restore = true
	check("there is no Restore button, because every pack is consumable",
		not restore)

	screen.queue_free()
	s.queue_free()


# ---- in the real shell -------------------------------------------------------

func _in_the_shell() -> void:
	print("\n=== in the shell ===")
	# THE WIRING. Store.gd was complete and reachable from nothing for the
	# whole life of the feature, so the only assertion that matters here is
	# that the real shell builds a real Store and hands it to the screen.
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	get_root().add_child(main)
	for i in range(10):
		await process_frame
	var shell: UiShell = main as UiShell if main is UiShell \
		else main.find_children("*", "UiShell", true, false)[0]

	var owned = shell.get("_store")
	check("the shell owns a Store", owned != null and owned is Store)
	check("...and started it, so prices are already on their way",
		owned != null and (owned as Store).backend() != Store.BackendKind.NONE,
		"backend %d" % (owned.backend() if owned != null else -1))

	shell.goto(UiRoute.STORE)
	for i in range(8):
		await process_frame
	var screen: UiScreen = shell.current_screen()
	check("the store screen opens", screen != null
		and screen is StoreScreenS, "%s" % screen)
	check("...and is handed the shell's Store, not one of its own",
		screen != null and screen.get("store") == owned)

	# It is reachable from the navigation panel, which is now the only way
	# around the game.
	var nav: Node = shell.get("_nav")
	var row: Button = nav.find_child("Nav_" + UiRoute.STORE, true, false) \
		as Button if nav != null else null
	check("the store has a row in the navigation panel", row != null)
	if row != null:
		shell.goto(UiRoute.CHAMPIONS)
		for i in range(6):
			await process_frame
		row.pressed.emit()
		for i in range(6):
			await process_frame
		check("...which opens it", shell.current_route() == UiRoute.STORE,
			shell.current_route())

	# AND THE GRANT SURVIVES THE SCREEN BEING GONE. A purchase begun here is
	# delivered a second or two later, often after the player has navigated
	# away — the shell holds the Store for exactly this reason, and a Store
	# freed with the screen would drop currency somebody paid for.
	var store: Store = owned as Store
	store.autosave = false
	if store.backend() == Store.BackendKind.SIMULATED:
		var gold: IAPCatalog.Pack = null
		for pack in IAPCatalog.all():
			if (pack as IAPCatalog.Pack).kind == Wallet.Kind.GOLD:
				gold = pack
				break
		var before: int = shell.roster.wallet.balance(Wallet.Kind.GOLD)
		store.purchase(gold.product_id, false)
		# Walk away BEFORE the delivery is polled.
		shell.goto(UiRoute.CHAMPIONS)
		for i in range(6):
			await process_frame
		store.poll()
		await process_frame
		check("a purchase delivered after leaving the store still lands",
			shell.roster.wallet.balance(Wallet.Kind.GOLD)
				> before, "%d -> %d" % [before,
				shell.roster.wallet.balance(Wallet.Kind.GOLD)])
	else:
		check("the simulated backend was available to test late delivery",
			false, "backend %d" % store.backend())

	main.queue_free()
