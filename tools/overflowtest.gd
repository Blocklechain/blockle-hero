extends SceneTree
# ------------------------------------------------------------------------------
# Is any part of any menu unreachable?
#
# This exists because "everything needs to be scrollable" is not a thing you can
# check by looking at a screenshot. A screenshot shows you the top of a screen;
# it cannot tell you whether there were four more rows below the fold with no
# way to reach them. Every menu bug this session was of that shape — content
# that WAS there, laid out, correct, and off-screen.
#
# THE RULE: a Control that needs more height than it was given is only
# acceptable if something above it scrolls. Needing more room is normal; needing
# more room inside a fixed box means the overflow is gone and the player has no
# way to know it existed.
#
# It runs headless because Control layout is CPU-side — the dummy display server
# computes every rect exactly as the device does. No screen required, so this
# can gate a commit.
#
#   godot --headless --path . --script tools/overflowtest.gd
# ------------------------------------------------------------------------------

const ROUTES: Array = [
	UiRoute.TITLE, UiRoute.CHAMPIONS, UiRoute.SHEET,
	UiRoute.STASH, UiRoute.SHOP, UiRoute.CAMPAIGN,
]

## Slack, in pixels. Container separation and rounding leave a control a pixel
## or two short of its minimum routinely; that is not lost content.
const SLACK: float = 2.0

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	# THE SIZE IS THE WHOLE TEST. Headless the root window comes up 64x64 and
	# content_scale is never applied, so every container grows to whatever its
	# children ask for and NOTHING can overflow — the first run of this test
	# passed on all six routes while reporting a content box 2464x2222, taller
	# than the device it claims to measure. Pin the design resolution the
	# project ships with, or this file is decoration.
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
	var shells: Array = main.find_children("*", "UiShell", true, false)
	var shell: UiShell = main as UiShell if main is UiShell else shells[0]

	print("viewport: %dx%d" % [get_root().size.x, get_root().size.y])

	for route in ROUTES:
		shell.goto(route)
		# A screen builds on entry and the containers settle a frame or two
		# later; measuring immediately measures a half-built screen.
		for i in range(6):
			await process_frame
		print("\n=== %s ===" % route)
		var clipped: Array[String] = []
		_walk(shell, clipped)
		check("nothing is cut off with no way to scroll to it",
			clipped.is_empty(),
			"%d clipped%s" % [clipped.size(),
				"  " + ", ".join(clipped.slice(0, 4)) if not clipped.is_empty()
				else ""])
		# A screen whose own content box collapsed is the other failure mode:
		# it reports no overflow because it has nothing in it.
		if route == UiRoute.CHAMPIONS:
			_dump(shell, 0)
		var c: Control = _content_of(shell)
		check("...and the screen actually has a content area",
			c != null and c.size.x > 200.0 and c.size.y > 200.0,
			"%.0fx%.0f" % [c.size.x, c.size.y] if c != null else "missing")

	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


## Record every Control that wants more height than it has and has nothing
## scrollable above it.
func _walk(n: Node, out: Array[String]) -> void:
	if n is Control:
		var c := n as Control
		if c.visible and c.size.y > 1.0:
			var need: float = c.get_combined_minimum_size().y
			if need > c.size.y + SLACK and not _scrolls(c):
				out.append("%s(%s needs %.0f has %.0f)"
					% [c.name, c.get_class(), need, c.size.y])
	for k in n.get_children():
		_walk(k, out)


## Is this control inside something that scrolls? A ScrollContainer anywhere up
## the chain means the overflow is reachable. A VirtualList counts too: it
## scrolls its own window over an arbitrary row count by design, so its minimum
## height is a request, not a requirement.
func _scrolls(c: Control) -> bool:
	var n: Node = c
	while n != null:
		if n is ScrollContainer or n is VirtualList:
			return true
		n = n.get_parent()
	return false


func _content_of(n: Node) -> Control:
	for s in n.find_children("*", "UiScreen", true, false):
		var sc := s as UiScreen
		if sc.visible and sc.content != null:
			return sc.content
	return null


func _dump(n: Node, d: int) -> void:
	if d > 6:
		return
	if n is Control:
		var c := n as Control
		print("    %s%s %s  %.0fx%.0f at %.0f,%.0f  min=%.0f" % [
			"  ".repeat(d), c.get_class(), c.name, c.size.x, c.size.y,
			c.position.x, c.position.y, c.get_combined_minimum_size().y])
	for k in n.get_children():
		_dump(k, d + 1)
