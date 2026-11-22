extends SceneTree
# ------------------------------------------------------------------------------
# Proves the menu shell actually works: every screen builds against a REAL
# Roster, every button is wired to the real class behind it, and what the player
# does on screen is in the save file afterwards.
#
# WHY THIS IS NOT A UNIT TEST: the systems under tools/metatest.gd were all
# green while the game had no menus at all — the bug this guards against is a
# screen that silently fails half way through _ready() and shows an empty
# panel, which no test of Roster or Stash can ever catch. So it drives the
# shell: route to a screen, find a real Button by its label, emit its pressed
# signal, and assert the Roster changed.
#
# THE SAVE FILE IS BACKED UP AND RESTORED. The shell is the one writer of
# user://roster.json (UiShell._on_state_changed) and this test makes it write,
# which must not cost a developer their own save.
# ------------------------------------------------------------------------------

var fails: int = 0
var _backup: String = ""
var _had_save: bool = false


## Sections that reached their end — see the check in _init.
var _ran: int = 0

func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	# Deferred so the tree is actually running: the screens are Controls and
	# this test waits on real frames so container layout and VirtualList's
	# resize-driven binding happen the way they do in the game.
	_run.call_deferred()


func _run() -> void:
	_had_save = FileAccess.file_exists(Roster.SAVE_PATH)
	if _had_save:
		var f := FileAccess.open(Roster.SAVE_PATH, FileAccess.READ)
		if f != null:
			_backup = f.get_as_text()

	var heroes: PackedStringArray = HeroRig.animated_heroes()
	if heroes.is_empty():
		print("no hero models found")
		quit()
		return

	await _screens_build(heroes); _ran += 1
	await _champion_select(heroes); _ran += 1
	await _champion_sheet(heroes); _ran += 1
	await _stash(heroes); _ran += 1
	await _merchant(heroes); _ran += 1
	await _campaign(heroes); _ran += 1
	await _handoff(heroes); _ran += 1
	await _persistence(heroes); _ran += 1
	_restore_save()

	# EVERY SECTION MUST HAVE REACHED ITS END.
	#
	# A runtime error inside one of these aborts that function and GDScript
	# carries on to the next, so without this a crash reads as a clean run.
	# It happened the moment the campaign screen stopped containing a
	# VirtualList: this file indexed [0] into an empty array, the whole
	# campaign section stopped dead, and the summary still said 0 failures.
	check("every section ran to completion", _ran == 8, "%d of 8" % _ran)
	print("\n=== %d failure(s) ===" % fails)
	quit()


# ------------------------------------------------------------------------------
# Scaffolding
# ------------------------------------------------------------------------------

## A roster with something to look at: owned champions, gear in the stash, and
## currency to spend. Everything comes from the real classes — Roster.create
## for the starters, Campaign.roll_region_loot for the gear.
func _rich_roster(heroes: PackedStringArray, extra_champions: int = 0) -> Roster:
	var r := Roster.create(heroes, 90210)
	r.wallet.grant(Wallet.Kind.GOLD, 250000, "uitest")
	r.wallet.grant(Wallet.Kind.GEMS, 400, "uitest")
	r.wallet.grant(Wallet.Kind.CRYSTALS, 5, "uitest")
	for it in Campaign.roll_region_loot(4242, 9, Campaign.Tier.VETERAN, 24):
		r.stash.add(it)
	var granted: int = 0
	for h in r.locked_names():
		if granted >= extra_champions:
			break
		r._grant_champion(h)
		granted += 1
	return r


func _shell(r: Roster) -> UiShell:
	var packed: PackedScene = load("res://scenes/Main.tscn") as PackedScene
	var shell: UiShell = packed.instantiate() as UiShell
	shell.roster = r
	root.add_child(shell)
	return shell


func _settle(frames: int = 3) -> void:
	for _i in range(frames):
		await process_frame


func _close(shell: UiShell) -> void:
	root.remove_child(shell)
	shell.queue_free()
	await _settle(1)


