class_name StoreScreen
extends UiScreen
# ------------------------------------------------------------------------------
# THE IN-GAME STORE.
#
# Store.gd, IAPCatalog.gd and CrystalOdds.gd were written, unit-tested in
# tools/storetest.gd, and reachable from NOTHING. Nine products, a payment
# seam, a grant-once-per-transaction invariant and a full Guideline 3.1.1
# odds disclosure, and no screen in the game ever constructed a Store — so
# the app had no way to take a payment at all.
#
# ------------------------------------------------------------------------------
# WHAT THIS SCREEN IS NOT ALLOWED TO DO.
#
# A store screen is the one place in a game where being loose with the truth
# is both a review rejection and a real harm to the person paying, so the
# rules here are hard ones and all of them are enforced in Store.gd rather
# than by this file being careful:
#
#   * NEVER SHOW A PRICE THIS APP MADE UP. Prices come from StoreKit and from
#     nowhere else — Store.price_text() returns "" until they arrive, and an
#     empty string means the row is disabled and says why. A hard-coded
#     "$4.99" is wrong the moment it is read in another storefront, and it is
#     wrong immediately for everyone if the tier is ever changed in App Store
#     Connect.
#
#   * NEVER SELL A CRYSTAL PACK WITHOUT SHOWING THE ODDS FIRST. Spawn
#     crystals are a random draw. Store.purchase() refuses outright unless
#     the caller passes odds_acknowledged, and the only honest way to set it
#     is from the sheet this screen actually put on the glass.
#
#   * NEVER HIDE AN UNAVAILABLE STORE. If purchases cannot be made, the
#     reason goes on screen. A store that silently shows nothing reads as a
#     bug and generates a support mail; a store that says "In-app purchases
#     are unavailable in this build" tells the truth.
#
#   * NEVER PROMISE A REFUND OR A RESTORE IT CANNOT PERFORM. Every product
#     here is a CONSUMABLE currency pack, so there is nothing to restore and
#     Apple does not require a restore control for consumables. A Restore
#     button that cannot do anything is worse than none. Unfinished
#     transactions come back on their own — Store polls them and redeems
#     exactly once — which is the real mechanism and needs no button.
# ------------------------------------------------------------------------------

## Set by UiShell before the screen is built. The shell owns the Store, because
## it must outlive any one screen: a purchase begun here and delivered two
## seconds later has to land even if the player has already walked away.
var store: Store = null

var _rows: VBoxContainer = null
var _status: Label = null
## The disclosure sheet, while it is up. Only ever one.
var _sheet: Control = null


func screen_title() -> String:
	return "Store"


func build() -> void:
	var col := scroll_column()
	col.add_child(context_strip())

	_status = HeroTheme.prose("", HeroTheme.F_SMALL, HeroTheme.DIM)
	col.add_child(_status)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", HeroTheme.GAP)
	col.add_child(_rows)

	# Prices arrive asynchronously, so the screen has to be able to change
	# after it is built — before they land every row is correctly unbuyable.
	if store != null:
		store.prices_updated.connect(_on_store_changed)
		store.purchase_granted.connect(_on_granted)
		store.purchase_refused.connect(_on_refused)
		store.store_unavailable.connect(func(_why: String) -> void:
			_on_store_changed())

	refresh()


func _exit_tree() -> void:
	# The Store outlives this screen, so every connection made above has to be
	# dropped: a signal into a freed screen is an error per emission, and the
	# shell keeps emitting for as long as the game is running.
	if store == null:
		return
	for pair in [[store.prices_updated, _on_store_changed],
			[store.purchase_granted, _on_granted],
			[store.purchase_refused, _on_refused]]:
		var sig: Signal = pair[0]
		if sig.is_connected(pair[1]):
			sig.disconnect(pair[1])


func _on_store_changed() -> void:
	refresh()


func _on_granted(product_id: String, _txn: String) -> void:
	var p: IAPCatalog.Pack = IAPCatalog.by_id(product_id)
	notified.emit("%s added to your account." % (p.title if p != null
		else "Your purchase"))
	# The grant is already on disk — Store.redeem() saves before it finishes
	# the transaction — so this is only asking the shell to redraw the
	# currency bar, not to write anything.
	state_changed.emit()
	refresh()


func _on_refused(_product_id: String, reason: String) -> void:
	if reason.is_empty():
		return
	notified.emit(reason)
	refresh()


