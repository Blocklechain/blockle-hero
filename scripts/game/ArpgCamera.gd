class_name ArpgCamera
extends Camera3D
# ------------------------------------------------------------------------------
# The fixed-angle follow camera, at the framing the screenshot harness
# established: 48 degrees down, 35 degrees of yaw, ~25 m out, narrow lens.
#
# It does NOT rotate with the hero. A camera that yaws to follow a character is
# a third-person camera; an ARPG camera holds one orientation so the world keeps
# a constant reading and "up on screen" always means the same direction.
#
# Tap-to-world uses a raymarch against the heightfield rather than a physics
# raycast: the terrain has no collision shapes (the walk grid is the authority
# on movement) and marching 150 m of ray is a handful of bilinear samples.
# ------------------------------------------------------------------------------

const PITCH_DEG: float = 48.0
const YAW_DEG: float = 35.0
const DISTANCE: float = 25.0
const HEIGHT_BIAS: float = 1.0        # look slightly above the hero's feet
const FOLLOW_LAG: float = 6.5         # higher = tighter

## Pinch zoom, as a multiplier on DISTANCE.
##
## DELIBERATELY NARROW. Zooming out far enough to see a whole 300 m lane stops
## the game being an ARPG — the champion becomes a dot, the enemy silhouettes
## stop being readable, and the camera angle that was chosen to show the models
## is wasted. This is a comfort adjustment for different hands and eyesight, not
## a tactical map view.
const ZOOM_MIN: float = 0.80
const ZOOM_MAX: float = 1.45
## How fast the zoom chases the pinch. Low enough that the jitter in two moving
## fingers does not make the world shiver.
const ZOOM_LAG: float = 10.0

var target: Node3D = null
var terrain: Terrain = null

var _offset: Vector3
var _look: Vector3 = Vector3.ZERO
var _zoom: float = 1.0
var _zoom_want: float = 1.0


func _ready() -> void:
	fov = 38.0
	far = 600.0
	var pitch: float = deg_to_rad(PITCH_DEG)
	var yaw: float = deg_to_rad(YAW_DEG)
	_offset = Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * DISTANCE


## Screen-space stick direction (+x right, +y down) -> world XZ.
##
## THE ONE PLACE THIS ARITHMETIC LIVES. It was written twice — once here and
## once in the test that was supposed to prove it — and the two differed by a
## sign, so the test passed against its own copy while the shipping path sent
## the champion down the screen when the thumb pushed up. A test that
## re-implements the thing it is testing proves only that it agrees with
## itself.
##
## The camera holds a fixed yaw and never turns, so screen-up is not
## world-north; -y on the stick has to become "away from the camera", which is
## the direction the camera's own offset points AWAY from.
static func stick_to_world(dir: Vector2) -> Vector2:
	if dir == Vector2.ZERO:
		return Vector2.ZERO
	var yaw: float = deg_to_rad(YAW_DEG)
	# The camera sits at +(sin yaw, cos yaw) from what it looks at, so moving
	# away from it — up the screen — is the NEGATIVE of that.
	var fwd := Vector2(sin(yaw), cos(yaw))
	var right := Vector2(fwd.y, -fwd.x)
	return right * dir.x + fwd * dir.y


func snap_to_target() -> void:
	if target == null:
		return
	_look = target.position + Vector3(0, HEIGHT_BIAS, 0)
	_apply()


func _process(delta: float) -> void:
	if target == null:
		return
	# Critically-damped-ish follow. Framerate independent, so the camera does
	# not feel different on a 120 Hz iPad and a 60 Hz phone.
	var want: Vector3 = target.position + Vector3(0, HEIGHT_BIAS, 0)
	_look = _look.lerp(want, 1.0 - exp(-FOLLOW_LAG * delta))
	# Same framerate-independent easing as the follow, for the same reason.
	_zoom = lerpf(_zoom, _zoom_want, 1.0 - exp(-ZOOM_LAG * delta))
	_apply()


## Scale the zoom by `k` (1.0 = no change). Clamped, so no amount of pinching
## reaches a strategy-game view.
func pinch(k: float) -> void:
	_zoom_want = clampf(_zoom_want * k, ZOOM_MIN, ZOOM_MAX)


func zoom_level() -> float:
	return _zoom


func _apply() -> void:
	position = _look + _offset * _zoom
	look_at(_look, Vector3.UP)


# Where on the ground is this screen point? Returns Vector2.INF on a miss.
func screen_to_ground(screen: Vector2) -> Vector2:
	if terrain == null:
		return Vector2.INF
	var origin: Vector3 = project_ray_origin(screen)
	var dir: Vector3 = project_ray_normal(screen)
	if absf(dir.y) < 0.0001:
		return Vector2.INF

	# March until the ray passes below the surface, then bisect. Marching alone
	# would quantise taps to the step size; bisection gets sub-centimetre
	# accuracy for eight more samples.
	const MAX_DIST: float = 400.0
	const STEP: float = 1.5
	var prev_t: float = 0.0
	var prev_above: bool = origin.y > terrain.height_at(Vector2(origin.x, origin.z))
	var t: float = STEP
	while t < MAX_DIST:
		var p: Vector3 = origin + dir * t
		var above: bool = p.y > terrain.height_at(Vector2(p.x, p.z))
		if above != prev_above:
			var lo: float = prev_t
			var hi: float = t
			for _i in range(8):
				var mid: float = (lo + hi) * 0.5
				var pm: Vector3 = origin + dir * mid
				if (pm.y > terrain.height_at(Vector2(pm.x, pm.z))) == prev_above:
					lo = mid
				else:
					hi = mid
			var hit: Vector3 = origin + dir * ((lo + hi) * 0.5)
			return Vector2(hit.x, hit.z)
		prev_above = above
		prev_t = t
		t += STEP
	return Vector2.INF
