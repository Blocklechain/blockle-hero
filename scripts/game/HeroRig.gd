class_name HeroRig
extends Node3D
# ------------------------------------------------------------------------------
# A hero's visual body, and THE SEAM between the controller and the animation
# work.
#
# Two model sets exist, and the difference matters to the player:
#
#   animated/  139 heroes, rigged — Skeleton3D + AnimationPlayer, 8 clips each.
#   tex/       all 200 heroes as STATIC meshes — one surface, no skeleton, no
#              AnimationPlayer, no skin.
#
# The controller must never know which it is holding. It calls `set_state()`
# with a canonical name and this class decides:
#
#   RIGGED   -> play the matching clip on the AnimationPlayer
#   STATIC   -> drive a procedural stand-in (bob, lean, lunge) so the game is
#               playable and readable, with no placeholder-looking T-pose
#               sliding across the ground
#
# WHICH SET THE ROSTER COMES FROM IS A SHIPPING DECISION, NOT A FALLBACK:
# see `animated_heroes()`. The playable roster is the animated set only; the
# static set survives purely as a per-hero load-time fallback.
# ------------------------------------------------------------------------------

## Canonical animation states. The animator's clips should map to these names;
## matching is fuzzy (see `_find_clip`) because exporters mangle them.
enum State { IDLE, WALK, RUN, ATTACK, ABILITY_1, ABILITY_2, ABILITY_3, HIT, DEATH }

const STATE_NAMES: Dictionary = {
	State.IDLE: "idle", State.WALK: "walk", State.RUN: "run",
	State.ATTACK: "attack", State.ABILITY_1: "ability_1",
	State.ABILITY_2: "ability_2", State.ABILITY_3: "ability_3",
	State.HIT: "hit", State.DEATH: "death",
}

## Extra spellings to accept per state, because Mixamo and Blender exports are
## rarely the clean name anyone intended. A clip called "Armature|mixamo.com" or
## "Take 001" is normal, not an error.
const ALIASES: Dictionary = {
	State.IDLE: ["idle", "stand", "breathing"],
	State.WALK: ["walk", "walking"],
	State.RUN: ["run", "running", "jog", "sprint"],
	State.ATTACK: ["attack", "slash", "swing", "punch", "strike"],
	State.ABILITY_1: ["ability_1", "ability1", "skill_1", "skill1", "cast", "spell"],
	State.ABILITY_2: ["ability_2", "ability2", "skill_2", "skill2"],
	State.ABILITY_3: ["ability_3", "ability3", "skill_3", "skill3", "ultimate"],
	State.HIT: ["hit", "hurt", "impact", "damage", "flinch"],
	State.DEATH: ["death", "die", "dying", "dead"],
}

## The rigged export: Skeleton3D + AnimationPlayer per file. THE PLAYABLE
## ROSTER IS EXACTLY THIS DIRECTORY — see `animated_heroes()`.
const ANIMATED_DIR: String = "/Volumes/ExtremePro/raid/assets/heroes/animated"

## The static set: all 200 heroes as unskinned meshes. Not a roster source, only
## a per-hero load fallback for heroes a save already owns.
const STATIC_DIR: String = "/Volumes/ExtremePro/raid/assets/heroes/tex"

## THE SHIPPED COPY — the only one that exists on a device.
##
## ANIMATED_DIR/STATIC_DIR above are absolute paths on the authoring machine.
## They are fine for the editor and the headless tools, and they are USELESS in
## an exported build: an iPhone has no /Volumes, so every hero failed to load
## and the game shipped with no characters at all. The 139 rigged heroes are now
## copied into the project and imported by Godot, so they live in the PCK.
##
## Bundled is tried FIRST and the absolute dirs remain as a dev fallback, which
## keeps `tools/*.gd` working against the authoring tree without a re-import.
const BUNDLED_DIR: String = "res://assets/heroes/animated"

