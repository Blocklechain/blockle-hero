extends SceneTree
# ------------------------------------------------------------------------------
# THE TRAINING SCREEN, WHICH DID NOT WORK WHILE ITS ENGINE WAS GREEN.
#
# trainingtest.gd covers Training.gd and passes every assertion: the accrual,
# the cap, the hostile clock, the persistence, the balance. None of that was
# the problem. The screen in front of it had two faults that no test of the
# engine could see:
#
#   * EVERY EMPTY SLOT OFFERED ONE BUTTON — "Train <the champion you have
#     selected>". A champion cannot occupy two slots, so with one hero
#     selected the second, third and fourth slots were four taps that all
#     refused. Four slots that can only hold one champion are one slot.
#
#   * THE NUMBERS NEVER MOVED. No timer, no _process: the screen rendered
#     once and froze at "0 xp waiting". For a feature whose whole subject is
#     elapsed time, a frozen clock is indistinguishable from a feature that
#     does nothing at all — which is exactly how it was reported.
#
# Both are UI-only, both read as "training is broken", and both are asserted
# here by pressing the real buttons on the real screen.
# ------------------------------------------------------------------------------

const TrainingS := preload("res://scripts/game/Training.gd")
const TrainingScreenS := preload("res://scripts/ui/TrainingScreen.gd")

const HOUR: int = 3600

var _fails: int = 0
var _ran: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _roster() -> Roster:
	var r := Roster.create(HeroRig.animated_heroes(), 1212)
	var heroes: PackedStringArray = HeroRig.animated_heroes()
	for i in range(6):
		if not r.owns(heroes[i]):
			r.owned[heroes[i]] = HeroProgress.create(heroes[i])
	r.wallet.grant(Wallet.Kind.GOLD, 10_000_000, "test")
	return r


func _screen(r: Roster) -> UiScreen:
	var s: UiScreen = TrainingScreenS.new()
	s.roster = r
	s.hero = r.owned_names()[0]
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(s)
	return s


func _init() -> void:
	var design := Vector2i(2532, 1170)
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_root().content_scale_size = design
	get_root().size = design
	await process_frame

	await _filling_every_slot(); _ran += 1
	await _the_clock_moves(); _ran += 1
	await _collecting(); _ran += 1
	print("")
	check("every section ran to completion", _ran == 3, "%d of 3" % _ran)
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


func _buttons(node: Node, out: Array = []) -> Array:
	if node is Button:
		out.append(node)
	for c in node.get_children():
		_buttons(c, out)
	return out


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


# ---- the fault that made it useless ------------------------------------------

func _filling_every_slot() -> void:
	print("\n=== every slot can be filled, with a different champion ===")
	var r := _roster()
	# Open all four, so the test is about the screen and not about gold.
	while r.unlock_slot():
		pass
	var screen := _screen(r)
	await process_frame

	# A PICKER, not a single named button. The old screen's button said
	# "Train <selected champion>" — assert that the champion's name is NOT
	# the only way in, because that is the shape of the bug.
	var choose: Array = []
	for b in _buttons(screen):
		if (b as Button).text == "Choose a champion":
			choose.append(b)
	check("every empty slot offers a picker",
		choose.size() == TrainingS.SLOTS_MAX,
		"%d of %d slots" % [choose.size(), TrainingS.SLOTS_MAX])

	# FILL ALL FOUR, each with a different champion, pressing only what is on
	# screen. This is the assertion that fails on the old screen: slot 2
	# onward had no way to name anybody else.
	var filled: int = 0
	var used: Dictionary = {}
	for slot in range(TrainingS.SLOTS_MAX):
		var open_picker: Button = null
		for b in _buttons(screen):
			if (b as Button).text == "Choose a champion":
				open_picker = b
				break
		if open_picker == null:
			break
		open_picker.pressed.emit()
		await process_frame
		# Any champion row in the picker that is not already training.
		var picked: bool = false
		for b in _buttons(screen):
			var t: String = (b as Button).text
			if t.find("·  level") < 0:
				continue
			(b as Button).pressed.emit()
			await process_frame
			picked = true
			break
		if not picked:
			break
		var sl: TrainingS.Slot = r.slot(slot)
		if sl != null and not sl.is_empty() and not used.has(sl.hero):
			used[sl.hero] = true
			filled += 1
	check("all four slots can be filled from the screen alone",
		filled == TrainingS.SLOTS_MAX,
		"%d of %d filled" % [filled, TrainingS.SLOTS_MAX])
	check("...each with a DIFFERENT champion",
		used.size() == TrainingS.SLOTS_MAX, "%d distinct" % used.size())

	# THE PICKER MUST NOT OFFER SOMEONE ALREADY TRAINING, or it lists choices
	# it then refuses — which is the fault in its first form wearing a
	# different hat.
	var sl0: TrainingS.Slot = r.slot(0)
	var freed: String = sl0.hero
	sl0.hero = ""
	sl0.since = 0
	screen.call("_refresh")
	await process_frame
	var reopen: Button = _labelled(screen, "Choose a champion")
	if reopen != null:
		reopen.pressed.emit()
		await process_frame
		var offered_busy: bool = false
		for b in _buttons(screen):
			var t: String = (b as Button).text
			if t.find("·  level") < 0:
				continue
			for i in range(1, TrainingS.SLOTS_MAX):
				var other: TrainingS.Slot = r.slot(i)
				if other != null and not other.is_empty() \
						and t.begins_with(ChampionName.of(other.hero)):
					offered_busy = true
		check("the picker never offers a champion already training",
			not offered_busy)
		check("...but does offer the one just freed",
			_labelled(screen, "%s  ·  level %d"
				% [ChampionName.of(freed), r.progress(freed).level]) != null,
			ChampionName.of(freed))

	screen.queue_free()


