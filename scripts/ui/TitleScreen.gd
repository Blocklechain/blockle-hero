class_name TitleScreen
extends UiScreen
# ------------------------------------------------------------------------------
# THE FIRST THING THE PLAYER SEES, AND THE ONLY THING ON IT.
#
# This used to be a title screen doing a second job: it carried six quick
# links to Champions, Stash, Merchant, Training, Contracts and Party, because
# the bottom tab strip only had room for four destinations and those six had
# nowhere else to live.
#
# The left navigation panel holds every destination now, so the quick links
# were a duplicate menu on the one screen that should not have a menu at all.
# What is left is a door: the mark, the name, and one button.
#
# ------------------------------------------------------------------------------
# WHY THERE ARE PARTICLES.
#
# A title screen that is a still image reads as a loading screen that has got
# stuck — the player cannot tell whether the app is running until they touch
# it. Something has to move. Embers drifting up across the painting is the
# cheapest honest way to say "this is alive", and it suits a game whose art
# is all dusk and ash.
#
# They are drawn, not an asset: GPUParticles2D with a generated dot, because
# a title screen must not wait on a texture to load and a 4 px circle is not
# worth a file. They also respect the drift the backdrop already had, so the
# two motions are one slow movement rather than two competing ones.
# ------------------------------------------------------------------------------

## How far the backdrop drifts, as a share of its own size. Small enough that
## nobody consciously sees it move, large enough that the screen is not a
## still image.
const DRIFT: float = 0.035
## Seconds for one full drift cycle. Slow — a title screen that visibly pans
## is a screensaver.
const DRIFT_TIME: float = 26.0

## Embers on screen at once. Few enough to read as sparks rather than snow,
## and cheap enough that a phone idling on this screen is not working hard.
const EMBERS: int = 64

var _art: TextureRect
var _mark: Control
var _sparks: GPUParticles2D
var _t: float = 0.0


func wants_header() -> bool:
	return false


## NO BACK BUTTON AND NO SIDE PANEL on this screen — UiShell hides its chrome
## for the title route. There is nowhere to go back to from the front door.
func show_back() -> bool:
	return false


func build() -> void:
	_backdrop()
	_embers()
	content.alignment = BoxContainer.ALIGNMENT_CENTER

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	content.add_child(col)

	_mark = UiGlyph.make(UiGlyph.Kind.MARK, 230, HeroTheme.ACCENT)
	_mark.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(_mark)
	col.add_child(HeroTheme.spacer(20))

	var over: Label = HeroTheme.label("B L O C K L E", HeroTheme.F_SMALL,
		HeroTheme.DIM)
	over.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(over)
	var name_label: Label = HeroTheme.label("HERO", HeroTheme.F_TITLE,
		HeroTheme.TEXT)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(name_label)

	# ONE BUTTON. It goes where the player left off when there is a somewhere
	# — a returning player should not have to find their own champion again —
	# but it says the same thing either way, because "Enter game" is a door
	# and a door does not need to explain the room.
	var enter: Button = HeroTheme.button("Enter game", HeroTheme.Btn.PRIMARY,
		180)
	enter.name = "EnterGame"
	enter.add_theme_font_size_override("font_size", HeroTheme.F_SUPER)
	enter.custom_minimum_size = Vector2(760, 180)
	enter.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var landing: Dictionary = _landing()
	var route: String = String(landing.get("route", UiRoute.CHAMPIONS))
	var who: String = String(landing.get("hero", hero))
	enter.pressed.connect(func() -> void: navigate.emit(route, who))
	footer.add_child(enter)

	set_process(true)


## WHERE "ENTER GAME" ACTUALLY GOES.
##
## A returning player lands on the campaign with the champion they have been
## playing — the one furthest along, not whichever sorts first. Someone with
## no champion levelled and nothing cleared lands on the roster, because a
## campaign screen is meaningless before you have picked anyone.
##
## The button text does not change with it. Naming the region was useful when
## this screen was also the menu and the player needed to know the button was
## the right one; with a single door it is noise, and it goes stale the moment
## the save does.
func _landing() -> Dictionary:
	if roster == null:
		return {"route": UiRoute.CHAMPIONS}

	var best: String = ""
	var best_level: int = 0
	for id in roster.owned.keys():
		var p: HeroProgress = roster.progress(id)
		if p != null and p.level >= best_level:
			best_level = p.level
			best = String(id)
	if best == "":
		return {"route": UiRoute.CHAMPIONS}

	var tier: int = roster.unlocked_tier
	if roster.cleared_map_count(tier) <= 0 and best_level <= 1:
		# Still new, even though the save file exists.
		return {"route": UiRoute.CHAMPIONS, "hero": best}
	return {"route": UiRoute.CAMPAIGN, "hero": best}


