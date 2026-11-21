class_name CurrencyBar
extends PanelContainer
# ------------------------------------------------------------------------------
# Gold, gems and spawn crystals, always on screen.
#
# All three are consumable IAP products (IAPCatalog.gd), which makes their
# balances the most sensitive numbers in the app: the stash sells into gold, the
# champion list spends gems and crystals, and a balance that is one frame stale
# after a purchase is the kind of thing players screenshot. So this reads the
# live Wallet and subscribes to Wallet.changed rather than being told to update
# by whichever screen happens to have spent something.
# ------------------------------------------------------------------------------

var _wallet: Wallet = null
var _values: Dictionary = {}           # Wallet.Kind -> Label
var _back: Button
var _title: Label
var _mark: Control


func _init() -> void:
	var sb := HeroTheme.panel_style(HeroTheme.BG_LIFT, HeroTheme.LINE, 0, 0)
	sb.set_content_margin_all(18)
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.border_width_bottom = 2
	add_theme_stylebox_override("panel", sb)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", HeroTheme.GAP)
	add_child(line)

	# THE BACK BUTTON AND THE TITLE LIVE HERE NOW.
	#
	# Every screen used to stack five horizontal bands — currency bar, a
	# header holding nothing but a chevron and one word, the content, a
	# footer, and the tab strip — before any of the game appeared. Two of
	# those carried almost nothing. Folding the header into this bar gives
	# every screen back about a tenth of its height and removes a rule across
	# the display, which is the thing that was reading as clutter.
	_back = HeroTheme.button("", HeroTheme.Btn.GHOST)
	_back.custom_minimum_size = Vector2(HeroTheme.TAP, HeroTheme.TAP)
	var glyph := UiGlyph.make(UiGlyph.Kind.BACK, 52, HeroTheme.TEXT)
	glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
	_back.add_child(glyph)
	_back.visible = false
	line.add_child(_back)

	_mark = UiGlyph.make(UiGlyph.Kind.MARK, 56, HeroTheme.ACCENT)
	line.add_child(_mark)

	_title = HeroTheme.label("", HeroTheme.F_HEAD)
	_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(_title)

	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(gap)

	for kind in [Wallet.Kind.GOLD, Wallet.Kind.GEMS, Wallet.Kind.CRYSTALS]:
		var cell := HBoxContainer.new()
		cell.add_theme_constant_override("separation", 10)
		cell.tooltip_text = String(Wallet.KIND_NAMES[kind])
		line.add_child(cell)
		cell.add_child(UiGlyph.make(UiGlyph.for_currency(kind), 48,
			HeroTheme.currency_colour(kind)))
		var value := HeroTheme.label("0", HeroTheme.F_BODY,
			HeroTheme.currency_colour(kind))
		value.custom_minimum_size = Vector2(150, 0)
		_values[kind] = value
		cell.add_child(value)


## Watch a wallet. Safe to call again with the same wallet.
func bind_wallet(w: Wallet) -> void:
	if _wallet == w:
		refresh()
		return
	if _wallet != null and _wallet.changed.is_connected(_on_changed):
		_wallet.changed.disconnect(_on_changed)
	_wallet = w
	if _wallet != null:
		_wallet.changed.connect(_on_changed)
	refresh()


func _on_changed(_kind: int, _amount: int, _balance: int, _reason: String) -> void:
	refresh()


func refresh() -> void:
	if _wallet == null:
		return
	for kind in _values.keys():
		(_values[kind] as Label).text = HeroTheme.money(_wallet.balance(kind))


## Put the current screen's name, and its way back, in the bar.
##
## `on_back` empty means this screen is the root: the chevron is hidden and
## the mark stands in for it, so the bar never shows a way back to nowhere.
func set_context(title: String, on_back: Callable) -> void:
	if _title == null:
		return
	_title.text = title
	var has_back: bool = not on_back.is_null()
	_back.visible = has_back
	# The mark is the logo AND the spacer. With a chevron beside it the row
	# reads as two competing icons, so it steps aside.
	_mark.visible = not has_back
	for c in _back.pressed.get_connections():
		_back.pressed.disconnect(c["callable"])
	if has_back:
		_back.pressed.connect(on_back)
