class_name TitleScreen
extends UiScreen
# ------------------------------------------------------------------------------
# The first thing the player sees.
#
# It used to be the mark, the name and Play, centred in a column — which is
# the right screen for someone opening the game for the first time and the
# wrong one for everybody else. A player on their fortieth session does not
# need the pitch; they need to know where they were and to get back there in
# one tap.
#
# So it is two screens wearing one layout:
#
#   A NEW PLAYER gets the pitch. The counts are real and derived, the button
#   says Begin, and nothing else is on screen to read.
#
#   A RETURNING PLAYER gets their own game back. The button names the
#   champion and the region they stopped at and goes straight there; the line
#   under it is their progress, not the game's feature list; and the shortcuts
#   mean restocking before the next region is one tap rather than three.
#
# LEFT-WEIGHTED, NOT CENTRED. The plate has a champion standing on a cliff on
# the right-hand side and empty sky on the left, and the old layout put the
# wordmark squarely over the one part of the painting worth looking at. The
# column now sits in the sky and the scrim fades out before it reaches them.
# ------------------------------------------------------------------------------

## How much of the width the text column occupies. The rest is painting.
const COLUMN: float = 0.52
## How far the backdrop drifts, as a share of its own size. Small enough that
## nobody consciously sees it move, large enough that the screen is not a
## still image.
const DRIFT: float = 0.035
## Seconds for one full drift cycle. Slow — a title screen that visibly pans
## is a screensaver.
const DRIFT_TIME: float = 26.0

var _art: TextureRect
var _mark: Control
var _t: float = 0.0


func wants_header() -> bool:
	return false


func build() -> void:
	_backdrop()
	content.alignment = BoxContainer.ALIGNMENT_CENTER

	# The whole column is pushed left, into the empty half of the painting.
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(row)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = COLUMN
	col.add_theme_constant_override("separation", 4)
	row.add_child(col)

	# The right half is deliberately empty. It is not wasted space; it is the
	# reason the plate was generated.
	var air := Control.new()
	air.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	air.size_flags_stretch_ratio = 1.0 - COLUMN
	row.add_child(air)

	_mark = UiGlyph.make(UiGlyph.Kind.MARK, 210, HeroTheme.ACCENT)
	_mark.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	col.add_child(_mark)
	col.add_child(HeroTheme.spacer(18))

	var over := HeroTheme.label("B L O C K L E", HeroTheme.F_SMALL,
		HeroTheme.DIM)
	col.add_child(over)
	col.add_child(HeroTheme.label("HERO", HeroTheme.F_TITLE, HeroTheme.TEXT))

	col.add_child(HeroTheme.spacer(16))
	col.add_child(_strap())

	# --- what the buttons do -------------------------------------------------
	var resume: Dictionary = _resume()
	var play := HeroTheme.button(String(resume.get("label", "Begin")),
		HeroTheme.Btn.PRIMARY, 170)
	play.add_theme_font_size_override("font_size", HeroTheme.F_SUPER)
	var route: String = String(resume.get("route", UiRoute.CHAMPIONS))
	var who: String = String(resume.get("hero", hero))
	play.pressed.connect(func() -> void: navigate.emit(route, who))
	footer.add_child(play)

	if bool(resume.get("returning", false)):
		# ONLY FOR A RETURNING PLAYER. On a first run these three go to
		# screens with nothing in them, and a row of empty rooms is a worse
		# first impression than no row at all.
		var quick := HBoxContainer.new()
		quick.add_theme_constant_override("separation", 14)
		footer.add_child(quick)
		_quick(quick, "Champions", UiRoute.CHAMPIONS, who)
		_quick(quick, "Stash", UiRoute.STASH, who)
		_quick(quick, "Merchant", UiRoute.SHOP, who)
		# The bench. On the title screen because the whole point is to
		# collect on the way past, not to go looking for it.
		_quick(quick, "Training", UiRoute.TRAINING, who)
		# The board, next to the bench: both are things to check before a run
		# rather than destinations of their own.
		_quick(quick, "Contracts", UiRoute.QUESTS, who)
		# Who else is coming. On the title screen because it is a decision
		# made on the way into a run, not a menu to go hunting for.
		_quick(quick, "Party", UiRoute.PARTY, who)

	set_process(true)


func _quick(into: HBoxContainer, text: String, route: String,
		who: String) -> void:
	var b := HeroTheme.button(text, HeroTheme.Btn.SECONDARY, 120)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(func() -> void: navigate.emit(route, who))
	into.add_child(b)


## Where the player left off, and what to call the button that returns them.
##
## "Continue" on its own is a promise with no content. Naming the champion and
## the region is the difference between a button the player trusts and one
## they press hoping it does the right thing.
func _resume() -> Dictionary:
	if roster == null:
		return {"label": "Begin", "route": UiRoute.CHAMPIONS,
			"returning": false}

	var tier: int = roster.unlocked_tier
	var cleared: int = roster.cleared_map_count(tier)
	# Pick the champion the player has actually been playing: the one furthest
	# along, not whichever sorts first.
	var best: String = ""
	var best_level: int = 0
	for id in roster.owned.keys():
		var p: HeroProgress = roster.progress(id)
		if p != null and p.level >= best_level:
			best_level = p.level
			best = String(id)
	if best == "":
		return {"label": "Begin", "route": UiRoute.CHAMPIONS,
			"returning": false}

	# Someone who has cleared nothing and levelled nobody is still new, even
	# if the save file exists.
	if cleared <= 0 and best_level <= 1:
		return {"label": "Begin", "route": UiRoute.CHAMPIONS,
			"hero": best, "returning": false}

	var region: int = roster.furthest_unlocked(tier)
	return {
		"label": "Continue · %s" % Campaign.region_title(region),
		"route": UiRoute.CAMPAIGN,
		"hero": best,
		"returning": true,
	}


