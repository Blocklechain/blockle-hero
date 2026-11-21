class_name UiScreen
extends Control
# ------------------------------------------------------------------------------
# What every screen in the shell has in common.
#
# A screen is handed the real Roster — never a copy, never mock data — plus the
# champion currently in context. It does not know how to navigate and it does
# not know how to save: it asks, by signal, and UiShell does both. That split
# is what makes the screens testable headlessly (tools/uitest.gd drives them
# with no shell at all) and it is what guarantees there is exactly ONE place
# that writes user://roster.json.
#
# Layout is fixed for all screens: a header that does not scroll, a body that
# does, and a footer that holds the one action the thumb should be able to
# reach without looking. On a 2532 px-tall phone the footer is the only part of
# the screen a one-handed grip can comfortably hit.
# ------------------------------------------------------------------------------

## Where the player asked to go. `arg` carries a champion id or a route-specific
## payload; UiShell owns the routing table.
signal navigate(route: String, arg: Variant)

## The roster was mutated and must be persisted. Screens never call save()
## themselves — see UiShell._on_state_changed.
signal state_changed()

## A short message for the player: why a purchase failed, what a bulk action
## did. Shown by the shell as a transient line, never as a modal.
signal notified(text: String)

## Ask the shell to play the champion-arrival sequence. Raised here rather
## than built by the screen because it covers the WHOLE display, including the
## currency bar and the tab strip, and a screen owns none of those.
signal reveal_champion(hero: String, duplicate: bool, gold: int)


var roster: Roster = null
## The champion this screen acts on. "" on screens that have no subject.
var hero: String = ""

var header: HBoxContainer
var content: VBoxContainer
var footer: VBoxContainer

var _title_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", HeroTheme.GAP)
	add_child(col)

	header = HBoxContainer.new()
	header.add_theme_constant_override("separation", HeroTheme.GAP)
	header.custom_minimum_size = Vector2(0, HeroTheme.TAP)
	header.visible = wants_header()
	col.add_child(header)

	if show_back():
		var back := HeroTheme.button("", HeroTheme.Btn.GHOST)
		back.custom_minimum_size = Vector2(HeroTheme.TAP, HeroTheme.TAP)
		var glyph := UiGlyph.make(UiGlyph.Kind.BACK, 52, HeroTheme.TEXT)
		glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
		back.add_child(glyph)
		back.pressed.connect(func() -> void: navigate.emit(back_route(), hero))
		header.add_child(back)

	_title_label = HeroTheme.label(screen_title(), HeroTheme.F_HEAD)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(_title_label)
	header.visible = wants_header()

	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", HeroTheme.GAP)
	col.add_child(content)

	footer = VBoxContainer.new()
	footer.add_theme_constant_override("separation", 14)
	col.add_child(footer)

	build()


# --- the bits a screen overrides ----------------------------------------------

func screen_title() -> String:
	return ""


func show_back() -> bool:
	return true


## Whether this screen draws its OWN title row.
##
## False for everything now: the back button and the title moved into the
## currency bar, which was already on screen and already had the room. A
## screen that wants a header of its own can still say so.
func wants_header() -> bool:
	return false


## Where the back button goes. Champion-contextual screens return to the sheet,
## the rest to the champion list.
func back_route() -> String:
	return UiRoute.CHAMPIONS


## Build the screen. Called once, with `roster` and `hero` already set.
func build() -> void:
	pass


## Re-read the roster and update everything on screen. Called after the player
## changes something here, so no screen keeps a stale copy of a balance.
func refresh() -> void:
	pass


# --- helpers every screen uses ------------------------------------------------

func set_title(text: String) -> void:
	if _title_label != null:
		_title_label.text = text


## A scrolling column for screens whose content is prose and panels rather than
## a long list. Lists use VirtualList instead.
func scroll_column() -> VBoxContainer:
	var sc := ScrollContainer.new()
	TouchScroll.attach(sc)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(sc)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", HeroTheme.GAP)
	sc.add_child(col)
	return col


