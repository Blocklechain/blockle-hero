extends SceneTree
# ------------------------------------------------------------------------------
# Can a FINGER actually scroll these lists?
#
# overflowtest.gd asks whether content fits, and it passes. That is a different
# question from whether the player can reach the content that does not fit, and
# the answer the player gave was no.
#
# Two things it cannot see:
#
#   1. A ScrollContainer scrolls to its child's minimum height. VirtualList
#      sets that in set_count() from row_height — but row_height now GROWS
#      during _sync when a row turns out to need a third line. Nothing
#      recomputes the extent when it does, so the rows are laid out on a
#      203px step inside a range measured at 150, and the tail of every list
#      is below the bottom of a scrollbar that has already run out.
#
#   2. A mouse wheel is not a finger. Every row is a Button, and a Button
#      takes the press — so on a phone the drag never reaches the
#      ScrollContainer underneath and the list simply does not move. On a
#      desktop, where the capture tooling runs, the wheel works and everything
#      looks fine.
#
# So this drives real InputEventScreenTouch/Drag through the viewport and
# asserts the list moved.
#
#   godot --headless --path . --script tools/scrolltest.gd
# ------------------------------------------------------------------------------

const ROUTES: Array = [
	UiRoute.CHAMPIONS, UiRoute.STASH, UiRoute.SHOP, UiRoute.CAMPAIGN,
]

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-50s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	var design := Vector2i(
		ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height"))
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	get_root().content_scale_size = design
	get_root().size = design
	await process_frame

	var main: Node = load("res://scenes/Main.tscn").instantiate()
	get_root().add_child(main)
	for i in range(8):
		await process_frame
	var shell: UiShell = main as UiShell if main is UiShell \
		else main.find_children("*", "UiShell", true, false)[0]

	for route in ROUTES:
		shell.goto(route)
		for i in range(8):
			await process_frame
		print("\n=== %s ===" % route)
		# EVERY visible ScrollContainer, not only the VirtualLists. The first
		# version of this looked for VirtualList and so reported nothing at
		# all on the stash and the merchant, whose lists are hidden behind the
		# inactive tab — the content the player is actually looking at on
		# those screens is a plain ScrollContainer, and it did not scroll
		# either.
		var seen: int = 0
		for sc in main.find_children("*", "ScrollContainer", true, false):
			if not sc.is_visible_in_tree():
				continue
			seen += 1
			await _one(sc)
		check("the screen has something scrollable on it", seen > 0,
			"%d containers" % seen)

	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


func _one(list: ScrollContainer) -> void:
	var need: float = 0.0
	var have: float = 0.0
	if list is VirtualList:
		# The extent has to cover where the rows actually are. Rows sit at
		# index * (row_height + SPACING), so the last row's bottom is the
		# floor.
		var vl := list as VirtualList
		var step: int = vl.row_height + VirtualList.SPACING
		need = float(vl.count()) * float(step) - float(VirtualList.SPACING)
		have = vl.get_child(0).get_combined_minimum_size().y
		check("the scroll range reaches the last row",
			have >= need - 1.0,
			"range %.0f, rows end at %.0f (%d x %d)" % [have, need,
				vl.count(), step])
	else:
		for c in list.get_children():
			if c is Control:
				need = maxf(need, (c as Control).get_combined_minimum_size().y)

	if need <= list.size.y + 1.0:
		# Everything fits; there is nothing to scroll to and nothing to prove.
		return

	# A FINGER, not a wheel. Press inside the list, drag up well past any
	# deadzone, release.
	var from: Vector2 = list.global_position + list.size * Vector2(0.5, 0.7)
	var before: float = list.scroll_vertical

	var down := InputEventScreenTouch.new()
	down.index = 0
	down.pressed = true
	down.position = from
	Input.parse_input_event(down)
	await process_frame

	var at: Vector2 = from
	for i in range(10):
		var drag := InputEventScreenDrag.new()
		drag.index = 0
		drag.position = at - Vector2(0.0, 26.0)
		drag.relative = Vector2(0.0, -26.0)
		drag.velocity = Vector2(0.0, -900.0)
		at = drag.position
		Input.parse_input_event(drag)
		await process_frame

	var up := InputEventScreenTouch.new()
	up.index = 0
	up.pressed = false
	up.position = at
	Input.parse_input_event(up)
	for i in range(4):
		await process_frame

	check("...and a finger drag actually moves it",
		list.scroll_vertical > before,
		"%.0f -> %.0f" % [before, list.scroll_vertical])
