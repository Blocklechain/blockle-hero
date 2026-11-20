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

	var mark := UiGlyph.make(UiGlyph.Kind.MARK, 56, HeroTheme.ACCENT)
	line.add_child(mark)

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
