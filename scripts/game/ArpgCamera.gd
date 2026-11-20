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

var target: Node3D = null
var terrain: Terrain = null

var _offset: Vector3
var _look: Vector3 = Vector3.ZERO


func _ready() -> void:
	fov = 38.0
	far = 600.0
	var pitch: float = deg_to_rad(PITCH_DEG)
	var yaw: float = deg_to_rad(YAW_DEG)
	_offset = Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * DISTANCE


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
	_apply()


func _apply() -> void:
	position = _look + _offset
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
