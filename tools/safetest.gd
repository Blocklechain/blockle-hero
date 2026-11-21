extends SceneTree
# ------------------------------------------------------------------------------
# The camera cut-out was sitting on the UI.
#
# This game is landscape-only, and in landscape the Dynamic Island and the home
# indicator are on the LEFT and RIGHT edges — not the top. The shell computed
# top and bottom from the device's reported safe area and hardcoded left and
# right to a 34px pad, so on every notched phone the cut-out covered whatever
# the leftmost column was drawing. HeroTheme.SAFE_X was written for exactly
# this problem and wired to nothing.
#
# The arithmetic is tested here rather than on a device because none of the
# tooling has a notch: every bug this code has had lived in a branch that only
# executes on hardware the screenshots never see.
#
#   godot --headless --path . --script tools/safetest.gd
# ------------------------------------------------------------------------------

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	var design := Vector2(2532, 1170)

	print("\n=== a notched phone, held in landscape ===")
	# iPhone 15 Pro, landscape, island on the left: 59pt inset at 3x = 177px,
	# and a 21pt home indicator along the bottom = 63px.
	var win := Vector2i(2556, 1179)
	var area := Rect2i(177, 0, 2556 - 177, 1179 - 63)
	var m: Dictionary = UiShell.safe_margins(win, area, design)
	check("the side the island is on is inset properly",
		int(m["left"]) > 150, "%d px" % int(m["left"]))
	check("...far more than the old hardcoded pad",
		int(m["left"]) > HeroTheme.PAD * 3,
		"%d vs the %d it used to use" % [int(m["left"]), HeroTheme.PAD])
	check("the home indicator is cleared at the bottom",
		int(m["bottom"]) >= 60, "%d px" % int(m["bottom"]))
	check("the clean edges still get breathing room",
		int(m["right"]) >= UiShell.MIN_INSET and int(m["top"])
			>= UiShell.MIN_INSET,
		"right %d, top %d" % [int(m["right"]), int(m["top"])])

	print("\n=== the island on the other side ===")
	# The same phone rotated the other way. Both orientations are landscape
	# and the game does not lock which one, so an inset applied to one side
	# only would be right half the time.
	var flipped := Rect2i(0, 0, 2556 - 177, 1179 - 63)
	var f: Dictionary = UiShell.safe_margins(win, flipped, design)
	check("the inset follows the cut-out to the right edge",
		int(f["right"]) > 150, "%d px" % int(f["right"]))

	print("\n=== the axes are measured independently ===")
	# A viewport stretched to a different aspect than the window: the old
	# code scaled vertical insets by the HORIZONTAL ratio, which is only
	# correct when the two happen to match.
	var tall := Vector2(2532, 1600)
	var t: Dictionary = UiShell.safe_margins(win, area, tall)
	check("a taller viewport scales the bottom inset further",
		int(t["bottom"]) > int(m["bottom"]),
		"%d px vs %d at the design aspect" % [int(t["bottom"]),
			int(m["bottom"])])
	check("...without moving the side insets",
		int(t["left"]) == int(m["left"]),
		"%d px either way" % int(t["left"]))

	print("\n=== nonsense never eats the screen ===")
	check("a device that reports nothing still gets a pad",
		int(UiShell.safe_margins(Vector2i.ZERO, Rect2i(), design)["left"])
			== UiShell.MIN_INSET)
	check("an absurd safe area is clamped",
		int(UiShell.safe_margins(win, Rect2i(2000, 0, 100, 100),
			design)["left"]) <= UiShell.MAX_INSET,
		"capped at %d" % UiShell.MAX_INSET)

	print("\n=== the in-game HUD keeps clear of it too ===")
	# The HUD is NOT inside the shell's safe container — it is part of the
	# play scene — so it has to apply the insets itself. It used to carry a
	# private copy of the same arithmetic, with the same two bugs.
	var keys: Array[Dictionary] = Hud.key_layout(design, 62.0, 175.0)
	var basic: Vector2 = keys[0]["centre"]
	var clear: Array[Dictionary] = Hud.key_layout(design, 62.0, 0.0)
	check("the ability keys move in off a cut-out edge",
		basic.x < float(clear[0]["centre"].x) - 150.0,
		"x %.0f vs %.0f with no inset" % [basic.x, clear[0]["centre"].x])
	check("...and every key stays on screen",
		_on_screen(keys, design), "%d keys" % keys.size())
	check("...including with no inset at all",
		_on_screen(clear, design))

	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


## Every key, including its radius, inside the display.
func _on_screen(keys: Array[Dictionary], view: Vector2) -> bool:
	for k in keys:
		var c: Vector2 = k["centre"]
		var r: float = float(k["radius"])
		if c.x - r < 0.0 or c.y - r < 0.0 \
				or c.x + r > view.x or c.y + r > view.y:
			return false
	return true
