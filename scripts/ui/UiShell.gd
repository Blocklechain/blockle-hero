class_name UiShell
extends Node
# ------------------------------------------------------------------------------
# THE MENU SHELL: the thing that makes the rest of the game reachable.
#
# Before this existed the project booted straight into scenes/Play.tscn and
# every system behind it — the roster, the stash, the merchant, the wallet, the
# campaign ladder — was headless-tested GDScript with no way in. This node owns
# the one Roster, routes between screens, and hands off to Play.tscn with the
# champion and region the player chose.
#
# THREE RULES THAT LIVE HERE AND NOWHERE ELSE:
#   * ONE ROSTER. Every screen is handed this object, never a copy, so a sale
#     on the merchant screen is already true on the character sheet.
#   * ONE WRITER. Screens emit `state_changed`; only this node calls
#     Roster.save(). Persistence is a single file by design (Roster.gd) and it
#     stays that way by having a single caller.
#   * ONE WAY INTO THE GAME. `_launch` is the only place that instantiates
#     Play.tscn, and it sets the scene's three exports BEFORE the node enters
#     the tree, because Play.gd reads them in _ready().
# ------------------------------------------------------------------------------

const PLAY_SCENE: String = "res://scenes/Play.tscn"

## Assign before the node enters the tree to drive the shell with a roster of
## your own; tools/uitest.gd uses this so a test never touches the save file.
var roster: Roster = null

## The champion every champion-contextual screen acts on. Always owned.
var selected_hero: String = ""

var _ui: CanvasLayer
var _safe: MarginContainer
var _overlay: CanvasLayer

var _bar: CurrencyBar
var _host: Control
var _tabs: HBoxContainer
var _tab_buttons: Dictionary = {}          # route -> Button
var _screen: UiScreen = null
var _route: String = UiRoute.TITLE

var _toast: PanelContainer
var _toast_label: Label
var _toast_timer: Timer

var _play: Node = null
var _leave: Button
var _bag: Button = null


func _ready() -> void:
	_ui = get_node_or_null("Ui") as CanvasLayer
	_safe = get_node_or_null("Ui/Safe") as MarginContainer
	_overlay = get_node_or_null("Overlay") as CanvasLayer
	if _ui == null or _safe == null or _overlay == null:
		push_error("UiShell: scenes/Main.tscn is missing Ui/Safe or Overlay")
		return

	if roster == null:
		roster = Roster.load_or_create()
	_ensure_selection()
	_apply_safe_area()
	_build_chrome()
	_go(UiRoute.TITLE, "")


## A screen that acts on a champion must always have one, even on an account
## that has somehow ended up owning nothing.
func _ensure_selection() -> void:
	if roster.owns(selected_hero):
		return
	var owned: PackedStringArray = roster.owned_names()
	selected_hero = owned[0] if owned.size() > 0 else ""


# iOS has a notch and a home indicator, and the whole UI is one stretched
# viewport, so the safe area has to be converted from window pixels into
# viewport pixels before it means anything.
func _apply_safe_area() -> void:
	var top: int = 40
	var bottom: int = 40
	var win: Vector2i = DisplayServer.window_get_size()
	var area: Rect2i = DisplayServer.get_display_safe_area()
	if win.x > 0 and area.size.x > 0 and area.size.y > 0:
		var view: Vector2 = get_viewport().get_visible_rect().size
		var scale: float = view.x / float(win.x)
		top = int(float(area.position.y) * scale)
		bottom = int(float(win.y - (area.position.y + area.size.y)) * scale)
	_safe.add_theme_constant_override("margin_top",
		clampi(top, 24, 200) + HeroTheme.GAP)
	_safe.add_theme_constant_override("margin_bottom",
		clampi(bottom, 24, 200) + HeroTheme.GAP)
	_safe.add_theme_constant_override("margin_left", HeroTheme.PAD)
	_safe.add_theme_constant_override("margin_right", HeroTheme.PAD)