# ------------------------------------------------------------------------------
# The painting behind it
# ------------------------------------------------------------------------------

func _backdrop() -> void:
	var holder := Control.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.clip_contents = true
	add_child(holder)
	move_child(holder, 0)

	_art = TextureRect.new()
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Oversized so the drift never exposes an edge.
	_art.offset_left = -DRIFT * 1200.0
	_art.offset_right = DRIFT * 1200.0
	_art.offset_top = -DRIFT * 600.0
	_art.offset_bottom = DRIFT * 600.0
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# THE FIRST MAP'S OWN PLATE. Reusing it rather than commissioning a title
	# painting means the front door shows the place the game actually starts.
	_art.texture = StagePlate.texture_for(0)
	_art.visible = _art.texture != null
	holder.add_child(_art)

	# A scrim, so the type is readable over whatever the painting is doing.
	var scrim := ColorRect.new()
	scrim.color = Color(HeroTheme.BG.r, HeroTheme.BG.g, HeroTheme.BG.b, 0.62)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(scrim)


## Embers drifting up the screen.
func _embers() -> void:
	# A NODE2D, NOT A CONTROL. GPUParticles2D has no anchors and no
	# set_anchors_and_offsets_preset — calling it threw, and because a
	# runtime error aborts the whole function, it took the rest of build()
	# with it: no mark, no wordmark, no Enter button. A title screen that
	# silently renders nothing but a backdrop.
	#
	# It is placed in _process instead, from the live size, because at build
	# time this screen has not been laid out and its size is still zero.
	var p := GPUParticles2D.new()
	p.name = "Embers"
	p.amount = EMBERS
	p.lifetime = 7.0
	# PRE-WARMED. Without this the screen opens empty and fills over seven
	# seconds, so the first thing a player sees is still a still image.
	p.preprocess = 7.0
	p.texture = _dot()

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	# Emitted across the full width, from BELOW the bottom edge, so nothing is
	# seen to pop into existence.
	mat.emission_box_extents = Vector3(1400.0, 10.0, 0.0)
	mat.direction = Vector3(0.0, -1.0, 0.0)
	mat.spread = 14.0
	mat.initial_velocity_min = 40.0
	mat.initial_velocity_max = 110.0
	# A gentle sideways wander, so they do not rise in parallel lines.
	mat.turbulence_enabled = true
	mat.turbulence_noise_strength = 0.6
	mat.turbulence_noise_scale = 1.4
	mat.scale_min = 0.35
	mat.scale_max = 1.0
	mat.color = HeroTheme.GOLD
	# Fading in and out at the ends of the life, so an ember never blinks out
	# at full brightness.
	var ramp := Gradient.new()
	ramp.set_offset(0, 0.0)
	ramp.set_color(0, Color(1, 1, 1, 0.0))
	ramp.add_point(0.18, Color(1, 1, 1, 0.9))
	ramp.add_point(0.75, Color(1, 1, 1, 0.5))
	ramp.set_offset(ramp.get_point_count() - 1, 1.0)
	ramp.set_color(ramp.get_point_count() - 1, Color(1, 1, 1, 0.0))
	var tex := GradientTexture1D.new()
	tex.gradient = ramp
	mat.color_ramp = tex
	p.process_material = mat

	# Below the type, above the painting: embers crossing the wordmark would
	# fight the one thing on screen that has to be legible.
	add_child(p)
	move_child(p, 1)
	_sparks = p
	_place_embers()


## A soft 8 px dot, generated rather than loaded. A title screen must not wait
## on a file, and this is not worth one.
static func _dot() -> Texture2D:
	var size: int = 8
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c: float = (size - 1) * 0.5
	for y in range(size):
		for x in range(size):
			var d: float = Vector2(x - c, y - c).length() / (c + 0.5)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(1.0 - d * d, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


## Emit from across the bottom edge, wherever that currently is.
func _place_embers() -> void:
	if _sparks == null:
		return
	var span: Vector2 = size
	if span.x <= 1.0:
		# Not laid out yet. A sensible guess beats a stack of embers in the
		# top-left corner for the first frame.
		span = Vector2(2532, 1170)
	_sparks.position = Vector2(span.x * 0.5, span.y + 20.0)
	var mat := _sparks.process_material as ParticleProcessMaterial
	if mat != null:
		mat.emission_box_extents = Vector3(span.x * 0.55, 10.0, 0.0)


func _process(delta: float) -> void:
	_place_embers()
	if _art == null or not _art.visible:
		return
	_t += delta
	var phase: float = TAU * _t / DRIFT_TIME
	var span: Vector2 = size * DRIFT * 0.5
	_art.position = Vector2(sin(phase) * span.x, cos(phase * 0.7) * span.y)
