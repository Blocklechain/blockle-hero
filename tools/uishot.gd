extends SceneTree
# Screenshots every menu route, so the layout can be LOOKED at rather than
# reasoned about. The menus were authored against a 1170x2532 portrait design
# and the game now runs 2532x1170 landscape; nothing in the headless checks
# measures whether a control ended up off-screen or on top of another one.
#
#   godot --path . --script tools/uishot.gd        (windowed: needs a display)
#
# Writes tools/out/ui/<route>.png.

const OUT: String = "res://tools/out/ui"

const ROUTES: Array = [
	UiRoute.TITLE, UiRoute.CHAMPIONS, UiRoute.SHEET,
	UiRoute.STASH, UiRoute.SHOP, UiRoute.CAMPAIGN,
]


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	await process_frame

	# THE REAL BOOT SCENE, not a bare UiShell. The shell expects to live inside
	# Main.tscn and reads Ui/Safe and Overlay out of it; instantiated alone it
	# errors on _ready and every capture is the same empty frame.
	var packed: PackedScene = load("res://scenes/Main.tscn")
	var main: Node = packed.instantiate()
	get_root().add_child(main)
	for i in range(8):
		await process_frame
	var shell: UiShell = main if main is UiShell else main.find_children(
		"*", "UiShell", true, false)[0]

	var vp: Vector2i = Vector2i(get_root().size)
	print("viewport: %dx%d" % [vp.x, vp.y])

	for route in ROUTES:
		shell.goto(route)
		# Several frames: a screen builds its children on entry and the
		# container layout settles a frame or two later. Capturing immediately
		# photographs a half-laid-out screen and blames the design for it.
		for i in range(6):
			await process_frame
		for vl in main.find_children("*", "VirtualList", true, false):
			if vl.visible:
				print("  VirtualList row_height=%d  count=%d  size=%.0fx%.0f"
					% [vl.row_height, vl.count(), vl.size.x, vl.size.y])
		if route == UiRoute.CHAMPIONS:
			print("  --- layout chain ---")
			_dump(shell, 0)
		var img: Image = get_root().get_texture().get_image()
		var path: String = "%s/%s.png" % [OUT, route]
		img.save_png(ProjectSettings.globalize_path(path))
		print("  wrote %s  (%dx%d)" % [path, img.get_width(), img.get_height()])

	quit(0)


## Print the rect of every Control, so a collapsed container is visible as a
## number instead of inferred from a screenshot.
func _dump(n: Node, depth: int) -> void:
	if depth > 7:
		return
	if n is Control:
		var c := n as Control
		print("  %s%s %s  size=%.0fx%.0f  hflag=%d vflag=%d min=%.0fx%.0f" % [
			"  ".repeat(depth), c.get_class(), c.name, c.size.x, c.size.y,
			c.size_flags_horizontal, c.size_flags_vertical,
			c.custom_minimum_size.x, c.custom_minimum_size.y])
	for k in n.get_children():
		_dump(k, depth + 1)