func refresh() -> void:
	if _rows == null or roster == null:
		return
	for c in _rows.get_children():
		c.queue_free()

	if store == null:
		_status.text = "The store is not available right now."
		return

	# SAID OUT LOUD, at the top, before any row. An unavailable store that
	# shows nine disabled buttons and no explanation is a screen that looks
	# broken.
	if not store.available():
		_status.text = store.unavailable_reason()
		_status.add_theme_color_override("font_color", HeroTheme.GOLD)
	elif store.backend() == Store.BackendKind.SIMULATED:
		# Debug builds only — _choose_backend() cannot reach this path in
		# anything a player installs. Said plainly so nobody mistakes a test
		# grant for a real one.
		_status.text = "Simulated store (debug build). No payment is taken " \
			+ "and nothing is charged."
		_status.add_theme_color_override("font_color", HeroTheme.GOLD)
	else:
		_status.text = "Purchases are handled by the App Store. Spawn " \
			+ "crystals grant a random champion — the odds are shown before " \
			+ "you buy."
		_status.add_theme_color_override("font_color", HeroTheme.DIM)

	var kind: int = -1
	for pack in IAPCatalog.all():
		var p := pack as IAPCatalog.Pack
		if p == null:
			continue
		# A heading per currency, so nine rows read as three offers rather
		# than as one long undifferentiated list of prices.
		if p.kind != kind:
			kind = p.kind
			_rows.add_child(_heading(kind))
		_rows.add_child(_pack_row(p))


func _heading(kind: int) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(HeroTheme.label(String(Wallet.KIND_NAMES.get(kind, "")),
		HeroTheme.F_BODY, _currency_colour(kind)))
	# WHAT THE CURRENCY IS FOR, once per group. The distinction that matters
	# most to someone about to pay is gems-versus-crystals: one buys the
	# champion you point at, the other buys a draw. Saying it here, above the
	# prices, is the difference between an informed purchase and a surprise.
	var note: String = ""
	match kind:
		Wallet.Kind.GOLD:
			note = "Spent at the merchant, and on training and party slots."
		Wallet.Kind.GEMS:
			note = "Unlock a champion you CHOOSE. No randomness."
		Wallet.Kind.CRYSTALS:
			note = "Each one grants a RANDOM champion."
			if store != null:
				note += "  " + store.pity_progress_text()
	if not note.is_empty():
		box.add_child(HeroTheme.label(note, HeroTheme.F_SMALL, HeroTheme.DIM))
	return box


func _pack_row(p: IAPCatalog.Pack) -> Control:
	var card := HeroTheme.panel()
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", HeroTheme.PAD)
	pad.add_theme_constant_override("margin_right", HeroTheme.PAD)
	pad.add_theme_constant_override("margin_top", 22)
	pad.add_theme_constant_override("margin_bottom", 22)
	card.add_child(pad)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", HeroTheme.GAP)
	pad.add_child(row)

	row.add_child(UiGlyph.make(UiGlyph.for_currency(p.kind), 54,
		_currency_colour(p.kind)))

	var text := VBoxContainer.new()
	text.add_theme_constant_override("separation", 4)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text)
	text.add_child(HeroTheme.label(p.title, HeroTheme.F_BODY, HeroTheme.TEXT))

	# WHAT YOU GET, as a number, including the bonus called out separately —
	# a pack that advertises "16,000" and pays 18,000 is fine; one that
	# advertises a total and hides which part is the bonus is the kind of
	# phrasing that makes a player go back and check.
	var what: String = "%s %s" % [_commas(p.amount),
		String(Wallet.KIND_NAMES.get(p.kind, ""))]
	if p.bonus > 0:
		what += "  +%s bonus" % _commas(p.bonus)
	if p.crystals_bonus > 0:
		what += "  +%d spawn crystal%s" % [p.crystals_bonus,
			"" if p.crystals_bonus == 1 else "s"]
	text.add_child(HeroTheme.label(what, HeroTheme.F_SMALL, HeroTheme.DIM))

	var blocked: String = store.offer_blocked_reason(p.product_id)
	var price: String = store.price_text(p.product_id)

	var buy: Button = HeroTheme.button(
		# THE STORE'S OWN PRICE STRING, never one built here. When it has not
		# arrived the button says so rather than guessing or showing a blank.
		price if not price.is_empty() else "Price unavailable",
		HeroTheme.Btn.PRIMARY, HeroTheme.TAP)
	buy.custom_minimum_size = Vector2(430, HeroTheme.TAP)
	buy.disabled = not blocked.is_empty()
	buy.pressed.connect(_on_buy.bind(p))
	row.add_child(buy)

	if not blocked.is_empty():
		# DISABLED ROWS SAY WHY. A greyed button with no reason leaves the
		# player unable to tell a sold-out pack from a broken app.
		text.add_child(HeroTheme.label(blocked, HeroTheme.F_SMALL,
			HeroTheme.GOLD))
	elif IAPCatalog.pack_needs_disclosure(p):
		text.add_child(HeroTheme.label("Random champion — odds shown first.",
			HeroTheme.F_SMALL, HeroTheme.CRYSTAL))
	return card


