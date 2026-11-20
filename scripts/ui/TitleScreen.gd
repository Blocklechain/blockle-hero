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
		"Sixteen regions. One hundred and thirty-nine champions. "
		+ "Everything they find is shared; everything they learn is theirs alone.",
		HeroTheme.F_SMALL, HeroTheme.FAINT)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(tag)

	var play := HeroTheme.button("Play", HeroTheme.Btn.PRIMARY, 170)
	play.add_theme_font_size_override("font_size", HeroTheme.F_SUPER)
	play.pressed.connect(func() -> void:
		navigate.emit(UiRoute.CHAMPIONS, hero))
	footer.add_child(play)