# ---- the fault that made it look dead ----------------------------------------

func _the_clock_moves() -> void:
	print("\n=== the numbers move ===")
	var r := _roster()
	var screen := _screen(r)
	await process_frame

	# A SLOT THAT HAS BEEN RUNNING FOR A WHILE. Started in the past, so there
	# is something to show without waiting hours in a test.
	var who: String = r.owned_names()[0]
	var now: int = int(Time.get_unix_time_from_system())
	r.begin_training(0, who, now - 2 * HOUR)
	screen.call("_refresh")
	await process_frame

	var waiting: Label = screen.find_child("Waiting", true, false) as Label
	check("an occupied slot says how much is waiting", waiting != null,
		waiting.text if waiting != null else "")
	check("...and it is not zero", waiting != null
		and waiting.text.find(" 0 xp") < 0, waiting.text if waiting != null
			else "")
	check("...and says when it stops earning", waiting != null
		and (waiting.text.findn("until full") >= 0
			or waiting.text.findn("Full") >= 0))

	# THE TICK. The screen has a timer, and the timer actually redraws — the
	# old screen had neither, so the text above would be the same forever.
	var timer: Timer = null
	for c in screen.get_children():
		if c is Timer:
			timer = c
	check("the screen has a clock at all", timer != null)
	check("...which is running", timer != null and not timer.is_stopped())

	if timer != null and waiting != null:
		# Wind the slot's start backwards and fire the tick by hand, rather
		# than waiting a real second: the question is whether _on_tick
		# rewrites the label, not whether Godot's Timer works.
		var before: String = waiting.text
		r.slot(0).since = now - 5 * HOUR
		screen.call("_on_tick")
		await process_frame
		check("a tick rewrites the figures", waiting.text != before,
			"'%s' -> '%s'" % [before, waiting.text])

		# AND THE CAP IS SHOWN AS A CAP. A bar that silently stopped is the
		# thing that makes players distrust an idle system.
		r.slot(0).since = now - 400 * HOUR
		screen.call("_on_tick")
		await process_frame
		check("a capped slot says Full rather than a growing number",
			waiting.text.findn("Full") >= 0, waiting.text)
		var bar: ProgressBar = screen.find_child("Fill", true, false) \
			as ProgressBar
		check("...and the bar is full", bar != null
			and is_equal_approx(bar.value, 1.0),
			"%.2f" % (bar.value if bar != null else -1.0))

	screen.queue_free()


# ---- collecting --------------------------------------------------------------

func _collecting() -> void:
	print("\n=== collecting ===")
	var r := _roster()
	while r.unlock_slot():
		pass
	var screen := _screen(r)
	var notices: Array = []
	screen.notified.connect(func(t: String) -> void: notices.append(t))
	var saves: Array = [0]
	screen.state_changed.connect(func() -> void: saves[0] += 1)
	await process_frame

	var now: int = int(Time.get_unix_time_from_system())
	var names: PackedStringArray = r.owned_names()
	for i in range(TrainingS.SLOTS_MAX):
		r.begin_training(i, names[i], now - 6 * HOUR)
	screen.call("_refresh")
	await process_frame

	# ONE TAP, NOT FOUR. Collecting is the single action a player performs
	# every time they open this screen, and four slots meant four taps on it.
	var before: Array = []
	for i in range(TrainingS.SLOTS_MAX):
		before.append(r.progress(names[i]).xp + float(
			r.progress(names[i]).level) * 100000.0)
	var all: Button = screen.find_child("CollectAll", true, false) as Button
	check("there is a Collect all", all != null)
	if all != null:
		all.pressed.emit()
		await process_frame
		var moved: int = 0
		for i in range(TrainingS.SLOTS_MAX):
			var p: HeroProgress = r.progress(names[i])
			if p.xp + float(p.level) * 100000.0 > float(before[i]):
				moved += 1
		check("...and it pays every slot at once",
			moved == TrainingS.SLOTS_MAX,
			"%d of %d champions gained" % [moved, TrainingS.SLOTS_MAX])
		check("...and says what it collected", notices.size() == 1,
			"" if notices.is_empty() else String(notices[0]))
		check("...and asks the shell to save", int(saves[0]) >= 1)

	# Collecting again immediately must pay nothing, and SAY so rather than
	# looking like it worked.
	notices.clear()
	if all != null:
		all.pressed.emit()
		await process_frame
		check("collecting twice pays nothing the second time",
			notices.size() == 1
				and String(notices[0]).findn("Nothing is ready") >= 0,
			"" if notices.is_empty() else String(notices[0]))

	# A slot still has its champion afterwards — collecting is not emptying.
	check("a collected slot keeps its champion",
		not r.slot(0).is_empty(), r.slot(0).hero)

	screen.queue_free()
