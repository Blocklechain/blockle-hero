class_name TitleScreen
extends UiScreen
# ------------------------------------------------------------------------------
# The first thing the player sees: the mark, the name, and Play.
#
# Deliberately empty of everything else. No news panel, no daily reward, no
# settings gear — the champion list behind this button is where the game is, and
# a title screen that asks the player to read before playing is a title screen
# that gets skipped angrily.
# ------------------------------------------------------------------------------

func wants_header() -> bool:
	return false


func build() -> void:
	# The generated title plate behind everything. It is the same art department
	# as the stage select, and a title screen that is one flat colour next to a
	# painted stage list reads as unfinished.
	_backdrop()
	content.alignment = BoxContainer.ALIGNMENT_CENTER

	var mark := UiGlyph.make(UiGlyph.Kind.MARK, 360, HeroTheme.ACCENT)
	mark.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	content.add_child(mark)

	content.add_child(HeroTheme.spacer(40))

	var over := HeroTheme.label("BLOCKLE", HeroTheme.F_HEAD, HeroTheme.DIM,
		HORIZONTAL_ALIGNMENT_CENTER)
	# Letter-spacing by hand: the shell ships no font resource, and a wordmark
	# needs the tracking a display face would have given it.
	over.text = "B L O C K L E"
	content.add_child(over)

	content.add_child(HeroTheme.label("HERO", HeroTheme.F_TITLE,
		HeroTheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER))

	content.add_child(HeroTheme.spacer(24))
	var tag := HeroTheme.prose(
		# DERIVED, NOT TYPED. This said "Sixteen regions" long after the
		# campaign became a hundred maps across eight difficulties — a number
		# written into prose goes stale the moment the thing it describes
		# changes, and nobody re-reads the title screen.
		"%d maps. %d difficulties. %d champions. Everything they find is "
		% [Campaign.map_count(), Campaign.tier_count(),
			HeroRig.animated_heroes().size()]
		+ "shared; everything they learn is theirs alone.",
		HeroTheme.F_SMALL, HeroTheme.FAINT)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(tag)

	var play := HeroTheme.button("Play", HeroTheme.Btn.PRIMARY, 170)
	play.add_theme_font_size_override("font_size", HeroTheme.F_SUPER)
	play.pressed.connect(func() -> void:
		navigate.emit(UiRoute.CHAMPIONS, hero))
	footer.add_child(play)


## A full-bleed plate behind the title, dimmed so type stays legible on it.
##
## Degrades to nothing: if the art has not been generated the screen is exactly
## what it was before, which is tidy rather than broken.
func _backdrop() -> void:
	var path: String = "res://assets/art/menu/title.jpg"
	if not ResourceLoader.exists(path):
		return
	var art := TextureRect.new()
	art.texture = load(path) as Texture2D
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(art)
	move_child(art, 0)

	var veil := ColorRect.new()
	veil.color = Color(HeroTheme.BG.r, HeroTheme.BG.g, HeroTheme.BG.b, 0.68)
	veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(veil)
	move_child(veil, 1)