## The line under the title. Their numbers if they have any, the pitch if not.
func _strap() -> Control:
	var tier: int = roster.unlocked_tier if roster != null else 0
	var cleared: int = roster.cleared_map_count(tier) if roster != null else 0
	var owned: int = roster.owned.size() if roster != null else 0

	if roster == null or (cleared <= 0 and owned <= 3):
		# DERIVED, NOT TYPED. This said "Sixteen regions" long after the
		# campaign became a hundred maps across eight difficulties — a number
		# written into prose goes stale the moment the thing it describes
		# changes, and nobody re-reads the title screen.
		var tag := HeroTheme.prose(
			"%d regions. %d difficulties. %d champions. Everything they find "
			% [Campaign.map_count(), Campaign.tier_count(),
				HeroRig.animated_heroes().size()]
			+ "is shared; everything they learn is theirs alone.",
			HeroTheme.F_SMALL, HeroTheme.FAINT)
		return tag

	# A returning player's own game, in three numbers they earned.
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", HeroTheme.GAP * 2)
	_stat(line, "%d/%d" % [cleared, Campaign.map_count()], "regions cleared")
	_stat(line, "%d" % owned, "champions")
	_stat(line, Campaign.tier_name(tier), "difficulty")
	return line


func _stat(into: HBoxContainer, value: String, label: String) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.add_child(HeroTheme.label(value, HeroTheme.F_HEAD, HeroTheme.ACCENT))
	box.add_child(HeroTheme.label(label, HeroTheme.F_SMALL, HeroTheme.DIM))
	into.add_child(box)


func _process(delta: float) -> void:
	_t += delta
	# A very slow drift across the plate, and the mark breathing with it. Both
	# are below the threshold of being noticed and both are the difference
	# between a screen and a photograph of a screen.
	if _art != null:
		var k: float = sin(_t * TAU / DRIFT_TIME)
		_art.position = Vector2(-size.x * DRIFT * 0.5 * (1.0 + k * 0.6),
			-size.y * DRIFT * 0.5)
	if _mark != null:
		_mark.modulate.a = 0.88 + 0.12 * sin(_t * 1.1)


## A full-bleed plate behind the title.
##
## Degrades to nothing: if the art has not been generated the screen is exactly
## what it was before, which is tidy rather than broken.
func _backdrop() -> void:
	var path: String = "res://assets/art/menu/title.jpg"
	if not ResourceLoader.exists(path):
		return
	_art = TextureRect.new()
	_art.texture = load(path) as Texture2D
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Oversized, so there is something to drift INTO. A plate scaled exactly
	# to the screen would show a bar of background the moment it moved.
	# OUT TO THE GLASS. The shell insets every screen by the safe area, which
	# on a title plate reads as a framed picture hanging inside the app rather
	# than as the app's own surface — there was a dark border down all four
	# sides of the one full-bleed image in the game.
	add_child(_art)
	move_child(_art, 0)
	bleed(_art)
	_art.offset_right += size.x * DRIFT
	_art.offset_bottom += size.y * DRIFT

	# A GRADIENT, NOT A FLAT VEIL. The old screen dimmed the whole painting to
	# 32% so that type centred on top of it stayed legible — which made the
	# art pointless. The scrim is now heavy where the words are and gone by
	# the time it reaches the champion on the right.
	var grad := Gradient.new()
	var bg: Color = HeroTheme.BG
	grad.set_color(0, Color(bg.r, bg.g, bg.b, 0.93))
	grad.set_color(1, Color(bg.r, bg.g, bg.b, 0.0))
	grad.set_offset(0, 0.0)
	grad.set_offset(1, 1.0)
	grad.add_point(0.55, Color(bg.r, bg.g, bg.b, 0.62))

	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 256
	tex.height = 2
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(1, 0)

	var scrim := TextureRect.new()
	scrim.texture = tex
	scrim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	scrim.stretch_mode = TextureRect.STRETCH_SCALE
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)
	move_child(scrim, 1)
	bleed(scrim)

	# A second wash under the footer, so the buttons sit on something solid
	# without dimming the sky above them. GRADED, not a rectangle: a flat
	# ColorRect drew a hard horizontal line straight across the painting at
	# its top edge, which reads as a rendering seam rather than as lighting.
	var down := Gradient.new()
	down.set_color(0, Color(bg.r, bg.g, bg.b, 0.0))
	down.set_color(1, Color(bg.r, bg.g, bg.b, 0.72))
	var dtex := GradientTexture2D.new()
	dtex.gradient = down
	dtex.width = 2
	dtex.height = 256
	dtex.fill_from = Vector2(0, 0)
	dtex.fill_to = Vector2(0, 1)

	var foot := TextureRect.new()
	foot.texture = dtex
	foot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	foot.stretch_mode = TextureRect.STRETCH_SCALE
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(foot)
	move_child(foot, 2)
	bleed(foot, true, false, true, true)
	foot.offset_top = size.y - 420.0
