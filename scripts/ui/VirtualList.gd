class_name VirtualList
extends ScrollContainer
# ------------------------------------------------------------------------------
# A scrolling list that only ever holds as many row nodes as fit on screen.
#
# WHY THIS EXISTS: the roster is 139 champions and the stash holds up to 300
# items. Instantiating a row per entry means ~440 Controls, each with a
# stylebox, a glyph and four labels, built on a mid-range iPhone every time a
# screen opens — that is a visible hitch on open and a scroll that drops
# frames. Here the pool is (visible rows + 2), about sixteen nodes, and
# scrolling REBINDS them instead of creating any.
#
# The list owns no data. It is given a count, a factory for a blank row and a
# binder that fills one in, so the same machinery drives champions, stash
# items, shop offers and campaign regions.
# ------------------------------------------------------------------------------

const SPACING: int = 12

var row_height: int = HeroTheme.ROW_H

var _count: int = 0
var _factory: Callable                      # () -> Control
var _binder: Callable                       # (row: Control, index: int) -> void
var _content: Control
var _pool: Array[Control] = []
## Which entry each pooled row currently shows, so a scroll that does not
## change a row's entry does not rebind it.
var _showing: PackedInt32Array = PackedInt32Array()


func _init() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	_content = Control.new()
	# Rows are positioned by hand inside this, so it must not eat the touches
	# that belong to them.
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_content)

	resized.connect(_relayout)
	get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _sync(false))


## `factory` builds one blank row; `binder` fills a row in for an entry.
func configure(factory: Callable, binder: Callable, height: int = -1) -> void:
	_factory = factory
	_binder = binder
	if height > 0:
		row_height = height


func count() -> int:
	return _count


## Point the list at `n` entries. Rebinds everything visible, so this is also
## how a screen refreshes after the player changed something.
func set_count(n: int) -> void:
	_count = maxi(n, 0)
	_content.custom_minimum_size = Vector2(0,
		maxf(float(_count) * float(_step()) - SPACING, 0.0))
	_sync(true)


## Rebind what is on screen without changing the entry count.
func rebind() -> void:
	_sync(true)


func _step() -> int:
	return row_height + SPACING


func _relayout() -> void:
	_sync(true)


func _sync(force: bool) -> void:
	if _factory.is_null() or _binder.is_null():
		return
	var grew: bool = false
	var step: int = _step()
	var width: float = maxf(_content.size.x, size.x - 8.0)
	# One row above and one below the viewport, so a fast flick never shows a
	# blank strip before the bind catches up.
	var visible_rows: int = int(ceil(size.y / float(step))) + 2
	var first: int = maxi(int(floor(scroll_vertical / float(step))) - 1, 0)

	while _pool.size() < visible_rows:
		var row: Control = _factory.call()
		if row == null:
			return
		_content.add_child(row)
		_pool.append(row)
		_showing.append(-1)

	for k in range(_pool.size()):
		var row: Control = _pool[k]
		var idx: int = first + k
		if idx >= _count or k >= visible_rows:
			row.visible = false
			_showing[k] = -1
			continue
		row.visible = true
		row.position = Vector2(0, float(idx * step))
		row.size = Vector2(width, float(row_height))
		if force or _showing[k] != idx:
			_showing[k] = idx
			_binder.call(row, idx)
		# A recycled row is one height for every entry, but what goes IN a row
		# varies — some entries carry a third line, some do not. Take the step
		# from the tallest row actually bound rather than assuming ROW_H fits
		# everything, or that third line draws over the entry below it.
		var need: int = int(ceil(row.get_combined_minimum_size().y))
		if need > row_height:
			row_height = need
			grew = true

	if grew:
		# One re-run at the new step. Guarded by the height only ever rising,
		# so this cannot ping-pong.
		_sync(true)
