extends SceneTree
# Photographs the champion-arrival sequence at its final beat.
#   godot --path . --script tools/revealshot.gd
func _init() -> void: _go.call_deferred()
func _go() -> void:
	var design := Vector2i(2532, 1170)
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_size = design
	get_root().size = design
	await process_frame
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.1)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_root().add_child(bg)
	var s := RevealScreen.new()
	get_root().add_child(s)
	# A rare one, so the rarity colour is worth photographing.
	var pick: String = HeroRig.animated_heroes()[0]
	for h in HeroRig.animated_heroes():
		if Champion.rarity_of(h) >= 4:
			pick = h
			break
	s.reveal(pick, false, 0)
	for i in range(150):
		await process_frame
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://tools/out/ui"))
	get_root().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://tools/out/ui/reveal.png"))
	print("wrote reveal.png for %s (%s)" % [pick, Champion.rarity_name(pick)])
	quit(0)