## Every Button under `node`, depth first.
func _buttons(node: Node, out: Array = []) -> Array:
	if node is Button:
		out.append(node)
	for c in node.get_children():
		_buttons(c, out)
	return out


func _button_with(node: Node, needle: String) -> Button:
	for b in _buttons(node):
		if (b as Button).text.findn(needle) >= 0:
			return b
	return null


func _press(node: Node, needle: String) -> bool:
	var b: Button = _button_with(node, needle)
	if b == null or b.disabled:
		return false
	b.pressed.emit()
	return true


## Every Label and Button string on screen, for the checks that no user-visible
## text is a placeholder.
func _strings(node: Node, out: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	if node is Label:
		out.append((node as Label).text)
	elif node is Button:
		out.append((node as Button).text)
	for c in node.get_children():
		_strings(c, out)
	return out


func _rows(node: Node, out: Array = []) -> Array:
	if node is UiListRow:
		out.append(node)
	for c in node.get_children():
		_rows(c, out)
	return out


func _lists(node: Node, out: Array = []) -> Array:
	if node is VirtualList:
		out.append(node)
	for c in node.get_children():
		_lists(c, out)
	return out


## Buttons carrying a drawn glyph instead of a label — the attribute "+" keys
## and the header's back arrow. Matched by glyph so the two cannot be confused:
## pressing back thinking it was "+" frees the screen under the test.
func _glyph_buttons(node: Node, kind: int, out: Array = []) -> Array:
	if node is Button:
		for c in node.get_children():
			if c is UiGlyph and (c as UiGlyph).kind == kind:
				out.append(node)
	for c in node.get_children():
		_glyph_buttons(c, kind, out)
	return out


# ------------------------------------------------------------------------------
# Every screen builds
# ------------------------------------------------------------------------------

func _screens_build(heroes: PackedStringArray) -> void:
	print("\n=== every screen builds against a real roster ===")
	var r := _rich_roster(heroes, 12)
	var shell := _shell(r)
	await _settle()

	check("shell boots on the title screen",
		shell.current_route() == UiRoute.TITLE
		and shell.current_screen() is TitleScreen)
	# NOT "Play" any more, and deliberately so: the title says Begin to
	# someone who has never played and Continue · <region> to someone who
	# has. Asserting either, because this roster could legitimately be in
	# either state and the contract is "there is one obvious way in".
	var way_in: Button = _button_with(shell.current_screen(), "Begin")
	if way_in == null:
		way_in = _button_with(shell.current_screen(), "Continue")
	check("the title screen offers one obvious way in", way_in != null,
		way_in.text if way_in != null else "no primary button")

	for route in [UiRoute.CHAMPIONS, UiRoute.SHEET, UiRoute.STASH,
			UiRoute.SHOP, UiRoute.CAMPAIGN, UiRoute.TITLE]:
		shell.goto(route, "")
		await _settle()
		var screen: UiScreen = shell.current_screen()
		var built: bool = screen != null and screen.get_child_count() > 0 \
			and screen.content != null and screen.content.get_child_count() > 0
		var texts: PackedStringArray = _strings(screen) if screen != null \
			else PackedStringArray()
		check("'%s' builds" % route, built, "%d strings on screen" % texts.size())

		var clean: bool = true
		var dirty: String = ""
		for t in texts:
			if t.findn("TODO") >= 0 or t.findn("placeholder") >= 0 \
					or t.find("/Volumes") >= 0:
				clean = false
				dirty = t
			for i in range(t.length()):
				# Emoji live above the BMP; the shell draws its symbols
				# (UiGlyph) instead, per the project's rules.
				if t.unicode_at(i) >= 0x1F000:
					clean = false
					dirty = t
		check("  no placeholder or emoji text on '%s'" % route, clean, dirty)

	# A champion-contextual screen must always have a champion, even though the
	# shell was handed a route and an empty argument.
	shell.goto(UiRoute.STASH, "")
	await _settle()
	check("a contextual screen always has an owned champion",
		r.owns(shell.current_screen().hero), shell.current_screen().hero)
	await _close(shell)


# ------------------------------------------------------------------------------
# Champion select
# ------------------------------------------------------------------------------

func _champion_select(heroes: PackedStringArray) -> void:
	print("\n=== champion select: 3 owned, %d in the catalogue ===" % heroes.size())
	var r := _rich_roster(heroes)
	var shell := _shell(r)
	shell.goto(UiRoute.CHAMPIONS, "")
	await _settle()
	var screen: UiScreen = shell.current_screen()
	var lists: Array = _lists(screen)
	check("the roster list exists", lists.size() == 1)
	var list: VirtualList = lists[0]

	check("a new account lists its 3 champions", list.count() == 3,
		"%d rows" % list.count())
	var pooled: int = _rows(screen).size()
	check("rows are recycled, not one per entry", pooled <= 20,
		"%d row nodes for %d entries" % [pooled, list.count()])

	check("switching to the whole catalogue", _press(screen, "Every champion"))
	await _settle()
	check("every champion is listed", list.count() == heroes.size(),
		"%d rows" % list.count())
	var pooled_all: int = _rows(screen).size()
	check("139 entries still only build a handful of rows", pooled_all <= 20,
		"%d row nodes for %d entries" % [pooled_all, list.count()])

	# Unlock something with gems, through the row's own button.
	var before: int = r.owned.size()
	var gems_before: int = r.wallet.balance(Wallet.Kind.GEMS)
	var unlocked: bool = false
	for row in _rows(screen):
		var b: Button = _button_with(row, "Unlock")
		if b != null and b.visible and not b.disabled:
			b.pressed.emit()
			unlocked = true
			break
	await _settle()
	check("gems unlock a champion from the list", unlocked
		and r.owned.size() == before + 1
		and r.wallet.balance(Wallet.Kind.GEMS) < gems_before,
		"%d -> %d champions, %d -> %d gems" % [before, r.owned.size(),
			gems_before, r.wallet.balance(Wallet.Kind.GEMS)])

	var crystals_before: int = r.wallet.balance(Wallet.Kind.CRYSTALS)
	check("the odds are shown before a crystal is opened",
		_press(screen, "Odds"))
	await _settle()
	var odds_shown: bool = false
	for t in _strings(screen):
		if t.findn("Spawn Crystal odds") >= 0:
			odds_shown = true
	check("  the disclosure text is the published one", odds_shown)
	# Matched on "Spawn Crystal ·", the separator included: the button now reads
	# "Spawn Crystal · 5" so that its count survives the narrow column, and a
	# looser match would also hit the "Odds" disclosure text beside it.
	check("a crystal can be opened", _press(screen, "Spawn Crystal ·"))
	await _settle()
	check("  the crystal was spent",
		r.wallet.balance(Wallet.Kind.CRYSTALS) == crystals_before - 1,
		"%d -> %d" % [crystals_before, r.wallet.balance(Wallet.Kind.CRYSTALS)])
	await _close(shell)


# ------------------------------------------------------------------------------
# The character sheet
# ------------------------------------------------------------------------------

func _champion_sheet(heroes: PackedStringArray) -> void:
	print("\n=== the character sheet spends skill points ===")
	var r := _rich_roster(heroes)
	var owned: PackedStringArray = r.owned_names()
	var a: String = owned[0]
	var b: String = owned[1]
	r.progress(a).gain_xp(4000.0)

	var shell := _shell(r)
	shell.goto(UiRoute.SHEET, a)
	await _settle()
	var screen: UiScreen = shell.current_screen()
	check("the sheet is the chosen champion's", screen.hero == a,
		ChampionName.of(a))

	var points_before: int = r.progress(a).unspent_points()
	check("levelling granted points to spend", points_before > 0,
		"%d unspent at L%d" % [points_before, r.progress(a).level])

	var spent_before: int = r.progress(a).spent_points()
	# Matched by glyph, not by "has no label": the header's back arrow is also a
	# label-less button with a child, and pressing it routes away and frees the
	# screen — which took the rest of this function with it.
	var plus: Array = _glyph_buttons(screen, UiGlyph.Kind.PLUS)
	check("there is one spend button per attribute", plus.size() == 4,
		"%d found" % plus.size())
	for i in range(mini(3, plus.size())):
		(plus[i] as Button).pressed.emit()
		await _settle(1)
	check("points are spent on the real HeroProgress",
		r.progress(a).spent_points() == spent_before + 3,
		"%d -> %d spent" % [spent_before, r.progress(a).spent_points()])
	check("SKILL POINTS DO NOT TRANSFER between champions",
		r.progress(b).spent_points() == 0 and r.progress(b).level == 1,
		"%s is still L1 with 0 spent" % ChampionName.of(b))

	var says_so: bool = false
	for t in _strings(screen):
		if t.findn("cannot be moved to another") >= 0:
			says_so = true
	check("  and the screen says so in words", says_so)

	var effective: Stats = r.effective_stats(a)
	var shown: bool = false
	for t in _strings(screen):
		if t == "%.0f" % effective.get_attr(Stats.Attr.STRENGTH):
			shown = true
	check("the sheet shows Roster.effective_stats, not its own arithmetic",
		shown, "STR %.0f" % effective.get_attr(Stats.Attr.STRENGTH))

	# A respec is PRICED and CONFIRMED now. One press arms the warning and
	# must change nothing; the second spends the gold and returns the points.
	var had_spent: int = r.progress(a).spent_points()
	var quoted: int = r.respec_cost(a)
	var purse: int = r.wallet.balance(Wallet.Kind.GOLD)
	check("a respec is offered, with its price on the button",
		_press(screen, "Refund"))
	await _settle()
	check("  and the first press only warns",
		r.progress(a).spent_points() == had_spent,
		"%d points still spent" % r.progress(a).spent_points())
	check("  the second press is the one that acts",
		_press(screen, "Confirm"))
	await _settle()
	check("  and it returns this champion's points",
		r.progress(a).spent_points() == 0)
	check("  for the gold it quoted",
		r.wallet.balance(Wallet.Kind.GOLD) == purse - quoted,
		"%d gold for %d points" % [quoted, had_spent])
	await _close(shell)


# ------------------------------------------------------------------------------
# Stash
# ------------------------------------------------------------------------------

func _stash(heroes: PackedStringArray) -> void:
	print("\n=== the stash makes the gear legible ===")
	var r := _rich_roster(heroes)
	var hero: String = r.owned_names()[0]
	var shell := _shell(r)
	shell.goto(UiRoute.STASH, hero)
	await _settle()
	var screen: UiScreen = shell.current_screen()

	var bare_damage: float = r.effective_damage(hero)
	var bare_health: float = r.effective_health(hero)
	var loose_before: int = r.stash.count()
	check("the pooled stash has something in it", loose_before > 0,
		"%d items" % loose_before)

	check("the best gear can be equipped in one action",
		_press(screen, "Equip best ·"))
	await _settle()
	var worn: int = r.stash.gear_of(hero).keys().size()
	check("  gear is on the champion", worn > 0, "%d slots filled" % worn)
	check("  and came out of the shared pool",
		r.stash.count() == loose_before - worn,
		"%d -> %d loose" % [loose_before, r.stash.count()])
	check("  the champion is measurably stronger",
		r.effective_damage(hero) > bare_damage
		and r.effective_health(hero) > bare_health,
		"damage %.0f -> %.0f, health %.0f -> %.0f" % [bare_damage,
			r.effective_damage(hero), bare_health, r.effective_health(hero)])

	# The screen's entire job: show that difference, since gear is invisible.
	var with_gear: String = "%.0f" % r.effective_damage(hero)
	var shows_delta: bool = false
	var says_invisible: bool = false
	for t in _strings(screen):
		if t == with_gear:
			shows_delta = true
		if t.findn("never drawn on your champion") >= 0:
			says_invisible = true
	check("the gear's contribution is on screen", shows_delta,
		"damage with gear %s" % with_gear)
	check("  and the screen is honest that gear is invisible", says_invisible)

	check("a piece can be taken off", _press(screen, "Take off"))
	await _settle()
	check("  and goes back to the shared pool",
		r.stash.gear_of(hero).keys().size() == worn - 1
		and r.stash.count() == loose_before - worn + 1,
		"%d slots, %d loose" % [r.stash.gear_of(hero).keys().size(),
			r.stash.count()])

	check("the pool itself can be browsed", _press(screen, "Stash ("))
	await _settle()
	var list: VirtualList = (_lists(screen) as Array)[0]
	check("  every loose item is listed", list.count() == r.stash.count(),
		"%d rows for %d items" % [list.count(), r.stash.count()])
	var pooled: int = _rows(screen).size()
	check("  rows are recycled", pooled <= 24,
		"%d row nodes" % pooled)

	var pool_before: Dictionary = {}
	for it in r.stash.items:
		pool_before[it.id] = true
	var equipped_one: bool = false
	for row in _rows(screen):
		var b: Button = _button_with(row, "Equip")
		if b != null and b.visible and not b.disabled:
			b.pressed.emit()
			equipped_one = true
			break
	await _settle()
	# The loose COUNT is the wrong thing to assert on: the pool is sorted best
	# first, so the top row is usually an upgrade for a slot that is already
	# filled, and Stash.equip returns the displaced piece to the pool. One out,
	# one in, count unchanged. What has to be true is that a piece which was
	# loose a moment ago is now worn.
	var moved: Array = []
	var gear: Dictionary = r.stash.gear_of(hero)
	for slot in gear.keys():
		if pool_before.has((gear[slot] as Item).id):
			moved.append(slot)
	check("an item can be equipped from the pool",
		equipped_one and moved.size() == 1,
		"%d of %d loose pieces moved onto the champion" % [moved.size(),
			pool_before.size()])
	await _close(shell)


# ------------------------------------------------------------------------------
# Merchant
# ------------------------------------------------------------------------------

func _merchant(heroes: PackedStringArray) -> void:
	print("\n=== the merchant trades against the wallet ===")
	var r := _rich_roster(heroes)
	var hero: String = r.owned_names()[0]
	var shell := _shell(r)
	shell.goto(UiRoute.SHOP, hero)
	await _settle()
	var screen: UiScreen = shell.current_screen()

	var offers: Array = []
	for row in _rows(screen):
		if _button_with(row, "Buy") != null:
			offers.append(row)
	check("the merchant has stock", offers.size() == Shop.OFFER_COUNT,
		"%d offers" % offers.size())

	var gold_before: int = r.wallet.balance(Wallet.Kind.GOLD)
	var items_before: int = r.stash.count()
	var bought: bool = false
	for row in offers:
		var b: Button = _button_with(row, "Buy")
		if b != null and not b.disabled:
			b.pressed.emit()
			bought = true
			break
	await _settle()
	check("buying costs gold and fills the stash", bought
		and r.wallet.balance(Wallet.Kind.GOLD) < gold_before
		and r.stash.count() == items_before + 1,
		"%s -> %s gold, %d -> %d items" % [HeroTheme.money(gold_before),
			HeroTheme.money(r.wallet.balance(Wallet.Kind.GOLD)),
			items_before, r.stash.count()])

	check("the sell list opens", _press(screen, "Sell ("))
	await _settle()
	gold_before = r.wallet.balance(Wallet.Kind.GOLD)
	items_before = r.stash.count()
	var sold: bool = false
	for row in _rows(screen):
		var b: Button = _button_with(row, "Sell")
		if b != null and b.visible and not b.disabled:
			b.pressed.emit()
			sold = true
			break
	await _settle()
	check("selling pays gold out of the stash", sold
		and r.wallet.balance(Wallet.Kind.GOLD) > gold_before
		and r.stash.count() == items_before - 1,
		"%s -> %s gold, %d -> %d items" % [HeroTheme.money(gold_before),
			HeroTheme.money(r.wallet.balance(Wallet.Kind.GOLD)),
			items_before, r.stash.count()])

	# The bulk sale is the one irreversible action in the shell, so it must take
	# two taps.
	items_before = r.stash.count()
	check("a bulk sale arms before it fires", _press(screen, "Sell everything"))
	await _settle()
	check("  nothing was sold on the first tap",
		r.stash.count() == items_before, "%d items" % r.stash.count())
	check("  the second tap confirms", _press(screen, "Tap again"))
	await _settle()
	check("  and the chaff is gone", r.stash.count() < items_before,
		"%d -> %d items" % [items_before, r.stash.count()])
	for it in r.stash.items:
		if it.rarity < Item.Rarity.RARE:
			check("  only below-Rare pieces were sold", false, it.item_name)
			break
	await _close(shell)


# ------------------------------------------------------------------------------
# Campaign
# ------------------------------------------------------------------------------

func _campaign(heroes: PackedStringArray) -> void:
	print("\n=== the campaign screen gates on the real rules ===")
	var r := _rich_roster(heroes)
	var hero: String = r.owned_names()[0]
	var shell := _shell(r)
	shell.goto(UiRoute.CAMPAIGN, hero)
	await _settle()
	var screen: UiScreen = shell.current_screen()

	# EVERY REGION MUST STILL BE REACHABLE. This used to be "the list has one
	# row per region", which a carousel cannot satisfy — but the property it
	# was protecting is reach, not rows, and dropping the list is exactly how
	# reach gets lost. The act row is what replaces the scrollbar: ten
	# buttons, so the last act is one tap away rather than ninety.
	var acts: int = 0
	for b in _all_buttons(screen):
		if (b as Button).tooltip_text.is_empty():
			continue
		for a in range(Campaign.act_count()):
			if (b as Button).tooltip_text == Campaign.act_name(a):
				acts += 1
	check("every act can be jumped to", acts == Campaign.act_count(),
		"%d of %d acts" % [acts, Campaign.act_count()])
	check("...which is how the whole campaign stays in reach",
		Campaign.act_count() * Campaign.maps_per_act()
			>= Campaign.region_count(),
		"%d acts x %d maps covers %d regions" % [Campaign.act_count(),
			Campaign.maps_per_act(), Campaign.region_count()])

	var locked: Button = _button_with(screen, Campaign.tier_name(
		Campaign.Tier.MERCILESS))
	check("a tier the account has not unlocked is refused",
		locked != null and locked.disabled)

	# Normal is unlocked but a level-1 champion may still enter it, so the
	# enterable path is the one to prove.
	check("the chosen region can be entered",
		_button_with(screen, "Enter") != null,
		_button_with(screen, "Enter").text if _button_with(screen, "Enter") != null else "")

	r.unlocked_tier = Campaign.Tier.VETERAN
	shell.goto(UiRoute.CAMPAIGN, hero)
	await _settle()
	screen = shell.current_screen()
	check("a tier unlocked but out of reach says why",
		_press(screen, Campaign.tier_name(Campaign.Tier.VETERAN)))
	await _settle()
	var reason: String = Campaign.entry_blocked_reason(Campaign.Tier.VETERAN,
		r.progress(hero), r.unlocked_tier)
	var said: bool = false
	for t in _strings(screen):
		if reason != "" and t.findn(reason) >= 0:
			said = true
	check("  Campaign.entry_blocked_reason is shown verbatim", said, reason)
	var enter: Button = _button_with(screen, "Choose a difficulty")
	check("  and entering is refused", enter != null and enter.disabled)
	await _close(shell)


# ------------------------------------------------------------------------------
# The handoff into the game
# ------------------------------------------------------------------------------

func _handoff(heroes: PackedStringArray) -> void:
	print("\n=== launching hands Play.tscn the champion and the region ===")
	var r := _rich_roster(heroes)
	var hero: String = r.owned_names()[1]
	var shell := _shell(r)
	shell.goto(UiRoute.CAMPAIGN, hero)
	await _settle()

	# EARN THE REGION FIRST. The campaign is a sequence now — region 3 is
	# sealed until 1 and 2 are cleared, so without this the launcher refuses
	# and this test measures the gate instead of the handoff it is about.
	var region: int = 3
	for i in range(region):
		r.record_map_cleared(Campaign.Tier.NORMAL, i)
	shell.goto(UiRoute.LAUNCH, {"hero": hero, "region": region,
		"tier": Campaign.Tier.NORMAL})
	await _settle(2)

	var play: Node = null
	for c in shell.get_children():
		if c.get_script() != null and c is Node3D:
			play = c
	check("the game scene was instantiated", play != null)
	if play != null:
		check("  it was given the chosen champion",
			String(play.get("hero")) == hero, ChampionName.of(hero))
		# The biome id carries the map's DREAD as well as its name — that tag is
		# the only route the dread curve has into the game (see UiShell._launch),
		# so this checks both halves: the right place, lit for the right point in
		# the campaign. Comparing against the bare id would pass while every map
		# in the game was lit like map 1.
		var handed: String = String(play.get("biome"))
		check("  and the chosen region's ground, at its dread",
			int(play.get("world_seed"))
				== Campaign.region_seed(r.crystal_seed, region)
			and Biome.base_id(handed) == Campaign.biome_at(region)
			and absf(Biome.dread_in(handed) - Campaign.dread(region)) <= 0.01,
			"%s seed %d" % [handed, Campaign.region_seed(r.crystal_seed, region)])
	check("the menus are out of the way while playing",
		not (shell.get_node("Ui") as CanvasLayer).visible)

	# Leaving puts the shell back, which also joins the world-generation thread
	# through WorldBuilder._exit_tree.
	shell._return_to_menu()
	await _settle(2)
	check("leaving the game returns to the menus",
		(shell.get_node("Ui") as CanvasLayer).visible
		and shell.current_screen() != null)
	await _close(shell)


# ------------------------------------------------------------------------------
# Persistence
# ------------------------------------------------------------------------------

func _persistence(heroes: PackedStringArray) -> void:
	print("\n=== what the player did is in the save file ===")
	var r := _rich_roster(heroes)
	var hero: String = r.owned_names()[0]
	r.progress(hero).gain_xp(4000.0)
	var shell := _shell(r)
	shell.goto(UiRoute.SHEET, hero)
	await _settle()
	var screen: UiScreen = shell.current_screen()

	# Deleted first, so "the file exists" is evidence that THIS action wrote it
	# and not that an earlier section of this test left one behind. Safe: the
	# developer's own save was copied out in _run and is put back by
	# _restore_save.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Roster.SAVE_PATH))

	var plus: Array = _glyph_buttons(screen, UiGlyph.Kind.PLUS)
	check("the sheet offers a key per attribute", plus.size() == 4,
		"%d spend keys" % plus.size())
	if plus.size() > 0:
		(plus[0] as Button).pressed.emit()
	await _settle()

	var level: int = r.progress(hero).level
	var spent: int = r.progress(hero).spent_points()
	var gold: int = r.wallet.balance(Wallet.Kind.GOLD)
	check("spending a point wrote the save file",
		spent == 1 and FileAccess.file_exists(Roster.SAVE_PATH),
		"%d point spent" % spent)

	var reloaded: Roster = Roster.load_or_create(heroes)
	check("the champion's level survives a restart",
		reloaded.progress(hero) != null
		and reloaded.progress(hero).level == level, "L%d" % level)
	check("the spent skill point survives",
		reloaded.progress(hero) != null
		and reloaded.progress(hero).spent_points() == spent,
		"%d spent" % spent)
	check("the wallet survives", reloaded.wallet.balance(Wallet.Kind.GOLD)
		== gold, "%s gold" % HeroTheme.money(gold))
	check("the stash survives", reloaded.stash.count() == r.stash.count(),
		"%d items" % reloaded.stash.count())
	await _close(shell)


func _restore_save() -> void:
	if not _had_save:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(
			Roster.SAVE_PATH))
		return
	var f := FileAccess.open(Roster.SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(_backup)


func _all_buttons(node: Node, out: Array = []) -> Array:
	if node is Button:
		out.append(node)
	for c in node.get_children():
		_all_buttons(c, out)
	return out
