extends SceneTree
# ------------------------------------------------------------------------------
# Undoing a build costs gold, and never happens on one tap.
#
# A respec wipes points the player spent twenty levels assembling, and the
# button sits beside the four they press constantly. Before this it was free
# and instant: one mis-tap, no price, no confirmation, no way back.
#
#   godot --headless --path . --script tools/respectest.gd
# ------------------------------------------------------------------------------

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	print("\n=== it costs gold, and the charge is real ===")
	var r: Roster = Roster.create(HeroRig.animated_heroes())
	var hero: String = String(r.owned.keys()[0])
	var p: HeroProgress = r.progress(hero)

	check("nothing spent means nothing to charge",
		r.respec_cost(hero) == 0, "%d gold" % r.respec_cost(hero))
	check("...and the respec is refused outright", r.respec(hero) != "")

	p.gain_xp(100000.0)
	var points: int = p.unspent_points()
	for i in range(points):
		p.spend(Stats.Attr.STRENGTH, 1)
	check("a champion with a build has points to undo",
		p.spent_points() > 0, "%d points" % p.spent_points())

	var cost: int = r.respec_cost(hero)
	check("the price scales with the size of the build",
		cost == Roster.RESPEC_BASE
			+ Roster.RESPEC_PER_POINT * p.spent_points(),
		"%d gold for %d points" % [cost, p.spent_points()])

	# Cannot pay: the build must survive untouched.
	r.wallet.spend(Wallet.Kind.GOLD, r.wallet.balance(Wallet.Kind.GOLD),
		"test")
	var before: int = p.spent_points()
	var refused: String = r.respec(hero)
	check("a player who cannot pay is refused", refused != "", refused)
	check("...and keeps every point", p.spent_points() == before,
		"%d points" % p.spent_points())

	# Can pay: charged exactly once, and the points come back.
	r.wallet.grant(Wallet.Kind.GOLD, cost + 500, "test")
	var purse: int = r.wallet.balance(Wallet.Kind.GOLD)
	var ok: String = r.respec(hero)
	check("a player who can pay gets their points back", ok == "", ok)
	check("...all of them", p.spent_points() == 0
		and p.unspent_points() == before,
		"%d unspent" % p.unspent_points())
	check("...and was charged exactly the quoted price",
		r.wallet.balance(Wallet.Kind.GOLD) == purse - cost,
		"%d -> %d, quoted %d" % [purse, r.wallet.balance(Wallet.Kind.GOLD),
			cost])
	check("...and cannot be charged again for nothing",
		r.respec(hero) != "" and r.wallet.balance(Wallet.Kind.GOLD)
			== purse - cost)

	await _warned()
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


func _warned() -> void:
	print("\n=== the first press is a warning, not the act ===")
	var design := Vector2i(2532, 1170)
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_size = design
	get_root().size = design
	await process_frame

	var main: Node = load("res://scenes/Main.tscn").instantiate()
	get_root().add_child(main)
	for i in range(8):
		await process_frame
	var shell: UiShell = main as UiShell if main is UiShell \
		else main.find_children("*", "UiShell", true, false)[0]

	var hero: String = String(shell.roster.owned.keys()[0])
	var p: HeroProgress = shell.roster.progress(hero)
	p.gain_xp(100000.0)
	for i in range(p.unspent_points()):
		p.spend(Stats.Attr.STRENGTH, 1)
	shell.roster.wallet.grant(Wallet.Kind.GOLD, 100000, "test")
	var spent: int = p.spent_points()

	shell.goto(UiRoute.SHEET, hero)
	for i in range(8):
		await process_frame
	var screen: UiScreen = _sheet(main)
	check("the champion sheet came up", screen != null)
	if screen == null:
		return

	var button: Button = _button(screen, "Refund")
	check("the button quotes the price before it is pressed",
		button != null and button.text.findn("gold") >= 0,
		button.text if button != null else "no button")
	if button == null:
		return

	button.pressed.emit()
	for i in range(4):
		await process_frame

	# THE POINT. One press must change nothing but the button.
	check("one press does NOT reset anything",
		p.spent_points() == spent, "%d points still spent" % p.spent_points())
	var armed: Button = _button(screen, "Confirm")
	check("...it turns into a warning instead",
		armed != null and armed.text.findn("cannot be undone") >= 0,
		armed.text if armed != null else "no warning")
	if armed == null:
		return

	armed.pressed.emit()
	for i in range(6):
		await process_frame
	check("the second press is what actually does it",
		p.spent_points() == 0, "%d points spent" % p.spent_points())


func _sheet(n: Node) -> UiScreen:
	for s in n.find_children("*", "UiScreen", true, false):
		if s.visible and s is ChampionSheetScreen:
			return s
	return null


func _button(n: Node, needle: String) -> Button:
	if n is Button and (n as Button).text.findn(needle) >= 0:
		return n
	for c in n.get_children():
		var found: Button = _button(c, needle)
		if found != null:
			return found
	return null