## A LANDSCAPE SPLIT: something fixed on the left, a scrolling column right.
##
## The menus were authored as one narrow centred column, which is a portrait
## shape. In a 2532 px-wide viewport that wastes two thirds of the glass and
## pushes the content the player came for off the bottom of a 1170 px-tall
## screen. Returns the scrolling column; the caller fills `left` itself.
func split_column(left: Control) -> VBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", HeroTheme.GAP * 2)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(row)

	left.custom_minimum_size = Vector2(HeroTheme.COL_W, 0)
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(left)

	var sc := ScrollContainer.new()
	TouchScroll.attach(sc)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(sc)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", HeroTheme.GAP)
	sc.add_child(col)
	return col


## Like split_column, but the right side does NOT scroll.
##
## A ScrollContainer hands its child the child's MINIMUM height, so anything
## that scrolls itself — a VirtualList — collapses to nothing inside one. The
## campaign's hundred-map list did exactly that and vanished. Screens whose
## right column is a list want this; screens whose right column is prose want
## split_column.
func split_fixed(left: Control) -> VBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", HeroTheme.GAP * 2)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(row)

	left.custom_minimum_size = Vector2(HeroTheme.COL_W, 0)
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(left)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", HeroTheme.GAP)
	row.add_child(col)
	return col


## The strip that says which champion everything on this screen applies to.
## Tapping it goes back to the champion list — the stash, the merchant and the
## campaign all act on ONE champion, and that has to be impossible to miss.
func context_strip() -> Control:
	var b := HeroTheme.button("", HeroTheme.Btn.SECONDARY, 150)
	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_theme_constant_override("margin_left", 28)
	pad.add_theme_constant_override("margin_right", 24)
	b.add_child(pad)

	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override("separation", HeroTheme.GAP)
	pad.add_child(line)

	var p: HeroProgress = roster.progress(hero) if roster != null else null
	var cls: int = p.hero_class if p != null else HeroClass.Kind.FIGHTER
	line.add_child(UiGlyph.make(UiGlyph.for_class(cls), 54,
		Champion.colour(hero)))

	var stack := VBoxContainer.new()
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_theme_constant_override("separation", 4)
	line.add_child(stack)
	stack.add_child(HeroTheme.clipped(ChampionName.of(hero), HeroTheme.F_BODY))
	var sub: String = "—"
	if p != null:
		sub = "%s %s · level %d" % [Champion.rarity_name(hero),
			p.class_name_str(), p.level]
	stack.add_child(HeroTheme.clipped(sub, HeroTheme.F_SMALL, HeroTheme.DIM))

	stack.add_child(HeroTheme.label("Change champion", HeroTheme.F_SMALL,
		HeroTheme.ACCENT))
	line.add_child(UiGlyph.make(UiGlyph.Kind.CHEVRON, 44, HeroTheme.FAINT))

	b.pressed.connect(func() -> void:
		navigate.emit(UiRoute.CHAMPIONS, hero))
	return b


## A titled panel, added to `parent`, returning the column to fill in. Most of
## this UI is one of these.
static func group(parent: Container, title: String,
		accent: Color = HeroTheme.LINE) -> VBoxContainer:
	var p := HeroTheme.panel(HeroTheme.PANEL, accent)
	parent.add_child(p)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	p.add_child(col)
	if title != "":
		col.add_child(HeroTheme.label(title, HeroTheme.F_SMALL, HeroTheme.DIM))
	return col


## A label/value line, the workhorse of the character sheet and the stash.
static func stat_line(key: String, value: String, value_colour: Color = HeroTheme.TEXT,
		value_size: int = HeroTheme.F_BODY) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var k := HeroTheme.label(key, HeroTheme.F_BODY, HeroTheme.DIM)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(k)
	h.add_child(HeroTheme.label(value, value_size, value_colour,
		HORIZONTAL_ALIGNMENT_RIGHT))
	return h


func mutated() -> void:
	state_changed.emit()
	refresh()