## The roster, baked at build time by `tools/genroster.gd`.
##
## WHY NOT JUST LIST THE DIRECTORY: Godot rewrites imported assets in an export
## — a `.glb` becomes a `.scn` reached through a `.remap`, so `DirAccess` over
## `res://` returns different names in an exported build than in the editor. A
## roster that silently changes shape between editor and device is the kind of
## bug that only shows up on TestFlight, so the names are frozen into a file.
const ROSTER_MANIFEST: String = "res://assets/heroes/roster.json"

static var _roster_cache: PackedStringArray = PackedStringArray()

## Where to look for a hero's model, in order. Resolution is PER HERO
## (`_resolve`), not per directory: a rigged hero loads from ANIMATED_DIR, and a
## hero that only exists statically still loads, so no save can be orphaned.
static var search_dirs: PackedStringArray = PackedStringArray([
	ANIMATED_DIR,
	STATIC_DIR,
])

## Target height in metres. The raid models are authored at ~2 m already, but
## normalising means a re-export at a different scale cannot break the game.
const TARGET_HEIGHT: float = 1.85

signal state_finished(state: int)

## How long the hit reaction lasts. THE SAME 0.25 s the HIT state has always
## reported as its duration, so `state_finished(HIT)` still fires when the
## controller expects it — the recoil is layered on, it does not retime anything.
const RECOIL_TIME: float = 0.25

## Peak recoil, in radians and metres. Big enough to read from across a phone
## screen at the game camera's distance, small enough to layer over a run cycle
## without fighting the clip's own lean. 0.22 rad is about 13 degrees.
const RECOIL_PITCH: float = 0.22       # rad, backwards (negative X)
const RECOIL_ROLL: float = 0.07        # rad, a twist so it is not a flat nod
const RECOIL_PUSH: float = 0.085       # m, shoved back along local -Z
const RECOIL_LIFT: float = 0.03        # m, up off the feet
const RECOIL_SQUASH: float = 0.06      # fraction, classic squash-and-stretch

## Normalises the impulse in `_advance_recoil()` to peak at exactly 1.0, so the
## constants above are the real peak rather than roughly a third of it. The raw
## curve exp(-5.5k)·sin(1.6πk) tops out at 0.2999 (k = 0.1473, where its
## derivative -5.5·sin + 1.6π·cos crosses zero); this is its reciprocal.
## Measured, not guessed — the first cut of this leaned the body 4.5 degrees
## while the source claimed 15.
const RECOIL_GAIN: float = 3.334

## The flash fades out over this fraction of the recoil, so it is gone well
## before the body has finished settling. A flash that lasts as long as the
## movement reads as a shader bug rather than an impact.
const FLASH_SPAN: float = 0.5

## Overlay alpha at its brightest. This is ADDED to the hero's lit colour, so it
## climbs fast: at 0.55 the armour, skin and every material difference wash out
## to a single near-white silhouette, which reads as a texture that failed to
## load. It has to tint the body, not erase it.
const FLASH_PEAK: float = 0.30

var hero_name: String = ""
var is_rigged: bool = false

## True once `kill()` has run. A corpse ignores every further state request —
## see `set_state()`.
var is_dead: bool = false

var _model: Node3D = null
var _anim: AnimationPlayer = null
var _state: int = State.IDLE
var _clip_for: Dictionary = {}          # State -> clip name, resolved once
var _t: float = 0.0                     # procedural animation clock
var _speed01: float = 0.0               # 0 standing .. 1 running, drives the stand-in
var _oneshot_left: float = 0.0

var _recoil_left: float = 0.0
var _base_pos: Vector3 = Vector3.ZERO
var _base_rot: Vector3 = Vector3.ZERO
var _base_scale: Vector3 = Vector3.ONE
var _meshes: Array[MeshInstance3D] = []
var _flash: StandardMaterial3D = null
var _flash_on: bool = false


# ------------------------------------------------------------------------------
# Loading
# ------------------------------------------------------------------------------

