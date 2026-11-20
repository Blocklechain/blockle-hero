class_name Joystick
extends Control
# ------------------------------------------------------------------------------
# The movement stick.
#
# IT FLOATS. There is no fixed ring to find: the stick appears wherever the
# thumb first lands inside its zone and re-centres there. A fixed stick means
# looking down to locate it, and on a phone held in two hands during a fight the
# player is looking at the fight. Every mobile ARPG that ships a fixed stick
# gets the same complaint, and the fix costs nothing.
#
# IT OWNS ONE TOUCH, BY INDEX. The stick and the ability buttons are used at the
# same time — walking backwards while casting is the whole point of a kiting
# class — so this tracks the finger that started it (`_touch`) and ignores every
# other. Tracking "is a touch down" instead would make the second finger steal
# the stick, which reads as the hero lurching whenever an ability is pressed.
# The same discipline leaves other fingers free for the pinch-zoom in Play.gd.
#
# The zone is the left portion of the screen, bounded so it cannot swallow the
# taps the camera and the HUD need. It deliberately does NOT cover the full left
# half: tap-to-move still works, and a stick that claims every touch on its side
# of the glass makes the rest of the interface feel broken.
# ------------------------------------------------------------------------------

## Direction in SCREEN space: +x right, +y down, length 0..1. Length scales the
## speed, so a half-pushed stick walks. Zero means released.
signal moved(dir: Vector2)

## The zone the stick may be summoned in, as a fraction of the viewport.
const ZONE_W: float = 0.42
## Kept off the very bottom so the home indicator's swipe area is not fought.
const ZONE_BOTTOM_INSET: float = 0.06

## Travel from centre to full deflection.
const RADIUS: float = 180.0
## Below this fraction of RADIUS the stick reads as released. A thumb resting on
## glass is never perfectly still, and without this the champion creeps.
const DEAD_ZONE: float = 0.14
## Above this fraction the champion runs rather than walks — the analogue range
## is what makes a stick better than a d-pad, so it is a real threshold and not
## a formality.
const RUN_AT: float = 0.55

const RING_R: float = 92.0
const KNOB_R: float = 46.0

var _touch: int = -1                     # finger index, -1 = released
var _origin: Vector2 = Vector2.ZERO      # where the stick was summoned
var _knob: Vector2 = Vector2.ZERO        # current thumb position
var _dir: Vector2 = Vector2.ZERO


func _ready() -> void:
	# The stick must not eat input meant for the world; it inspects touches in
	# _input and only consumes the ones it actually claims.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


## Is `p` inside the summoning zone? Play.gd asks before treating a press as a
## tap-to-move, so a press that will become a stick never also issues an order.
func claims(p: Vector2) -> bool:
	var vp: Vector2 = get_viewport_rect().size
	return p.x <= vp.x * ZONE_W and p.y <= vp.y * (1.0 - ZONE_BOTTOM_INSET)


func is_active() -> bool:
	return _touch != -1


## Length 0..1 in screen space; see `moved`.
func direction() -> Vector2:
	return _dir


func wants_run() -> bool:
	return _dir.length() >= RUN_AT


func _input(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		var t := e as InputEventScreenTouch
		if t.pressed:
			if _touch == -1 and claims(t.position):
				_grab(t.index, t.position)
				get_viewport().set_input_as_handled()
		elif t.index == _touch:
			_release()
			get_viewport().set_input_as_handled()

	elif e is InputEventScreenDrag:
		var d := e as InputEventScreenDrag
		if d.index == _touch:
			_move(d.position)
			get_viewport().set_input_as_handled()

	# Mouse, so the stick is usable in the editor and in the headless harnesses
	# without a touchscreen. Index -2 can never collide with a real finger.
	elif e is InputEventMouseButton:
		var m := e as InputEventMouseButton
		if m.button_index == MOUSE_BUTTON_LEFT:
			if m.pressed and _touch == -1 and claims(m.position):
				_grab(-2, m.position)
				get_viewport().set_input_as_handled()
			elif not m.pressed and _touch == -2:
				_release()
				get_viewport().set_input_as_handled()
	elif e is InputEventMouseMotion and _touch == -2:
		_move((e as InputEventMouseMotion).position)


func _grab(index: int, at: Vector2) -> void:
	_touch = index
	_origin = at
	_knob = at
	_dir = Vector2.ZERO
	queue_redraw()


func _move(to: Vector2) -> void:
	_knob = to
	var off: Vector2 = to - _origin
	var len_: float = off.length()
	if len_ < 0.001:
		_dir = Vector2.ZERO
	else:
		var mag: float = minf(len_ / RADIUS, 1.0)
		_dir = Vector2.ZERO if mag < DEAD_ZONE else (off / len_) * mag
	moved.emit(_dir)
	queue_redraw()


func _release() -> void:
	_touch = -1
	_dir = Vector2.ZERO
	moved.emit(Vector2.ZERO)
	queue_redraw()


func _draw() -> void:
	if _touch == -1:
		return
	var run: bool = wants_run()
	var tint: Color = HeroTheme.ACCENT if run else HeroTheme.TEXT

	# Ring at the summon point, knob clamped to the travel radius so the thumb
	# can slide past the edge without the knob flying off with it.
	draw_circle(_origin, RING_R, Color(0, 0, 0, 0.28))
	draw_arc(_origin, RING_R, 0.0, TAU, 48, Color(tint, 0.45), 4.0, true)

	var off: Vector2 = _knob - _origin
	if off.length() > RADIUS:
		off = off.normalized() * RADIUS
	var knob: Vector2 = _origin + off
	draw_circle(knob, KNOB_R, Color(tint, 0.30))
	draw_arc(knob, KNOB_R, 0.0, TAU, 32, Color(tint, 0.85), 4.0, true)
