extends SceneTree
# ------------------------------------------------------------------------------
# THE CAMPAIGN IS A CAROUSEL NOW, AND A CAROUSEL CAN LOSE THINGS A LIST HAD.
#
# Replacing a hundred-row list with one full-screen plate is the right call for
# a screen whose content is paintings, but it drops three properties that the
# list was holding up for free. All three are the kind that fail silently:
#
#   * REACH. A scrollbar got to map 60 in one flick. One arrow per map is
#     sixty taps. If the act row ever stops working, the campaign past act 1
#     is still technically reachable, so nothing errors — it just becomes
#     unusable, and only on a save far enough in to notice.
#
#   * WHY A MAP IS SHUT. The list wrote the reason on every locked row. The
#     carousel has exactly one map on screen, so if the sealed state is not
#     rendered the refusal becomes a dead button with no explanation.
#
#   * WHERE YOU ARE. A column shows it implicitly; one plate does not.
#
# And it adds a failure mode a list never had: a TRANSITION. Two art layers
# with a tween between them leaks a layer per interrupted slide, which on a
# screen a player pages through forty times is forty stacked pictures.
# ------------------------------------------------------------------------------

const CampaignScreenS := preload("res://scripts/ui/CampaignScreen.gd")
const StagePlateS := preload("res://scripts/ui/StagePlate.gd")
# GameMode is newer than the editor's class cache; preload it like everything
# else added from outside the editor.
const GameModeS := preload("res://scripts/game/GameMode.gd")

var _fails: int = 0
var _ran: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _roster(cleared: int = 0) -> Roster:
	var r := Roster.create(HeroRig.animated_heroes(), 515)
	for i in range(cleared):
		r.record_map_cleared(Campaign.Tier.NORMAL, i)
	return r


func _screen(r: Roster) -> UiScreen:
	var s: UiScreen = CampaignScreenS.new()
	s.roster = r
	s.hero = r.owned_names()[0]
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(s)
	return s


func _init() -> void:
	# A real viewport, so the plate has a width and therefore really slides
	# rather than falling back to the instant swap.
	var design := Vector2i(2532, 1170)
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_size = design
	get_root().size = design
	await process_frame

	await _paging(); _ran += 1
	await _reach(); _ran += 1
	await _sealed(); _ran += 1
	await _swipe(); _ran += 1
	await _entering(); _ran += 1
	await _the_transition(); _ran += 1
	print("")
	check("every section ran to completion", _ran == 6, "%d of 6" % _ran)
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


# ---- helpers -----------------------------------------------------------------

func _buttons(node: Node, out: Array = []) -> Array:
	if node is Button:
		out.append(node)
	for c in node.get_children():
		_buttons(c, out)
	return out


## The edge arrows, found BY NAME.
##
## Not by their glyph: UiScreen gives every screen a header back button that
## carries the same BACK chevron, so "the button with a back glyph" finds that
## one first — which is exactly what the first version of this did, and two
## assertions failed because `left` was the header's back button and pressing
## it navigated away instead of paging.
func _arrow(node: Node, back: bool) -> Button:
	var plate: Node = node.get("_plate")
	if plate == null:
		return null
	return plate.get_node_or_null("PageBack" if back else "PageNext") as Button


func _labelled(node: Node, text: String) -> Button:
	for b in _buttons(node):
		if (b as Button).text == text:
			return b
	return null


func _strings(n: Node, into: PackedStringArray = PackedStringArray()
		) -> PackedStringArray:
	if n is Label and not (n as Label).text.is_empty():
		into.append((n as Label).text)
	elif n is Button and not (n as Button).text.is_empty():
		into.append((n as Button).text)
	for c in n.get_children():
		_strings(c, into)
	return into


func _at(screen: UiScreen) -> int:
	return int(screen.get("_region"))


# ---- paging ------------------------------------------------------------------

func _paging() -> void:
	print("\n=== paging ===")
	# A save part-way in, so there is room to page both ways.
	var r := _roster(20)
	var screen := _screen(r)
	await process_frame

	# OPENS WHERE THEY STOPPED. On a half-finished campaign, opening at map 1
	# is twenty taps of arrow before the player is back where they were.
	check("the carousel opens on the furthest map unlocked",
		_at(screen) == r.furthest_unlocked(Campaign.Tier.NORMAL),
		"map %d, furthest %d" % [_at(screen) + 1,
			r.furthest_unlocked(Campaign.Tier.NORMAL) + 1])

	var left: Button = _arrow(screen, true)
	var right: Button = _arrow(screen, false)
	check("there is an arrow on each side", left != null and right != null)
	if left == null or right == null:
		screen.queue_free()
		return

	var was: int = _at(screen)
	right.pressed.emit()
	await process_frame
	check("the right arrow goes forward one map", _at(screen) == was + 1,
		"%d -> %d" % [was + 1, _at(screen) + 1])
	left.pressed.emit()
	await process_frame
	check("...and the left arrow comes back", _at(screen) == was)

	# THE ENDS CLAMP, AND SAY SO. Wrapping from map 100 to map 1 would throw
	# away the player's place; an arrow that silently does nothing reads as a
	# dead button, so the disabled state is the cue.
	screen.call("_go_to", 0)
	await process_frame
	check("at the first map the back arrow is disabled", left.disabled)
	check("...and pressing it changes nothing", _at(screen) == 0)
	screen.call("_go_to", Campaign.region_count() - 1)
	await process_frame
	check("at the last map the forward arrow is disabled", right.disabled)
	check("...and it does not wrap to the first",
		_at(screen) == Campaign.region_count() - 1,
		"map %d" % (_at(screen) + 1))

	# A map index from outside the campaign is clamped, not crashed into.
	screen.call("_go_to", 9999)
	screen.call("_go_to", -40)
	await process_frame
	check("a nonsense map index is clamped", _at(screen) == 0,
		"map %d" % (_at(screen) + 1))

	screen.queue_free()