func _build_chrome() -> void:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", HeroTheme.GAP)
	_safe.add_child(column)

	_bar = CurrencyBar.new()
	_bar.bind_wallet(roster.wallet)
	column.add_child(_bar)

	_host = Control.new()
	_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_host.clip_contents = true
	column.add_child(_host)

	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 12)
	column.add_child(_tabs)
	var group := ButtonGroup.new()
	for pair in [[UiRoute.CHAMPIONS, "Champions"], [UiRoute.STASH, "Stash"],
			[UiRoute.SHOP, "Merchant"], [UiRoute.CAMPAIGN, "Campaign"]]:
		var b := HeroTheme.segment(String(pair[1]), group)
		b.add_theme_font_size_override("font_size", HeroTheme.F_SMALL)
		b.pressed.connect(_go.bind(String(pair[0]), ""))
		_tab_buttons[String(pair[0])] = b
		_tabs.add_child(b)

	# The toast sits on its own layer so it is readable over the menus AND over
	# the game — "progress saved" matters most on the way out.
	_toast = HeroTheme.panel(HeroTheme.BG_LIFT, HeroTheme.ACCENT)
	_toast.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_toast.offset_left = 40
	_toast.offset_right = -40
	_toast.offset_top = -300
	_toast.offset_bottom = -120
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.visible = false
	_toast_label = HeroTheme.prose("", HeroTheme.F_BODY, HeroTheme.TEXT)
	_toast.add_child(_toast_label)
	_overlay.add_child(_toast)

	_toast_timer = Timer.new()
	_toast_timer.one_shot = true
	_toast_timer.wait_time = 3.4
	_toast_timer.timeout.connect(func() -> void: _toast.visible = false)
	add_child(_toast_timer)


# ------------------------------------------------------------------------------
# Routing
# ------------------------------------------------------------------------------

## Go somewhere from outside the screen graph. The screens themselves navigate
## by signal; this is the entry point for tools/uitest.gd and for anything that
## later needs to open the shell at a particular screen.
func goto(route: String, arg: Variant = null) -> void:
	_go(route, arg)


## The screen on display, or null before the shell has built itself.
func current_screen() -> UiScreen:
	return _screen


func current_route() -> String:
	return _route


func _go(route: String, arg: Variant = null) -> void:
	if route == UiRoute.LAUNCH:
		_launch(arg)
		return
	if typeof(arg) == TYPE_STRING and String(arg) != "" \
			and roster.owns(String(arg)):
		selected_hero = String(arg)
	_ensure_selection()

	if _screen != null:
		_host.remove_child(_screen)
		_screen.queue_free()
		_screen = null

	_route = route
	_screen = _make_screen(route)
	if _screen == null:
		return
	_screen.roster = roster
	_screen.hero = selected_hero
	_screen.navigate.connect(_go)
	_screen.state_changed.connect(_on_state_changed)
	_screen.notified.connect(toast)
	_host.add_child(_screen)
	# FILL THE HOST, EXPLICITLY, AFTER PARENTING.
	#
	# UiScreen._ready() calls set_anchors_preset(FULL_RECT), which sets the
	# anchors and leaves the OFFSETS alone — so the screen stayed 0x0 inside a
	# 2464x872 host and every container under it fell back to its own minimum
	# width. The symptom was the entire menu squeezed into a ~420 px column on
	# a 2532 px-wide screen, with the champion list collapsed to nothing.
	# set_anchors_AND_OFFSETS_preset is the one that actually resizes.
	_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var chrome: bool = route != UiRoute.TITLE
	_bar.visible = chrome
	_tabs.visible = chrome
	# The character sheet is pushed on top of the champion list, so the list's
	# tab stays lit rather than leaving every tab dark.
	var lit: String = UiRoute.CHAMPIONS if route == UiRoute.SHEET else route
	for key in _tab_buttons.keys():
		(_tab_buttons[key] as Button).button_pressed = String(key) == lit


func _make_screen(route: String) -> UiScreen:
	match route:
		UiRoute.TITLE: return TitleScreen.new()
		UiRoute.CHAMPIONS: return ChampionSelectScreen.new()
		UiRoute.SHEET: return ChampionSheetScreen.new()
		UiRoute.STASH: return StashScreen.new()
		UiRoute.SHOP: return ShopScreen.new()
		UiRoute.CAMPAIGN: return CampaignScreen.new()
	push_error("UiShell: no screen for route '%s'" % route)
	return null


func _on_state_changed() -> void:
	_bar.refresh()
	if not roster.save():
		toast("Could not save — your progress is still in this session.")


func toast(text: String) -> void:
	if text == "":
		return
	_toast_label.text = text
	_toast.visible = true
	_toast_timer.start()


