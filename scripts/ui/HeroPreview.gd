class_name HeroPreview
extends SubViewportContainer
# ------------------------------------------------------------------------------
# The champion you are about to play, alive, in the menu.
#
# A REAL HeroRig IN A SubViewport, not a pre-rendered portrait. 139 champions
# would be 139 portraits to render, store and keep in step with the models —
# and the models are already here, already rigged, already playing an idle. The
# loadout screen showing the same body that will walk out of the gate is the
# whole point: a portrait is a promise, this is the thing itself.
#
# It is also the only place in the menus where gear SHOWS. Armour and weapons
# are deliberately invisible on the champion in play (they boost stats and do
# not change the silhouette), so the sheet has to carry that weight in numbers.
# Seeing the champion move at least anchors those numbers to a body.
#
# COST. One SubViewport with one skinned mesh and one light, rendered only
# while the screen is open and only when `update_mode` says so. The world
# itself is not loaded here; this is a 3D node in a 2D menu, not a second game.
# ------------------------------------------------------------------------------

## Degrees per second of turntable. Slow — this is a presentation, and a model
## spinning fast enough to notice is a model nobody can actually look at.
const SPIN: float = 18.0

## Framing. The rig normalises every champion to 1.85 m tall, so one camera
## placement fits all 139 without per-hero tuning.
const CAM_HEIGHT: float = 1.15
const CAM_DISTANCE: float = 3.45
const CAM_PITCH: float = -7.0

var _vp: SubViewport
var _pivot: Node3D
var _rig: HeroRig = null
var _hero: String = ""
var _spin: float = 0.0
var _cam: Camera3D
## Multiplier on the camera's distance. 1.0 is the roster thumbnail; the
## champion-arrival screen pulls in closer, because the same framing that
## reads as a neat portrait in a list reads as a small figure in a lot of
## black when it is the only thing on the display.
var zoom: float = 1.0:
	set(v):
		zoom = maxf(v, 0.2)
		_frame()


func _init() -> void:
	stretch = true
	custom_minimum_size = Vector2(HeroTheme.COL_W, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	# The preview is decoration: it must never eat a touch meant for the
	# scrolling sheet beside it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_vp = SubViewport.new()
	_vp.transparent_bg = true
	# UPDATE_ALWAYS, because the idle clip and the turntable are both animating.
	# UPDATE_ONCE renders a single frame and leaves a still image that looks
	# exactly like the pre-rendered portrait this exists to avoid.
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.own_world_3d = true
	add_child(_vp)

	var world := Node3D.new()
	_vp.add_child(world)

	_pivot = Node3D.new()
	world.add_child(_pivot)

	var cam := Camera3D.new()
	cam.fov = 34.0
	cam.position = Vector3(0.0, CAM_HEIGHT, CAM_DISTANCE)
	cam.rotation_degrees = Vector3(CAM_PITCH, 0.0, 0.0)
	world.add_child(cam)
	cam.current = true
	_cam = cam
	_frame()

	# Three-point-ish: a warm key from the front left, a cool fill opposite so
	# the shadowed side does not read as a silhouette, and enough ambient that
	# a dark champion is still legible against a dark menu.
	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.95, 0.86)
	key.light_energy = 2.1
	key.basis = Basis.looking_at(Vector3(-0.6, -0.75, -1.0))
	world.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.light_color = HeroTheme.ACCENT
	fill.light_energy = 0.55
	fill.basis = Basis.looking_at(Vector3(0.9, -0.2, 0.7))
	world.add_child(fill)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CANVAS
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.42, 0.46, 0.58)
	e.ambient_light_energy = 1.0
	# Matches the renderer the game ships: ACES would re-grade a palette that
	# was already graded, which is how the world art came out pastel once.
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.environment = e
	world.add_child(env)

	if _hero != "":
		_load(_hero)


## Show `hero`. Safe to call before the node is in the tree.
## Put the camera where `zoom` says.
func _frame() -> void:
	if _cam == null:
		return
	# DISTANCE ONLY. Scaling the camera's height as well dropped the eye line
	# as it pulled in, and at the reveal's framing that cut the champion's
	# head off the top of the display.
	_cam.position = Vector3(0.0, CAM_HEIGHT, CAM_DISTANCE * zoom)


func show_hero(hero: String) -> void:
	if hero == _hero:
		return
	_hero = hero
	if _pivot != null:
		_load(hero)


func _load(hero: String) -> void:
	if _rig != null:
		_rig.queue_free()
		_rig = null
	if hero == "":
		return
	_rig = HeroRig.new()
	_pivot.add_child(_rig)
	if not _rig.load_hero(hero):
		# A champion that cannot be shown is not a crash: the sheet beside this
		# still has every number the player needs.
		push_warning("HeroPreview: no model for '%s'" % hero)
		_rig.queue_free()
		_rig = null
		return
	_rig.set_state(HeroRig.State.IDLE)
	_spin = 0.0


func _process(delta: float) -> void:
	if _pivot == null:
		return
	_spin = fmod(_spin + SPIN * delta, 360.0)
	# Start three-quarters on rather than face-front: a character reads better
	# at an angle, and it is the pose every roster portrait in the genre uses.
	_pivot.rotation_degrees = Vector3(0.0, -28.0 + _spin, 0.0)