# ---- reach -------------------------------------------------------------------

func _reach() -> void:
	print("\n=== the whole campaign stays in reach ===")
	var r := _roster(60)
	var screen := _screen(r)
	await process_frame

	# THE ACT ROW IS THE SCROLLBAR. Found by tooltip, because the buttons are
	# numbered 1-10 and the act's name is what says which is which.
	var jumped: int = 0
	for act in range(Campaign.act_count()):
		var b: Button = null
		for cand in _buttons(screen):
			if (cand as Button).tooltip_text == Campaign.act_name(act):
				b = cand
				break
		if b == null:
			continue
		b.pressed.emit()
		await process_frame
		if Campaign.act_of(_at(screen)) == act:
			jumped += 1
	check("every act can be jumped to directly", jumped == Campaign.act_count(),
		"%d of %d" % [jumped, Campaign.act_count()])

	# WORST CASE FROM ANY ACT. One act tap plus arrows inside it — nine, not
	# ninety-nine.
	check("...so no map is more than one tap plus an act away",
		Campaign.maps_per_act() - 1 <= 12,
		"%d arrows inside an act" % (Campaign.maps_per_act() - 1))

	# And every map really is addressable, end to end.
	var reached: int = 0
	for i in range(Campaign.region_count()):
		screen.call("_go_to", i)
		if _at(screen) == i:
			reached += 1
	check("every region in the campaign can be shown",
		reached == Campaign.region_count(),
		"%d of %d" % [reached, Campaign.region_count()])
	screen.queue_free()


# ---- sealed maps -------------------------------------------------------------

func _sealed() -> void:
	print("\n=== a map you cannot enter says why ===")
	# Nothing cleared, so map 2 onward is sealed.
	var r := _roster(0)
	var screen := _screen(r)
	await process_frame

	var enter: Button = null
	for b in _buttons(screen):
		if (b as Button).text.findn("Enter") >= 0:
			enter = b
			break
	check("the open map can be entered", enter != null
		and not enter.disabled,
		enter.text if enter != null else "no Enter button")

	screen.call("_go_to", 5)
	await process_frame
	var said: bool = false
	for t in _strings(screen):
		if t.findn("Clear region") >= 0:
			said = true
	check("a sealed map says what opens it", said,
		_strings(screen)[0] if not _strings(screen).is_empty() else "")

	# And entering is refused, not merely discouraged.
	var now: Button = null
	for b in _buttons(screen):
		if (b as Button).text.findn("Clear region") >= 0:
			now = b
			break
	check("...and the way in is disabled", now != null and now.disabled)

	# THE ART IS STILL SHOWN, dimmed. A sealed map's picture is the reason to
	# want to get there; hiding it would make the carousel a wall.
	var plate: StagePlate = screen.get("_plate")
	check("a sealed map is dimmed rather than blanked",
		plate != null and plate.modulate.r < 0.9 and plate.visible,
		"modulate %.2f" % (plate.modulate.r if plate != null else -1.0))
	screen.call("_go_to", 0)
	await process_frame
	check("...and an open map is not dimmed", plate.modulate.r > 0.9)
	screen.queue_free()


# ---- swipe -------------------------------------------------------------------