# ------------------------------------------------------------------------------
# Into the game, and back out
# ------------------------------------------------------------------------------

func _launch(arg: Variant) -> void:
	var spec: Dictionary = arg if typeof(arg) == TYPE_DICTIONARY else {}
	var who: String = String(spec.get("hero", selected_hero))
	var region: int = clampi(int(spec.get("region", 0)), 0,
		Campaign.region_count() - 1)
	if not roster.owns(who):
		toast("Choose a champion first.")
		return
	# THE LAST GATE. The campaign screen checks too, but it is not the only
	# caller — the clear screen's "next stage" comes straight here, and so
	# would a deep link or a restored session. A rule enforced only in the UI
	# that happens to be on screen is not a rule.
	var want_tier: int = clampi(int(spec.get("tier", Campaign.Tier.NORMAL)),
		0, Campaign.tier_count() - 1)
	if not roster.is_map_unlocked(want_tier, region):
		toast("Region %d is sealed until you clear region %d."
			% [region + 1, region])
		return
	roster.save()

	var packed: PackedScene = load(PLAY_SCENE) as PackedScene
	if packed == null:
		toast("The game scene could not be loaded.")
		return
	_play = packed.instantiate()
	# set() rather than direct assignment: these are @export vars on Play.gd,
	# which this layer is not allowed to depend on by type.
	_play.set("world_seed", Campaign.region_seed(roster.crystal_seed, region))
	# THE DREAD CURVE ENTERS THE GAME HERE, in one line, and this is the only
	# place it can. Biome.tag() stamps the map's dread onto the biome id, and
	# every renderer downstream — terrain palette, props, ground cover, sky, fog,
	# key light — already resolves ids through Biome.get_biome(), so all of them
	# shift together off the single number Campaign.dread() gave this map. Pass
	# the bare id instead and map 100 is lit exactly like map 1.
	_play.set("biome", Biome.tag(Campaign.biome_at(region), Campaign.dread(region)))
	_play.set("hero", who)
	# WHICH MAP, WHICH CAMPAIGN, WHICH DIFFICULTY, WHICH LEVEL. Without these
	# Play falls back to map 0 of campaign 0 at tier Normal — and since the map
	# index drives the cast, the pack count and the boss, every region in the
	# game would be populated as though it were the first one.
	_play.set("region_index", region)
	# The clear screen is raised from here, not from inside Play: "what happens
	# after this map" is a question about the campaign and the save, which is
	# this layer's business, and Play has no idea the menus exist.
	_play.connect("region_cleared", _on_region_cleared)
	_play.set("campaign_seed", roster.crystal_seed)
	# The tier is in the launch payload and always has been — the campaign
	# screen puts it there. It was simply never read, so every difficulty the
	# player picked was played on Normal.
	_play.set("tier", want_tier)
	var prog: HeroProgress = roster.progress(who)
	if prog != null:
		_play.set("champion_level", prog.level)
	add_child(_play)

	_ui.visible = false
	_leave = HeroTheme.button("Menu", HeroTheme.Btn.GHOST, HeroTheme.TAP)
	_leave.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_leave.offset_left = -300
	_leave.offset_right = -40
	_leave.offset_top = 80
	_leave.offset_bottom = 80 + HeroTheme.TAP
	_leave.pressed.connect(_return_to_menu)
	_overlay.add_child(_leave)

	# INVENTORY, REACHABLE FROM THE RUN. Loot drops mid-fight and the whole
	# point of a pooled stash is swapping gear when you find it; making the
	# player abandon the map to equip what just dropped is the kind of friction
	# that turns a loot game into an errand.
	_bag = HeroTheme.button("Inventory", HeroTheme.Btn.GHOST, HeroTheme.TAP)
	_bag.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_bag.offset_left = -640
	_bag.offset_right = -320
	_bag.offset_top = 80
	_bag.offset_bottom = 80 + HeroTheme.TAP
	_bag.pressed.connect(_open_inventory)
	_overlay.add_child(_bag)
	toast("%s — %s" % [ChampionName.of(who),
		Campaign.region_title(region)])


