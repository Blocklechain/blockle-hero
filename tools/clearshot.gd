extends SceneTree
# Photographs the clear screen at the end of its animation.
#   godot --path . --script tools/clearshot.gd
func _init() -> void: _go.call_deferred()
func _go() -> void:
	var design := Vector2i(2532, 1170)
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	get_root().content_scale_size = design
	get_root().size = design
	await process_frame
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.07, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_root().add_child(bg)
	var s := ClearScreen.new()
	get_root().add_child(s)
	s.show_summary({
		"region": 11, "tier": Campaign.Tier.NORMAL, "hero": "brom",
		"kills": 17, "gold": 1430, "items": 4, "levels": 1,
		"crystals": 0, "cleared": 12, "total": Campaign.map_count(),
		"next": 12,
	})
	for i in range(140):
		await process_frame
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://tools/out/ui"))
	get_root().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://tools/out/ui/clear.png"))
	print("wrote clear.png")
	quit(0)