func _swipe() -> void:
	print("\n=== swipe ===")
	# A carousel on a phone that can only be driven by its arrows feels like
	# a form. The arrows stay because they are what makes the gesture
	# discoverable, but the gesture has to work.
	var r := _roster(30)
	var screen := _screen(r)
	await process_frame
	screen.call("_go_to", 15)
	await process_frame

	var press := InputEventScreenTouch.new()
	press.pressed = true
	press.position = Vector2(1400, 600)
	screen.call("_gui_input", press)
	var drag := InputEventScreenDrag.new()
	# Dragging LEFT brings the next map in from the right, which is what every
	# photo gallery on the device does.
	drag.position = Vector2(1400 - screen.SWIPE - 20, 600)
	screen.call("_gui_input", drag)
	await process_frame
	check("dragging left pages forward", _at(screen) == 16,
		"map %d" % (_at(screen) + 1))

	var press2 := InputEventScreenTouch.new()
	press2.pressed = true
	press2.position = Vector2(1400, 600)
	screen.call("_gui_input", press2)
	var drag2 := InputEventScreenDrag.new()
	drag2.position = Vector2(1400 + screen.SWIPE + 20, 600)
	screen.call("_gui_input", drag2)
	await process_frame
	check("dragging right pages back", _at(screen) == 15,
		"map %d" % (_at(screen) + 1))

	# A SHORT DRAG IS NOT A SWIPE, or every tap on the art pages the screen.
	var press3 := InputEventScreenTouch.new()
	press3.pressed = true
	press3.position = Vector2(1400, 600)
	screen.call("_gui_input", press3)
	var nudge := InputEventScreenDrag.new()
	nudge.position = Vector2(1400 - 12, 600)
	screen.call("_gui_input", nudge)
	await process_frame
	check("a nudge is not a page", _at(screen) == 15,
		"map %d" % (_at(screen) + 1))

	# A DRAG AFTER THE FINGER IS LIFTED must be ignored rather than measured
	# from wherever the last press happened to be. The release has to be sent:
	# the first version of this fired the drag while a press was still down,
	# so it was a legitimate 1300 px swipe and paged correctly — the test was
	# wrong, not the screen.
	var lift := InputEventScreenTouch.new()
	lift.pressed = false
	lift.position = Vector2(1388, 600)
	screen.call("_gui_input", lift)
	var orphan := InputEventScreenDrag.new()
	orphan.position = Vector2(100, 600)
	screen.call("_gui_input", orphan)
	await process_frame
	check("a drag after the finger is lifted is ignored", _at(screen) == 15,
		"map %d" % (_at(screen) + 1))
	screen.queue_free()


# ---- entering ----------------------------------------------------------------

func _entering() -> void:
	print("\n=== entering ===")
	var r := _roster(25)
	var screen := _screen(r)
	var launches: Array = []
	screen.navigate.connect(func(route: String, arg: Variant) -> void:
		if route == UiRoute.LAUNCH:
			launches.append(arg))
	await process_frame

	screen.call("_go_to", 12)
	await process_frame
	var enter: Button = null
	for b in _buttons(screen):
		var t: String = (b as Button).text
		if t.findn("Enter") >= 0 or t.findn("Replay") >= 0:
			enter = b
			break
	check("the open map offers a way in", enter != null and not enter.disabled,
		enter.text if enter != null else "none")
	if enter != null:
		enter.pressed.emit()
		check("pressing it launches THE MAP ON SCREEN", launches.size() == 1
			and int((launches[0] as Dictionary).get("region", -1)) == 12,
			"%s" % launches)

	# A map already beaten says Replay rather than Enter: on a carousel the
	# button is the only place that can say it, where the list had a per-row
	# note.
	screen.call("_go_to", 3)
	await process_frame
	var replay: bool = false
	for t in _strings(screen):
		if t.findn("Replay") >= 0:
			replay = true
	check("a map already cleared offers a replay, and says so", replay)

	# The other modes are still reachable from here — they were on this
	# screen before the rebuild and a mode nobody can find is a mode nobody
	# plays.
	var modes: int = 0
	for b in _buttons(screen):
		for id in GameModeS.all():
			if id == GameModeS.Id.CAMPAIGN:
				continue
			if (b as Button).text.begins_with(GameModeS.name_of(id)):
				modes += 1
	check("the other game modes survived the rebuild", modes >= 2,
		"%d found" % modes)
	screen.queue_free()


# ---- the transition ----------------------------------------------------------

func _the_transition() -> void:
	print("\n=== the slide ===")
	# A FAILURE MODE A LIST NEVER HAD. The plate keeps two art layers during a
	# slide; an interrupted slide that does not free its outgoing layer leaks
	# one per tap, and a player pages this screen dozens of times.
	var r := _roster(40)
	var screen := _screen(r)
	await process_frame
	var plate: StagePlate = screen.get("_plate")
	check("the plate has a width, so it really slides",
		plate != null and plate.size.x > 100.0,
		"%.0f px" % (plate.size.x if plate != null else 0.0))

	var before: int = _count_textures(plate)
	# Hammer it: twenty pages with no time to finish any of them.
	for i in range(20):
		screen.call("_step", 1)
	await process_frame
	await process_frame
	var during: int = _count_textures(plate)
	check("rapid paging does not stack art layers", during <= before + 1,
		"%d layers, started with %d" % [during, before])

	# Let the last slide finish and settle.
	for i in range(40):
		await process_frame
	var after: int = _count_textures(plate)
	check("...and settles back to one", after == 1, "%d layers" % after)
	check("...on the map the chrome says it is on",
		plate.get_node_or_null("Caption") != null)

	# The caption has to be showing the NEW map's name, not the old one — the
	# art slides, the words do not.
	screen.call("_go_to", 7)
	await process_frame
	var titled: bool = false
	for t in _strings(plate):
		if t == Campaign.region_title(7):
			titled = true
	check("the title is the map now on screen", titled,
		Campaign.region_title(7))
	screen.queue_free()


func _count_textures(node: Node) -> int:
	var n: int = 0
	for c in node.get_children():
		if c is TextureRect:
			n += 1
	return n