static func _currency_colour(kind: int) -> Color:
	match kind:
		Wallet.Kind.GOLD: return HeroTheme.GOLD
		Wallet.Kind.GEMS: return HeroTheme.GEM
		_: return HeroTheme.CRYSTAL


# ------------------------------------------------------------------------------
# Buying
# ------------------------------------------------------------------------------

func _on_buy(p: IAPCatalog.Pack) -> void:
	if store == null:
		return
	var blocked: String = store.offer_blocked_reason(p.product_id)
	if not blocked.is_empty():
		notified.emit(blocked)
		return
	# THE GATE. A pack that pays out crystals cannot be bought until the odds
	# have been on the glass and the player has pressed through them. Store
	# refuses it anyway if this screen gets it wrong, which is the point of
	# the check living there.
	if IAPCatalog.pack_needs_disclosure(p):
		_show_odds(p)
		return
	_begin(p, false)


func _begin(p: IAPCatalog.Pack, acknowledged: bool) -> void:
	var refused: String = store.purchase(p.product_id, acknowledged)
	if not refused.is_empty():
		# purchase() already emitted purchase_refused, so the message is
		# shown by _on_refused; nothing to add here.
		return
	notified.emit("Opening the App Store payment sheet…")


## The odds sheet. Guideline 3.1.1: the published chances have to be visible
## BEFORE the payment, not somewhere in a settings menu.
##
## Every number in it comes from Store.disclosure_text(), which reads
## CrystalOdds at call time. Nothing is typed in twice — a disclosure screen
## that keeps its own copy of the odds is one that will eventually be wrong,
## and wrong published odds are the rejection, not the typo.
func _show_odds(p: IAPCatalog.Pack) -> void:
	if _sheet != null and is_instance_valid(_sheet):
		return
	var veil := ColorRect.new()
	veil.color = Color(HeroTheme.BG.r, HeroTheme.BG.g, HeroTheme.BG.b, 0.93)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Eats the taps, so the row underneath cannot be pressed through the
	# sheet — a second purchase started behind a modal is a real double charge.
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(veil)
	_sheet = veil

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", HeroTheme.SAFE_X)
	pad.add_theme_constant_override("margin_right", HeroTheme.SAFE_X)
	pad.add_theme_constant_override("margin_top", 40)
	pad.add_theme_constant_override("margin_bottom", 32)
	veil.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", HeroTheme.GAP)
	pad.add_child(col)

	var title: Label = HeroTheme.label("Spawn crystal odds", HeroTheme.F_HEAD,
		HeroTheme.CRYSTAL)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)

	var sc := ScrollContainer.new()
	TouchScroll.attach(sc)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(sc)
	var body: Label = HeroTheme.prose(store.disclosure_text(p.product_id),
		HeroTheme.F_SMALL, HeroTheme.TEXT)
	body.name = "OddsText"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(body)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", HeroTheme.GAP)
	col.add_child(buttons)

	var away: Button = HeroTheme.button("Not now", HeroTheme.Btn.GHOST,
		HeroTheme.TAP)
	away.name = "OddsCancel"
	away.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	away.pressed.connect(_close_odds)
	buttons.add_child(away)

	var price: String = store.price_text(p.product_id)
	var go: Button = HeroTheme.button(
		"Buy  ·  %s" % price if not price.is_empty() else "Price unavailable",
		HeroTheme.Btn.PRIMARY, HeroTheme.TAP)
	go.name = "OddsAccept"
	go.disabled = price.is_empty()
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	go.pressed.connect(func() -> void:
		# CLOSED FIRST. The payment sheet is the App Store's, and leaving our
		# modal under it means the player comes back to a screen still asking
		# a question they have answered.
		_close_odds()
		_begin(p, true))
	buttons.add_child(go)


func _close_odds() -> void:
	if _sheet != null and is_instance_valid(_sheet):
		_sheet.queue_free()
	_sheet = null


static func _commas(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	var c: int = 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if n < 0 else "") + out
