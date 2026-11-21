class_name TouchScroll
extends Node
# ------------------------------------------------------------------------------
# Makes a ScrollContainer scroll with a FINGER.
#
# Godot's ScrollContainer already handles touch dragging — in `_gui_input`,
# which only runs on events no child consumed. Every row in this game is a
# Button, and a Control with MOUSE_FILTER_STOP consumes the whole gesture
# whether or not it does anything with it. So the drag dies on the row and the
# list never moves.
#
# On a desktop the wheel goes to the ScrollContainer directly and everything
# looks fine, which is exactly why this survived every screenshot pass: the
# capture tool has a mouse and the player has a thumb.
#
# This watches `_input`, which runs BEFORE GUI dispatch, so it sees the gesture
# first. It arms on a touch inside its container, starts scrolling once the
# finger has moved past a deadzone, and from that moment swallows the gesture
# so the row underneath never fires. A tap is still a tap: below the deadzone
# nothing is consumed and the Button behaves normally.
#
#   TouchScroll.attach(some_scroll_container)
# ------------------------------------------------------------------------------

## How far a finger must travel before this is a scroll and not a tap, in
## pixels at the design resolution. Below it, taps on a row still work; above
## it, the row is let go of. Roughly a finger's worth of wobble.
const DEADZONE: float = 24.0

## Carried after release, decaying, so a flick keeps going.
const FRICTION: float = 6.0
## Below this the glide stops rather than creeping for another second.
const STOP_AT: float = 8.0

var _sc: ScrollContainer
var _touch: int = -1
var _from: float = 0.0
var _at_press: float = 0.0
var _dragging: bool = false
var _velocity: float = 0.0


## Give `sc` finger scrolling. Safe to call more than once; the second call
## does nothing.
static func attach(sc: ScrollContainer) -> TouchScroll:
	if sc == null:
		return null
	for c in sc.get_children():
		if c is TouchScroll:
			return c
	var t := TouchScroll.new()
	t.name = "TouchScroll"
	t._sc = sc
	sc.add_child(t)
	return t


func _ready() -> void:
	set_process(true)
	set_process_input(true)


func _max_scroll() -> float:
	var bar: VScrollBar = _sc.get_v_scroll_bar()
	return maxf(bar.max_value - bar.page, 0.0)


func _input(e: InputEvent) -> void:
	if _sc == null or not _sc.is_visible_in_tree():
		return

	if e is InputEventScreenTouch:
		var touch := e as InputEventScreenTouch
		if touch.pressed:
			if _touch != -1:
				return
			if not _sc.get_global_rect().has_point(touch.position):
				return
			# Armed, NOT consumed. Most touches on a list are taps, and a tap
			# that got eaten here would be a row that never responds.
			_touch = touch.index
			_from = touch.position.y
			_at_press = _sc.scroll_vertical
			_dragging = false
			_velocity = 0.0
		elif touch.index == _touch:
			_touch = -1
			if _dragging:
				# Swallow the release: the Button under the finger is waiting
				# for it to fire row_pressed, and the player was scrolling.
				_dragging = false
				get_viewport().set_input_as_handled()
		return

	if not (e is InputEventScreenDrag):
		return
	var drag := e as InputEventScreenDrag
	if drag.index != _touch:
		return

	var moved: float = drag.position.y - _from
	if not _dragging:
		if absf(moved) < DEADZONE:
			return
		_dragging = true
		# Let go of whatever the finger landed on, so it does not sit lit up
		# for the whole scroll.
		_unpress(_sc)

	_sc.scroll_vertical = int(clampf(_at_press - moved, 0.0, _max_scroll()))
	_velocity = -drag.velocity.y
	get_viewport().set_input_as_handled()


## Carry a flick past the release. Without it every list stops dead the
## instant the finger lifts, which on a hundred-entry list means flicking
## through it one screenful at a time.
func _process(delta: float) -> void:
	if _dragging or absf(_velocity) < STOP_AT or _sc == null:
		return
	_sc.scroll_vertical = int(clampf(
		float(_sc.scroll_vertical) + _velocity * delta, 0.0, _max_scroll()))
	_velocity = move_toward(_velocity, 0.0, absf(_velocity) * FRICTION * delta)
	if _sc.scroll_vertical <= 0 or _sc.scroll_vertical >= int(_max_scroll()):
		_velocity = 0.0


## Release every button under this container. Walked rather than tracked
## because the rows are pooled and recycled, so the set changes as you scroll.
func _unpress(n: Node) -> void:
	for c in n.get_children():
		if c is BaseButton:
			(c as BaseButton).set_pressed_no_signal(false)
		_unpress(c)