static func _glb_names_in(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var f: String = dir.get_next()
	while f != "":
		if f.ends_with(".glb"):
			out.append(f.get_basename())
		f = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


## THE PLAYABLE ROSTER. Only heroes with a rigged export in ANIMATED_DIR.
##
## WHY THIS IS NARROWER THAN THE ART SET: 139 of the 200 heroes could be
## auto-rigged; the other 61 could not (skeleton inference failed on their
## meshes). A hero with no skeleton falls back to the procedural stand-in, which
## is honest for a hero the player already owns but unacceptable as something to
## *hand out* — a crystal or a 300-gem purchase that yields a stiff, sliding
## T-pose reads as a broken product, and reads worst exactly when the player has
## just paid. So the 61 ship HIDDEN rather than shipping bad. They are not
## deleted: drop a rigged .glb into ANIMATED_DIR and that hero rejoins the
## roster with no code change, which is the same incremental-delivery contract
## docs/ANIMATION-HANDOFF.md promises.
##
## Every grant path (starters, gem unlock, crystal roll) draws from
## `Roster.catalogue`, which is this list — so a static hero cannot be granted.
static func animated_heroes() -> PackedStringArray:
	if not _roster_cache.is_empty():
		return _roster_cache

	# Baked manifest first: it is the only source that is correct on a device.
	if FileAccess.file_exists(ROSTER_MANIFEST):
		var txt: String = FileAccess.get_file_as_string(ROSTER_MANIFEST)
		var parsed: Variant = JSON.parse_string(txt)
		if parsed is Array:
			var names: PackedStringArray = PackedStringArray()
			for n in parsed:
				names.append(String(n))
			names.sort()
			_roster_cache = names
			return _roster_cache
		push_error("HeroRig: %s is not a JSON array" % ROSTER_MANIFEST)

	# Editor / headless-tools fallback: scan the authoring directory.
	_roster_cache = _glb_names_in(ANIMATED_DIR)
	return _roster_cache


## Path to the shipped model for `hero`, or "" if it is not bundled.
static func _bundled_path(hero: String) -> String:
	var p: String = BUNDLED_DIR.path_join(hero + ".glb")
	return p if ResourceLoader.exists(p) else ""


## Every hero the game can LOAD at all (rigged ∪ static), which is a superset of
## the playable roster. Use this only where the question is "can this name be
## displayed/loaded", never to populate a roster or an unlock pool — a save made
## before the roster was gated may legitimately own a static-only hero.
static func all_loadable_heroes() -> PackedStringArray:
	var seen: Dictionary = {}
	for d in search_dirs:
		for h in _glb_names_in(d):
			seen[h] = true
	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


## True if `hero` has a rigged export, i.e. is on the playable roster.
static func is_animated(hero: String) -> bool:
	if _bundled_path(hero) != "":
		return true
	return FileAccess.file_exists(ANIMATED_DIR.path_join(hero + ".glb"))


static func _resolve(hero: String) -> String:
	for d in search_dirs:
		var path: String = d.path_join(hero + ".glb")
		if FileAccess.file_exists(path):
			return path
	return ""


## Load a hero by name. Returns false if no model could be found — the caller
## should treat that as a content error, not substitute a cube silently.
func load_hero(hero: String) -> bool:
	hero_name = hero
	var scene: Node = _instantiate_bundled(hero)
	if scene == null:
		scene = _import_from_disk(hero)
	if scene == null:
		return false

	_model = Node3D.new()
	_model.add_child(scene)
	add_child(_model)

	var players: Array = scene.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		_anim = players[0] as AnimationPlayer
		is_rigged = true
		_resolve_clips()
		if not _anim.animation_finished.is_connected(_on_clip_finished):
			_anim.animation_finished.connect(_on_clip_finished)

	_normalise_scale(scene)

	# Captured AFTER normalising, because that is what sets the model's scale.
	# The hit reaction works as an offset from this rest pose, so a hero whose
	# source .glb was authored at a different scale recoils by the same amount
	# on screen rather than by the same amount in model units.
	_base_pos = _model.position
	_base_rot = _model.rotation
	_base_scale = _model.scale
	_collect_meshes(scene)

	# FORCED. `_state` already reads IDLE on a fresh rig, so an unforced
	# call matches the early-out in set_state and returns without ever
	# reaching _anim.play(): the champion stands in its bind pose until
	# something else moves it, and a menu preview that only ever wants an
	# idle never animates at all.
	set_state(State.IDLE, true)
	return true


# The surfaces the hit flash is painted onto. Gathered once: find_children walks
# the whole subtree, and a hero can be struck four times a second.
func _collect_meshes(scene: Node) -> void:
	_meshes.clear()
	for c in scene.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null:
			_meshes.append(mi)


## The shipped path: a Godot-imported PackedScene out of the PCK. Works in the
## editor and on a device, and the importer gives us compressed textures, which
## is why the install is ~580 MiB rather than the 1.1 GB of raw .glb.
func _instantiate_bundled(hero: String) -> Node:
	var path: String = _bundled_path(hero)
	if path == "":
		return null
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		push_error("HeroRig: '%s' is bundled but did not load as a scene" % hero)
		return null
	return packed.instantiate()


## Dev-only path: parse a .glb straight off the authoring volume at runtime.
## Cannot work in an exported build — there is no /Volumes on a phone — so this
## is strictly for the editor and tools/*.gd running against the raid tree.
func _import_from_disk(hero: String) -> Node:
	var path: String = _resolve(hero)
	if path == "":
		push_error("HeroRig: no model for '%s' — not in %s and not in %s" % [
			hero, BUNDLED_DIR, search_dirs])
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		push_error("HeroRig: failed to parse " + path)
		return null
	return doc.generate_scene(state)


func _normalise_scale(scene: Node) -> void:
	var aabb := AABB()
	var first := true
	for c in scene.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null:
			continue
		var a: AABB = mi.get_aabb()
		if first:
			aabb = a
			first = false
		else:
			aabb = aabb.merge(a)
	if aabb.size.y > 0.001:
		_model.scale = Vector3.ONE * (TARGET_HEIGHT / aabb.size.y)


# Resolve each canonical state to a real clip name ONCE, rather than searching
# the animation list on every state change.
func _resolve_clips() -> void:
	var clips: PackedStringArray = _anim.get_animation_list()
	for st in STATE_NAMES.keys():
		var found: String = _find_clip(clips, st)
		if found != "":
			_clip_for[st] = found


func _find_clip(clips: PackedStringArray, st: int) -> String:
	var wanted: Array = ALIASES[st]
	# Exact match on the canonical name first.
	for c in clips:
		if c.to_lower() == String(STATE_NAMES[st]):
			return c
	# Then substring, after stripping the usual exporter noise. Godot names
	# library clips "Library/Clip", Blender prefixes "Armature|".
	for c in clips:
		var norm: String = c.to_lower().replace("armature|", "").replace("mixamo.com", "")
		norm = norm.get_file()
		for w in wanted:
			if norm.contains(String(w)):
				return c
	return ""


# ------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------

func state() -> int:
	return _state


## How fast the body should look like it is moving, 0..1. Drives blend speed on
## a rigged model and the stand-in's stride on a static one.
func set_locomotion(speed01: float) -> void:
	_speed01 = clampf(speed01, 0.0, 1.0)


func set_state(st: int, force: bool = false) -> void:
	# A CORPSE IGNORES ORDERS. The controller's idle branch calls set_state(IDLE)
	# on every frame it is not moving, so without this the death clip is replaced
	# by a standing idle on the very next frame and the hero dies by vanishing
	# into a T-pose stand. Death is the one state nothing may leave.
	if is_dead and st != State.DEATH:
		return
	if st == _state and not force:
		return
	_state = st
	_oneshot_left = 0.0

	# The reaction is driven here as well as from `flinch()` so that an explicit
	# HIT state still reads on a rigged hero, which otherwise has no clip for it.
	if st == State.HIT:
		_recoil_left = RECOIL_TIME

	if is_rigged and _clip_for.has(st):
		var clip: String = _clip_for[st]
		var looping: bool = st in [State.IDLE, State.WALK, State.RUN]
		_anim.play(clip)
		if not looping:
			_oneshot_left = _anim.current_animation_length
		return

	# No clip — either the model is static, or the animator has not produced
	# this state yet. Both are expected right now, and neither should stall the
	# game, so fall through to the stand-in with a duration that keeps the
	# controller's timing honest.
	if st in [State.ATTACK, State.ABILITY_1, State.ABILITY_2, State.ABILITY_3]:
		_oneshot_left = 0.45
	elif st == State.HIT:
		_oneshot_left = 0.25


## Take a hit WITHOUT changing state.
##
## This is the one the game should normally call. None of the 139 rigged heroes
## was delivered with a `hit` clip (see tools/bundlecheck.gd, which asserts
## missing == ["hit"] precisely because it is expected), so switching to
## State.HIT on a rigged hero used to change the AnimationPlayer not at all —
## being damaged was completely invisible. Instead the reaction is an ADDITIVE
## offset on the model node, layered over whichever clip is already playing, so
## a hero can be struck mid-swing and mid-run and still show it without the
## swing or the run being interrupted. Interrupting them would also be wrong on
## a phone: a stagger lock-out costs the player the attack they just paid a
## cooldown for.
##
## Re-striking restarts the reaction, which is what makes a flurry read as a
## flurry rather than as one long lean.
func flinch() -> void:
	if is_dead:
		return
	_recoil_left = RECOIL_TIME


## True while the hit reaction is playing. Callers use it to avoid stacking
## feedback (a second screen shake, a second grunt) inside one impact.
func is_flinching() -> bool:
	return _recoil_left > 0.0


## Die: play the death clip and stay down.
##
## Every rigged hero ships a real ~5.8 s death animation, which until now was
## never played by anything. Separate from `set_state(DEATH)` because death is
## also a latch: it sets `is_dead`, which locks the rig so nothing can animate
## the corpse back to its feet.
func kill() -> void:
	if is_dead:
		return
	is_dead = true
	_recoil_left = 0.0
	_set_flash(0.0)
	# Forced, because a hero killed by the blow that was already playing DEATH
	# (or killed twice in a frame) must still restart the clip from frame 0.
	set_state(State.DEATH, true)


func _process(delta: float) -> void:
	_t += delta
	if _oneshot_left > 0.0:
		_oneshot_left -= delta
		if _oneshot_left <= 0.0:
			state_finished.emit(_state)
	if not is_rigged and _model != null:
		_procedural(delta)
	if _model != null:
		_advance_recoil(delta)


# ------------------------------------------------------------------------------
# Procedural stand-in, used until the rigged models arrive
# ------------------------------------------------------------------------------

func _procedural(_delta: float) -> void:
	# Deliberately simple and deliberately temporary. The goal is only that a
	# moving hero reads as moving and a swing reads as a swing, so the
	# controller and camera can be judged on their own merits before animation
	# lands. None of this survives the rigged models.
	var bob: float = 0.0
	var lean: float = 0.0
	var roll: float = 0.0

	match _state:
		State.WALK, State.RUN:
			var stride: float = lerpf(7.0, 12.0, _speed01)
			bob = absf(sin(_t * stride)) * lerpf(0.04, 0.10, _speed01)
			lean = lerpf(0.05, 0.16, _speed01)
			roll = sin(_t * stride * 0.5) * lerpf(0.03, 0.07, _speed01)
		State.ATTACK, State.ABILITY_1, State.ABILITY_2, State.ABILITY_3:
			# A quick forward lunge that snaps back — enough to read as a hit.
			var k: float = clampf(1.0 - _oneshot_left / 0.45, 0.0, 1.0)
			lean = sin(k * PI) * 0.55
			bob = sin(k * PI) * 0.06
		State.HIT:
			lean = -0.4 * clampf(_oneshot_left / 0.25, 0.0, 1.0)
		State.DEATH:
			lean = 1.4
		_:
			bob = sin(_t * 1.8) * 0.018          # idle breathing
			roll = sin(_t * 1.1) * 0.012

	_model.position = Vector3(0.0, bob, 0.0)
	_model.rotation = Vector3(lean, 0.0, roll)


# ------------------------------------------------------------------------------
# Hit reaction — an additive layer, used by rigged and static models alike
# ------------------------------------------------------------------------------

func _advance_recoil(delta: float) -> void:
	if _recoil_left <= 0.0:
		return
	_recoil_left = maxf(_recoil_left - delta, 0.0)
	var k: float = 1.0 - _recoil_left / RECOIL_TIME        # 0 at impact, 1 at rest

	# A struck-and-settle impulse, not a fade. exp() gives the hard spike of the
	# impact (peaks ~15% in) and sin() past PI carries the body back THROUGH its
	# rest pose into a small overshoot before returning, which is what makes it
	# read as a body absorbing a blow rather than a node being lerped. It is
	# exactly 0 at k = 0 and ~0 at k = 1, so nothing pops on either end — and it
	# is forced to a clean 0 on the final frame so the rest pose is exact.
	var env: float = 0.0
	if _recoil_left > 0.0:
		env = exp(-k * 5.5) * sin(k * PI * 1.6) * RECOIL_GAIN

	# WHERE THE OFFSET IS MEASURED FROM differs by model type, and getting this
	# wrong accumulates drift: a static hero has just been positioned by
	# _procedural() this same frame, so the recoil rides on top of that value; a
	# rigged hero is moved internally by its skeleton and leaves this node at its
	# load-time rest, so the offset is taken from the captured base.
	var pos: Vector3 = _base_pos if is_rigged else _model.position
	var rot: Vector3 = _base_rot if is_rigged else _model.rotation

	_model.position = pos + Vector3(0.0, RECOIL_LIFT, -RECOIL_PUSH) * env
	_model.rotation = rot + Vector3(-RECOIL_PITCH * env, 0.0, RECOIL_ROLL * env)
	# Squash: shorter and wider, so the silhouette changes even on a frame where
	# the lean happens to be hidden by the camera angle.
	_model.scale = _base_scale * Vector3(
		1.0 + RECOIL_SQUASH * 0.75 * env,
		1.0 - RECOIL_SQUASH * env,
		1.0 + RECOIL_SQUASH * 0.75 * env)

	# The flash front-loads: full brightness at the impact, gone by the time the
	# body is still moving. pow() sharpens the decay.
	var fade: float = maxf(0.0, 1.0 - k / FLASH_SPAN)
	_set_flash(pow(fade, 1.4) * FLASH_PEAK)


## Paint every surface with an additive white overlay at `alpha`.
##
## `material_overlay` rather than touching the hero's own materials: the models
## arrive from an art pipeline with 139 different material setups, and anything
## that mutates them has to be able to put them back exactly. An overlay is
## additive, respects skinning, and is removed by assigning null — there is no
## state to restore and no way to corrupt a hero's appearance permanently.
func _set_flash(alpha: float) -> void:
	if alpha <= 0.001:
		if _flash_on:
			_flash_on = false
			for mi in _meshes:
				mi.material_overlay = null
		return

	if _flash == null:
		_flash = StandardMaterial3D.new()
		_flash.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flash.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_flash.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_flash.cull_mode = BaseMaterial3D.CULL_DISABLED
		# An additive overlay that writes depth punches a hole in whatever is
		# drawn after it, so the hero would flash and the scenery behind them
		# would disappear for two frames.
		_flash.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		_flash.disable_receive_shadows = true

	# Slightly warm rather than pure white — a white flash on a green biome under
	# a warm sun reads as a missing texture.
	_flash.albedo_color = Color(1.0, 0.92, 0.84, alpha)
	if not _flash_on:
		_flash_on = true
		for mi in _meshes:
			mi.material_overlay = _flash


func _on_clip_finished(_name: StringName) -> void:
	if _state in [State.IDLE, State.WALK, State.RUN]:
		return
	state_finished.emit(_state)


## What the animator still owes us, for whichever model is loaded. Useful as a
## content check once the rigged set lands.
##
## `hit` is on this list for all 139 heroes and that is NOT a gap any more — it
## is covered by `flinch()`, which is additive and needs no clip. Keep reporting
## it: tools/bundlecheck.gd asserts the list is exactly ["hit"], which is how a
## hero that is missing a REAL clip gets caught.
func missing_states() -> PackedStringArray:
	var out := PackedStringArray()
	if not is_rigged:
		return PackedStringArray(["<model is not rigged>"])
	for st in STATE_NAMES.keys():
		if not _clip_for.has(st):
			out.append(String(STATE_NAMES[st]))
	return out
