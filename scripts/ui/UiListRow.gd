class_name UiListRow
extends Button
# ------------------------------------------------------------------------------
# One row in any list in the shell: a champion, a stash item, a shop offer, a
# campaign region.
#
# IT IS A BUTTON, not a panel with a button in it. The whole 190 px row is the
# touch target, because a phone row with a small "view" affordance on the right
# is a row most thumbs miss. Up to two explicit actions (Equip / Sell, Buy,
# Unlock) sit on the right and take precedence over the row tap.
#
# ONE CLASS FOR EVERY LIST because the rows are recycled by VirtualList — a
# single configure() that rebinds text and colour is what lets 139 champions or
# 300 items scroll on sixteen nodes.
# ------------------------------------------------------------------------------

signal row_pressed(index: int)
signal action_pressed(index: int, action: int)

const ACTION_W: int = 250

## Which list entry this row is currently showing. Set by VirtualList before
## each configure(); the action buttons report it back so a recycled row can
## never act on the entry it used to hold.
var index: int = -1

var _glyph: UiGlyph
var _title: Label
var _subtitle: Label
var _note: Label
var _value: Label
var _chevron: UiGlyph
var _actions: Array[Button] = []
var _edge: Color = HeroTheme.LINE


func _init() -> void:
	text = ""
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(0, HeroTheme.ROW_H)
	_restyle(HeroTheme.LINE)

	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_theme_constant_override("margin_left", 34)
	pad.add_theme_constant_override("margin_right", 24)
	pad.add_theme_constant_override("margin_top", 18)
	pad.add_theme_constant_override("margin_bottom", 18)
	add_child(pad)

	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override("separation", HeroTheme.GAP)
	pad.add_child(line)

	_glyph = UiGlyph.make(UiGlyph.Kind.BLADE, 58)
	line.add_child(_glyph)

	var stack := VBoxContainer.new()
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_theme_constant_override("separation", 6)
	line.add_child(stack)

	_title = HeroTheme.clipped("", HeroTheme.F_BODY)
	stack.add_child(_title)
	_subtitle = HeroTheme.clipped("", HeroTheme.F_SMALL, HeroTheme.DIM)
	stack.add_child(_subtitle)
	_note = HeroTheme.clipped("", HeroTheme.F_SMALL, HeroTheme.ACCENT)
	stack.add_child(_note)

	_value = HeroTheme.label("", HeroTheme.F_BODY, HeroTheme.TEXT,
		HORIZONTAL_ALIGNMENT_RIGHT)
	line.add_child(_value)

	for i in range(2):
		var b := HeroTheme.button("", HeroTheme.Btn.SECONDARY,
			HeroTheme.TAP_SMALL)
		b.custom_minimum_size = Vector2(ACTION_W, HeroTheme.TAP_SMALL)
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		b.visible = false
		b.pressed.connect(_on_action.bind(i))
		_actions.append(b)
		line.add_child(b)

	_chevron = UiGlyph.make(UiGlyph.Kind.CHEVRON, 44, HeroTheme.FAINT)
	line.add_child(_chevron)

	pressed.connect(func() -> void: row_pressed.emit(index))


func _on_action(which: int) -> void:
	action_pressed.emit(index, which)


# Rebuilding the style boxes on every bind would allocate on every scrolled
# pixel, so the rarity edge is only rebuilt when the colour actually changes.
func _restyle(edge: Color) -> void:
	_edge = edge
	var normal := HeroTheme.edge_style(HeroTheme.PANEL, edge)
	normal.set_content_margin_all(0)
	var down := HeroTheme.edge_style(HeroTheme.PANEL_HI, edge)
	down.set_content_margin_all(0)
	add_theme_stylebox_override("normal", normal)
	add_theme_stylebox_override("hover", normal)
	add_theme_stylebox_override("focus", normal)
	add_theme_stylebox_override("pressed", down)
	add_theme_stylebox_override("disabled", normal)


# ------------------------------------------------------------------------------

## `actions` is one label per button, "" to hide it. `note` is the third line —
## an upgrade marker, an unspent-points nudge, a reason a tier is locked.
func configure(title: String, subtitle: String, value: String, edge: Color,
		glyph: int = -1, note: String = "",
		actions: PackedStringArray = PackedStringArray()) -> void:
	if edge != _edge:
		_restyle(edge)
	_title.text = title
	_title.add_theme_color_override("font_color", HeroTheme.TEXT)
	_subtitle.text = subtitle
	_note.text = note
	_note.visible = note != ""
	_value.text = value
	_value.visible = value != ""

	_glyph.visible = glyph >= 0
	if glyph >= 0:
		_glyph.kind = glyph
		_glyph.tint = edge

	for i in range(_actions.size()):
		var on: bool = i < actions.size() and actions[i] != ""
		_actions[i].visible = on
		_actions[i].disabled = false
		if on:
			_actions[i].text = actions[i]


## Tint the title — used for item names, which carry their rarity colour.
func title_colour(c: Color) -> void:
	_title.add_theme_color_override("font_color", c)


func note_colour(c: Color) -> void:
	_note.add_theme_color_override("font_color", c)


func value_colour(c: Color) -> void:
	_value.add_theme_color_override("font_color", c)


func show_chevron(on: bool) -> void:
	_chevron.visible = on


func set_action_disabled(which: int, off: bool) -> void:
	if which >= 0 and which < _actions.size():
		_actions[which].disabled = off