## Open the stash without ending the run.
##
## THE RUN IS FROZEN, NOT LEFT. process_mode DISABLED stops the champion, the
## enemies, the cooldowns and the status ticks together — reading your bags
## while a boss keeps swinging is not a pause, it is a punishment. The map and
## its 580 MiB of loaded models stay exactly as they were, so coming back is
## instant rather than a regenerate.
func _open_inventory() -> void:
	if _play == null:
		return
	_play.process_mode = Node.PROCESS_MODE_DISABLED
	_play.visible = false
	_ui.visible = true
	if _bag != null:
		_bag.visible = false
	if _leave != null:
		_leave.text = "Resume"
		# Disconnect the quit and re-point it: the same button must not both
		# resume a frozen run and abandon it depending on state nobody can see.
		if _leave.pressed.is_connected(_return_to_menu):
			_leave.pressed.disconnect(_return_to_menu)
		if not _leave.pressed.is_connected(_resume_run):
			_leave.pressed.connect(_resume_run)
	goto(UiRoute.STASH)


func _resume_run() -> void:
	if _play == null:
		return
	_ui.visible = false
	_play.visible = true
	_play.process_mode = Node.PROCESS_MODE_INHERIT
	if _bag != null:
		_bag.visible = true
	if _leave != null:
		_leave.text = "Menu"
		if _leave.pressed.is_connected(_resume_run):
			_leave.pressed.disconnect(_resume_run)
		if not _leave.pressed.is_connected(_return_to_menu):
			_leave.pressed.connect(_return_to_menu)


## The boss went down. Put up the clear screen over the frozen region.
##
## The region is FROZEN, not torn down. Behind the panel is the field the
## player just won, with the corpse still on it — tearing it down to show a
## summary over a black rectangle throws away the only thing on screen that
## says where the numbers came from.
func _on_region_cleared(summary: Dictionary) -> void:
	if _play == null:
		return
	_play.process_mode = Node.PROCESS_MODE_DISABLED
	if _leave != null:
		_leave.visible = false

	var screen := ClearScreen.new()
	screen.name = "ClearScreen"
	_overlay.add_child(screen)
	screen.show_summary(summary)
	screen.back_to_camp.connect(func() -> void:
		screen.queue_free()
		_return_to_menu())
	screen.next_stage.connect(func() -> void:
		var next: int = int(summary.get("next", -1))
		var who: String = String(summary.get("hero", selected_hero))
		var tier: int = int(summary.get("tier", Campaign.Tier.NORMAL))
		screen.queue_free()
		_return_to_menu()
		if next >= 0:
			# Straight back in, same champion, same difficulty. Walking the
			# player out to the campaign screen to press the next map is the
			# friction this screen exists to remove.
			_launch({"hero": who, "region": next, "tier": tier}))


func _return_to_menu() -> void:
	if _play != null:
		_abandon_build(_play)
		remove_child(_play)
		# WorldBuilder joins its generation thread in _exit_tree, so leaving
		# mid-build is safe and never detaches a thread.
		_play.queue_free()
		_play = null
	if _leave != null:
		_leave.queue_free()
		_leave = null
	if _bag != null:
		_bag.queue_free()
		_bag = null
	_ui.visible = true
	_bar.refresh()
	if _screen != null:
		_screen.refresh()


# Leaving a region WHILE IT IS STILL GENERATING is the awkward case, because the
# work is on a thread that cannot be cancelled: WorldBuilder joins it on the way
# out of the tree and the finished world is then delivered by a deferred call,
# to a scene that is about to be freed. Letting that land makes Play.tscn parent
# a world into a detached node and snap a camera that is no longer in the tree
# (one engine error per abandoned load); dropping it instead leaks the world.
#
# So the shell takes delivery itself. It owns the lifetime of a scene it
# launched, and the only thing it does with the late arrival is free it.
func _abandon_build(play: Node) -> void:
	for child in play.get_children():
		var builder := child as WorldBuilder
		if builder == null or not builder.is_busy():
			continue
		var existing: Array = builder.finished.get_connections()
		for conn in existing:
			builder.finished.disconnect(conn["callable"])
		builder.finished.connect(
			func(world: Node3D, _ter: Terrain, _plan: Layout) -> void:
				if world != null:
					world.queue_free())


# iOS can suspend the app without ever sending a close request, and a player
# who loses a level because they switched apps will not come back.
func _notification(what: int) -> void:
	if roster == null:
		return
	if what == NOTIFICATION_APPLICATION_PAUSED \
			or what == NOTIFICATION_WM_CLOSE_REQUEST \
			or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		roster.save()
